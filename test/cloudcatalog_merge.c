// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Offline merge/assembly tests for the libchiaki cloud catalog. Synthetic
// inputs exercise the tricky cases that drove the parity work: apollo<->imagic
// browse dedup, device-based PS5 membership, trial suppression, cross-buy
// wrapper drop, category tagging, the contract fields, and sort order.

#include <munit.h>

#include "../lib/src/cloudcatalog_internal.h"
#include <chiaki/cloudcatalog.h>
#include "test_log.h"

#include <json-c/json.h>
#include <string.h>

static struct json_object *parse(const char *s)
{
	struct json_object *o = json_tokener_parse(s);
	munit_assert_not_null(o);
	return o;
}

static struct json_object *games_of(struct json_object *env)
{
	struct json_object *g = NULL;
	munit_assert_true(json_object_object_get_ex(env, "games", &g));
	return g;
}

static struct json_object *find_pid(struct json_object *games, const char *pid)
{
	size_t n = json_object_array_length(games);
	struct json_object *found = NULL;
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *g = json_object_array_get_idx(games, i);
		if(strcmp(cc_json_str(g, "productId"), pid) == 0)
			found = g; // last match (also lets us count)
	}
	return found;
}

static int count_pid(struct json_object *games, const char *pid)
{
	size_t n = json_object_array_length(games);
	int c = 0;
	for(size_t i = 0; i < n; i++)
		if(strcmp(cc_json_str(json_object_array_get_idx(games, i), "productId"), pid) == 0)
			c++;
	return c;
}

static int count_cat(struct json_object *games, const char *cat)
{
	size_t n = json_object_array_length(games);
	int c = 0;
	for(size_t i = 0; i < n; i++)
		if(strcmp(cc_json_str(json_object_array_get_idx(games, i), "category"), cat) == 0)
			c++;
	return c;
}

// Apollo title that also appears in the imagic PS5 browse list (same productId)
// must emit exactly once, as the authoritative psnow/streamable row.
static MunitResult test_apollo_dedup(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *apollo = parse("[{\"id\":\"PPSA-CROW_00\",\"name\":\"Crow Country\",\"conceptId\":111}]");
	struct json_object *browse = parse("[{\"productId\":\"PPSA-CROW_00\",\"name\":\"Crow Country\",\"conceptId\":111,\"device\":[\"PS5\"],\"streamingSupported\":true}]");

	CCAssembleInput in = { 0 };
	in.apollo_games = apollo;
	in.imagic_browse = browse;
	in.native_mode = true;
	in.fallback_region = "";

	struct json_object *env = cc_assemble_unified_catalog(get_test_log(), &in);
	struct json_object *games = games_of(env);

	munit_assert_int(count_pid(games, "PPSA-CROW_00"), ==, 1);
	struct json_object *crow = find_pid(games, "PPSA-CROW_00");
	munit_assert_string_equal(cc_json_str(crow, "serviceType"), "psnow");
	munit_assert_string_equal(cc_json_str(crow, "category"), "streamable");
	munit_assert_string_equal(cc_json_str(crow, "streamServiceType"), "psnow");

	json_object_put(env);
	json_object_put(apollo);
	json_object_put(browse);
	return MUNIT_OK;
}

// A CUSA-id browse game whose device[] includes "PS5" is a PS5 title and must be
// kept (the bug we fixed: token-only PPSA check dropped these). A PS4-only device
// game is excluded from the PS5 browse universe.
static MunitResult test_device_based_ps5(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *browse = parse(
		"[{\"productId\":\"CUSA-BUNDLE_00\",\"name\":\"Indie Bundle\",\"device\":[\"PS4\",\"PS5\"],\"streamingSupported\":true,\"conceptId\":501},"
		" {\"productId\":\"CUSA-PS4ONLY_00\",\"name\":\"PS4 Only\",\"device\":[\"PS4\"],\"streamingSupported\":true,\"conceptId\":502}]");

	CCAssembleInput in = { 0 };
	in.imagic_browse = browse;
	in.native_mode = false; // skip gate so we test pure membership
	in.fallback_region = "US";

	struct json_object *env = cc_assemble_unified_catalog(get_test_log(), &in);
	struct json_object *games = games_of(env);

	struct json_object *bundle = find_pid(games, "CUSA-BUNDLE_00");
	munit_assert_not_null(bundle);
	munit_assert_string_equal(cc_json_str(bundle, "platform"), "ps5");
	munit_assert_string_equal(cc_json_str(bundle, "serviceType"), "pscloud");
	munit_assert_string_equal(cc_json_str(bundle, "category"), "purchaseable");

	munit_assert_null(find_pid(games, "CUSA-PS4ONLY_00"));

	json_object_put(env);
	json_object_put(browse);
	return MUNIT_OK;
}

