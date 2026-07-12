// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Offline tests for the Kamaji resolve helpers. Covers the step 0.5d fallbacks
// that run when a title's store container exposes no license_type==4 streaming
// reservation: km_pick_streaming_gs_id (packageType "*GS" published with
// license_type=0 — real GB-store Bloodborne data) and km_pick_fullgame_id (the
// PS Plus full-game "*GD" fallback), both title-matched first. The *GD branch is
// effectively unreachable with the live US catalog (every sampled PS4 title
// carries a streaming reservation), so synthetic JSON pins its behavior.

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

// Real-world regression (GB store, July 2026): Bloodborne's PSNow sku carries the
// PSRSVD streaming entitlement with license_type=0 — the license_type==4 pass misses
// it, and before the *GS fallback existed the *GD purchase entitlement won and Gaikai
// rejected it (002.2026 noGameForEntitlementId). Sku JSON trimmed from the live
// container response for EP9000-CUSA00207_00-BLOODBORNE0000EU.
static MunitResult test_gs_fallback_bloodborne_gb(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *gd_sku = parse(
		"{\"id\":\"EP9000-CUSA00207_00-BLOODBORNE0000EU-E009\",\"name\":\"Game\",\"entitlements\":["
		"{\"id\":\"EP9000-CUSA00207_00-BLOODBORNE0000EU\",\"license_type\":0,\"packageType\":\"PS4GD\"}"
		"]}");
	struct json_object *gs_sku = parse(
		"{\"id\":\"EP9000-CUSA00207_00-BLOODBORNE0000EU-EC02\",\"name\":\"PSNow\",\"entitlements\":["
		"{\"id\":\"EP9000-CUSA00207_00-PSRSVD0000000000\",\"license_type\":0,\"packageType\":\"PS4GS\"}"
		"]}");
	char out[128] = "";
	// The purchase sku has no *GS entitlement; the PSNow sku's is found despite license_type=0.
	munit_assert_false(km_pick_streaming_gs_id(gd_sku, true, "CUSA00207", out, sizeof(out), NULL));
	munit_assert_true(km_pick_streaming_gs_id(gs_sku, true, "CUSA00207", out, sizeof(out), NULL));
	munit_assert_string_equal(out, "EP9000-CUSA00207_00-PSRSVD0000000000");
	json_object_put(gd_sku);
	json_object_put(gs_sku);
	return MUNIT_OK;
}

// require_title picks the *GS entitlement whose id contains the title id; the relaxed
// pass takes the first *GS regardless (mirrors km_step0_5d_resolve's two-pass loop).
// Non-"GS" package types are never picked.
static MunitResult test_gs_fallback_title_match(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *sku = parse(
		"{\"id\":\"SKU-1\",\"entitlements\":["
		"{\"id\":\"UP9000-CUSA12345_00-FULLGAME00000001\",\"packageType\":\"PS4GD\"},"
		"{\"id\":\"UP9000-CUSA99999_00-PSRSVD0000000000\",\"packageType\":\"PS4GS\"},"
		"{\"id\":\"UP9000-CUSA12345_00-PSRSVD0000000000\",\"packageType\":\"PS4GS\"}"
		"]}");
	char out[128] = "";
	munit_assert_true(km_pick_streaming_gs_id(sku, true, "CUSA12345", out, sizeof(out), NULL));
	munit_assert_string_equal(out, "UP9000-CUSA12345_00-PSRSVD0000000000");

	out[0] = '\0';
	munit_assert_false(km_pick_streaming_gs_id(sku, true, "CUSA00000", out, sizeof(out), NULL));
	munit_assert_string_equal(out, "");

	munit_assert_true(km_pick_streaming_gs_id(sku, false, "CUSA00000", out, sizeof(out), NULL));
	munit_assert_string_equal(out, "UP9000-CUSA99999_00-PSRSVD0000000000");
	json_object_put(sku);
	return MUNIT_OK;
}

// No *GS entitlement, and a missing entitlements array, both yield no pick (no crash).
static MunitResult test_gs_fallback_none(const MunitParameter p[], void *data)
{
	(void)p; (void)data;
	struct json_object *sku = parse(
		"{\"id\":\"SKU-1\",\"entitlements\":["
		"{\"id\":\"UP9000-CUSA00001_00-DLC0000000000001\",\"packageType\":\"PS4DL\"},"
		"{\"id\":\"UP9000-CUSA12345_00-FULLGAME00000001\",\"packageType\":\"PS4GD\"}"
		"]}");
	char out[128] = "unchanged";
	munit_assert_false(km_pick_streaming_gs_id(sku, false, NULL, out, sizeof(out), NULL));
	munit_assert_string_equal(out, "unchanged");
	json_object_put(sku);

	struct json_object *empty = parse("{\"id\":\"SKU-2\"}");
	munit_assert_false(km_pick_streaming_gs_id(empty, false, NULL, out, sizeof(out), NULL));
	munit_assert_string_equal(out, "unchanged");
	json_object_put(empty);
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
	{ "/gd_fallback_picks_gd", test_gd_fallback_picks_gd, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gd_fallback_title_match", test_gd_fallback_title_match, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gd_fallback_none", test_gd_fallback_none, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gs_fallback_bloodborne_gb", test_gs_fallback_bloodborne_gb, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gs_fallback_title_match", test_gs_fallback_title_match, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gs_fallback_none", test_gs_fallback_none, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/cancelled_before_start", test_cancelled_before_start, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL }
};
