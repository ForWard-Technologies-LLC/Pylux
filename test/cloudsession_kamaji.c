// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Offline tests for the Kamaji resolve helpers: streaming/full-game entitlement
// selection and regional store routing.

#include <munit.h>

#include "../lib/src/cloudsession_internal.h"

#include <json-c/json.h>
#include <string.h>

static struct json_object *parse(const char *s)
{
	struct json_object *o = json_tokener_parse(s);
	munit_assert_not_null(o);
	return o;
}

static MunitResult test_streaming_package_fallback(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *sku = parse(
		"{\"id\":\"EP9000-CUSA00207_00-BLOODBORNE0000EU-E009\",\"entitlements\":["
		"{\"id\":\"EP9000-CUSA00207_00-BLOODBORNE0000EU\",\"license_type\":0,\"packageType\":\"PS4GD\"},"
		"{\"id\":\"EP9000-CUSA00207_00-PSRSVD0000000000\",\"license_type\":0,\"packageType\":\"PS4GS\"}"
		"]}");
	char out[128] = "";
	munit_assert_true(km_pick_streaming_id(sku, out, sizeof(out)));
	munit_assert_string_equal(out, "EP9000-CUSA00207_00-PSRSVD0000000000");
	json_object_put(sku);
	return MUNIT_OK;
}

// A non-"GD" entitlement is skipped; the *GD one is chosen (packageType-driven).
static MunitResult test_gd_fallback_picks_gd(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *sku = parse(
		"{\"id\":\"SKU-1\",\"entitlements\":["
		"{\"id\":\"UP9000-CUSA00001_00-DLC0000000000001\",\"packageType\":\"PS4DL\"},"
		"{\"id\":\"UP9000-CUSA12345_00-FULLGAME00000001\",\"packageType\":\"PS4GD\"}"
		"]}");
	char out[128] = "";
	munit_assert_true(km_pick_fullgame_id(sku, false, NULL, out, sizeof(out), NULL));
	munit_assert_string_equal(out, "UP9000-CUSA12345_00-FULLGAME00000001");
	json_object_put(sku);
	return MUNIT_OK;
}

// require_title picks the *GD entitlement whose id contains the title id; a
// non-matching title id finds nothing on that pass, but the relaxed pass takes
// the first *GD regardless (mirrors km_step0_5d_resolve's two-pass loop).
static MunitResult test_gd_fallback_title_match(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *sku = parse(
		"{\"id\":\"SKU-1\",\"entitlements\":["
		"{\"id\":\"UP9000-CUSA99999_00-OTHERGAME0000001\",\"packageType\":\"PS4GD\"},"
		"{\"id\":\"UP9000-CUSA12345_00-FULLGAME00000001\",\"packageType\":\"PS4GD\"}"
		"]}");
	char out[128] = "";
	munit_assert_true(km_pick_fullgame_id(sku, true, "CUSA12345", out, sizeof(out), NULL));
	munit_assert_string_equal(out, "UP9000-CUSA12345_00-FULLGAME00000001");

	out[0] = '\0';
	munit_assert_false(km_pick_fullgame_id(sku, true, "CUSA00000", out, sizeof(out), NULL));
	munit_assert_string_equal(out, "");

	munit_assert_true(km_pick_fullgame_id(sku, false, "CUSA00000", out, sizeof(out), NULL));
	munit_assert_string_equal(out, "UP9000-CUSA99999_00-OTHERGAME0000001");
	json_object_put(sku);
	return MUNIT_OK;
}

// No *GD entitlement, and a missing entitlements array, both yield no pick (no crash).
static MunitResult test_gd_fallback_none(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *sku = parse(
		"{\"id\":\"SKU-1\",\"entitlements\":["
		"{\"id\":\"UP9000-CUSA00001_00-DLC0000000000001\",\"packageType\":\"PS4DL\"},"
		"{\"id\":\"UP9000-CUSA00001_00-SEASONPASS000001\",\"packageType\":\"PS4SP\"}"
		"]}");
	char out[128] = "unchanged";
	munit_assert_false(km_pick_fullgame_id(sku, false, NULL, out, sizeof(out), NULL));
	json_object_put(sku);

	struct json_object *empty = parse("{\"id\":\"SKU-2\"}");
	munit_assert_false(km_pick_fullgame_id(empty, false, NULL, out, sizeof(out), NULL));
	json_object_put(empty);
	return MUNIT_OK;
}

static MunitResult test_regional_store_routing(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	char country[8], lang[8];

	// Modern PS4 titles resolve in the account storefront. God of War's HU/en
	// product exists while the same product returns 404 from the GB store.
	km_resolve_store_locale("EP9000-CUSA07410_00-0000000GODOFWARN",
		"HU", "en", country, sizeof(country), lang, sizeof(lang));
	munit_assert_string_equal(country, "HU");
	munit_assert_string_equal(lang, "en");

	// Legacy Classics use one of the two Apollo id families regardless of the
	// account storefront's own language/country path.
	km_resolve_store_locale("EP9000-NPEA00255_00-GGODOFWARH000001",
		"HU", "hu", country, sizeof(country), lang, sizeof(lang));
	munit_assert_string_equal(country, "GB");
	munit_assert_string_equal(lang, "en");
	km_resolve_store_locale("UP9000-NPUA80490_00-LEGACYCLASSIC00",
		"BR", "pt", country, sizeof(country), lang, sizeof(lang));
	munit_assert_string_equal(country, "US");
	munit_assert_string_equal(lang, "en");

	// A foreign Classics catalog skips checkout only for legacy ids. Modern PS4
	// reservations still need their free entitlement acquired before Gaikai auth.
	munit_assert_false(km_should_skip_acquire(
		"EP0001-CUSA00605_00-AC5GAMEPS4000001", true));
	munit_assert_true(km_should_skip_acquire(
		"EP9000-NPEA00255_00-GGODOFWARH000001", true));
	munit_assert_false(km_should_skip_acquire(
		"EP9000-NPEA00255_00-GGODOFWARH000001", false));
	return MUNIT_OK;
}

static bool always_cancelled(void *user)
{
	(void)user;
	return true;
}

// A cancel that lands before provisioning starts must return CHIAKI_ERR_CANCELED
// without any network activity (the entry poll runs before the DUID/auth pre-flight,
// so this test is fully offline).
static MunitResult test_cancelled_before_start(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	ChiakiCloudProvisionConfig cfg;
	memset(&cfg, 0, sizeof(cfg));
	cfg.npsso = "test-npsso";
	cfg.service_type = "psnow";
	cfg.game_identifier = "UP9000-CUSA12345_00-FULLGAME00000001";
	cfg.is_cancelled = always_cancelled;
	ChiakiCloudProvisionResult out;
	munit_assert_int(chiaki_cloud_provision_session(&cfg, &out, NULL), ==, CHIAKI_ERR_CANCELED);
	munit_assert_int(out.err, ==, CHIAKI_ERR_CANCELED);
	chiaki_cloud_provision_result_fini(&out);
	return MUNIT_OK;
}

MunitTest tests_cloudsession_kamaji[] = {
	{ "/streaming_package_fallback", test_streaming_package_fallback, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gd_fallback_picks_gd", test_gd_fallback_picks_gd, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gd_fallback_title_match", test_gd_fallback_title_match, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gd_fallback_none", test_gd_fallback_none, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/regional_store_routing", test_regional_store_routing, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/cancelled_before_start", test_cancelled_before_start, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL }
};
