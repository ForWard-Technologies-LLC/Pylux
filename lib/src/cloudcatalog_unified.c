// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Unified catalog orchestrator + public API. Mirrors the Qt fetchUnifiedCatalog
// chain: native APOLLOROOT probe -> (public APOLLOROOT fallback walk | expired-warning) ->
// imagic 6-list -> owned entitlements -> cross-reference -> assemble. Cache keys
// (unified_catalog_v3 [contract schema; was v2 pre-migration], ps5_cloud_catalog_v6,
// ps5_cloud_library) are shared across platforms so files stay byte-comparable, and
// the unified read is guarded by schemaVersion so a stale older payload is never served.
//
// =============================================================================
// CONTRIBUTOR NOTES — read this before changing how the catalog is built
// =============================================================================
// This file (and its cloudcatalog_*.c siblings) is THE one place where the cloud
// game library is assembled. Edits here are welcome, but please keep to a few
// ground rules so the three clients (Qt, Android, iOS) stay in lockstep.
//
// 1. ALL catalog logic lives HERE, in libchiaki — never in a client.
//    Qt/QML, the Android Kotlin layer, and the iOS Swift layer must stay "dumb":
//    they call chiaki_cloudcatalog_fetch_unified() and render the JSON it returns.
//    Do NOT re-derive platform, ownership, service type, or identifiers in a
//    client. If a client needs a new field, ADD IT TO THE CONTRACT HERE (see
//    cloudcatalog_merge.c) and emit it for everyone — don't special-case one OS.
//
// 2. The two sources, and what each is authoritative for:
//      - imagic  -> owned PS5 cloud games (the PS5 browse universe + your
//                   entitlements / "plus library" supplement).
//      - Apollo  -> the PS3/PS4 (PS Now classics) catalog.
//    Treat them as the source of truth for their own domain. When in doubt about
//    where a game should come from, prefer imagic for PS5-owned and Apollo for
//    the PS3/PS4 classics, rather than inventing a heuristic.
//
// 3. Apollo can legitimately be unavailable (region not served, expired session).
//    That is NOT a fatal error. The chain already degrades gracefully: native
//    APOLLOROOT probe -> public fallback for the account's country -> still serve
//    the imagic PS5 universe (+ a re-login warning on auth failure). If you touch
//    the fetch/fallback path, KEEP these fallbacks working — losing your owned PS5
//    list because Apollo 404'd in someone's region is the exact bug we avoid here.
//
// 4. DO NOT pattern-match / regex on title IDs to infer platform or anything else.
//    Product/title IDs (CUSA####, PPSA####, etc.) vary by region and over time, so
//    "starts with CUSA" / "looks like PPSA" style checks are brittle and unsafe.
//    When you must parse an identifier, split on its real structural separators
//    ('-' and '_') and use the resulting parts — never a regex over the raw ID.
//    Platform/ownership decisions should come from the source data (device lists,
//    serviceType, entitlements), not from how an ID happens to be spelled.
//
// 5. Keep the cache keys and emitted contract fields stable and shared. The cache
//    files are meant to be byte-comparable across platforms; if you change the
//    shape, bump the schema/key version (see CHIAKI_CLOUDCATALOG_SCHEMA_VERSION
//    and the versioned key names) so stale payloads are never served.
// =============================================================================

#include "cloudcatalog_internal.h"

#include <chiaki/cloudcatalog.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h> // strcasecmp

#define WARNING_EXPIRED \
	"Your session has expired. Please log in again to see your owned games."

static const char *account_country_from_locale(const char *locale, char *out, size_t out_sz)
{
	snprintf(out, out_sz, "US");
	if(!locale)
		return out;
	const char *dash = strchr(locale, '-');
	if(dash && dash[1])
	{
		size_t i = 0;
		for(const char *p = dash + 1; *p && i < out_sz - 1; p++)
		{
			char c = *p;
			if(c >= 'a' && c <= 'z')
				c = (char)(c - 'a' + 'A');
			out[i++] = c;
		}
		out[i] = 0;
	}
	return out;
}

