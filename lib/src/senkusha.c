// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include <chiaki/senkusha.h>
#include <chiaki/session.h>
#include <chiaki/random.h>
#include <chiaki/time.h>

#include <string.h>
#include <assert.h>

#include "utils.h"
#include "pb_utils.h"

#include <takion.pb.h>
#include <pb_encode.h>
#include <pb_decode.h>
#include <pb.h>
#include <chiaki/takion.h>
#include <chiaki/gkcrypt.h>

#ifndef _WIN32
#include <sys/types.h>
#include <sys/socket.h>
#include <netdb.h>
#include <netinet/in.h>
#endif


#define SENKUSHA_PORT 9297

#define EXPECT_TIMEOUT_MS 5000
#define CONNECT_TIMEOUT_MS 30000

#define SENKUSHA_PING_COUNT_DEFAULT 10
#define EXPECT_PONG_TIMEOUT_MS 1000

// Assuming IPv4, sizeof(ip header) + sizeof(udp header)
#define MTU_UDP_PACKET_ADD 0x1c

#define MTU_AV_PACKET_ADD CHIAKI_TAKION_V7_AV_HEADER_SIZE_BASE

// Amount of bytes to add to AV data size for MTU pings to get the full size of the ip packet for MTU
#define MTU_PING_DATA_ADD (MTU_UDP_PACKET_ADD + MTU_AV_PACKET_ADD)

typedef enum {
	STATE_IDLE,
	STATE_TAKION_CONNECT,
	STATE_EXPECT_STREAMINFO_ACK,
	STATE_EXPECT_BANG,
	STATE_EXPECT_DATA_ACK,
	STATE_EXPECT_PROTOCOL_ACK,
	STATE_EXPECT_PONG,
	STATE_EXPECT_MTU,
	STATE_EXPECT_CLIENT_MTU_COMMAND,
	STATE_EXPECT_BIG_ECHO_COMPLETE
} SenkushaState;

static ChiakiErrorCode senkusha_run_rtt_test(ChiakiSenkusha *senkusha, uint16_t ping_test_index, uint16_t ping_count, uint64_t *rtt_us);
static ChiakiErrorCode senkusha_run_mtu_in_test(ChiakiSenkusha *senkusha, uint32_t min, uint32_t max, uint32_t retries, uint64_t timeout_ms, uint32_t *mtu);
static ChiakiErrorCode senkusha_run_mtu_out_test(ChiakiSenkusha *senkusha, uint32_t mtu_in, uint32_t min, uint32_t max, uint32_t retries, uint64_t timeout_ms, uint32_t *mtu);
static void senkusha_takion_cb(ChiakiTakionEvent *event, void *user);
static void senkusha_takion_data(ChiakiSenkusha *senkusha, ChiakiTakionMessageDataType data_type, uint8_t *buf, size_t buf_size);
static void senkusha_takion_data_ack(ChiakiSenkusha *senkusha, ChiakiSeqNum32 seq_num);
static void senkusha_takion_av(ChiakiSenkusha *senkusha, ChiakiTakionAVPacket *packet);
static ChiakiErrorCode senkusha_set_version(ChiakiSenkusha *senkusha);
static ChiakiErrorCode senkusha_send_big(ChiakiSenkusha *senkusha);
static ChiakiErrorCode senkusha_send_disconnect(ChiakiSenkusha *senkusha);
static ChiakiErrorCode senkusha_send_echo_command(ChiakiSenkusha *senkusha, bool enable);
static ChiakiErrorCode senkusha_send_mtu_command(ChiakiSenkusha *senkusha, tkproto_SenkushaMtuCommand *command);
static ChiakiErrorCode senkusha_send_client_mtu_command(ChiakiSenkusha *senkusha, tkproto_SenkushaClientMtuCommand *command, bool wait_for_ack);
static ChiakiErrorCode senkusha_send_data_wait_for_ack(ChiakiSenkusha *senkusha, uint8_t *buf, size_t buf_size);

CHIAKI_EXPORT ChiakiErrorCode chiaki_senkusha_init(ChiakiSenkusha *senkusha, ChiakiSession *session)
{
	senkusha->session = session;
	senkusha->log = session->log;

	ChiakiErrorCode err = chiaki_mutex_init(&senkusha->state_mutex, false);
	if(err != CHIAKI_ERR_SUCCESS)
		goto error;

	err = chiaki_cond_init(&senkusha->state_cond);
	if(err != CHIAKI_ERR_SUCCESS)
		goto error_state_mutex;

	senkusha->state = STATE_IDLE;
	senkusha->state_finished = false;
	senkusha->state_failed = false;
	senkusha->should_stop = false;
	senkusha->data_ack_seq_num_expected = 0;
	senkusha->ping_tag = 0;
	senkusha->pong_time_us = 0;
	senkusha->protocol_version = 0; // 0 means "not set, use default based on session"
	senkusha->cloud_launch_spec = NULL; // NULL means "not set, use empty string"
	senkusha->sent_big_size = 0;
	senkusha->echo_reassembly_buf = NULL;
	senkusha->echo_reassembly_pos = 0;

	chiaki_key_state_init(&senkusha->takion.key_state);

	return CHIAKI_ERR_SUCCESS;

error_state_mutex:
	chiaki_mutex_fini(&senkusha->state_mutex);
error:
	return err;
}

CHIAKI_EXPORT void chiaki_senkusha_fini(ChiakiSenkusha *senkusha)
{
	chiaki_cond_fini(&senkusha->state_cond);
	chiaki_mutex_fini(&senkusha->state_mutex);
}