// pscloud owned claim stamps the PS5 browse card; a PS4 cross-buy psnow wrapper
// carrying the SAME PPSA productId is dropped (no ghost duplicate). The trial of
// a fully-owned product is suppressed.
static MunitResult test_crossbuy_and_trial(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *browse = parse(
		"[{\"productId\":\"PPSA-TRACK_00\",\"name\":\"Trackmania\",\"conceptId\":333,\"device\":[\"PS5\"],\"streamingSupported\":true}]");
	struct json_object *owned = parse(
		"[{\"serviceType\":\"pscloud\",\"id\":\"PPSA-TRACK-ENT\",\"product_id\":\"PPSA-TRACK_00\",\"conceptId\":333,\"feature_type\":3,\"game_meta\":{\"name\":\"Trackmania\"}},"
		" {\"serviceType\":\"psnow\",\"id\":\"CUSA-TRACK-ENT\",\"product_id\":\"PPSA-TRACK_00\",\"conceptId\":333,\"feature_type\":1,\"game_meta\":{\"name\":\"Trackmania Trial\"}}]");

	CCAssembleInput in = { 0 };
	in.imagic_browse = browse;
	in.owned_cross_ref = owned;
	in.native_mode = true;
	in.fallback_region = "";

	struct json_object *env = cc_assemble_unified_catalog(get_test_log(), &in);
	struct json_object *games = games_of(env);

	munit_assert_int(count_pid(games, "PPSA-TRACK_00"), ==, 1);
	struct json_object *track = find_pid(games, "PPSA-TRACK_00");
	munit_assert_true(cc_json_bool(track, "isOwned"));
	munit_assert_string_equal(cc_json_str(track, "category"), "owned");
	munit_assert_string_equal(cc_json_str(track, "serviceType"), "pscloud");
	// pscloud owned streams the entitlement's own id
	munit_assert_string_equal(cc_json_str(track, "streamIdentifier"), "PPSA-TRACK-ENT");

	json_object_put(env);
	json_object_put(browse);
	json_object_put(owned);
	return MUNIT_OK;
}

// Cross-buy stranded-sibling regression (Worms World Party). The browse lists the
// same concept under two SKUs on the same platform (a CUSA and a PPSA productId,
// both PS5-cloud streamable). The owned PS5 entitlement (product_id = CUSA, id =
// PPSA) claims the CUSA row; the PPSA sibling must NOT remain as a purchaseable
// "Add Game" duplicate of a title you already own.
static MunitResult test_crossbuy_sku_sibling(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *browse = parse(
		"[{\"productId\":\"UP-CUSA_00\",\"name\":\"Worms\",\"conceptId\":900,\"device\":[\"PS5\"],\"streamingSupported\":true},"
		" {\"productId\":\"UP-PPSA_00\",\"name\":\"Worms\",\"conceptId\":900,\"device\":[\"PS5\"],\"streamingSupported\":true}]");
	struct json_object *owned = parse(
		"[{\"serviceType\":\"pscloud\",\"id\":\"UP-PPSA_00\",\"product_id\":\"UP-CUSA_00\",\"conceptId\":900,\"feature_type\":3,\"game_meta\":{\"name\":\"Worms\"}},"
		" {\"serviceType\":\"psnow\",\"id\":\"UP-CUSA_00\",\"product_id\":\"UP-CUSA_00\",\"conceptId\":900,\"feature_type\":3,\"game_meta\":{\"name\":\"Worms\"}}]");

	CCAssembleInput in = { 0 };
	in.imagic_browse = browse;
	in.owned_cross_ref = owned;
	in.native_mode = true;
	in.fallback_region = "";

	struct json_object *env = cc_assemble_unified_catalog(get_test_log(), &in);
	struct json_object *games = games_of(env);

	// Exactly one Worms card, owned; the purchaseable PPSA sibling is gone.
	munit_assert_int(count_cat(games, "owned"), ==, 1);
	munit_assert_int(count_cat(games, "purchaseable"), ==, 0);
	munit_assert_int(count_pid(games, "UP-PPSA_00"), ==, 0);
	struct json_object *worms = find_pid(games, "UP-CUSA_00");
	munit_assert_not_null(worms);
	munit_assert_true(cc_json_bool(worms, "isOwned"));
	// Streams via the PS5 entitlement id (cross-buy rescue).
	munit_assert_string_equal(cc_json_str(worms, "streamIdentifier"), "UP-PPSA_00");

	json_object_put(env);
	json_object_put(browse);
	json_object_put(owned);
	return MUNIT_OK;
}

