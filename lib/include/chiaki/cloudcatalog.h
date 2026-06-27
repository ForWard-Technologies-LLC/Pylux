// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Unified PS Cloud catalog: single source of truth for Qt, Android and iOS.
//
// The platform supplies only npsso/locale/cache_dir and receives one JSON
// payload that is *display-and-stream ready*. Clients MUST NOT recompute
// category, serviceType, platform, ownership or stream identifiers — every
// value the UI renders and every routing value the stream/purchase actions
// need is precomputed here. See the JSON contract below.

#ifndef CHIAKI_CLOUDCATALOG_H
#define CHIAKI_CLOUDCATALOG_H

#include <chiaki/common.h>
#include <chiaki/log.h>

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Current schema version of the JSON payload (top-level "schemaVersion").
 * v2: settledLocale is now the locale the lib resolved AFTER re-basing on the
 *     account's Kamaji-session country (region detection moved into the lib), so a
 *     pre-v2 cached payload can hold wrong-region content for international accounts
 *     and must be refetched. */
#define CHIAKI_CLOUDCATALOG_SCHEMA_VERSION 2

typedef struct chiaki_cloudcatalog_config_t
{
	const char *npsso;      /**< cookie value only (no "npsso=" prefix); may be NULL/empty for public fallback */
	const char *locale;     /**< BCP-47, e.g. "en-US"; NULL => "en-US" */
	const char *cache_dir;  /**< platform-supplied dir; lib owns every file inside */
	bool force_refresh;     /**< bypass the on-disk unified cache (and intermediates) */
} ChiakiCloudCatalogConfig;

typedef struct chiaki_cloudcatalog_result_t
{
	ChiakiErrorCode err;
	char *json;             /**< UTF-8 unified payload; NULL on hard failure. Free via _result_fini */
	char *error_message;    /**< human-readable detail on failure; may be NULL */
} ChiakiCloudCatalogResult;

/**
 * Fetch (or load from cache) the unified cloud catalog and return it as JSON.
 *
 * Blocking / single-threaded: call from a worker thread. Performs all OAuth
 * exchanges internally from @c config->npsso; never persists tokens. On a
 * unified-cache hit it performs no network I/O.
 *
 * The JSON envelope (see CHIAKI_CLOUDCATALOG_SCHEMA_VERSION):
 *
 *   {
 *     "schemaVersion": 2,
 *     "total": <int>,
 *     "nativeMode": <bool>,            // true when the authenticated PS Now walk succeeded
 *     "fallbackRegion": "US"|"GB"|"",  // region-group store country in public fallback; "" when native
 *     "settledLocale": "en-US",        // locale the lib resolved (account region from the Kamaji
 *                                      // session re-bases the caller locale, then the imagic store-
 *                                      // locale chain settles); clients persist this verbatim
 *     "warning": "",                   // non-empty => client shows a banner verbatim (e.g. expired npsso)
 *     "games": [ {
 *       "productId":        <string>,  // canonical catalog id + stable dedup key
 *       "name":             <string>,
 *       "imageUrl":         <string>,  // portrait/box art
 *       "landscapeImageUrl":<string>,
 *       "conceptId":        <string>,
 *       "category":         "owned"|"streamable"|"purchaseable",
 *       "serviceType":      "psnow"|"pscloud",   // catalog routing
 *       "platform":         "ps3"|"ps4"|"ps5",   // badge; derived from device[]
 *       "isOwned":          <bool>,
 *       "streamServiceType":"psnow"|"pscloud",   // endpoint the stream action uses
 *       "streamIdentifier": <string>,            // exact id handed to the streaming session
 *       "entitlementId":    <string>,            // owned rows
 *       "storeProductId":   <string>,            // owned / purchaseable rows
 *       "conceptUrl":       <string>,            // purchase / add-to-library deep link
 *       "plusCatalog":      <bool>
 *     }, ... ]
 *   }
 *
 * "games" is pre-sorted in the canonical order (owned first, then by name);
 * clients render in array order and must not re-sort.
 *
 * @return err in @p out; out->json non-NULL on success (and on degraded-but-
 *         usable results such as expired npsso, where "warning" is set).
 */
CHIAKI_EXPORT ChiakiErrorCode chiaki_cloudcatalog_fetch_unified(
	const ChiakiCloudCatalogConfig *config,
	ChiakiCloudCatalogResult *out,
	ChiakiLog *log);

/** Release a result populated by chiaki_cloudcatalog_fetch_unified(). */
CHIAKI_EXPORT void chiaki_cloudcatalog_result_fini(ChiakiCloudCatalogResult *out);

/** Delete all lib-owned cache files under @p cache_dir (e.g. on locale change). */
CHIAKI_EXPORT void chiaki_cloudcatalog_invalidate_cache(const char *cache_dir);

// ---------------------------------------------------------------------------
// Cloud streaming language / datacenter helpers (single source of truth)
//
// Cloud game language is tied to the datacenter region: the streaming spec
// "language" field only takes effect when a datacenter that serves that
// language is selected — Gaikai silently ignores a language with no matching
// datacenter. These helpers let every platform (Qt/iOS/Android) share one
// table to (a) hand Gaikai the bare language code it expects, (b) build a
// language picker limited to the account's reachable datacenters, and (c)
// auto-select the datacenter for a chosen language.
// ---------------------------------------------------------------------------

/** Convert a BCP-47 locale ("de-DE", "en-US") to the bare, lowercase language
 *  code Gaikai expects ("de", "en"). Gaikai ignores full locales. Writes a
 *  NUL-terminated code into @p out (>= 8 bytes recommended); defaults to "en"
 *  for empty/NULL input. */
CHIAKI_EXPORT void chiaki_cloud_gaikai_language(const char *locale, char *out, size_t out_sz);

/** Number of locales offered in the cloud-language picker. */
CHIAKI_EXPORT size_t chiaki_cloud_supported_locale_count(void);

/** The @p idx-th supported locale (BCP-47, e.g. "en-GB"), or "" if out of range.
 *  Human-readable display names are the platform's responsibility (localized in
 *  its own UI resources keyed off this code). */
CHIAKI_EXPORT const char *chiaki_cloud_supported_locale(size_t idx);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_CLOUDCATALOG_H
