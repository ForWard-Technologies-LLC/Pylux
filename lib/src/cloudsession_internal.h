// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Internal declarations shared across the cloudsession_*.c units.
// Not part of the public API (chiaki/cloudsession.h).

#ifndef CHIAKI_CLOUDSESSION_INTERNAL_H
#define CHIAKI_CLOUDSESSION_INTERNAL_H

#include <chiaki/common.h>
#include <chiaki/cloudsession.h>
#include <chiaki/log.h>

#include <ctype.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN // keep windows.h from dragging in winsock 1 / macro pollution
#endif
#include <windows.h>
#define CC_MS_SLEEP(ms) Sleep(ms)
#else
#include <unistd.h>
#define CC_MS_SLEEP(ms) usleep((ms) * 1000)
#endif

// Portable case-insensitive substring search (strcasestr is a GNU extension).
static inline const char *cc_strcasestr(const char *haystack, const char *needle)
{
	if(!haystack || !needle || !*needle)
		return haystack;
	size_t nlen = strlen(needle);
	for(; *haystack; haystack++)
	{
		size_t i = 0;
		while(i < nlen && haystack[i]
			&& tolower((unsigned char)haystack[i]) == tolower((unsigned char)needle[i]))
			i++;
		if(i == nlen)
			return haystack;
	}
	return NULL;
}

#ifdef __cplusplus
extern "C" {
#endif

struct json_object; // json-c, forward-declared so this header needs no umbrella include

// Shared PSNOW/Kamaji OAuth constants -- single source of truth for the cloudsession
// units (each file aliases its local macro to these). Protocol-stable Sony values; the
// catalog module (cloudcatalog_fetch.c) keeps its own copy as it's a separate module.
#define CS_PSNOW_CLIENT_ID  "bc6b0777-abb5-40da-92ca-e133cf18e989"
#define CS_PSNOW_REDIRECT   "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html"
#define CS_PSNOW_USER_AGENT "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) playstation-now/0.0.0 Chrome/83.0.4103.104 Electron/9.0.4 Safari/537.36 gkApollo"

/**
 * Pure picker for the PS Plus full-game ("*GD") fallback that step 0.5d uses when a
 * title exposes no license_type==4 streaming reservation. Scans @p sku's
 * "entitlements" for the first whose "packageType" ends in "GD"; when @p require_title
 * is set, additionally requires the entitlement id to contain @p title_id. On a match
 * copies the id into @p out_id (capacity @p out_sz) and returns true; logs the pick via
 * @p log when non-NULL. Exposed (non-static) so the unit suite can exercise it.
 */
bool km_pick_fullgame_id(struct json_object *sku, bool require_title,
	const char *title_id, char *out_id, size_t out_sz, ChiakiLog *log);

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