// Ownership stamping can make two source rows converge on the same canonical
// productId. The contract must emit one card, preferring the directly streamable
// owned pscloud route over the legacy psnow wrapper. Android used to crash as soon
// as both cards were laid out because productId backed RecyclerView stable IDs.
static MunitResult test_duplicate_product_id_after_routing(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *browse = parse(
		"[{\"productId\":\"EP-CUSA-DUP_00\",\"name\":\"Duplicate\",\"conceptId\":700,\"device\":[\"PS5\"],\"streamingSupported\":true,\"serviceType\":\"psnow\",\"isOwned\":true,\"plusCatalog\":true},"
		" {\"productId\":\"EP-CUSA-DUP_00\",\"name\":\"Duplicate\",\"conceptId\":700,\"device\":[\"PS5\"],\"streamingSupported\":true,\"serviceType\":\"pscloud\",\"isOwned\":true}]");

	CCAssembleInput in = { 0 };
	in.imagic_browse = browse;
	in.native_mode = false;
	in.fallback_region = "";

	struct json_object *env = cc_assemble_unified_catalog(get_test_log(), &in);
	struct json_object *games = games_of(env);

	munit_assert_int(count_pid(games, "EP-CUSA-DUP_00"), ==, 1);
	struct json_object *game = find_pid(games, "EP-CUSA-DUP_00");
	munit_assert_not_null(game);
	munit_assert_string_equal(cc_json_str(game, "category"), "owned");
	munit_assert_string_equal(cc_json_str(game, "streamServiceType"), "pscloud");
	munit_assert_true(cc_json_bool(game, "plusCatalog"));

	json_object_put(env);
	json_object_put(browse);
	return MUNIT_OK;
}

// Canonical full-game entitlements commonly have id == product_id. They are still
// real owned entitlements and must reach the contract so PSNOW can use its owned
// fast path instead of resolving a potentially stale catalog alias through pcnow.
static MunitResult test_owned_psnow_canonical_entitlement(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *owned = parse(
		"[{\"id\":\"EP9000-CUSA07410_00-00000000GODOFWAR\","
		"\"product_id\":\"EP9000-CUSA07410_00-00000000GODOFWAR\","
		"\"productId\":\"EP9000-CUSA07410_00-00000000GODOFWAR\","
		"\"catalogProductId\":\"EP9000-CUSA07410_00-0000000GODOFWARN\","
		"\"name\":\"God of War\",\"serviceType\":\"psnow\","
		"\"feature_type\":3,\"device\":[\"PS4\"]}]");

	CCAssembleInput in = { 0 };
	in.owned_cross_ref = owned;
	in.native_mode = false;
	in.fallback_region = "GB";

	struct json_object *env = cc_assemble_unified_catalog(get_test_log(), &in);
	struct json_object *game = find_pid(games_of(env),
		"EP9000-CUSA07410_00-00000000GODOFWAR");
	munit_assert_not_null(game);
	munit_assert_true(cc_json_bool(game, "isOwned"));
	munit_assert_string_equal(cc_json_str(game, "entitlementId"),
		"EP9000-CUSA07410_00-00000000GODOFWAR");
	munit_assert_string_equal(cc_json_str(game, "storeProductId"),
		"EP9000-CUSA07410_00-00000000GODOFWAR");
	munit_assert_string_equal(cc_json_str(game, "streamIdentifier"),
		"EP9000-CUSA07410_00-0000000GODOFWARN");

	json_object_put(env);
	json_object_put(owned);
	return MUNIT_OK;
}

