// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// On-disk cache I/O. Ported from cloudcatalogbackend.cpp ensureCacheDirectory /
// getCacheFilePath / getCachedData / setCachedData. The lib owns every file
// inside cache_dir; platforms never read/write cache files themselves.

#include "cloudcatalog_internal.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>

#ifdef _WIN32
#include <direct.h>
#include <process.h>
#define cc_mkdir(p) _mkdir(p)
#define cc_getpid() _getpid()
#else
#include <unistd.h>
#define cc_mkdir(p) mkdir((p), 0755)
#define cc_getpid() getpid()
#endif

static void sanitize_key(const char *key, char *out, size_t out_sz)
{
	size_t i = 0;
	for(; key && key[i] && i < out_sz - 1; i++)
	{
		char c = key[i];
		if(c == '/' || c == '\\' || c == ':')
			c = '_';
		out[i] = c;
	}
	out[i] = 0;
}

static void cache_file_path(const char *cache_dir, const char *key, char *out, size_t out_sz)
{
	char safe[256];
	sanitize_key(key, safe, sizeof(safe));
	snprintf(out, out_sz, "%s/%s.json", cache_dir, safe);
}

ChiakiErrorCode cc_cache_ensure_dir(const char *cache_dir)
{
	if(!cache_dir || !*cache_dir)
		return CHIAKI_ERR_INVALID_DATA;

	// mkdir -p
	char tmp[1024];
	snprintf(tmp, sizeof(tmp), "%s", cache_dir);
	size_t len = strlen(tmp);
	if(len > 0 && tmp[len - 1] == '/')
		tmp[len - 1] = 0;
	for(char *p = tmp + 1; *p; p++)
	{
		if(*p == '/')
		{
			*p = 0;
			if(cc_mkdir(tmp) != 0 && errno != EEXIST)
				return CHIAKI_ERR_UNKNOWN;
			*p = '/';
		}
	}
	if(cc_mkdir(tmp) != 0 && errno != EEXIST)
		return CHIAKI_ERR_UNKNOWN;
	return CHIAKI_ERR_SUCCESS;
}

struct json_object *cc_cache_read(ChiakiLog *log, const char *cache_dir, const char *key, long max_age_ms)
{
	char path[1024];
	cache_file_path(cache_dir, key, path, sizeof(path));

	struct stat st;
	if(stat(path, &st) != 0)
	{
		CHIAKI_LOGI(log, "[CACHE MISS] %s", key);
		return NULL;
	}

	time_t now = time(NULL);
	int64_t age_ms = (int64_t)difftime(now, st.st_mtime) * 1000;
	if(age_ms > max_age_ms)
	{
		remove(path);
		CHIAKI_LOGI(log, "[CACHE EXPIRED] %s (age %lldsec)", key, (long long)(age_ms / 1000));
		return NULL;
	}

	FILE *f = fopen(path, "rb");
	if(!f)
		return NULL;
	fseek(f, 0, SEEK_END);
	long sz = ftell(f);
	fseek(f, 0, SEEK_SET);
	if(sz <= 0)
	{
		fclose(f);
		return NULL;
	}
	char *buf = malloc((size_t)sz + 1);
	if(!buf)
	{
		fclose(f);
		return NULL;
	}
	size_t rd = fread(buf, 1, (size_t)sz, f);
	fclose(f);
	buf[rd] = 0;

	struct json_object *obj = json_tokener_parse(buf);
	free(buf);
	if(!obj)
	{
		CHIAKI_LOGW(log, "[CACHE PARSE FAIL] %s; removing", key);
		remove(path);
		return NULL;
	}
	CHIAKI_LOGI(log, "[CACHE HIT] %s (%ldKB, age %lldsec)", key, sz / 1024, (long long)(age_ms / 1000));
	return obj;
}

ChiakiErrorCode cc_cache_write(ChiakiLog *log, const char *cache_dir, const char *key, struct json_object *obj)
{
	if(!obj)
		return CHIAKI_ERR_INVALID_DATA;
	cc_cache_ensure_dir(cache_dir);

	char path[1024];
	cache_file_path(cache_dir, key, path, sizeof(path));

	const char *json = json_object_to_json_string_ext(obj, JSON_C_TO_STRING_PLAIN);
	if(!json)
		return CHIAKI_ERR_UNKNOWN;

	// Write to a unique temp file then atomically rename, so a concurrent reader
	// (or an overlapping writer on the same cache dir) never sees a torn file.
	char tmp[1056];
	snprintf(tmp, sizeof(tmp), "%s.tmp.%ld", path, (long)cc_getpid());

	FILE *f = fopen(tmp, "wb");
	if(!f)
	{
		CHIAKI_LOGW(log, "[CACHE ERROR] cannot write %s", tmp);
		return CHIAKI_ERR_UNKNOWN;
	}
	size_t len = strlen(json);
	size_t wr = fwrite(json, 1, len, f);
	fclose(f);
	if(wr != len)
	{
		remove(tmp);
		return CHIAKI_ERR_UNKNOWN;
	}
	if(rename(tmp, path) != 0)
	{
		remove(tmp);
		CHIAKI_LOGW(log, "[CACHE ERROR] cannot rename %s -> %s", tmp, path);
		return CHIAKI_ERR_UNKNOWN;
	}
	CHIAKI_LOGI(log, "[CACHE SAVED] %s (%zuKB)", key, len / 1024);
	return CHIAKI_ERR_SUCCESS;
}

void cc_cache_remove(const char *cache_dir, const char *key)
{
	char path[1024];
	cache_file_path(cache_dir, key, path, sizeof(path));
	remove(path);
}
