// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Internal declarations shared across the cloudsession_*.c units.
// Not part of the public API (chiaki/cloudsession.h).

#ifndef CHIAKI_CLOUDSESSION_INTERNAL_H
#define CHIAKI_CLOUDSESSION_INTERNAL_H

#include <chiaki/common.h>
#include <chiaki/cloudsession.h>
#include <chiaki/log.h>

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Kamaji session flow (PSNOW): 0.5b anonymous OAuth -> 0.5c anonymous session
 * -> 0.5d productId->entitlementId (uses store_country/store_lang) -> 0.5e
 * check/acquire ($0 checkout) -> step5/6 authenticated session. With a non-empty
 * cfg->owned_entitlement_id it takes the owned fast-path (skips 0.5b-0.5e).
 * @p duid is the shared client device uid (also used by Gaikai's OAuth).
 * On success writes the resolved entitlement + platform; on failure may set
 * *out_error (heap, caller frees) -- "PS_PLUS_SUBSCRIPTION_REQUIRED" /
 * "ACCOUNT_PRIVACY_SETTINGS:<url>" are recognised sentinels.
 */
ChiakiErrorCode cc_kamaji_resolve(ChiakiLog *log,
	const ChiakiCloudProvisionConfig *cfg, const char *duid,
	char out_entitlement_id[128], char out_platform[8], char **out_error);

/**
 * Gaikai allocation flow (steps 0/7-13): client ids -> config -> start session
 * -> OAuth auth codes -> authorize -> lock -> datacenters -> ping/select ->
 * allocate slot. @p platform is the resolved "ps3"|"ps4"|"ps5"; @p entitlement_id
 * is the entitlement to stream; @p duid the shared client device uid (Kamaji's).
 * cfg->service_type selects PSNOW vs PSCLOUD. On success fills out->{server_ip,
 * server_port,handshake_key,launch_spec,session_id,mtu_*,rtt_us,platform,
 * datacenter_pings,psn_wrapper_type}. On step8 entitlement rejection sets
 * out->error_message to the response body (the noGameForEntitlementId marker).
 */
ChiakiErrorCode cc_gaikai_allocate(ChiakiLog *log,
	const ChiakiCloudProvisionConfig *cfg, const char *duid,
	const char *platform, const char *entitlement_id,
	ChiakiCloudProvisionResult *out);

/**
 * Ping one datacenter using the senkusha echo/ping handshake (Takion connect ->
 * BIG/BANG -> echo -> averaged RTT), the same flow Remote Play uses. Blocking;
 * senkusha applies its own internal timeout.
 *
 * @param public_ip   datacenter host or IPv4 (resolved here)
 * @param port        datacenter UDP port (typically 40101)
 * @param session_key x-gaikai-session value, used as the BIG message launch_spec
 * @param service_type "psnow" (adds the PSN wrapper) or "pscloud"
 * @param out_rtt_us  averaged RTT in microseconds, or <0 on failure
 * @param out_mtu_in/out_mtu_out  negotiated MTU (0 on failure)
 * @return CHIAKI_ERR_SUCCESS only when a valid RTT was measured.
 */
ChiakiErrorCode cc_ping_datacenter(ChiakiLog *log, const char *public_ip, int port,
	const char *session_key, const char *service_type,
	int64_t *out_rtt_us, uint32_t *out_mtu_in, uint32_t *out_mtu_out);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_CLOUDSESSION_INTERNAL_H
