// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Mirrors: android/app/src/main/cpp/chiaki-jni.c Java_...DatacenterPingNative_performPing
//
// IMPORTANT: This file is compiled by Xcode, not CMake. ChiakiSession field offsets
// can differ from libchiaki. Always use chiaki_session_set_*_ex() bridge helpers —
// see <chiaki/ios_bridge_helpers.h> for details.

#import "ChiakiDatacenterPing.h"
#import "PyluxChiakiLog.h"

#include <chiaki/session.h>
#include <chiaki/senkusha.h>
#include <chiaki/ios_bridge_helpers.h>

#include <netdb.h>
#include <stdlib.h>
#include <string.h>
#import <Foundation/Foundation.h>

static void ping_log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
	(void)user;
	if (!msg)
		return;
	NSLog(@"[SenkushaPing] %s", msg);
}

bool chiaki_datacenter_ping(const char *public_ip, int32_t port,
	const char *session_key, const char *service_type,
	ChiakiDatacenterPingOutput *out)
{
	if (!out)
		return false;
	out->rtt_us = -1;
	out->mtu_in = 0;
	out->mtu_out = 0;

	if (!public_ip || !session_key || !service_type || port <= 0 || !session_key[0])
		return false;

	ChiakiLog log;
	pylux_chiaki_log_init(&log, ping_log_cb, NULL);

	struct addrinfo hints;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_DGRAM;
	hints.ai_protocol = IPPROTO_UDP;

	char port_str[16];
	snprintf(port_str, sizeof(port_str), "%d", (int)port);

	struct addrinfo *addrinfo_result = NULL;
	int gai_err = getaddrinfo(public_ip, port_str, &hints, &addrinfo_result);
	if (gai_err != 0 || !addrinfo_result)
	{
		CHIAKI_LOGE(&log, "DatacenterPing: resolve failed %s:%d", public_ip, (int)port);
		return false;
	}

	size_t session_size = chiaki_session_get_sizeof();
	ChiakiSession *session = (ChiakiSession *)calloc(1, session_size);
	if (!session)
	{
		freeaddrinfo(addrinfo_result);
		return false;
	}

	chiaki_session_set_log_ex(session, &log);
	chiaki_session_set_host_addrinfo_selected_ex(session, addrinfo_result);
	chiaki_session_set_enable_dualsense_ex(session, false);
	chiaki_session_set_target_ex(session, CHIAKI_TARGET_PS5_1);
	chiaki_session_set_cloud_port_ex(session, (uint16_t)port);

	if (strcmp(service_type, "pscloud") == 0)
	{
		chiaki_session_set_cloud_psn_wrapper_type_ex(session, 0);
		chiaki_session_set_service_type_ex(session, CHIAKI_SERVICE_TYPE_PSCLOUD);
	}
	else
	{
		chiaki_session_set_cloud_psn_wrapper_type_ex(session, 0x01);
		chiaki_session_set_service_type_ex(session, CHIAKI_SERVICE_TYPE_PSNOW);
	}

	ChiakiSenkusha senkusha;
	ChiakiErrorCode chiaki_err = chiaki_senkusha_init(&senkusha, session);
	if (chiaki_err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(&log, "DatacenterPing: senkusha_init failed %d", chiaki_err);
		freeaddrinfo(addrinfo_result);
		free(session);
		return false;
	}

	/* Cloud ping always uses protocol version 9, regardless of pscloud vs psnow.
	 * Version 12 is for the actual streaming connection only (matches Qt datacenterping.cpp). */
	senkusha.protocol_version = 9;

	size_t session_key_len = strlen(session_key);
	senkusha.cloud_launch_spec = (char *)malloc(session_key_len + 1);
	if (!senkusha.cloud_launch_spec)
	{
		chiaki_senkusha_fini(&senkusha);
		freeaddrinfo(addrinfo_result);
		free(session);
		return false;
	}
	memcpy(senkusha.cloud_launch_spec, session_key, session_key_len);
	senkusha.cloud_launch_spec[session_key_len] = '\0';

	uint32_t mtu_in = 0;
	uint32_t mtu_out = 0;
	uint64_t rtt_us = 0;
	chiaki_err = chiaki_senkusha_run(&senkusha, &mtu_in, &mtu_out, &rtt_us, NULL);

	if (senkusha.cloud_launch_spec)
	{
		free(senkusha.cloud_launch_spec);
		senkusha.cloud_launch_spec = NULL;
	}
	chiaki_senkusha_fini(&senkusha);
	freeaddrinfo(addrinfo_result);
	free(session);

	if (chiaki_err == CHIAKI_ERR_SUCCESS)
	{
		out->rtt_us = (int64_t)rtt_us;
		out->mtu_in = mtu_in;
		out->mtu_out = mtu_out;
		CHIAKI_LOGI(&log, "DatacenterPing: ok rtt=%llu us mtu_in=%u mtu_out=%u",
			(unsigned long long)rtt_us, mtu_in, mtu_out);
		return true;
	}

	CHIAKI_LOGE(&log, "DatacenterPing: senkusha_run failed %d", chiaki_err);
	return false;
}