static bool state_finished_cond_check(void *user)
{
	ChiakiSenkusha *senkusha = user;
	return senkusha->state_finished || senkusha->should_stop;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_senkusha_run(ChiakiSenkusha *senkusha, uint32_t *mtu_in, uint32_t *mtu_out, uint64_t *rtt_us, chiaki_socket_t *socket)
{
	ChiakiSession *session = senkusha->session;
	ChiakiErrorCode err;

	err = chiaki_mutex_lock(&senkusha->state_mutex);
	assert(err == CHIAKI_ERR_SUCCESS);

#define QUIT(quit_label) do { \
		chiaki_mutex_unlock(&senkusha->state_mutex); \
		goto quit_label; \
	} while(0)

	if(senkusha->should_stop)
	{
		err = CHIAKI_ERR_CANCELED;
		QUIT(quit);
	}

	ChiakiTakionConnectInfo takion_info;
	takion_info.log = senkusha->log;
	if(!socket)
	{
		takion_info.close_socket = true;
		takion_info.sa_len = session->connect_info.host_addrinfo_selected->ai_addrlen;
		takion_info.sa = malloc(takion_info.sa_len);
		if(!takion_info.sa)
		{
			err = CHIAKI_ERR_MEMORY;
			QUIT(quit);
		}

		memcpy(takion_info.sa, session->connect_info.host_addrinfo_selected->ai_addr, takion_info.sa_len);
		// Cloud streaming: use cloud port, Remote Play: use SENKUSHA_PORT
		uint16_t port = (chiaki_service_type_is_cloud(session->service_type) && session->cloud_port > 0) ? session->cloud_port : SENKUSHA_PORT;
		err = set_port(takion_info.sa, htons(port));
		assert(err == CHIAKI_ERR_SUCCESS);
	}
	else
		takion_info.close_socket = false;
	/* Remote Play: DF on (MTU discovery). Cloud: off — matches cloud streamconnection on iOS
	 * (session->dontfrag=false). Android uses IP_MTU_DISCOVER when "on"; iOS uses IP_DONTFRAG
	 * on UDP and datacenter senkusha INIT would not get ack with DF set. */
	takion_info.ip_dontfrag = !chiaki_service_type_is_cloud(session->service_type);

	takion_info.enable_crypt = false;
	takion_info.disable_audio_video = false;
	takion_info.enable_dualsense = session->connect_info.enable_dualsense;
	// Takion INIT: 7 remote play, 9 PS Now cloud, 12 PS Cloud (matches streamconnection.c).
	if(senkusha->protocol_version == 0)
	{
		if(!chiaki_service_type_is_cloud(session->service_type))
			senkusha->protocol_version = 7;
		else if(session->service_type == CHIAKI_SERVICE_TYPE_PSCLOUD)
			senkusha->protocol_version = 12;
		else
			senkusha->protocol_version = 9;
	}
	takion_info.protocol_version = senkusha->protocol_version;
	takion_info.service_type = session->service_type;
	takion_info.psn_wrapper_type = chiaki_service_type_is_cloud(session->service_type) ? session->cloud_psn_wrapper_type : 0;
	takion_info.is_ping_handshake = true; // This is a ping handshake (senkusha)

	takion_info.cb = senkusha_takion_cb;
	takion_info.cb_user = senkusha;

	senkusha->state = STATE_TAKION_CONNECT;
	senkusha->state_finished = false;
	senkusha->state_failed = false;

	err = chiaki_takion_connect(&senkusha->takion, &takion_info, socket);
	if(!socket)
		free(takion_info.sa);
	
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(session->log, "Senkusha connect failed");
		QUIT(quit);
	}

	err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, CONNECT_TIMEOUT_MS, state_finished_cond_check, senkusha);
	assert(err == CHIAKI_ERR_SUCCESS || err == CHIAKI_ERR_TIMEOUT);
	if(!senkusha->state_finished)
	{
		if(err == CHIAKI_ERR_TIMEOUT)
			CHIAKI_LOGE(session->log, "Senkusha connect timeout");

		if(senkusha->should_stop)
			err = CHIAKI_ERR_CANCELED;
		else
			CHIAKI_LOGE(session->log, "Senkusha Takion connect failed");

		QUIT(quit_takion);
	}

	// Skip version setting for cloud streaming (not needed for cloud play)
	if(!chiaki_service_type_is_cloud(session->service_type))
	{
		CHIAKI_LOGI(session->log, "Setting takion versions");

		senkusha->state = STATE_EXPECT_PROTOCOL_ACK;
		senkusha->state_finished = false;
		senkusha->state_failed = false;

		err = senkusha_set_version(senkusha);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(session->log, "Senkusha failed to set takion version");
			QUIT(quit_takion);
		}
		err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, EXPECT_TIMEOUT_MS, state_finished_cond_check, senkusha);
		assert(err == CHIAKI_ERR_SUCCESS || err == CHIAKI_ERR_TIMEOUT);

		if(!senkusha->state_finished)
		{
			if(err == CHIAKI_ERR_TIMEOUT)
				CHIAKI_LOGE(session->log, "Senkusha set takion version receive timeout");

			if(senkusha->should_stop)
				err = CHIAKI_ERR_CANCELED;
			else
				CHIAKI_LOGE(session->log, "Senkusha didn't receive protocol request ack");

			QUIT(quit_takion);
		}

		CHIAKI_LOGI(session->log, "Senkusha successfully set takion version");
	}
	else
	{
		CHIAKI_LOGI(session->log, "Skipping takion version setting for cloud streaming");
	}

	CHIAKI_LOGI(session->log, "Senkusha sending big");

	// For cloud streaming, wait for echoed BIG message (not BANG)
	// For remote play, wait for BANG response
	if(chiaki_service_type_is_cloud(session->service_type))
		senkusha->state = STATE_EXPECT_BIG_ECHO_COMPLETE;
	else
		senkusha->state = STATE_EXPECT_BANG;
	senkusha->state_finished = false;
	senkusha->state_failed = false;
	err = senkusha_send_big(senkusha);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(session->log, "Senkusha failed to send big");
		QUIT(quit_takion);
	}

	if(chiaki_service_type_is_cloud(session->service_type))
	{
		err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, 2000, state_finished_cond_check, senkusha);
		if(!senkusha->state_finished)
			CHIAKI_LOGW(session->log, "Senkusha BIG echo timeout after 2s, proceeding anyway");
		else
			CHIAKI_LOGI(session->log, "Senkusha BIG echo complete, proceeding to RTT test");
		err = senkusha_run_rtt_test(senkusha, 0, SENKUSHA_PING_COUNT_DEFAULT, rtt_us);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha Ping Test failed");
			goto disconnect;
		}
	}
	else
	{
		// For remote play: wait for BANG response
		err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, EXPECT_TIMEOUT_MS, state_finished_cond_check, senkusha);
		assert(err == CHIAKI_ERR_SUCCESS || err == CHIAKI_ERR_TIMEOUT);

		if(!senkusha->state_finished)
		{
			if(err == CHIAKI_ERR_TIMEOUT)
				CHIAKI_LOGE(session->log, "Senkusha bang receive timeout");

			if(senkusha->should_stop)
				err = CHIAKI_ERR_CANCELED;
			else
				CHIAKI_LOGE(session->log, "Senkusha didn't receive bang");

			QUIT(quit_takion);
		}

		CHIAKI_LOGI(session->log, "Senkusha successfully received bang");

		err = senkusha_run_rtt_test(senkusha, 0, SENKUSHA_PING_COUNT_DEFAULT, rtt_us);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha Ping Test failed");
			goto disconnect;
		}
	}

	uint64_t mtu_timeout_ms = (*rtt_us * 5) / 1000;
	if(mtu_timeout_ms < 5)
		mtu_timeout_ms = 5;
	// CLOUD PLAY: Use longer timeout for large MTU packets
	// - Minimum 200ms (large packets need more processing/transmission time)
	// - Maximum 1000ms
	// Remote play: Cap at 500ms
	if(chiaki_service_type_is_cloud(session->service_type))
	{
		if(mtu_timeout_ms < 200)
			mtu_timeout_ms = 200; // Minimum 200ms for cloud play MTU tests
		if(mtu_timeout_ms > 1000)
			mtu_timeout_ms = 1000;
	}
	else
	{
		if(mtu_timeout_ms > 500)
			mtu_timeout_ms = 500;
	}

	err = senkusha_run_mtu_in_test(senkusha, 576, 1454, 3, mtu_timeout_ms, mtu_in);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha MTU in test failed");
		goto disconnect;
	}

	err = senkusha_run_mtu_out_test(senkusha, *mtu_in, 576, 1454, 3, mtu_timeout_ms, mtu_out);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha MTU out test failed");
		goto disconnect;
	}

