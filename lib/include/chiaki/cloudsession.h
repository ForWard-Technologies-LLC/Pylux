// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Unified PS Cloud session provisioning: single source of truth for Qt,
// Android and iOS. Mirrors the cloudcatalog module (chiaki_cloudcatalog_*).
//
// Given a chosen title + npsso (+ resolved store locale + datacenter prefs),
// this runs the entire provisioning flow that used to be duplicated per
// platform -- authorization check, the PSNOW Kamaji session (or the direct
// PSCLOUD path), datacenter discovery/ping/select, and the Gaikai allocation --
// and returns an allocation result that is *ready to stream*: the platform
// only needs to hand {server_ip, server_port, handshake_key, launch_spec,
// session_id} to its existing StreamSession (which already uses libchiaki).
//
// Blocking / single-threaded: call from a worker thread. Performs all OAuth
// exchanges and HTTP internally from @c cfg->npsso; never persists tokens.

#ifndef CHIAKI_CLOUDSESSION_H
#define CHIAKI_CLOUDSESSION_H

#include <chiaki/common.h>
#include <chiaki/log.h>

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Inputs for one provisioning attempt. All strings are borrowed (the caller
 * owns them and they must outlive the call). NULL is treated as "".
 */
typedef struct chiaki_cloud_provision_config_t
{
	const char *service_type;         /**< "psnow" (PS3/PS4) | "pscloud" (PS5) */
	const char *game_identifier;      /**< productId (psnow) or entitlementId (pscloud) */
	const char *game_name;            /**< display name (logging / result echo) */
	const char *npsso;                /**< cookie value only (no "npsso=" prefix) */
	const char *store_country;        /**< resolvedStoreCountry for the step0_5d container URL */
	const char *store_lang;           /**< resolvedStoreLang for the step0_5d container URL */
	const char *owned_entitlement_id; /**< owned-PSNOW fast-path entitlement, or "" */
	const char *owned_platform;       /**< platform accompanying owned_entitlement_id, or "" */
	const char *forced_datacenter;    /**< settings-selected region; non-empty => SKIP pinging */
	const char *cache_dir;            /**< lib-owned datacenter-ping cache lives here; may be "" */
	int  rtt_safety_offset_ms;        /**< cloud-only RTT offset (e.g. -20); Remote Play unaffected */

	/** Progress callback: @p stage is a UI-ready string shown verbatim. May be NULL. */
	void (*progress)(const char *stage, void *user);
	/** Cancellation check, polled between steps. May be NULL. */
	bool (*is_cancelled)(void *user);
	void *user;                       /**< opaque, passed back to the callbacks */
} ChiakiCloudProvisionConfig;

/**
 * Allocation result. On success the dynamic strings are heap-owned and must be
 * released with chiaki_cloud_provision_result_fini().
 */
typedef struct chiaki_cloud_provision_result_t
{
	ChiakiErrorCode err;
	char     server_ip[64];
	int      server_port;
	char    *handshake_key;     /**< base64; -> ConnectInfo.cloud_handshake_key */
	char    *launch_spec;       /**<          -> ConnectInfo.cloud_launch_spec */
	char    *session_id;
	char     entitlement_id[128]; /**< the entitlement actually streamed */
	char     platform[8];         /**< "ps3"|"ps4"|"ps5" */
	uint32_t mtu_in, mtu_out;
	uint64_t rtt_us;
	char    *datacenter_pings;  /**< JSON: [{"dataCenter":...,"rtt_ms":...}, ...] for Settings */
	char    *error_message;     /**< human-readable detail on failure; may be NULL */
} ChiakiCloudProvisionResult;

/**
 * Run the full provisioning flow. Blocking; call from a worker thread.
 * On a fast-path entitlement rejection (noGameForEntitlementId) the full
 * resolve/acquire flow is retried exactly once internally.
 *
 * @return err in @p out; out->err == CHIAKI_ERR_SUCCESS on a stream-ready result.
 */
CHIAKI_EXPORT ChiakiErrorCode chiaki_cloud_provision_session(
	const ChiakiCloudProvisionConfig *cfg,
	ChiakiCloudProvisionResult *out,
	ChiakiLog *log);

/** Release the heap-owned fields of a result populated by the call above. */
CHIAKI_EXPORT void chiaki_cloud_provision_result_fini(ChiakiCloudProvisionResult *out);

/**
 * Ping the account's reachable datacenters and return per-region latency for
 * the Settings/overlay UI, without starting a stream. @p out_pings_json is a
 * heap-owned JSON array [{"dataCenter":...,"rtt_ms":...}, ...]; free() it.
 * Uses the same senkusha-based ping as the provisioning flow.
 */
CHIAKI_EXPORT ChiakiErrorCode chiaki_cloud_ping_datacenters(
	const ChiakiCloudProvisionConfig *cfg,
	char **out_pings_json,
	ChiakiLog *log);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_CLOUDSESSION_H