// Build/write the ps5_cloud_catalog_v6 envelope from imagic outputs.
static void write_v6_cache(ChiakiLog *log, const char *cache_dir, const char *locale,
                           struct json_object *browse, struct json_object *supplement,
                           struct json_object *aliases)
{
	struct json_object *v6 = json_object_new_object();
	cc_json_set_str(v6, "locale", locale);
	json_object_object_add(v6, "games", cc_json_clone(browse));
	json_object_object_add(v6, "total", json_object_new_int((int)json_object_array_length(browse)));
	json_object_object_add(v6, "plusLibrarySupplement", cc_json_clone(supplement));
	if(aliases && json_object_object_length(aliases) > 0)
		json_object_object_add(v6, "productIdAliases", cc_json_clone(aliases));
	cc_cache_write(log, cache_dir, "ps5_cloud_catalog_v6", v6);
	json_object_put(v6);
}

static void write_library_cache(ChiakiLog *log, const char *cache_dir,
                                struct json_object *owned, struct json_object *components)
{
	struct json_object *lib = json_object_new_object();
	json_object_object_add(lib, "games", cc_json_clone(owned));
	json_object_object_add(lib, "total", json_object_new_int((int)json_object_array_length(owned)));
	json_object_object_add(lib, "componentIdsByProductId", cc_json_clone(components));
	cc_cache_write(log, cache_dir, "ps5_cloud_library", lib);
	json_object_put(lib);
}