disconnect:
	CHIAKI_LOGI(session->log, "Senkusha is disconnecting");

	senkusha_send_disconnect(senkusha);
	chiaki_mutex_unlock(&senkusha->state_mutex);

quit_takion:
	chiaki_takion_close(&senkusha->takion);
	CHIAKI_LOGI(session->log, "Senkusha closed takion");
quit:
	free(senkusha->echo_reassembly_buf);
	senkusha->echo_reassembly_buf = NULL;
	return err;
}

static ChiakiErrorCode senkusha_run_rtt_test(ChiakiSenkusha *senkusha, uint16_t ping_test_index, uint16_t ping_count, uint64_t *rtt_us)
{
	CHIAKI_LOGI(senkusha->log, "Senkusha Ping Test with count %u starting", (unsigned int)ping_count);

	ChiakiErrorCode err = senkusha_send_echo_command(senkusha, true);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha Ping Test failed because sending echo command (true) failed");
		return err;
	}

	CHIAKI_LOGI(senkusha->log, "Senkusha enabled echo");

	uint64_t rtt_us_acc = 0;
	uint64_t pings_successful = 0;
	for(uint16_t ping_index=0; ping_index<ping_count; ping_index++)
	{
		CHIAKI_LOGI(senkusha->log, "Senkusha sending Ping %u of test index %u", (unsigned int)ping_index, (unsigned int)ping_test_index);

		ChiakiTakionAVPacket av_packet = { 0 };
		av_packet.codec = 0xff;
		av_packet.is_video = false;
		av_packet.frame_index = ping_test_index;
		av_packet.unit_index = ping_index;
		av_packet.units_in_frame_total = 0x800; // or 0

		uint8_t data[0x224];
		memset(data, 0, sizeof(data));

		size_t header_size;
		err = chiaki_takion_v7_av_packet_format_header(data, sizeof(data), &header_size, &av_packet);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha failed to format AV Header");
			return err;
		}

		uint32_t tag = chiaki_random_32();
		*((chiaki_unaligned_uint32_t *)(data + header_size + 4)) = htonl(tag);

		senkusha->state = STATE_EXPECT_PONG;
		senkusha->state_finished = false;
		senkusha->state_failed = false;
		senkusha->ping_test_index = ping_test_index;
		senkusha->ping_index = ping_index;
		senkusha->ping_tag = tag;

		uint64_t time_start_us = chiaki_time_now_monotonic_us();

		CHIAKI_LOGV(senkusha->log, "[OUTGOING PING] Sending ping packet: tag=0x%x, size=%zu, ping_test_index=%u, ping_index=%u", 
		            tag, sizeof(data), ping_test_index, ping_index);
		
		// For cloud mode, add PSN wrapper to ping packets (skip wrapper for PSCloud)
		uint8_t *ping_data = data;
		size_t ping_data_size = sizeof(data);
		uint8_t wrapped_data[sizeof(data) + 4];
		// Add wrapper for PSNOW, but skip for PSCloud
		bool should_add_wrapper = false;
		if(chiaki_service_type_is_cloud(senkusha->session->service_type))
		{
			should_add_wrapper = senkusha->session->service_type != CHIAKI_SERVICE_TYPE_PSCLOUD;
			CHIAKI_LOGV(senkusha->log, "[OUTGOING PING] service_type=%s, psn_wrapper=%s",
				chiaki_service_type_string(senkusha->session->service_type),
				should_add_wrapper ? "enabled" : "disabled");
		}
		
		if(should_add_wrapper)
		{
			// Add 4-byte PSN wrapper at the beginning
			memmove(wrapped_data + 4, data, sizeof(data));
			wrapped_data[0] = 0x00;
			wrapped_data[1] = 0x00;
			wrapped_data[2] = 0x00;
			wrapped_data[3] = senkusha->takion.psn_wrapper_type;
			ping_data = wrapped_data;
			ping_data_size = sizeof(data) + 4;
		}
		
		err = chiaki_takion_send_raw(&senkusha->takion, ping_data, ping_data_size);
		if(err != CHIAKI_ERR_SUCCESS)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha failed to send ping");
			return err;
		}

		err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, EXPECT_PONG_TIMEOUT_MS, state_finished_cond_check, senkusha);
		assert(err == CHIAKI_ERR_SUCCESS || err == CHIAKI_ERR_TIMEOUT);

		if(!senkusha->state_finished)
		{
			if(err == CHIAKI_ERR_TIMEOUT)
				CHIAKI_LOGE(senkusha->log, "Senkusha pong receive timeout");

			if(senkusha->should_stop)
				return CHIAKI_ERR_CANCELED;
			else
				CHIAKI_LOGE(senkusha->log, "Senkusha failed to receive pong");

			continue;
		}

		uint64_t delta_us = senkusha->pong_time_us - time_start_us;
		rtt_us_acc += delta_us;
		pings_successful += 1;
		CHIAKI_LOGI(senkusha->log, "Senkusha received Pong, RTT = %.3f ms", (float)delta_us * 0.001f);
	}

	err = senkusha_send_echo_command(senkusha, false);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha Ping Test failed because sending echo command (false) failed");
		return err;
	}

	CHIAKI_LOGI(senkusha->log, "Senkusha disabled echo");

	if(pings_successful < 1)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha Ping test did not receive a single Pong");
		return CHIAKI_ERR_UNKNOWN;
	}

	*rtt_us = rtt_us_acc / pings_successful;
	CHIAKI_LOGI(senkusha->log, "Senkusha determined average RTT = %.3f ms", (float)(*rtt_us) * 0.001f);

	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode senkusha_run_mtu_in_test(ChiakiSenkusha *senkusha, uint32_t min, uint32_t max, uint32_t retries, uint64_t timeout_ms, uint32_t *mtu)
{
	CHIAKI_LOGI(senkusha->log, "Senkusha starting MTU in test with min %u, max %u, retries %u, timeout %llu ms",
			(unsigned int)min, (unsigned int)max, (unsigned int)retries, (unsigned long long)timeout_ms);

	uint32_t cur = max;
	uint32_t request_id = 0;
	while((max - min) > 1)
	{
		bool success = false;
		for(uint32_t attempt=0; attempt<retries; attempt++)
		{
			senkusha->state = STATE_EXPECT_MTU;
			senkusha->state_finished = false;
			senkusha->state_failed = false;
			senkusha->mtu_id = ++request_id;

			tkproto_SenkushaMtuCommand mtu_cmd = { 0 };
			mtu_cmd.id = request_id;
			mtu_cmd.mtu_req = cur;
			mtu_cmd.num = 1;
			ChiakiErrorCode err = senkusha_send_mtu_command(senkusha, &mtu_cmd);
			if(err != CHIAKI_ERR_SUCCESS)
			{
				CHIAKI_LOGE(senkusha->log, "Senkusha failed to send MTU command");
				return err;
			}

			CHIAKI_LOGI(senkusha->log, "Senkusha MTU request %u (min %u, max %u), id %u, attempt %u",
					(unsigned int)cur, (unsigned int)min, (unsigned int)max, (unsigned int)request_id, (unsigned int)attempt);

			err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, timeout_ms, state_finished_cond_check, senkusha);
			assert(err == CHIAKI_ERR_SUCCESS || err == CHIAKI_ERR_TIMEOUT);

			if(!senkusha->state_finished)
			{
				if(err == CHIAKI_ERR_TIMEOUT)
				{
					CHIAKI_LOGI(senkusha->log, "Senkusha MTU %u timeout", (unsigned int)cur);
					continue;
				}

				if(senkusha->should_stop)
					return CHIAKI_ERR_CANCELED;
				else
					CHIAKI_LOGE(senkusha->log, "Senkusha failed to receive MTU response");
			}

			CHIAKI_LOGI(senkusha->log, "Senkusha MTU %u success", (unsigned int)cur);
			success = true;
			break;
		}

		if(success)
			min = cur;
		else
			max = cur;
		cur = min + (max - min) / 2;
	}

	CHIAKI_LOGI(senkusha->log, "Senkusha determined inbound MTU %u", (unsigned int)min);
	*mtu = min;

	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode senkusha_run_mtu_out_test(ChiakiSenkusha *senkusha, uint32_t mtu_in, uint32_t min, uint32_t max, uint32_t retries, uint64_t timeout_ms, uint32_t *mtu)
{
	if(min < 8 + MTU_PING_DATA_ADD || max < min || mtu_in < min || mtu_in > max)
		return CHIAKI_ERR_INVALID_DATA;

	CHIAKI_LOGI(senkusha->log, "Senkusha starting MTU out test with min %u, max %u, retries %u, timeout %llu ms",
				(unsigned int)min, (unsigned int)max, (unsigned int)retries, (unsigned long long)timeout_ms);

	senkusha->state = STATE_EXPECT_CLIENT_MTU_COMMAND;
	senkusha->state_finished = false;
	senkusha->state_failed = false;
	senkusha->mtu_id = 1;

	tkproto_SenkushaClientMtuCommand client_mtu_cmd;
	client_mtu_cmd.id = senkusha->mtu_id;
	client_mtu_cmd.state = true;
	client_mtu_cmd.mtu_req = mtu_in;
	client_mtu_cmd.has_mtu_down = true;
	client_mtu_cmd.mtu_down = mtu_in;
	ChiakiErrorCode err = senkusha_send_client_mtu_command(senkusha, &client_mtu_cmd, false);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha failed to send client MTU command");
		return err;
	}

	CHIAKI_LOGI(senkusha->log, "Senkusha sent initial client MTU command");

	err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, EXPECT_TIMEOUT_MS, state_finished_cond_check, senkusha);
	assert(err == CHIAKI_ERR_SUCCESS || err == CHIAKI_ERR_TIMEOUT);

	if(!senkusha->state_finished)
	{
		if(err == CHIAKI_ERR_TIMEOUT)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha Client MTU Command from server receive timeout");
			return err;
		}

		if(senkusha->should_stop)
			return CHIAKI_ERR_CANCELED;
		else
			CHIAKI_LOGE(senkusha->log, "Senkusha failed to receive Client MTU command");

		return CHIAKI_ERR_UNKNOWN;
	}

	size_t packet_buf_size = max - MTU_UDP_PACKET_ADD;
	uint8_t *packet_buf = malloc(packet_buf_size);
	if(!packet_buf)
		return CHIAKI_ERR_MEMORY;
	memset(packet_buf, 0, MTU_AV_PACKET_ADD + 8);
	static const char padding[] = { 'C', 'H', 'I', 'A', 'K', 'I' };
	for(size_t i=0; i<packet_buf_size - (MTU_AV_PACKET_ADD + 8); i++)
		packet_buf[i + (MTU_AV_PACKET_ADD + 8)] = padding[i % sizeof(padding)];

	err = CHIAKI_ERR_SUCCESS;

	uint32_t cur = mtu_in;
	while((max - min) > 1)
	{
		bool success = false;
		for(uint32_t attempt=0; attempt<retries; attempt++)
		{
			uint32_t tag = chiaki_random_32();

			senkusha->state = STATE_EXPECT_PONG;
			senkusha->state_finished = false;
			senkusha->state_failed = false;
			senkusha->ping_tag = tag;
			senkusha->ping_test_index = 0;
			senkusha->ping_index = (uint16_t)attempt;

			ChiakiTakionAVPacket av_packet = { 0 };
			av_packet.codec = 0xff;
			av_packet.is_video = false;
			av_packet.frame_index = senkusha->ping_test_index;
			av_packet.unit_index = senkusha->ping_index;
			av_packet.units_in_frame_total = 0x800;

			size_t header_size;
			err = chiaki_takion_v7_av_packet_format_header(packet_buf, packet_buf_size, &header_size, &av_packet);
			if(err != CHIAKI_ERR_SUCCESS)
			{
				CHIAKI_LOGE(senkusha->log, "Senkusha failed to format AV Header");
				goto beach;
			}
			assert(header_size == MTU_AV_PACKET_ADD);

			*((chiaki_unaligned_uint32_t *)(packet_buf + MTU_AV_PACKET_ADD)) = 0;
			*((chiaki_unaligned_uint32_t *)(packet_buf + MTU_AV_PACKET_ADD + 4)) = htonl(tag);

			CHIAKI_LOGI(senkusha->log, "Senkusha MTU %u out ping attempt %u", (unsigned int)cur, (unsigned int)attempt);

			// CLOUD PLAY: Add PSN wrapper for MTU test packets (skip wrapper for PSCloud)
			size_t mtu_packet_size = cur - MTU_UDP_PACKET_ADD;
			uint8_t *mtu_packet_data = packet_buf;
			uint8_t mtu_wrapped_data[1500]; // Max MTU size
			// Add wrapper for PSNOW, but skip for PSCloud
			if(chiaki_service_type_is_cloud(senkusha->session->service_type) &&
			   senkusha->session->service_type != CHIAKI_SERVICE_TYPE_PSCLOUD)
			{
				// Add 4-byte PSN wrapper at the beginning
				if(mtu_packet_size + 4 > sizeof(mtu_wrapped_data))
				{
					CHIAKI_LOGE(senkusha->log, "Senkusha MTU packet too large for wrapper buffer");
					err = CHIAKI_ERR_INVALID_DATA;
					goto beach;
				}
				memmove(mtu_wrapped_data + 4, packet_buf, mtu_packet_size);
				mtu_wrapped_data[0] = 0x00;
				mtu_wrapped_data[1] = 0x00;
				mtu_wrapped_data[2] = 0x00;
				mtu_wrapped_data[3] = senkusha->takion.psn_wrapper_type;
				mtu_packet_data = mtu_wrapped_data;
				mtu_packet_size += 4;
			}

			err = chiaki_takion_send_raw(&senkusha->takion, mtu_packet_data, mtu_packet_size);
			if(err != CHIAKI_ERR_SUCCESS)
			{
				CHIAKI_LOGE(senkusha->log, "Senkusha failed to send ping");
				err = CHIAKI_ERR_TIMEOUT;
			}
			else
			{
				err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, timeout_ms, state_finished_cond_check, senkusha);
			}

			assert(err == CHIAKI_ERR_SUCCESS || err == CHIAKI_ERR_TIMEOUT);

			// Note: mutex is already locked here (chiaki_cond_timedwait_pred re-acquires it before returning)
			if(senkusha->state_failed)
			{
				if(chiaki_service_type_is_cloud(senkusha->session->service_type))
				{
					CHIAKI_LOGW(senkusha->log, "Senkusha [CLOUD] MTU pong %u validation failed (packet may have been received but rejected)", (unsigned int)cur);
				}
				else
				{
					CHIAKI_LOGW(senkusha->log, "Senkusha MTU pong %u validation failed", (unsigned int)cur);
				}
				continue;
			}
			
			if(!senkusha->state_finished)
			{
				if(err == CHIAKI_ERR_TIMEOUT)
				{
					if(chiaki_service_type_is_cloud(senkusha->session->service_type))
					{
						CHIAKI_LOGI(senkusha->log, "Senkusha [CLOUD] MTU pong %u timeout (timeout=%llu ms, packet_size=%u)", 
								(unsigned int)cur, (unsigned long long)timeout_ms, (unsigned int)(cur - MTU_UDP_PACKET_ADD));
					}
					else
					{
						CHIAKI_LOGI(senkusha->log, "Senkusha MTU pong %u timeout", (unsigned int)cur);
					}
					continue;
				}

				if(senkusha->should_stop)
				{
					err = CHIAKI_ERR_CANCELED;
					goto beach;
				}
				else
					CHIAKI_LOGE(senkusha->log, "Senkusha failed to receive MTU pong");
			}

			CHIAKI_LOGI(senkusha->log, "Senkusha MTU ping %u success", (unsigned int)cur);
			success = true;
			break;
		}

		if(success)
			min = cur;
		else
			max = cur;
		cur = min + (max - min) / 2;
	}

	CHIAKI_LOGI(senkusha->log, "Senkusha determined outbound MTU %u", (unsigned int)min);
	*mtu = min;

	CHIAKI_LOGI(senkusha->log, "Senkusha sending final Client MTU Command");
	client_mtu_cmd.id = 2;
	client_mtu_cmd.state = false;
	client_mtu_cmd.mtu_req = max;
	client_mtu_cmd.has_mtu_down = true;
	client_mtu_cmd.mtu_down = mtu_in;
	err = senkusha_send_client_mtu_command(senkusha, &client_mtu_cmd, true);
	if(err != CHIAKI_ERR_SUCCESS)
		CHIAKI_LOGE(senkusha->log, "Senkusha failed to send client MTU command");

