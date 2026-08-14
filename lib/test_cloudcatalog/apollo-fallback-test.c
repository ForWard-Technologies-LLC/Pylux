// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Region harness for the anonymous public-fallback catalog walk. Runs
// cc_fetch_apollo_fallback exactly as a fallback-region account would (the walk
// is anonymous and fully determined by the account country), so regional
// behavior — e.g. an HU account mapping to the GB Classics store family — can be
// proven from anywhere without an account in that region.
//
//   apollo-fallback-test <account_country> [out.json]
//
// Prints the walked title count, the completeness flag, and a platform-family
// histogram; optionally writes the raw rows for diffing against other runs.

#include <chiaki/log.h>

#include "../src/cloudcatalog_internal.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *family_of(const char *pid)
{
	if(!pid)
		return "unknown";
	if(cc_contains(pid, "CUSA"))
		return "PS4";
	if(cc_contains(pid, "PPSA"))
		return "PS5";
	return "legacy(PS1/PS2/PS3/PSP)";
}

int main(int argc, char *argv[])
{
	if(argc < 2)
	{
		fprintf(stderr, "usage: %s <account_country> [out.json]\n", argv[0]);
		return 2;
	}
	const char *country = argv[1];
	const char *out_path = argc > 2 ? argv[2] : NULL;

	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR,
		chiaki_log_cb_print, NULL);

	bool complete = false;
	struct json_object *games = cc_fetch_apollo_fallback(&log, country, &complete);
	if(!games)
	{
		fprintf(stderr, "cc_fetch_apollo_fallback returned NULL\n");
		return 1;
	}

	size_t n = json_object_array_length(games);
	size_t ps4 = 0, ps5 = 0, legacy = 0, unknown = 0;
	for(size_t i = 0; i < n; i++)
	{
		const char *pid = cc_json_str(json_object_array_get_idx(games, i), "id");
		const char *fam = family_of(pid);
		if(strcmp(fam, "PS4") == 0) ps4++;
		else if(strcmp(fam, "PS5") == 0) ps5++;
		else if(strcmp(fam, "unknown") == 0) unknown++;
		else legacy++;
	}

	printf("\n=== apollo fallback walk: account_country=%s (store %s) ===\n",
		country, cc_classics_store_country(country));
	printf("titles=%zu complete=%s  PS4=%zu PS5=%zu legacy=%zu unknown=%zu\n",
		n, complete ? "true" : "false", ps4, ps5, legacy, unknown);

	if(out_path)
	{
		const char *txt = json_object_to_json_string_ext(games, JSON_C_TO_STRING_PRETTY);
		FILE *f = fopen(out_path, "wb");
		if(f)
		{
			fwrite(txt, 1, strlen(txt), f);
			fclose(f);
			printf("wrote %s\n", out_path);
		}
	}
	json_object_put(games);
	return complete ? 0 : 3;
}