static ChiakiErrorCode finish_ok(ChiakiCloudCatalogResult *out, struct json_object *env)
{
	const char *s = json_object_to_json_string_ext(env, JSON_C_TO_STRING_PLAIN);
	out->json = s ? strdup(s) : NULL;
	out->err = out->json ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_MEMORY;
	return out->err;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_cloudcatalog_fetch_unified(
	const ChiakiCloudCatalogConfig *config, ChiakiCloudCatalogResult *out, ChiakiLog *log)
{
	if(!config || !out || !config->cache_dir)
		return CHIAKI_ERR_INVALID_DATA;
	memset(out, 0, sizeof(*out));

	const char *cache_dir = config->cache_dir;
	const char *locale = (config->locale && *config->locale) ? config->locale : "en-US";
	const char *npsso = config->npsso ? config->npsso : "";
	bool force = config->force_refresh;

	cc_cache_ensure_dir(cache_dir);

	// 1. unified cache hit -> no network. The cache key is versioned (v3) AND the
	// payload's schemaVersion is validated, so a unified cache written by an older
	// build (different contract) is never served as a stale hit.
	if(!force)
	{
		struct json_object *cached = cc_cache_read(log, cache_dir, "unified_catalog_v3", CC_CACHE_TTL_MS);
		if(cached)
		{
			struct json_object *sv = NULL;
			int ver = json_object_object_get_ex(cached, "schemaVersion", &sv)
				? json_object_get_int(sv) : 0;
			if(ver == CHIAKI_CLOUDCATALOG_SCHEMA_VERSION)
			{
				ChiakiErrorCode e = finish_ok(out, cached);
				json_object_put(cached);
				return e;
			}
			CHIAKI_LOGI(log, "[CACHE] unified schemaVersion %d != %d; refetching",
				ver, CHIAKI_CLOUDCATALOG_SCHEMA_VERSION);
			cc_cache_remove(cache_dir, "unified_catalog_v3");
			json_object_put(cached);
		}
	}

	// 2. native APOLLOROOT probe. The probe also reports the account's region
	// (country/language) from the Kamaji session so the lib can own region detection
	// instead of trusting only the caller-supplied locale.
	bool auth_error = false, native = false;
	char fallback_region[8] = "";
	const char *warning = "";
	struct json_object *apollo = NULL;
	char acct_country[8] = "", acct_language[8] = "";
	char store_country[8] = "", store_lang[8] = "";

	bool apollo_complete = true;
	CCNativeResult nr = cc_fetch_psnow_native(log, npsso, &apollo,
		acct_country, sizeof(acct_country), acct_language, sizeof(acct_language),
		store_country, sizeof(store_country), store_lang, sizeof(store_lang),
		&apollo_complete);
	if(nr == CC_NATIVE_OK)
	{
		native = true;
		if(store_country[0])
		{
			snprintf(fallback_region, sizeof(fallback_region), "%s", store_country);
			CHIAKI_LOGI(log, "[UNIFIED] resolvedStoreCountry=%s (native base_url)", store_country);
		}
	}
	else if(nr == CC_NATIVE_AUTH_ERROR)
	{
		auth_error = true;
		warning = WARNING_EXPIRED;
		apollo = json_object_new_array();
		CHIAKI_LOGW(log, "[UNIFIED] native probe auth error; prompting re-login");
	}
	else // region unsupported / fatal -> public fallback
	{
		char cc[8];
		// Prefer the account country from the Kamaji session (captured even when
		// /user/stores 404'd); only fall back to the input locale's country.
		if(acct_country[0])
			snprintf(cc, sizeof(cc), "%s", acct_country);
		else
			account_country_from_locale(locale, cc, sizeof(cc));
		bool fallback_complete = true;
		apollo = cc_fetch_apollo_fallback(log, cc, &fallback_complete);
		// Preserve the account country for modern PS4 product resolution. The
		// cloud-session layer maps only legacy PS3 ids to the regional US/GB
		// Classics store; using that Classics country for every title makes modern
		// CUSA products disappear (for example HU/en products 404 in GB/en).
		snprintf(fallback_region, sizeof(fallback_region), "%s", cc);
		CHIAKI_LOGI(log, "[UNIFIED] resolvedStoreCountry=%s (fallback account country)", fallback_region);
		// Only a definitive REGION_UNSUPPORTED (completed 4xx) may be cached: a FATAL
		// (transport failure / 5xx anywhere in the native probe) means a native-capable
		// account could be looking at the degraded fallback, so serve it for this
		// session but leave the cache empty and re-probe on the next fetch. A fallback
		// pagination abort likewise must not freeze a partial classics list for the TTL.
		if(nr == CC_NATIVE_FATAL || !fallback_complete)
			apollo_complete = false;
	}
	if(!apollo)
		apollo = json_object_new_array();

	// Effective store locale: the lib owns region detection. When the Kamaji session
	// reports a country that differs from the caller-supplied locale's country (e.g. a
	// fresh "en-US" install on a Hungarian account), re-base the locale on the real
	// account region ("hu-HU") so the imagic store-locale chain and the returned
	// settledLocale reflect it. When the country already matches, keep the caller's
	// locale so a previously imagic-settled refinement (e.g. "en-HU") is preserved.
	// Callers persist settledLocale, so this converges after one fetch.
	char effective_locale[16];
	snprintf(effective_locale, sizeof(effective_locale), "%s", locale);
	if(acct_country[0])
	{
		char input_cc[8];
		account_country_from_locale(locale, input_cc, sizeof(input_cc));
		if(strcasecmp(input_cc, acct_country) != 0)
		{
			// Compose canonically (lowercase lang subtag, uppercase country) to match
			// canonical_store_locale(); a server "language" may arrive as a full locale
			// (e.g. "hu-HU"), so keep only the bit before the first '-'.
			char lang[8] = "en";
			if(acct_language[0])
			{
				size_t i = 0;
				for(const char *p = acct_language; *p && *p != '-' && i < sizeof(lang) - 1; p++)
					lang[i++] = (char)tolower((unsigned char)*p);
				lang[i] = 0;
				if(!lang[0])
					snprintf(lang, sizeof(lang), "en");
			}
			char cc_up[8];
			size_t j = 0;
			for(const char *p = acct_country; *p && j < sizeof(cc_up) - 1; p++)
				cc_up[j++] = (char)toupper((unsigned char)*p);
			cc_up[j] = 0;
			snprintf(effective_locale, sizeof(effective_locale), "%s-%s", lang, cc_up);
			CHIAKI_LOGI(log, "[UNIFIED] account region %s differs from locale %s; using %s",
				acct_country, locale, effective_locale);
		}
	}

	// 3. imagic (cache, then network with locale fallback).
	struct json_object *browse = NULL, *supplement = NULL, *aliases = NULL;
	// True only when the PS5 browse universe is known-complete (v6 cache hit — its
	// write was already gated on all-ps5-list — or a fresh fetch where all-ps5-list
	// succeeded). Gates the unified cache write below: a browse missing its main
	// list would otherwise cache a catalog whose streamability gate silently drops
	// owned PS5 games for the whole TTL.
	bool browse_complete = false;
	char settled[16];
	snprintf(settled, sizeof(settled), "%s", effective_locale);

	struct json_object *v6 = force ? NULL : cc_cache_read(log, cache_dir, "ps5_cloud_catalog_v6", CC_CACHE_TTL_MS);
	if(v6)
	{
		const char *cl = cc_json_str(v6, "locale");
		if(*cl && strcmp(cl, effective_locale) != 0)
		{
			CHIAKI_LOGI(log, "[CACHE] v6 locale %s != %s; refetching", cl, effective_locale);
			json_object_put(v6);
			v6 = NULL;
		}
	}
	if(v6)
	{
		struct json_object *g = cc_json_arr(v6, "games");
		struct json_object *s = cc_json_arr(v6, "plusLibrarySupplement");
		struct json_object *a = cc_json_obj(v6, "productIdAliases");
		struct json_object *fb = NULL;
		browse = cc_json_clone(g ? g : (fb = json_object_new_array()));
		if(fb) { json_object_put(fb); fb = NULL; }
		supplement = cc_json_clone(s ? s : (fb = json_object_new_array()));
		if(fb) { json_object_put(fb); fb = NULL; }
		aliases = a ? cc_json_clone(a) : json_object_new_object();
		const char *cl = cc_json_str(v6, "locale");
		if(*cl)
			snprintf(settled, sizeof(settled), "%s", cl);
		json_object_put(v6);
		browse_complete = true;
	}
	else
	{
		CCImagicResult ir;
		if(cc_fetch_imagic(log, effective_locale, &ir))
		{
			browse = ir.browse; ir.browse = NULL;
			supplement = ir.supplement; ir.supplement = NULL;
			aliases = ir.aliases; ir.aliases = NULL;
			snprintf(settled, sizeof(settled), "%s", ir.settled_locale);
			browse_complete = ir.all_ps5_list_succeeded;
			if(ir.all_ps5_list_succeeded)
				write_v6_cache(log, cache_dir, settled, browse, supplement, aliases);
			cc_imagic_result_fini(&ir);
		}
		else
		{
			cc_imagic_result_fini(&ir);
		}
	}
	if(!browse) browse = json_object_new_array();
	if(!supplement) supplement = json_object_new_array();
	if(!aliases) aliases = json_object_new_object();

	// Hard-fail only when BOTH catalog sources came back empty and the session is
	// valid. An empty Apollo is fine as long as the imagic PS5 browse universe loaded
	// (e.g. a flaky native category walk shouldn't nuke 4000+ PS5 titles); an expired
	// session still returns the browse universe plus a re-login warning.
	if(json_object_array_length(apollo) == 0
		&& json_object_array_length(browse) == 0 && !auth_error)
	{
		json_object_put(apollo);
		json_object_put(browse);
		json_object_put(supplement);
		json_object_put(aliases);
		out->err = CHIAKI_ERR_UNKNOWN;
		out->error_message = strdup("Failed to fetch cloud catalog");
		return out->err;
	}

	// 4. owned entitlements (skip on missing/expired session).
	bool owned_complete = true;
	struct json_object *owned = NULL, *components = NULL;
	if(*npsso && !auth_error)
	{
		struct json_object *lib = force ? NULL : cc_cache_read(log, cache_dir, "ps5_cloud_library", CC_CACHE_TTL_MS);
		if(lib)
		{
			struct json_object *g = cc_json_arr(lib, "games");
			struct json_object *c = cc_json_obj(lib, "componentIdsByProductId");
			struct json_object *fb2 = NULL;
			owned = cc_json_clone(g ? g : (fb2 = json_object_new_array()));
			if(fb2) json_object_put(fb2);
			components = c ? cc_json_clone(c) : json_object_new_object();
			json_object_put(lib);
		}
		else
		{
			CCOwnedResult orr = cc_fetch_owned(log, npsso, &owned, &components);
			if(orr == CC_OWNED_OK)
				write_library_cache(log, cache_dir, owned, components);
			else if(orr == CC_OWNED_AUTH_ERROR)
			{
				auth_error = true;
				warning = WARNING_EXPIRED;
			}
			else
			{
				// Transient commerce-API failure: serve this session without
				// ownership, but don't cache the degraded catalog (same rule as
				// apollo_complete / browse_complete) — otherwise one 5xx hides
				// the user's whole owned library for the full cache TTL.
				owned_complete = false;
				CHIAKI_LOGW(log, "[CLOUDCATALOG] owned entitlements fetch failed; catalog will not be cached");
			}
		}
	}
	if(!owned) owned = json_object_new_array();
	if(!components) components = json_object_new_object();

	// 5. cross-reference owned -> catalog.
	struct json_object *owned_cross_ref =
		cc_build_owned_cross_ref(log, apollo, browse, supplement, aliases, owned, components);

	// 6. assemble.
	CCAssembleInput in;
	memset(&in, 0, sizeof(in));
	in.apollo_games = apollo;
	in.imagic_browse = browse;
	in.imagic_supplement = supplement;
	in.owned_cross_ref = owned_cross_ref;
	in.native_mode = native;
	in.fallback_region = fallback_region;
	// Server-authoritative store language parsed from the native base_url (e.g. "nl"); "" in the
	// public-fallback path (no base_url). Clients use it for the step0_5d container URL so a
	// non-English native store (which 404s on the wrong language) always gets its real language.
	in.resolved_store_lang = store_lang;
	in.settled_locale = settled;
	in.warning = warning;
	struct json_object *env = cc_assemble_unified_catalog(log, &in);

	// 7. cache write guard (non-empty + not auth error + all three sources complete).
	struct json_object *games = cc_json_arr(env, "games");
	int total = games ? (int)json_object_array_length(games) : 0;
	if(total > 0 && !auth_error && apollo_complete && browse_complete && owned_complete)
		cc_cache_write(log, cache_dir, "unified_catalog_v3", env);

	ChiakiErrorCode e = finish_ok(out, env);

	json_object_put(env);
	json_object_put(owned_cross_ref);
	json_object_put(apollo);
	json_object_put(browse);
	json_object_put(supplement);
	json_object_put(aliases);
	json_object_put(owned);
	json_object_put(components);
	return e;
}

CHIAKI_EXPORT void chiaki_cloudcatalog_result_fini(ChiakiCloudCatalogResult *out)
{
	if(!out)
		return;
	free(out->json);
	free(out->error_message);
	memset(out, 0, sizeof(*out));
}

CHIAKI_EXPORT void chiaki_cloudcatalog_invalidate_cache(const char *cache_dir)
{
	if(!cache_dir)
		return;
	// Current keys + legacy keys, so invalidation also purges caches written by
	// older builds (e.g. the pre-contract unified_catalog_v2).
	static const char *const keys[] = {
		"unified_catalog_v3", "ps5_cloud_catalog_v6", "ps5_cloud_library",
		"psnow_catalog",
		"unified_catalog_v2", "unified_catalog_v1",
		"ps5_cloud_catalog_v5", "ps5_cloud_catalog_v4", "ps5_cloud_catalog_v3",
		"ps5_cloud_catalog_v2", "ps5_cloud_catalog",
		NULL
	};
	for(size_t i = 0; keys[i]; i++)
		cc_cache_remove(cache_dir, keys[i]);
}