beach:
	free(packet_buf);
	return err;
}

static void senkusha_takion_cb(ChiakiTakionEvent *event, void *user)
{
	ChiakiSenkusha *senkusha = user;
	switch(event->type)
	{
		case CHIAKI_TAKION_EVENT_TYPE_CONNECTED:
		case CHIAKI_TAKION_EVENT_TYPE_DISCONNECT:
			chiaki_mutex_lock(&senkusha->state_mutex);
			if(senkusha->state == STATE_TAKION_CONNECT)
			{
				senkusha->state_finished = event->type == CHIAKI_TAKION_EVENT_TYPE_CONNECTED;
				senkusha->state_failed = event->type == CHIAKI_TAKION_EVENT_TYPE_DISCONNECT;
				chiaki_cond_signal(&senkusha->state_cond);
			}
			chiaki_mutex_unlock(&senkusha->state_mutex);
			break;
		case CHIAKI_TAKION_EVENT_TYPE_DATA:
			senkusha_takion_data(senkusha, event->data.data_type, event->data.buf, event->data.buf_size);
			break;
		case CHIAKI_TAKION_EVENT_TYPE_DATA_ACK:
			senkusha_takion_data_ack(senkusha, event->data_ack.seq_num);
			break;
		case CHIAKI_TAKION_EVENT_TYPE_AV:
			senkusha_takion_av(senkusha, event->av);
			break;
		default:
			break;
	}
}

