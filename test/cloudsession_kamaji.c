// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Offline tests for the Kamaji resolve helpers. Covers the step 0.5d full-game
// ("*GD") fallback: when a PS Plus title's store container exposes no
// license_type==4 streaming reservation, km_pick_fullgame_id selects the
// full-game digital entitlement (packageType ending "GD"), title-matched first.
// This branch is effectively unreachable with the live catalog (every sampled
// PS4 title carries a streaming reservation), so a synthetic JSON test is the
// only way to pin its behavior.

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

MunitTest tests_cloudsession_kamaji[] = {
	{ "/gd_fallback_picks_gd", test_gd_fallback_picks_gd, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gd_fallback_title_match", test_gd_fallback_title_match, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/gd_fallback_none", test_gd_fallback_none, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL }
};