// owned rows sort before non-owned; envelope carries schema + counts.
static MunitResult test_sort_and_envelope(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *browse = parse(
		"[{\"productId\":\"PPSA-ZEBRA_00\",\"name\":\"Zebra\",\"device\":[\"PS5\"],\"streamingSupported\":true,\"conceptId\":1},"
		" {\"productId\":\"PPSA-APPLE_00\",\"name\":\"Apple\",\"device\":[\"PS5\"],\"streamingSupported\":true,\"conceptId\":2}]");
	struct json_object *owned = parse(
		"[{\"serviceType\":\"pscloud\",\"id\":\"PPSA-ZEBRA_00\",\"product_id\":\"PPSA-ZEBRA_00\",\"conceptId\":1,\"feature_type\":3,\"game_meta\":{\"name\":\"Zebra\"}}]");

	CCAssembleInput in = { 0 };
	in.imagic_browse = browse;
	in.owned_cross_ref = owned;
	in.native_mode = false;
	in.fallback_region = "";
	in.settled_locale = "en-US";

	struct json_object *env = cc_assemble_unified_catalog(get_test_log(), &in);
	struct json_object *games = games_of(env);

	munit_assert_int(json_object_get_int(json_object_object_get(env, "schemaVersion")), ==, CHIAKI_CLOUDCATALOG_SCHEMA_VERSION);
	munit_assert_int(json_object_get_int(json_object_object_get(env, "total")), ==, (int)json_object_array_length(games));
	munit_assert_string_equal(cc_json_str(env, "settledLocale"), "en-US");

	// Owned Zebra sorts before unowned Apple despite alphabetical order.
	munit_assert_true(cc_json_bool(json_object_array_get_idx(games, 0), "isOwned"));
	munit_assert_string_equal(cc_json_str(json_object_array_get_idx(games, 0), "name"), "Zebra");

	munit_assert_int(count_cat(games, "owned"), ==, 1);
	munit_assert_int(count_cat(games, "purchaseable"), ==, 1);

	json_object_put(env);
	json_object_put(browse);
	json_object_put(owned);
	return MUNIT_OK;
}

// Cloud streaming language / datacenter helpers (cross-platform source of truth).
static MunitResult test_cloud_language_helpers(const MunitParameter params[], void *data)
{
	(void)params;
	(void)data;
	char buf[16];

	// Gaikai wants the bare lowercase language code, not the full locale.
	chiaki_cloud_gaikai_language("de-DE", buf, sizeof(buf));
	munit_assert_string_equal(buf, "de");
	chiaki_cloud_gaikai_language("en-US", buf, sizeof(buf));
	munit_assert_string_equal(buf, "en");
	chiaki_cloud_gaikai_language("pt_BR", buf, sizeof(buf));
	munit_assert_string_equal(buf, "pt");
	chiaki_cloud_gaikai_language("FR", buf, sizeof(buf));
	munit_assert_string_equal(buf, "fr");
	chiaki_cloud_gaikai_language("", buf, sizeof(buf));
	munit_assert_string_equal(buf, "en");
	chiaki_cloud_gaikai_language(NULL, buf, sizeof(buf));
	munit_assert_string_equal(buf, "en");

	// Supported locale enumeration.
	size_t n = chiaki_cloud_supported_locale_count();
	munit_assert_int((int)n, >=, 5);
	bool seen_de = false, seen_en_us = false;
	for(size_t i = 0; i < n; i++)
	{
		const char *l = chiaki_cloud_supported_locale(i);
		if(strcmp(l, "de-DE") == 0)
			seen_de = true;
		if(strcmp(l, "en-US") == 0)
			seen_en_us = true;
	}
	munit_assert_true(seen_de);
	munit_assert_true(seen_en_us);
	munit_assert_string_equal(chiaki_cloud_supported_locale(n), ""); // out of range

	return MUNIT_OK;
}