static void senkusha_takion_data(ChiakiSenkusha *senkusha, ChiakiTakionMessageDataType data_type, uint8_t *buf, size_t buf_size)
{
	chiaki_mutex_lock(&senkusha->state_mutex);
	if(senkusha->state == STATE_EXPECT_BIG_ECHO_COMPLETE && senkusha->echo_reassembly_buf)
	{
		size_t cap = senkusha->sent_big_size + 256;
		size_t remaining = cap > senkusha->echo_reassembly_pos ? cap - senkusha->echo_reassembly_pos : 0;
		size_t to_copy = buf_size < remaining ? buf_size : remaining;
		if(to_copy > 0)
		{
			memcpy(senkusha->echo_reassembly_buf + senkusha->echo_reassembly_pos, buf, to_copy);
			senkusha->echo_reassembly_pos += to_copy;
		}

		if(senkusha->echo_reassembly_pos >= senkusha->sent_big_size)
		{
			const char *spec = senkusha->cloud_launch_spec;
			size_t spec_len = spec ? strlen(spec) : 0;
			bool validated = false;
			if(spec_len > 0 && senkusha->echo_reassembly_pos >= spec_len)
			{
				for(size_t i = 0; i <= senkusha->echo_reassembly_pos - spec_len; i++)
				{
					if(memcmp(senkusha->echo_reassembly_buf + i, spec, spec_len) == 0)
					{
						validated = true;
						break;
					}
				}
			}
			if(validated)
				CHIAKI_LOGI(senkusha->log, "Senkusha BANG received: session key validated (%zu bytes in %zu byte response)",
					spec_len, senkusha->echo_reassembly_pos);
			else
				CHIAKI_LOGW(senkusha->log, "Senkusha BANG received but session key not found in %zu byte response",
					senkusha->echo_reassembly_pos);
			senkusha->state_finished = true;
			chiaki_cond_signal(&senkusha->state_cond);
		}
		chiaki_mutex_unlock(&senkusha->state_mutex);
		return;
	}
	chiaki_mutex_unlock(&senkusha->state_mutex);

	if(data_type != CHIAKI_TAKION_MESSAGE_DATA_TYPE_PROTOBUF)
		return;

	tkproto_TakionMessage msg;
	memset(&msg, 0, sizeof(msg));

	pb_istream_t stream = pb_istream_from_buffer(buf, buf_size);
	bool r = pb_decode(&stream, tkproto_TakionMessage_fields, &msg);
	if(!r)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha failed to decode data protobuf (buf_size=%zu)", buf_size);
		return;
	}

	chiaki_mutex_lock(&senkusha->state_mutex);
	if(senkusha->state == STATE_EXPECT_BANG)
	{
		if(msg.type != tkproto_TakionMessage_PayloadType_BANG || !msg.has_bang_payload)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha expected bang payload but received something else");
		}
		else
		{
			senkusha->state_finished = true;
			chiaki_cond_signal(&senkusha->state_cond);
		}
	}
	else if(senkusha->state == STATE_EXPECT_PROTOCOL_ACK)
	{
		if(msg.type != tkproto_TakionMessage_PayloadType_TAKIONPROTOCOLREQUESTACK || !msg.has_takion_protocol_request_ack)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha expected protocol request ack but received something else");
		}
		else
		{
			senkusha->state_finished = true;
			chiaki_cond_signal(&senkusha->state_cond);
		}
	}
	else if(senkusha->state == STATE_EXPECT_CLIENT_MTU_COMMAND)
	{
		if(msg.type != tkproto_TakionMessage_PayloadType_SENKUSHA
			|| !msg.has_senkusha_payload
			|| msg.senkusha_payload.command != tkproto_SenkushaPayload_Command_CLIENT_MTU_COMMAND
			|| !msg.senkusha_payload.has_client_mtu_command
			|| msg.senkusha_payload.client_mtu_command.id != senkusha->mtu_id)
		{
			// There might be another MTU_COMMAND from the server, which we ignore, but this is not an error.
			if(msg.type != tkproto_TakionMessage_PayloadType_SENKUSHA
				|| !msg.has_senkusha_payload
				|| msg.senkusha_payload.command != tkproto_SenkushaPayload_Command_MTU_COMMAND)
			{
				CHIAKI_LOGE(senkusha->log, "Senkusha expected Client MTU Command with matching id but received something else");
			}
		}
		else
		{
			CHIAKI_LOGI(senkusha->log, "Senkusha received expected Client MTU Command");
			senkusha->state_finished = true;
			chiaki_cond_signal(&senkusha->state_cond);
		}
	}
	chiaki_mutex_unlock(&senkusha->state_mutex);
}

