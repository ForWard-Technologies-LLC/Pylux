// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "cloudcatalog_internal.h"

#include <stdlib.h>
#include <string.h>
#include <strings.h>

const char *cc_json_str(struct json_object *obj, const char *key)
{
	if(!obj || !key)
		return "";
	struct json_object *v = NULL;
	if(!json_object_object_get_ex(obj, key, &v) || !v)
		return "";
	if(json_object_get_type(v) != json_type_string)
		return "";
	const char *s = json_object_get_string(v);
	return s ? s : "";
}

struct json_object *cc_json_obj(struct json_object *obj, const char *key)
{
	if(!obj || !key)
		return NULL;
	struct json_object *v = NULL;
	if(!json_object_object_get_ex(obj, key, &v) || !v)
		return NULL;
	return json_object_get_type(v) == json_type_object ? v : NULL;
}

struct json_object *cc_json_arr(struct json_object *obj, const char *key)
{
	if(!obj || !key)
		return NULL;
	struct json_object *v = NULL;
	if(!json_object_object_get_ex(obj, key, &v) || !v)
		return NULL;
	return json_object_get_type(v) == json_type_array ? v : NULL;
}

bool cc_json_bool(struct json_object *obj, const char *key)
{
	if(!obj || !key)
		return false;
	struct json_object *v = NULL;
	if(!json_object_object_get_ex(obj, key, &v) || !v)
		return false;
	return json_object_get_boolean(v);
}

int cc_json_int(struct json_object *obj, const char *key)
{
	if(!obj || !key)
		return 0;
	struct json_object *v = NULL;
	if(!json_object_object_get_ex(obj, key, &v) || !v)
		return 0;
	return json_object_get_int(v);
}

bool cc_json_has(struct json_object *obj, const char *key)
{
	if(!obj || !key)
		return false;
	struct json_object *v = NULL;
	return json_object_object_get_ex(obj, key, &v) && v != NULL;
}

char *cc_strdup(const char *s)
{
	return s ? strdup(s) : NULL;
}

bool cc_ieq(const char *a, const char *b)
{
	if(a == b)
		return true;
	if(!a || !b)
		return false;
	return strcasecmp(a, b) == 0;
}

bool cc_contains(const char *haystack, const char *needle)
{
	if(!haystack || !needle)
		return false;
	return strstr(haystack, needle) != NULL;
}

bool cc_ends_with(const char *s, const char *suffix)
{
	if(!s || !suffix)
		return false;
	size_t ls = strlen(s), lsuf = strlen(suffix);
	if(lsuf > ls)
		return false;
	return strcmp(s + (ls - lsuf), suffix) == 0;
}

void cc_json_set_str(struct json_object *obj, const char *key, const char *value)
{
	if(!obj || !key)
		return;
	json_object_object_add(obj, key, json_object_new_string(value ? value : ""));
}

void cc_json_set_bool(struct json_object *obj, const char *key, bool value)
{
	if(!obj || !key)
		return;
	json_object_object_add(obj, key, json_object_new_boolean(value));
}

struct json_object *cc_json_clone(struct json_object *src)
{
	if(!src)
		return NULL;
	struct json_object *dst = NULL;
	if(json_object_deep_copy(src, &dst, NULL) != 0)
		return NULL;
	return dst;
}
