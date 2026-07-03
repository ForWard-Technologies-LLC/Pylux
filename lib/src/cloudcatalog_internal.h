// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Internal declarations shared across the cloudcatalog_*.c modules. Not part of
// the public API (see include/chiaki/cloudcatalog.h for that).

#ifndef CHIAKI_CLOUDCATALOG_INTERNAL_H
#define CHIAKI_CLOUDCATALOG_INTERNAL_H

#include <chiaki/common.h>
#include <chiaki/log.h>

// Use the per-component json-c headers (like remote/holepunch.c) instead of the
// umbrella <json-c/json.h>: on the Android/iOS FetchContent build the generated
// umbrella lands in jsonc-build/json.h (no json-c/ prefix), so <json-c/json.h>
// is unresolvable there while these always resolve from the source include dir.
#include <json-c/json_object.h>
#include <json-c/json_tokener.h>
// json_object_object_foreach() expands to lh_table_head/lh_entry_* calls, declared here.
#include <json-c/linkhash.h>

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------------------------------------------------------------------------
// json-c convenience helpers (NULL-safe). These keep the ported merge logic
// close to the Qt original (QJsonObject::value(...).toString() etc.).
// ---------------------------------------------------------------------------

/** Return the string at obj[key], or "" if missing/not a string. Never NULL. */
const char *cc_json_str(struct json_object *obj, const char *key);

/** Return obj[key] as object, or NULL. */
struct json_object *cc_json_obj(struct json_object *obj, const char *key);

/** Return obj[key] as array, or NULL. */
struct json_object *cc_json_arr(struct json_object *obj, const char *key);

/** Return obj[key] as bool (false if missing). */
bool cc_json_bool(struct json_object *obj, const char *key);

/** Return obj[key] as int (0 if missing). */
int cc_json_int(struct json_object *obj, const char *key);

/** True if obj has a (non-null) value at key. */
bool cc_json_has(struct json_object *obj, const char *key);

/** strdup that tolerates NULL (returns NULL). */
char *cc_strdup(const char *s);

/** Case-insensitive equality (NULL-safe; NULL != non-NULL, NULL == NULL). */
bool cc_ieq(const char *a, const char *b);

/** strstr wrapper, NULL-safe. */
bool cc_contains(const char *haystack, const char *needle);

/** True if s ends with suffix. */
bool cc_ends_with(const char *s, const char *suffix);

/** Set obj[key] = string value (replaces). Copies the string. */
void cc_json_set_str(struct json_object *obj, const char *key, const char *value);

/** Set obj[key] = bool. */
void cc_json_set_bool(struct json_object *obj, const char *key, bool value);

/** Deep copy a json value (json_object_deep_copy with the standard copy fn). */
struct json_object *cc_json_clone(struct json_object *src);

// ---------------------------------------------------------------------------
// Region / locale (cloudcatalog_consts.c)
// ---------------------------------------------------------------------------

/** "US" for Americas account regions, else "GB". @p account_country may be NULL. */
const char *cc_classics_store_country(const char *account_country);

/** Fully-qualified APOLLOROOT container id for the account's region group. */
const char *cc_apollo_root_container_id(const char *account_country);

/**
 * Build the ordered store-locale fallback chain (canonical, en-COUNTRY, en-US).
 * Writes up to @p max NUL-terminated locales into @p out (caller frees each via
 * free()); returns the count.
 */
size_t cc_build_store_locale_chain(const char *stored, char **out, size_t max);

// ---------------------------------------------------------------------------
// Cache I/O (cloudcatalog_cache.c)
// ---------------------------------------------------------------------------

#define CC_CACHE_TTL_MS (24 * 60 * 60 * 1000) /* 24h */

/** mkdir -p the cache dir. */
ChiakiErrorCode cc_cache_ensure_dir(const char *cache_dir);

/**
 * Read cache_dir/<key>.json if present and younger than max_age_ms. Returns a
 * parsed json_object (caller json_object_put) or NULL on miss/expiry/parse-fail.
 * Expired files are deleted.
 */
struct json_object *cc_cache_read(ChiakiLog *log, const char *cache_dir, const char *key, long max_age_ms);

/** Write obj (compact) to cache_dir/<key>.json. */
ChiakiErrorCode cc_cache_write(ChiakiLog *log, const char *cache_dir, const char *key, struct json_object *obj);

/** Delete cache_dir/<key>.json. */
void cc_cache_remove(const char *cache_dir, const char *key);

// ---------------------------------------------------------------------------
// Merge / assembly (cloudcatalog_merge.c)
// ---------------------------------------------------------------------------

/** Inputs to the unified assembly (all borrowed; not freed by assemble). */
typedef struct cc_assemble_input_t
{
	struct json_object *apollo_games;     /**< raw PS Now (Apollo) rows array, or NULL */
	struct json_object *imagic_browse;    /**< imagic PS5 browse rows array, or NULL */
	struct json_object *imagic_supplement;/**< imagic plus-library supplement rows array, or NULL */
	struct json_object *owned_cross_ref;  /**< processed owned entitlements array, or NULL */
	bool native_mode;
	const char *fallback_region;          /**< "US"|"GB"|... store country from base_url, or "" */
	const char *resolved_store_lang;      /**< store language from native base_url ("nl"), "" in fallback */
	const char *settled_locale;           /**< or NULL */
	const char *warning;                  /**< or NULL/"" */
} CCAssembleInput;