static void senkusha_takion_data_ack(ChiakiSenkusha *senkusha, ChiakiSeqNum32 seq_num)
{
	chiaki_mutex_lock(&senkusha->state_mutex);
	if(senkusha->state == STATE_EXPECT_DATA_ACK && senkusha->data_ack_seq_num_expected == seq_num)
	{
		senkusha->state_finished = true;
		chiaki_mutex_unlock(&senkusha->state_mutex);
		chiaki_cond_signal(&senkusha->state_cond);
	}
	else
		chiaki_mutex_unlock(&senkusha->state_mutex);
}

static void senkusha_takion_av(ChiakiSenkusha *senkusha, ChiakiTakionAVPacket *packet)
{
	uint64_t time_us = chiaki_time_now_monotonic_us();

	ChiakiErrorCode err = chiaki_mutex_lock(&senkusha->state_mutex);
	assert(err == CHIAKI_ERR_SUCCESS);

	if(senkusha->state == STATE_EXPECT_PONG)
	{
		// CLOUD PLAY: Pong validation differs from remote play
		// - unit_index may not be echoed correctly (often 0)
		// - tag is at offset 3 instead of 4
		bool validation_failed = false;
		bool is_video_fail = packet->is_video;
		bool frame_index_fail = packet->frame_index != senkusha->ping_test_index;
		bool unit_index_fail;
		bool data_size_fail = packet->data_size < 8;
		
		if(chiaki_service_type_is_cloud(senkusha->session->service_type))
		{
			// Cloud play: unit_index validation is relaxed (pongs often return 0)
			// Only validate frame_index, is_video, and data_size
			unit_index_fail = false; // Skip unit_index check for cloud play
			validation_failed = is_video_fail || frame_index_fail || data_size_fail;
			
			if(validation_failed)
			{
				CHIAKI_LOGW(senkusha->log, "Senkusha [CLOUD] received invalid Pong %u/%u, size: %#llx (expected %u/%u, is_video=%d, frame_idx_fail=%d, size_fail=%d)",
						(unsigned int)packet->frame_index, (unsigned int)packet->unit_index, (unsigned long long)packet->data_size,
						(unsigned int)senkusha->ping_test_index, (unsigned int)senkusha->ping_index,
						is_video_fail ? 1 : 0, frame_index_fail ? 1 : 0, data_size_fail ? 1 : 0);
				CHIAKI_LOGV(senkusha->log, "Senkusha [CLOUD] pong packet details: packet_index=%u, codec=%#x, is_haptics=%d, units_in_frame_total=%u, units_in_frame_fec=%u",
						(unsigned int)packet->packet_index, packet->codec, packet->is_haptics ? 1 : 0,
						(unsigned int)packet->units_in_frame_total, (unsigned int)packet->units_in_frame_fec);
				if(packet->data_size > 0 && packet->data_size <= 64)
				{
					CHIAKI_LOGV(senkusha->log, "Senkusha [CLOUD] pong data (first %zu bytes):", packet->data_size);
					chiaki_log_hexdump(senkusha->log, CHIAKI_LOG_VERBOSE, packet->data, packet->data_size);
				}
			}
		}
		else
		{
			// REMOTE PLAY: Full validation including unit_index
			unit_index_fail = packet->unit_index != senkusha->ping_index;
			validation_failed = is_video_fail || frame_index_fail || unit_index_fail || data_size_fail;
			
			if(validation_failed)
			{
				CHIAKI_LOGW(senkusha->log, "Senkusha received invalid Pong %u/%u, size: %#llx",
						(unsigned int)packet->frame_index, (unsigned int)packet->unit_index, (unsigned long long)packet->data_size);
			}
		}
		
		if(validation_failed)
			goto beach;

		// Tag location: Cloud streaming uses offset 3, Remote play uses offset 4
		uint32_t tag;
		if(chiaki_service_type_is_cloud(senkusha->session->service_type))
		{
			// Cloud play (v9): Tag is at offset 3 in data portion
			if(packet->data_size >= 7)
			{
				tag = ntohl(*((uint32_t *)(packet->data + 3)));
			}
			else
			{
				CHIAKI_LOGW(senkusha->log, "Senkusha [CLOUD] pong data too small for tag read (size: %zu)", packet->data_size);
				goto beach;
			}
		}
		else
		{
			// Remote play (v7): Tag is at offset 4 in data portion
			if(packet->data_size >= 8)
			{
				tag = ntohl(*((uint32_t *)(packet->data + 4)));
			}
			else
			{
				CHIAKI_LOGW(senkusha->log, "Senkusha pong data too small for tag read (size: %zu)", packet->data_size);
				goto beach;
			}
		}
		
		if(tag != senkusha->ping_tag)
		{
			if(chiaki_service_type_is_cloud(senkusha->session->service_type))
			{
				CHIAKI_LOGW(senkusha->log, "Senkusha [CLOUD] received Pong with invalid tag: got 0x%x, expected 0x%x", tag, senkusha->ping_tag);
				if(packet->data_size >= 8)
				{
					CHIAKI_LOGV(senkusha->log, "Senkusha [CLOUD] pong tag data (first 8 bytes):");
					chiaki_log_hexdump(senkusha->log, CHIAKI_LOG_VERBOSE, packet->data, 8);
				}
			}
			else
			{
				CHIAKI_LOGW(senkusha->log, "Senkusha received Pong with invalid tag");
			}
			goto beach;
		}

		if(chiaki_service_type_is_cloud(senkusha->session->service_type))
		{
			CHIAKI_LOGV(senkusha->log, "Senkusha [CLOUD] received valid Pong %u/%u, size: %#llx, tag: 0x%x",
					(unsigned int)packet->frame_index, (unsigned int)packet->unit_index,
					(unsigned long long)packet->data_size, tag);
		}

		senkusha->pong_time_us = time_us;
		senkusha->state_finished = true;
		chiaki_mutex_unlock(&senkusha->state_mutex);
		chiaki_cond_signal(&senkusha->state_cond);
		return;
	}
	else if(senkusha->state == STATE_EXPECT_MTU)
	{
		//CHIAKI_LOGD(senkusha->log, "Senkusha received av while expecting mtu");
		//chiaki_log_hexdump(senkusha->log, CHIAKI_LOG_DEBUG, packet->data, packet->data_size);
		//CHIAKI_LOGD(senkusha->log, "packet index: %u, frame index: %u, unit index: %u, units in frame: %u", packet->packet_index, packet->frame_index, packet->unit_index, packet->units_in_frame_total);

		if(!packet->is_video
			|| packet->frame_index != senkusha->mtu_id)
		{
			CHIAKI_LOGW(senkusha->log, "Senkusha received invalid MTU response %u, size: %#llx, is video: %d",
					(unsigned int)packet->frame_index, (unsigned long long)packet->data_size, packet->is_video ? 1 : 0);
			goto beach;
		}

		senkusha->state_finished = true;
		chiaki_mutex_unlock(&senkusha->state_mutex);
		chiaki_cond_signal(&senkusha->state_cond);
		return;
	}

beach:
	chiaki_mutex_unlock(&senkusha->state_mutex);
}

