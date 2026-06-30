// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Datacenter ping for cloud provisioning -- C port of the Qt datacenterping.cpp.
// The heavy lifting is chiaki_senkusha_run (already in libchiaki); this just
// builds the minimal ChiakiSession senkusha needs and resolves the address.

#include "cloudsession_internal.h"

#include <chiaki/senkusha.h>
#include <chiaki/session.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>
#endif

ChiakiErrorCode cc_ping_datacenter(ChiakiLog *log, const char *public_ip, int port,
	const char *session_key, const char *service_type,
	int64_t *out_rtt_us, uint32_t *out_mtu_in, uint32_t *out_mtu_out)
{
	if(out_rtt_us) *out_rtt_us = -1;
	if(out_mtu_in) *out_mtu_in = 0;
	if(out_mtu_out) *out_mtu_out = 0;
	if(!public_ip || !*public_ip)
		return CHIAKI_ERR_INVALID_DATA;

	// Resolve host:port as UDP/IPv4 (getaddrinfo handles both literal IPs and names).
	struct addrinfo hints;
	memset(&hints, 0, sizeof(hints));
	hints.ai_family = AF_INET;
	hints.ai_socktype = SOCK_DGRAM;
	hints.ai_protocol = IPPROTO_UDP;

	char port_str[16];
	snprintf(port_str, sizeof(port_str), "%d", port);

	struct addrinfo *addrinfo_result = NULL;
	int gai = getaddrinfo(public_ip, port_str, &hints, &addrinfo_result);
	if(gai != 0 || !addrinfo_result)
	{
		CHIAKI_LOGW(log, "[PING] resolve failed for %s:%d", public_ip, port);
		return CHIAKI_ERR_HOST_DOWN;
	}

	// senkusha needs a (mostly zeroed) ChiakiSession with a few cloud fields set.
	ChiakiSession *session = (ChiakiSession *)calloc(1, sizeof(ChiakiSession));
	if(!session)
	{
		freeaddrinfo(addrinfo_result);
		return CHIAKI_ERR_MEMORY;
	}
	session->log = log;
	session->connect_info.host_addrinfo_selected = addrinfo_result;
	session->connect_info.enable_dualsense = false;
	session->target = CHIAKI_TARGET_PS5_1;
	session->cloud_port = port;
	if(service_type && strcmp(service_type, "pscloud") == 0)
	{
		session->cloud_psn_wrapper_type = 0;     // no PSN wrapper for PSCLOUD
		session->service_type = CHIAKI_SERVICE_TYPE_PSCLOUD;
	}
	else
	{
		session->cloud_psn_wrapper_type = 0x01;  // PSN wrapper for PSNOW (and default)
		session->service_type = CHIAKI_SERVICE_TYPE_PSNOW;
	}

	ChiakiSenkusha senkusha;
	ChiakiErrorCode err = chiaki_senkusha_init(&senkusha, session);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGW(log, "[PING] senkusha init failed for %s: %d", public_ip, err);
		freeaddrinfo(addrinfo_result);
		free(session);
		return err;
	}

	senkusha.protocol_version = 9; // cloud ping always v9
	// x-gaikai-session key -> BIG message launch_spec (senkusha owns nothing here;
	// it reads the pointer during run, so a stack/heap copy that outlives run() is fine).
	char *key_copy = NULL;
	if(session_key && *session_key)
	{
		key_copy = strdup(session_key);
		senkusha.cloud_launch_spec = key_copy;
	}

	uint32_t mtu_in = 0, mtu_out = 0;
	uint64_t rtt_us = 0;
	err = chiaki_senkusha_run(&senkusha, &mtu_in, &mtu_out, &rtt_us, NULL);

	senkusha.cloud_launch_spec = NULL;
	free(key_copy);
	chiaki_senkusha_fini(&senkusha);
	freeaddrinfo(addrinfo_result);
	free(session);

	if(err != CHIAKI_ERR_SUCCESS || rtt_us == 0)
		return (err != CHIAKI_ERR_SUCCESS) ? err : CHIAKI_ERR_UNKNOWN;

	if(out_rtt_us) *out_rtt_us = (int64_t)rtt_us;
	if(out_mtu_in) *out_mtu_in = mtu_in;
	if(out_mtu_out) *out_mtu_out = mtu_out;
	return CHIAKI_ERR_SUCCESS;
}