/**
 * Pure assembly: mirrors Qt assembleUnifiedCatalog. Returns a newly-allocated
 * json_object envelope { schemaVersion, total, nativeMode, fallbackRegion,
 * settledLocale, warning, games:[...] } with every contract field populated and
 * games pre-sorted (owned first, then name). Caller json_object_put().
 */
struct json_object *cc_assemble_unified_catalog(ChiakiLog *log, const CCAssembleInput *in);

/**
 * Cross-reference owned entitlements against the browse catalog + supplement.
 * Faithful port of processCrossReferenceComplete: produces the deduped owned
 * "cross-ref" array (conceptId+platform dedupe, canonical-entitlement rank,
 * bundle-sibling expansion, disc-upgrade rescue) that feeds the assemble step.
 *
 * All params borrowed. @p product_id_aliases is a {alias:canonical} object (or
 * NULL); @p component_ids is a {product_id:[entitlement_id,...]} object (or NULL).
 * Returns a new array (caller json_object_put()).
 */
struct json_object *cc_build_owned_cross_ref(ChiakiLog *log,
	struct json_object *psnow_catalog, struct json_object *imagic_browse,
	struct json_object *imagic_supplement, struct json_object *product_id_aliases,
	struct json_object *owned_games, struct json_object *component_ids);

/**
 * mergeImagicListIntoPs5Catalog: fold one imagic category-list document into the
 * accumulators. @p games_by_edition (concept|platform -> game), @p supplement
 * (productId -> game), @p aliases (alt productId -> canonical) are json object
 * maps mutated in place. Mirrors the Qt helper exactly.
 */
void cc_merge_imagic_list(const char *category_list, struct json_object *list_doc,
	struct json_object *games_by_edition, struct json_object *supplement,
	struct json_object *aliases, int *total_seen);

/** Cover-image extraction (images[type 10]>12>13, then imageUrl). Returns "" if none. */
const char *cc_extract_cover_image(struct json_object *game_obj, char *out, size_t out_sz);

/** Stable-key derivation for ownership-match: splits product_id on [-_], drops the last
 *  token, joins with '|'. Returns "" if fewer than 2 tokens. */
const char *cc_stable_key(const char *product_id, char *out, size_t out_sz);

/**
 * Strip Sony's numeric serviceType and set canonical pscloud/psnow from
 * entitlement_attributes[].platform_id. Mirrors sanitizeOwnedEntitlementServiceType.
 */
void cc_sanitize_owned_service_type(struct json_object *ent);

// ---------------------------------------------------------------------------
// Network fetch (cloudcatalog_fetch.c) — blocking HTTP flows
// ---------------------------------------------------------------------------

typedef enum cc_native_result_t
{
	CC_NATIVE_OK,                /**< authenticated APOLLOROOT walk succeeded */
	CC_NATIVE_AUTH_ERROR,        /**< OAuth/session failed (expired token) */
	CC_NATIVE_REGION_UNSUPPORTED,/**< auth OK but /user/stores 404 -> public fallback */
	CC_NATIVE_FATAL              /**< setup/transport failure */
} CCNativeResult;

/**
 * Parse the /container/{COUNTRY}/{lang}/ segments out of a Sony store base_url.
 * out_country / out_lang are set to "" on failure (each may be NULL to skip).
 * Returns true only when both segments were present and fit their buffers.
 */
bool cc_parse_container_store_locale(const char *base_url,
	char *out_country, size_t cc_sz, char *out_lang, size_t lang_sz);

/**
 * Authenticated PS Now APOLLOROOT probe. On CC_NATIVE_OK, *out_games is a new array.
 * Also reports the account region signal from the Kamaji session: out_country /
 * out_language receive data.country / data.language (each may be NULL to skip, and
 * is set to "" when unavailable). These are populated even on
 * CC_NATIVE_REGION_UNSUPPORTED (session succeeded, /user/stores 404'd).
 * out_store_country / out_store_lang receive the /container/{CC}/{lang}/ segments
 * parsed from the server base_url on CC_NATIVE_OK (empty when unavailable).
 */
CCNativeResult cc_fetch_psnow_native(ChiakiLog *log, const char *npsso, struct json_object **out_games,
	char *out_country, size_t cc_sz, char *out_language, size_t lang_sz,
	char *out_store_country, size_t store_cc_sz, char *out_store_lang, size_t store_lang_sz);

/** Public APOLLOROOT fallback pagination for @p account_country. New array or NULL. */
struct json_object *cc_fetch_apollo_fallback(ChiakiLog *log, const char *account_country);

typedef struct cc_imagic_result_t
{
	struct json_object *browse;       /**< new array of streamable PS5 rows */
	struct json_object *supplement;   /**< new array of plus-library rows */
	struct json_object *aliases;      /**< new object {altProductId: canonicalProductId} */
	char settled_locale[16];
	bool all_ps5_list_succeeded;
	bool any_succeeded;
} CCImagicResult;

/** imagic 6-list fetch with locale fallback chain. Returns true if any list loaded. */
bool cc_fetch_imagic(ChiakiLog *log, const char *stored_locale, CCImagicResult *out);
void cc_imagic_result_fini(CCImagicResult *r);

typedef enum cc_owned_result_t
{
	CC_OWNED_OK,
	CC_OWNED_AUTH_ERROR,
	CC_OWNED_ERROR
} CCOwnedResult;

/** Owned entitlements OAuth + pagination + filter. Outputs new games array + componentIds object. */
CCOwnedResult cc_fetch_owned(ChiakiLog *log, const char *npsso,
	struct json_object **out_games, struct json_object **out_component_ids);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_CLOUDCATALOG_INTERNAL_H