static ChiakiErrorCode senkusha_set_version(ChiakiSenkusha *senkusha)
{
	tkproto_TakionMessage msg;
	memset(&msg, 0, sizeof(msg));
	List versions;
	// Protocol version 9 for TAKIONPROTOCOLREQUEST (INIT stays at 7)
	versions.items[0] = 9;
	versions.num_items = 1;
	msg.type = tkproto_TakionMessage_PayloadType_TAKIONPROTOCOLREQUEST;
	msg.has_takion_protocol_request = true;
	msg.takion_protocol_request.supported_takion_versions.arg = &versions;
	msg.takion_protocol_request.supported_takion_versions.funcs.encode = chiaki_pb_encode_list;

	uint8_t buf[12];
	size_t buf_size;

	pb_ostream_t stream = pb_ostream_from_buffer(buf, sizeof(buf));
	bool pbr = pb_encode(&stream, tkproto_TakionMessage_fields, &msg);
	if(!pbr)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha set version protobuf encoding failed");
		return CHIAKI_ERR_UNKNOWN;
	}
	buf_size = stream.bytes_written;
	ChiakiErrorCode err = chiaki_takion_send_message_data(&senkusha->takion, 1, 1, buf, buf_size, NULL);
	return err;
}

static ChiakiErrorCode senkusha_send_big(ChiakiSenkusha *senkusha)
{
	ChiakiSession *session = senkusha->session;
	
	// ORIGINAL REMOTE PLAY PATH - unchanged logic (no session key)
	// Use this path only for Remote Play
	if(session->service_type == CHIAKI_SERVICE_TYPE_REMOTE_PLAY)
	{
		tkproto_TakionMessage msg;
		memset(&msg, 0, sizeof(msg));

		msg.type = tkproto_TakionMessage_PayloadType_BIG;
		msg.has_big_payload = true;
		msg.big_payload.client_version = 9;
		msg.big_payload.session_key.arg = "";
		msg.big_payload.session_key.funcs.encode = chiaki_pb_encode_string;
		msg.big_payload.launch_spec.arg = "";
		msg.big_payload.launch_spec.funcs.encode = chiaki_pb_encode_string;
		msg.big_payload.encrypted_key.arg = "";
		msg.big_payload.encrypted_key.funcs.encode = chiaki_pb_encode_string;

		uint8_t buf[12];
		pb_ostream_t stream = pb_ostream_from_buffer(buf, sizeof(buf));
		bool pbr = pb_encode(&stream, tkproto_TakionMessage_fields, &msg);
		if(!pbr)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha big protobuf encoding failed");
			return CHIAKI_ERR_UNKNOWN;
		}

		size_t buf_size = stream.bytes_written;
		return chiaki_takion_send_message_data(&senkusha->takion, 1, 1, buf, buf_size, NULL);
	}
	
	// Cloud streaming ping path - follows streamconnection.c structure closely
	{
		// Cloud mode: get session key (x-gaikai-session) - this will go in session_key field (field 2)
		const char *launch_spec_str = (senkusha->cloud_launch_spec && senkusha->cloud_launch_spec[0] != '\0') 
			? senkusha->cloud_launch_spec : "";
		
		tkproto_TakionMessage msg;
		memset(&msg, 0, sizeof(msg));

		msg.type = tkproto_TakionMessage_PayloadType_BIG;
		msg.has_big_payload = true;
		msg.big_payload.client_version = senkusha->protocol_version;
		CHIAKI_LOGV(session->log, "Sending BIG with client_version=%u", senkusha->protocol_version);
		
		// For ping, encode launch_spec data as session_key (field 2)
		// This matches the working capture: launch_spec data goes in session_key
		msg.big_payload.session_key.arg = (void*)launch_spec_str;
		msg.big_payload.session_key.funcs.encode = chiaki_pb_encode_string;
		
		// For ping, also encode launch_spec as field 3 with empty string (1a 00)
		// The actual data is in session_key above, but field 3 must be present as empty
		static const char empty_launch_spec[] = "";
		msg.big_payload.launch_spec.arg = (void*)empty_launch_spec;
		msg.big_payload.launch_spec.funcs.encode = chiaki_pb_encode_string;
		
		// For ping, encode encrypted_key as field 4 with empty bytes (22 00)
		static const char empty_encrypted_key[] = "";
		msg.big_payload.encrypted_key.arg = (void*)empty_encrypted_key;
		msg.big_payload.encrypted_key.funcs.encode = chiaki_pb_encode_string;

		// Use stack buffer like streamconnection.c (cloud launch spec can be 20000+ bytes)
		// Increased to 32768 to handle very large launch specs with protobuf overhead
		uint8_t buf[32768];
		size_t buf_size;

		pb_ostream_t stream = pb_ostream_from_buffer(buf, sizeof(buf));
		bool pbr = pb_encode(&stream, tkproto_TakionMessage_fields, &msg);
		if(!pbr)
		{
			CHIAKI_LOGE(senkusha->log, "Senkusha big protobuf encoding failed");
			return CHIAKI_ERR_UNKNOWN;
		}

		int32_t total_size = stream.bytes_written;
		CHIAKI_LOGV(session->log, "[OUTGOING BIG] Cloud ping BIG message: total_size=%d, session_key_data_len=%zu", 
		            total_size, launch_spec_str ? strlen(launch_spec_str) : 0);

		senkusha->sent_big_size = (size_t)total_size;
		free(senkusha->echo_reassembly_buf);
		senkusha->echo_reassembly_buf = calloc(1, senkusha->sent_big_size + 256);
		senkusha->echo_reassembly_pos = 0;
		
		// Cloud mode: 28 bytes overhead, 30/29 chunk overhead (PSN wrapper adds 4 bytes)
		// Use smaller MTU for ping (576 instead of session mtu)
		uint32_t mtu = 576;
		uint32_t net_overhead = 28;
		uint32_t first_chunk_overhead = 30;
		uint32_t cont_chunk_overhead = 29;
		mtu -= net_overhead;
		
		uint32_t buf_pos = 0;
		bool first = true;
		ChiakiErrorCode err = CHIAKI_ERR_SUCCESS;
		
		// Chunking logic matches streamconnection.c exactly
		while((mtu < total_size + first_chunk_overhead) || (mtu < total_size + cont_chunk_overhead && !first))
		{
			if(first)
			{
				buf_size = mtu - first_chunk_overhead;
				err = chiaki_takion_send_message_data(&senkusha->takion, 0, 1, buf + buf_pos, buf_size, NULL);
				first = false;
			}
			else
			{
				buf_size = mtu - cont_chunk_overhead;
				err = chiaki_takion_send_message_data_cont(&senkusha->takion, 0, 1, buf + buf_pos, buf_size, NULL);
			}
			if(err != CHIAKI_ERR_SUCCESS)
				return err;
			buf_pos += buf_size;
			total_size -= buf_size;
		}
		if(total_size > 0)
		{
			if(first)
				err = chiaki_takion_send_message_data(&senkusha->takion, 1, 1, buf + buf_pos, total_size, NULL);
			else
				err = chiaki_takion_send_message_data_cont(&senkusha->takion, 1, 1, buf + buf_pos, total_size, NULL);
		}
		return err;
	}
}

