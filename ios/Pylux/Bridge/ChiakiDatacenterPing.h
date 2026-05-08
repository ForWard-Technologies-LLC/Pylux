// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Senkusha datacenter ping for cloud allocation (mirrors android chiaki-jni DatacenterPing)

#ifndef ChiakiDatacenterPing_h
#define ChiakiDatacenterPing_h

#include <stdbool.h>
#include <stdint.h>

typedef struct ChiakiDatacenterPingOutput {
	int64_t rtt_us;   // microseconds, or -1 on failure
	uint32_t mtu_in;
	uint32_t mtu_out;
} ChiakiDatacenterPingOutput;

/// Run chiaki_senkusha_run against a Gaikai datacenter (UDP echo / BIG handshake).
/// @param public_ip Hostname or IPv4 string
/// @param session_key x-gaikai-session (configKey) for cloud BIG
/// @param service_type "pscloud" or "psnow"
/// @return true if senkusha completed successfully and RTT was measured
bool chiaki_datacenter_ping(const char *public_ip, int32_t port,
	const char *session_key, const char *service_type,
	ChiakiDatacenterPingOutput *out);

#endif