// Phase 2 store-country resolution: parse /container/{COUNTRY}/{lang}/ out of the
// Sony store base_url. The country drives step0_5d's product->entitlement lookup, so
// a wrong/partial parse must fail closed (return false, leave outputs empty) rather
// than feed a malformed container URL.
static MunitResult test_parse_container_store_locale(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	char cc[8], lang[8];

	// Happy path: US/en.
	munit_assert_true(cc_parse_container_store_locale(
		"https://store.example/container/US/en/19/PPSA01234_00?x=1", cc, sizeof(cc), lang, sizeof(lang)));
	munit_assert_string_equal(cc, "US");
	munit_assert_string_equal(lang, "en");

	// Non-English native account (the regression the store_lang fix protects): country
	// and language are both taken verbatim from the server base_url.
	munit_assert_true(cc_parse_container_store_locale(
		"https://store.example/container/FI/fi/19/EP9000-NPEA_00", cc, sizeof(cc), lang, sizeof(lang)));
	munit_assert_string_equal(cc, "FI");
	munit_assert_string_equal(lang, "fi");

	// No /container/ segment -> fail closed, outputs empty.
	munit_assert_false(cc_parse_container_store_locale(
		"https://store.example/foo/bar/baz", cc, sizeof(cc), lang, sizeof(lang)));
	munit_assert_string_equal(cc, "");
	munit_assert_string_equal(lang, "");

	// Empty country segment (//) -> fail.
	munit_assert_false(cc_parse_container_store_locale(
		"https://store.example/container//en/19/x", cc, sizeof(cc), lang, sizeof(lang)));

	// Country present but the language segment has no closing slash -> fail.
	munit_assert_false(cc_parse_container_store_locale(
		"https://store.example/container/US/en", cc, sizeof(cc), lang, sizeof(lang)));

	// Country segment longer than its buffer -> fail (bounds guard), not truncate.
	{
		char tiny[3]; // holds 2 chars + NUL
		munit_assert_false(cc_parse_container_store_locale(
			"https://store.example/container/USA/en/19/x", tiny, sizeof(tiny), lang, sizeof(lang)));
		munit_assert_string_equal(tiny, "");
	}

	return MUNIT_OK;
}

// Public fallback must walk the PS3 child container, not APOLLOROOT. The root
// contains category links only, so filtering it for products produces zero games.
static MunitResult test_classics_region_containers(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	munit_assert_string_equal(cc_classics_store_country("US"), "US");
	munit_assert_string_equal(cc_classics_ps3_container_id("US"),
		"STORE-MSF192018-APOLLOPS3GAMES");
	munit_assert_string_equal(cc_classics_store_country("BR"), "US");
	munit_assert_string_equal(cc_classics_ps3_container_id("BR"),
		"STORE-MSF192018-APOLLOPS3GAMES");

	munit_assert_string_equal(cc_classics_store_country("HU"), "GB");
	munit_assert_string_equal(cc_classics_ps3_container_id("HU"),
		"STORE-MSF192014-APOLLOPS3");
	munit_assert_string_equal(cc_classics_store_country("JP"), "GB");
	munit_assert_string_equal(cc_classics_ps3_container_id("JP"),
		"STORE-MSF192014-APOLLOPS3");
	return MUNIT_OK;
}

static MunitResult test_stable_key(const MunitParameter params[], void *user)
{
	(void)params; (void)user;
	char out[128];
	munit_assert_string_equal(
		cc_stable_key("UP9000-CUSA00552_00-GODOFWAR3HDGAME0", out, sizeof(out)),
		"UP9000|CUSA00552|00");
	munit_assert_string_equal(cc_stable_key("A-B-C", out, sizeof(out)), "A|B");
	munit_assert_string_equal(cc_stable_key("SINGLETOKEN", out, sizeof(out)), "");
	munit_assert_string_equal(cc_stable_key("", out, sizeof(out)), "");
	munit_assert_string_equal(cc_stable_key(NULL, out, sizeof(out)), "");
	return MUNIT_OK;
}

MunitTest tests_cloudcatalog_merge[] = {
	{ "/apollo_dedup", test_apollo_dedup, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/device_based_ps5", test_device_based_ps5, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/crossbuy_and_trial", test_crossbuy_and_trial, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/crossbuy_sku_sibling", test_crossbuy_sku_sibling, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/duplicate_product_id_after_routing", test_duplicate_product_id_after_routing, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/owned_psnow_canonical_entitlement", test_owned_psnow_canonical_entitlement, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/sort_and_envelope", test_sort_and_envelope, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/cloud_language_helpers", test_cloud_language_helpers, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/parse_container_store_locale", test_parse_container_store_locale, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/classics_region_containers", test_classics_region_containers, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/stable_key", test_stable_key, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL }
};