static ChiakiErrorCode senkusha_send_disconnect(ChiakiSenkusha *senkusha)
{
	tkproto_TakionMessage msg;
	memset(&msg, 0, sizeof(msg));

	msg.type = tkproto_TakionMessage_PayloadType_DISCONNECT;
	msg.has_disconnect_payload = true;
	msg.disconnect_payload.reason.arg = "Client Disconnecting";
	msg.disconnect_payload.reason.funcs.encode = chiaki_pb_encode_string;

	uint8_t buf[26];
	size_t buf_size;

	pb_ostream_t stream = pb_ostream_from_buffer(buf, sizeof(buf));
	bool pbr = pb_encode(&stream, tkproto_TakionMessage_fields, &msg);
	if(!pbr)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha disconnect protobuf encoding failed");
		return CHIAKI_ERR_UNKNOWN;
	}

	buf_size = stream.bytes_written;
	ChiakiErrorCode err = chiaki_takion_send_message_data(&senkusha->takion, 1, 1, buf, buf_size, NULL);

	return err;
}

static ChiakiErrorCode senkusha_send_echo_command(ChiakiSenkusha *senkusha, bool enable)
{
	tkproto_TakionMessage msg;
	memset(&msg, 0, sizeof(msg));

	msg.type = tkproto_TakionMessage_PayloadType_SENKUSHA;
	msg.has_senkusha_payload = true;
	msg.senkusha_payload.command = tkproto_SenkushaPayload_Command_ECHO_COMMAND;
	msg.senkusha_payload.has_echo_command = true;
	msg.senkusha_payload.echo_command.state = enable;

	uint8_t buf[0x10];
	pb_ostream_t stream = pb_ostream_from_buffer(buf, sizeof(buf));
	bool pbr = pb_encode(&stream, tkproto_TakionMessage_fields, &msg);
	if(!pbr)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha echo command protobuf encoding failed");
		return CHIAKI_ERR_UNKNOWN;
	}

	CHIAKI_LOGV(senkusha->log, "[OUTGOING ECHO] Sending ECHO_COMMAND: enable=%d, size=%zu", enable, stream.bytes_written);
	return senkusha_send_data_wait_for_ack(senkusha, buf, stream.bytes_written);
}

static ChiakiErrorCode senkusha_send_mtu_command(ChiakiSenkusha *senkusha, tkproto_SenkushaMtuCommand *command)
{
	tkproto_TakionMessage msg;
	memset(&msg, 0, sizeof(msg));

	msg.type = tkproto_TakionMessage_PayloadType_SENKUSHA;
	msg.has_senkusha_payload = true;
	msg.senkusha_payload.command = tkproto_SenkushaPayload_Command_MTU_COMMAND;
	msg.senkusha_payload.has_mtu_command = true;
	memcpy(&msg.senkusha_payload.mtu_command, command, sizeof(msg.senkusha_payload.mtu_command));

	uint8_t buf[0x20];
	pb_ostream_t stream = pb_ostream_from_buffer(buf, sizeof(buf));
	bool pbr = pb_encode(&stream, tkproto_TakionMessage_fields, &msg);
	if(!pbr)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha mtu command protobuf encoding failed");
		return CHIAKI_ERR_UNKNOWN;
	}

	return chiaki_takion_send_message_data(&senkusha->takion, 1, 8, buf, stream.bytes_written, NULL);
}

static ChiakiErrorCode senkusha_send_client_mtu_command(ChiakiSenkusha *senkusha, tkproto_SenkushaClientMtuCommand *command, bool wait_for_ack)
{
	tkproto_TakionMessage msg;
	memset(&msg, 0, sizeof(msg));

	msg.type = tkproto_TakionMessage_PayloadType_SENKUSHA;
	msg.has_senkusha_payload = true;
	msg.senkusha_payload.command = tkproto_SenkushaPayload_Command_CLIENT_MTU_COMMAND;
	msg.senkusha_payload.has_client_mtu_command = true;
	memcpy(&msg.senkusha_payload.client_mtu_command, command, sizeof(msg.senkusha_payload.client_mtu_command));

	uint8_t buf[0x20];
	pb_ostream_t stream = pb_ostream_from_buffer(buf, sizeof(buf));
	bool pbr = pb_encode(&stream, tkproto_TakionMessage_fields, &msg);
	if(!pbr)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha client mtu command protobuf encoding failed");
		return CHIAKI_ERR_UNKNOWN;
	}

	if(!wait_for_ack)
		return chiaki_takion_send_message_data(&senkusha->takion, 1, 8, buf, stream.bytes_written, NULL);

	return senkusha_send_data_wait_for_ack(senkusha, buf, stream.bytes_written);
}

static ChiakiErrorCode senkusha_send_data_wait_for_ack(ChiakiSenkusha *senkusha, uint8_t *buf, size_t buf_size)
{
	senkusha->state = STATE_EXPECT_DATA_ACK;
	senkusha->state_finished = false;
	senkusha->state_failed = false;
	ChiakiErrorCode err = chiaki_takion_send_message_data(&senkusha->takion, 1, 8, buf, buf_size, &senkusha->data_ack_seq_num_expected);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(senkusha->log, "Senkusha failed to send echo command");
		return err;
	}

	err = chiaki_cond_timedwait_pred(&senkusha->state_cond, &senkusha->state_mutex, EXPECT_TIMEOUT_MS, state_finished_cond_check, senkusha);
	assert(err == CHIAKI_ERR_SUCCESS || err == CHIAKI_ERR_TIMEOUT);

	if(!senkusha->state_finished)
	{
		if(err == CHIAKI_ERR_TIMEOUT)
			CHIAKI_LOGE(senkusha->log, "Senkusha data ack for echo command receive timeout");

		if(senkusha->should_stop)
			err = CHIAKI_ERR_CANCELED;
		else
			CHIAKI_LOGE(senkusha->log, "Senkusha failed to receive data ack for echo command");
	}

	return err;
}
