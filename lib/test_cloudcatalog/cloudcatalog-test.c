// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Desktop harness for the unified cloud catalog lib. Drives a real fetch with a
// provided NPSSO and writes the unified JSON to disk for baseline comparison.
//
//   cloudcatalog-test <npsso-file-or-token> [cache_dir] [out.json] [locale] [--force]
//
// Defaults: cache_dir=./tmp/cc-lib-cache, out=./tmp/lib-unified.json, locale=en-US

#include <chiaki/cloudcatalog.h>
#include <chiaki/log.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *read_token(const char *arg)
{
	// If arg names a readable file, use its first line; else treat arg as the token.
	FILE *f = fopen(arg, "rb");
	if(!f)
		return strdup(arg);
	char buf[512];
	size_t n = fread(buf, 1, sizeof(buf) - 1, f);
	fclose(f);
	buf[n] = 0;
	// trim trailing whitespace/newlines
	while(n > 0 && (buf[n - 1] == '\n' || buf[n - 1] == '\r' || buf[n - 1] == ' ' || buf[n - 1] == '\t'))
		buf[--n] = 0;
	return strdup(buf);
}

int main(int argc, char *argv[])
{
	if(argc < 2)
	{
		fprintf(stderr, "usage: %s <npsso-file-or-token> [cache_dir] [out.json] [locale] [--force]\n", argv[0]);
		return 2;
	}
	const char *cache_dir = argc > 2 ? argv[2] : "./tmp/cc-lib-cache";
	const char *out_path = argc > 3 ? argv[3] : "./tmp/lib-unified.json";
	const char *locale = argc > 4 ? argv[4] : "en-US";
	bool force = false;
	for(int i = 1; i < argc; i++)
		if(strcmp(argv[i], "--force") == 0)
			force = true;

	char *token = read_token(argv[1]);

	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_INFO | CHIAKI_LOG_WARNING | CHIAKI_LOG_ERROR, chiaki_log_cb_print, NULL);

	ChiakiCloudCatalogConfig cfg;
	memset(&cfg, 0, sizeof(cfg));
	cfg.npsso = token;
	cfg.locale = locale;
	cfg.cache_dir = cache_dir;
	cfg.force_refresh = force;

	ChiakiCloudCatalogResult res;
	ChiakiErrorCode err = chiaki_cloudcatalog_fetch_unified(&cfg, &res, &log);

	printf("\n=== fetch_unified err=%d ===\n", (int)err);
	if(res.error_message)
		printf("error_message: %s\n", res.error_message);
	if(res.json)
	{
		FILE *o = fopen(out_path, "wb");
		if(o)
		{
			fwrite(res.json, 1, strlen(res.json), o);
			fclose(o);
			printf("wrote %zu bytes -> %s\n", strlen(res.json), out_path);
		}
	}
	else
	{
		printf("no json payload\n");
	}

	chiaki_cloudcatalog_result_fini(&res);
	free(token);
	return err == CHIAKI_ERR_SUCCESS ? 0 : 1;
}
