// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Blocking network fetch flows for the unified cloud catalog. Faithful port of
// the async QNetworkAccessManager state machines in cloudcatalogbackend.cpp:
//   - PS Now OAuth -> session -> stores -> APOLLOROOT root + alphabetical walk
//   - public APOLLOROOT fallback pagination (region-unsupported accounts)
//   - imagic 6-list fetch with locale fallback chain
//   - owned entitlements OAuth(token) -> paginated internal_entitlements -> filter

#include "cloudcatalog_internal.h"
#include "curl_http.h"

#ifdef _WIN32
#include <ws2tcpip.h>
#else
#include <netinet/in.h>
#include <arpa/inet.h>
#endif
#include <chiaki/remote/holepunch.h>

#include <curl/curl.h>

#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// --- Constants (KamajiConsts + CloudConfig) --------------------------------
#define ACCOUNT_BASE    "https://ca.account.sony.com/api"
#define KAMAJI_BASE     "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000"
#define PSNOW_CLIENT_ID "bc6b0777-abb5-40da-92ca-e133cf18e989"
#define OWNED_CLIENT_ID "dc523cc2-b51b-4190-bff0-3397c06871b3"
#define PS4_SCOPES      "kamaji:commerce_native kamaji:commerce_container kamaji:lists kamaji:s2s.subscriptionsPremium.get"
#define OWNED_SCOPES    "kamaji:get_internal_entitlements user:account.attributes.validate"
#define KAMAJI_UA       "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) playstation-now/0.0.0 Chrome/83.0.4103.104 Electron/9.0.4 Safari/537.36 gkApollo"
#define KAMAJI_ORIGIN   "https://psnow.playstation.com"
#define KAMAJI_REFERER  "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/"
#define KAMAJI_REDIRECT "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html"
#define GENERIC_UA      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
#define OWNED_PAGE_SIZE 300

// --- small helpers ----------------------------------------------------------

static char *url_encode(const char *s)
{
	CURL *c = curl_easy_init();
	char *e = c ? curl_easy_escape(c, s, 0) : NULL;
	char *r = e ? strdup(e) : NULL;
	if(e)
		curl_free(e);
	if(c)
		curl_easy_cleanup(c);
	return r;
}

// Extract value of "key=" from a URL/query/fragment up to '&'. Returns true if found.
static bool extract_param(const char *url, const char *key, char *out, size_t out_sz)
{
	out[0] = 0;
	if(!url)
		return false;
	char pat[64];
	snprintf(pat, sizeof(pat), "%s=", key);
	const char *p = strstr(url, pat);
	if(!p)
		return false;
	p += strlen(pat);
	size_t i = 0;
	while(*p && *p != '&' && i < out_sz - 1)
		out[i++] = *p++;
	out[i] = 0;
	return i > 0;
}

// Extract JSESSIONID=...; from a raw header block.
static bool extract_jsessionid(const char *headers, char *out, size_t out_sz)
{
	out[0] = 0;
	if(!headers)
		return false;
	const char *p = strstr(headers, "JSESSIONID=");
	if(!p)
		return false;
	p += strlen("JSESSIONID=");
	size_t i = 0;
	while(*p && *p != ';' && *p != '\r' && *p != '\n' && i < out_sz - 1)
		out[i++] = *p++;
	out[i] = 0;
	return i > 0;
}

static struct json_object *parse_body(const CCHttpResponse *resp)
{
	if(!resp->data || !resp->size)
		return NULL;
	return json_tokener_parse(resp->data);
}

// status_code header == "0x0000" check on a Kamaji envelope.
static bool kamaji_ok(struct json_object *obj)
{
	struct json_object *header = cc_json_obj(obj, "header");
	return header && strcmp(cc_json_str(header, "status_code"), "0x0000") == 0;
}

// ===========================================================================
// PS Now native APOLLOROOT probe
// ===========================================================================

// Returns OAuth `code` (CC_NATIVE_OK) or an error class. Writes code into out_code.
static CCNativeResult psnow_oauth(ChiakiLog *log, const char *npsso, const char *duid,
                                  char *out_code, size_t code_sz)
{
	char *enc_scope = url_encode(PS4_SCOPES);
	char *enc_redirect = url_encode(KAMAJI_REDIRECT);
	char *enc_duid = url_encode(duid);
	if(!enc_scope || !enc_redirect || !enc_duid)
	{
		free(enc_scope); free(enc_redirect); free(enc_duid);
		return CC_NATIVE_FATAL;
	}

	char url[2048];
	snprintf(url, sizeof(url),
		ACCOUNT_BASE "/v1/oauth/authorize?smcid=pc%%3Apsnow&applicationId=psnow"
		"&response_type=code&scope=%s&client_id=" PSNOW_CLIENT_ID "&redirect_uri=%s"
		"&service_entity=urn%%3Aservice-entity%%3Apsn&prompt=none&renderMode=mobilePortrait"
		"&hidePageElements=forgotPasswordLink&displayFooter=none&disableLinks=qriocityLink"
		"&mid=PSNOW&duid=%s&layout_type=popup&service_logo=ps&tp_psn=true&noEVBlock=true",
		enc_scope, enc_redirect, enc_duid);
	free(enc_scope); free(enc_redirect); free(enc_duid);

	char *cookie = NULL;
	cc_http_make_cookie_header(&cookie, "npsso", npsso);
	const char *headers[] = { "User-Agent: " KAMAJI_UA, cookie };
	CCHttpRequest req = { 0 };
	req.url = url;
	req.headers = headers;
	req.header_count = 2;
	req.capture_headers = true;

	CCHttpResponse resp;
	ChiakiErrorCode e = cc_http_perform(log, &req, &resp);
	free(cookie);
	if(e != CHIAKI_ERR_SUCCESS)
		return CC_NATIVE_FATAL;

	CCNativeResult result = CC_NATIVE_AUTH_ERROR;
	if(resp.status_code == 302 && resp.redirect_url)
	{
		if(extract_param(resp.redirect_url, "code", out_code, code_sz))
			result = CC_NATIVE_OK;
	}
	cc_http_response_fini(&resp);
	return result;
}

// POST /user/session -> JSESSIONID. Returns CC_NATIVE_OK/AUTH_ERROR.
// Also captures the account region signal from the response body (data.country /
// data.language) into out_country/out_language when present (may be left empty).
static CCNativeResult psnow_session(ChiakiLog *log, const char *code, const char *duid,
                                    char *out_jsession, size_t js_sz,
                                    char *out_country, size_t cc_sz,
                                    char *out_language, size_t lang_sz)
{
	char body[1024];
	snprintf(body, sizeof(body), "code=%s&client_id=" PSNOW_CLIENT_ID "&duid=%s", code, duid);

	const char *headers[] = {
		"Content-Type: text/plain;charset=UTF-8",
		"User-Agent: " KAMAJI_UA,
		"X-Alt-Referer: " KAMAJI_REDIRECT,
		"Origin: " KAMAJI_ORIGIN,
		"Referer: " KAMAJI_REFERER,
		"Accept: */*",
	};
	CCHttpRequest req = { 0 };
	req.method = "POST";
	req.url = KAMAJI_BASE "/user/session";
	req.headers = headers;
	req.header_count = 6;
	req.body = body;
	req.capture_headers = true;

	CCHttpResponse resp;
	if(cc_http_perform(log, &req, &resp) != CHIAKI_ERR_SUCCESS)
		return CC_NATIVE_FATAL;

	CCNativeResult result = CC_NATIVE_AUTH_ERROR;
	if(resp.status_code == 200)
	{
		struct json_object *obj = parse_body(&resp);
		if(obj && kamaji_ok(obj))
		{
			// Capture the account's region signal (country/language) regardless of
			// the JSESSIONID outcome, so the lib can drive locale/region centrally
			// even on the region-unsupported path (/user/stores 404 after this).
			struct json_object *data = cc_json_obj(obj, "data");
			if(data)
			{
				if(out_country && cc_sz)
					snprintf(out_country, cc_sz, "%s", cc_json_str(data, "country"));
				if(out_language && lang_sz)
					snprintf(out_language, lang_sz, "%s", cc_json_str(data, "language"));
			}
			if(extract_jsessionid(resp.headers, out_jsession, js_sz))
				result = CC_NATIVE_OK;
		}
		if(obj)
			json_object_put(obj);
	}
	cc_http_response_fini(&resp);
	return result;
}

// Parse .../container/{CC}/{lang}/19/... from a store base_url.
static bool cc_parse_container_store_locale(const char *base_url,
	char *out_country, size_t cc_sz, char *out_lang, size_t lang_sz)
{
	if(out_country && cc_sz)
		out_country[0] = 0;
	if(out_lang && lang_sz)
		out_lang[0] = 0;
	const char *p = strstr(base_url, "/container/");
	if(!p)
		return false;
	p += strlen("/container/");
	const char *slash = strchr(p, '/');
	if(!slash || slash == p)
		return false;
	size_t cc_len = (size_t)(slash - p);
	if(!cc_len || cc_len >= cc_sz)
		return false;
	if(out_country && cc_sz)
	{
		memcpy(out_country, p, cc_len);
		out_country[cc_len] = 0;
	}
	p = slash + 1;
	slash = strchr(p, '/');
	if(!slash || slash == p)
		return false;
	size_t lang_len = (size_t)(slash - p);
	if(!lang_len || lang_len >= lang_sz)
		return false;
	if(out_lang && lang_sz)
	{
		memcpy(out_lang, p, lang_len);
		out_lang[lang_len] = 0;
	}
	return true;
}

// GET /user/stores -> base_url. Returns CC_NATIVE_OK or CC_NATIVE_REGION_UNSUPPORTED.
static CCNativeResult psnow_stores(ChiakiLog *log, const char *jsession,
                                   char *out_base_url, size_t url_sz,
                                   char *out_store_country, size_t cc_sz,
                                   char *out_store_lang, size_t lang_sz)
{
	char *cookie = NULL;
	cc_http_make_cookie_header(&cookie, "JSESSIONID", jsession);
	const char *headers[] = {
		"User-Agent: " KAMAJI_UA, cookie,
		"Origin: " KAMAJI_ORIGIN, "Referer: " KAMAJI_REFERER, "Accept: application/json",
	};
	CCHttpRequest req = { 0 };
	req.url = KAMAJI_BASE "/user/stores";
	req.headers = headers;
	req.header_count = 5;

	CCHttpResponse resp;
	ChiakiErrorCode e = cc_http_perform(log, &req, &resp);
	free(cookie);
	if(e != CHIAKI_ERR_SUCCESS)
		return CC_NATIVE_REGION_UNSUPPORTED;

	CCNativeResult result = CC_NATIVE_REGION_UNSUPPORTED;
	if(resp.status_code == 200)
	{
		struct json_object *obj = parse_body(&resp);
		if(obj && kamaji_ok(obj))
		{
			struct json_object *data = cc_json_obj(obj, "data");
			const char *base = data ? cc_json_str(data, "base_url") : "";
			if(*base)
			{
				snprintf(out_base_url, url_sz, "%s", base);
				cc_parse_container_store_locale(base, out_store_country, cc_sz, out_store_lang, lang_sz);
				result = CC_NATIVE_OK;
			}
		}
		if(obj)
			json_object_put(obj);
	}
	cc_http_response_fini(&resp);
	return result;
}

static bool is_alpha_category(const char *name)
{
	static const char *const pats[] = {
		"A - B", "C - D", "E - G", "H - L", "M - O", "P - R", "S", "T", "U - Z", NULL
	};
	for(size_t i = 0; pats[i]; i++)
		if(strcmp(name, pats[i]) == 0)
			return true;
	return false;
}

// GET base_url?size=100 -> list of alphabetical category URLs (appended to out array of strings).
static bool psnow_root_categories(ChiakiLog *log, const char *base_url, const char *jsession,
                                  char cat_urls[][1024], int *cat_count, int max_cats)
{
	char url[1100];
	snprintf(url, sizeof(url), "%s?size=100", base_url);
	char *cookie = NULL;
	cc_http_make_cookie_header(&cookie, "JSESSIONID", jsession);
	const char *headers[] = {
		"User-Agent: " KAMAJI_UA, cookie,
		"Origin: " KAMAJI_ORIGIN, "Referer: " KAMAJI_REFERER, "Accept: application/json",
	};
	CCHttpRequest req = { 0 };
	req.url = url;
	req.headers = headers;
	req.header_count = 5;

	CCHttpResponse resp;
	ChiakiErrorCode e = cc_http_perform(log, &req, &resp);
	free(cookie);
	if(e != CHIAKI_ERR_SUCCESS || resp.status_code != 200)
	{
		cc_http_response_fini(&resp);
		return false;
	}
	struct json_object *obj = parse_body(&resp);
	cc_http_response_fini(&resp);
	if(!obj)
		return false;

	*cat_count = 0;
	struct json_object *links = cc_json_arr(obj, "links");
	if(links)
	{
		size_t n = json_object_array_length(links);
		for(size_t i = 0; i < n && *cat_count < max_cats; i++)
		{
			struct json_object *link = json_object_array_get_idx(links, i);
			const char *name = cc_json_str(link, "name");
			const char *u = cc_json_str(link, "url");
			if(*u && is_alpha_category(name))
				snprintf(cat_urls[(*cat_count)++], 1024, "%s", u);
		}
	}
	json_object_put(obj);
	return *cat_count > 0;
}

// GET one category page (?start=0&size=500), append product rows to all_games.
static void psnow_fetch_category(ChiakiLog *log, const char *cat_url, struct json_object *all_games)
{
	char url[1200];
	snprintf(url, sizeof(url), strchr(cat_url, '?') ? "%s&start=0&size=500" : "%s?start=0&size=500", cat_url);
	const char *headers[] = {
		"Content-Type: application/json", "Accept: application/json",
		"User-Agent: " GENERIC_UA,
	};
	CCHttpRequest req = { 0 };
	req.url = url;
	req.headers = headers;
	req.header_count = 3;

	CCHttpResponse resp;
	if(cc_http_perform(log, &req, &resp) != CHIAKI_ERR_SUCCESS || resp.status_code != 200)
	{
		cc_http_response_fini(&resp);
		return;
	}
	struct json_object *obj = parse_body(&resp);
	cc_http_response_fini(&resp);
	if(!obj)
		return;
	struct json_object *links = cc_json_arr(obj, "links");
	if(links)
	{
		size_t n = json_object_array_length(links);
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *g = json_object_array_get_idx(links, i);
			if(!g || json_object_get_type(g) != json_type_object)
				continue;
			struct json_object *gc = cc_json_clone(g);
			char img[1024];
			cc_extract_cover_image(gc, img, sizeof(img));
			if(*img)
				cc_json_set_str(gc, "imageUrl", img);
			json_object_array_add(all_games, gc);
		}
	}
	json_object_put(obj);
}

CCNativeResult cc_fetch_psnow_native(ChiakiLog *log, const char *npsso, struct json_object **out_games,
	char *out_country, size_t cc_sz, char *out_language, size_t lang_sz,
	char *out_store_country, size_t store_cc_sz, char *out_store_lang, size_t store_lang_sz)
{
	*out_games = NULL;
	if(out_country && cc_sz)
		out_country[0] = 0;
	if(out_language && lang_sz)
		out_language[0] = 0;
	if(out_store_country && store_cc_sz)
		out_store_country[0] = 0;
	if(out_store_lang && store_lang_sz)
		out_store_lang[0] = 0;
	if(!npsso || !*npsso)
		return CC_NATIVE_AUTH_ERROR;

	size_t duid_size = CHIAKI_DUID_STR_SIZE;
	char duid[CHIAKI_DUID_STR_SIZE];
	if(chiaki_holepunch_generate_client_device_uid(duid, &duid_size) != CHIAKI_ERR_SUCCESS)
		return CC_NATIVE_FATAL;

	char code[1024];
	CCNativeResult r = psnow_oauth(log, npsso, duid, code, sizeof(code));
	if(r != CC_NATIVE_OK)
		return r;
	CHIAKI_LOGI(log, "[PSNOW] OAuth code obtained, creating session");

	char jsession[512];
	r = psnow_session(log, code, duid, jsession, sizeof(jsession), out_country, cc_sz, out_language, lang_sz);
	if(r != CC_NATIVE_OK)
		return r;
	CHIAKI_LOGI(log, "[PSNOW] Session created, fetching stores");

	char base_url[1024];
	r = psnow_stores(log, jsession, base_url, sizeof(base_url),
		out_store_country, store_cc_sz, out_store_lang, store_lang_sz);
	if(r != CC_NATIVE_OK)
		return r; // region unsupported -> caller does public fallback
	CHIAKI_LOGI(log, "[PSNOW] Stores OK, base_url=%s", base_url);

	char cat_urls[16][1024];
	int cat_count = 0;
	if(!psnow_root_categories(log, base_url, jsession, cat_urls, &cat_count, 16))
		return CC_NATIVE_REGION_UNSUPPORTED;

	struct json_object *all = json_object_new_array();
	for(int i = 0; i < cat_count; i++)
		psnow_fetch_category(log, cat_urls[i], all);

	// Dedup by id (first-wins).
	struct json_object *seen = json_object_new_object();
	struct json_object *final = json_object_new_array();
	size_t n = json_object_array_length(all);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *g = json_object_array_get_idx(all, i);
		const char *id = cc_json_str(g, "id");
		struct json_object *tmp = NULL;
		if(!*id || json_object_object_get_ex(seen, id, &tmp))
			continue;
		json_object_object_add(seen, id, json_object_new_int(1));
		json_object_array_add(final, cc_json_clone(g));
	}
	json_object_put(seen);
	json_object_put(all);

	CHIAKI_LOGI(log, "[PSNOW] APOLLOROOT native: %d games", (int)json_object_array_length(final));
	*out_games = final;
	return CC_NATIVE_OK;
}

// ===========================================================================
// Public APOLLOROOT fallback pagination
// ===========================================================================

struct json_object *cc_fetch_apollo_fallback(ChiakiLog *log, const char *account_country)
{
	const char *store_country = cc_classics_store_country(account_country);
	const char *container = cc_apollo_root_container_id(account_country);
	char container_url[512];
	snprintf(container_url, sizeof(container_url),
		"https://psnow.playstation.com/store/api/pcnow/00_09_000/container/%s/en/19/%s",
		store_country, container);

	struct json_object *games = json_object_new_array();
	int start = 0, total = -1;
	for(;;)
	{
		char url[700];
		snprintf(url, sizeof(url), "%s?useOffers=true&gkb=1&gkb2=1&start=%d&size=100", container_url, start);
		const char *headers[] = { "Accept: application/json", "User-Agent: " KAMAJI_UA };
		CCHttpRequest req = { 0 };
		req.url = url;
		req.headers = headers;
		req.header_count = 2;

		CCHttpResponse resp;
		if(cc_http_perform(log, &req, &resp) != CHIAKI_ERR_SUCCESS || resp.status_code != 200)
		{
			cc_http_response_fini(&resp);
			break;
		}
		struct json_object *obj = parse_body(&resp);
		cc_http_response_fini(&resp);
		if(!obj)
			break;
		if(total < 0)
			total = cc_json_int(obj, "total_results");
		int product_count = 0;
		struct json_object *links = cc_json_arr(obj, "links");
		if(links)
		{
			size_t n = json_object_array_length(links);
			for(size_t i = 0; i < n; i++)
			{
				struct json_object *g = json_object_array_get_idx(links, i);
				if(!cc_ieq(cc_json_str(g, "container_type"), "product"))
					continue;
				struct json_object *gc = cc_json_clone(g);
				char img[1024];
				cc_extract_cover_image(gc, img, sizeof(img));
				if(*img)
					cc_json_set_str(gc, "imageUrl", img);
				json_object_array_add(games, gc);
				product_count++;
			}
		}
		json_object_put(obj);
		start += 100;
		if(product_count <= 0 || (total >= 0 && start >= total))
			break;
	}
	CHIAKI_LOGI(log, "[UNIFIED] APOLLOROOT fallback: %d titles", (int)json_object_array_length(games));
	return games;
}

// ===========================================================================
// imagic 6-list
// ===========================================================================

static const char *const kImagicLists[] = {
	"plus-games-list", "ubisoft-classics-list", "plus-classics-list",
	"plus-monthly-games-list", "free-to-play-list", "all-ps5-list",
};
#define IMAGIC_LIST_COUNT 6

void cc_imagic_result_fini(CCImagicResult *r)
{
	if(!r)
		return;
	if(r->browse) json_object_put(r->browse);
	if(r->supplement) json_object_put(r->supplement);
	if(r->aliases) json_object_put(r->aliases);
	memset(r, 0, sizeof(*r));
}

bool cc_fetch_imagic(ChiakiLog *log, const char *stored_locale, CCImagicResult *out)
{
	memset(out, 0, sizeof(*out));
	char *chain[3];
	size_t chain_n = cc_build_store_locale_chain(stored_locale, chain, 3);

	for(size_t tier = 0; tier < chain_n; tier++)
	{
		// lower-case locale for imagic ("en-us")
		char locale[16];
		snprintf(locale, sizeof(locale), "%s", chain[tier]);
		for(char *p = locale; *p; p++)
			*p = (char)tolower((unsigned char)*p);

		struct json_object *games_by_edition = json_object_new_object();
		struct json_object *supplement = json_object_new_object();
		struct json_object *aliases = json_object_new_object();
		int total_seen = 0, succeeded = 0;
		bool all_ps5_ok = false;

		for(int i = 0; i < IMAGIC_LIST_COUNT; i++)
		{
			char url[256];
			snprintf(url, sizeof(url),
				"https://www.playstation.com/bin/imagic/gameslist?locale=%s&categoryList=%s",
				locale, kImagicLists[i]);
			const char *headers[] = {
				"Content-Type: application/json", "Accept: application/json",
				"User-Agent: " GENERIC_UA,
			};
			CCHttpRequest req = { 0 };
			req.url = url;
			req.headers = headers;
			req.header_count = 3;

			CCHttpResponse resp;
			if(cc_http_perform(log, &req, &resp) != CHIAKI_ERR_SUCCESS || resp.status_code != 200)
			{
				cc_http_response_fini(&resp);
				continue;
			}
			struct json_object *doc = parse_body(&resp);
			cc_http_response_fini(&resp);
			if(!doc || json_object_get_type(doc) != json_type_array)
			{
				if(doc)
					json_object_put(doc);
				continue;
			}
			succeeded++;
			if(strcmp(kImagicLists[i], "all-ps5-list") == 0)
				all_ps5_ok = true;
			cc_merge_imagic_list(kImagicLists[i], doc, games_by_edition, supplement, aliases, &total_seen);
			json_object_put(doc);
		}

		if(succeeded <= 0)
		{
			json_object_put(games_by_edition);
			json_object_put(supplement);
			json_object_put(aliases);
			continue; // escalate to next locale tier
		}

		// Materialize arrays (with image extraction).
		struct json_object *browse = json_object_new_array();
		json_object_object_foreach(games_by_edition, k1, v1)
		{
			(void)k1;
			struct json_object *gc = cc_json_clone(v1);
			if(!cc_json_has(gc, "imageUrl") || !*cc_json_str(gc, "imageUrl"))
			{
				char img[1024];
				cc_extract_cover_image(gc, img, sizeof(img));
				if(*img)
					cc_json_set_str(gc, "imageUrl", img);
			}
			json_object_array_add(browse, gc);
		}
		struct json_object *supp = json_object_new_array();
		json_object_object_foreach(supplement, k2, v2)
		{
			(void)k2;
			struct json_object *gc = cc_json_clone(v2);
			if(!cc_json_has(gc, "imageUrl") || !*cc_json_str(gc, "imageUrl"))
			{
				char img[1024];
				cc_extract_cover_image(gc, img, sizeof(img));
				if(*img)
					cc_json_set_str(gc, "imageUrl", img);
			}
			json_object_array_add(supp, gc);
		}

		json_object_put(games_by_edition);
		json_object_put(supplement);

		out->browse = browse;
		out->supplement = supp;
		out->aliases = aliases;
		snprintf(out->settled_locale, sizeof(out->settled_locale), "%s", chain[tier]);
		out->all_ps5_list_succeeded = all_ps5_ok;
		out->any_succeeded = true;
		CHIAKI_LOGI(log, "[PSCLOUD] imagic settled on %s: %d browse, %d supplement (scanned %d)",
			out->settled_locale, (int)json_object_array_length(browse),
			(int)json_object_array_length(supp), total_seen);
		break;
	}

	for(size_t i = 0; i < chain_n; i++)
		free(chain[i]);
	return out->any_succeeded;
}

// ===========================================================================
// Owned entitlements
// ===========================================================================

// filterOwnedPs5Games: keep active game entitlements (feature_type != 0), set imageUrl + serviceType.
static struct json_object *filter_owned(ChiakiLog *log, struct json_object *entitlements)
{
	(void)log;
	struct json_object *out = json_object_new_array();
	size_t n = json_object_array_length(entitlements);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *ent = json_object_array_get_idx(entitlements, i);
		if(!ent || json_object_get_type(ent) != json_type_object)
			continue;
		struct json_object *gm = cc_json_obj(ent, "game_meta");
		if(!gm)
			continue;
		if(!cc_json_bool(ent, "active_flag"))
			continue;
		const char *pid = cc_json_str(ent, "product_id");
		if(strncmp(pid, "IP", 2) == 0 || strncmp(pid, "SUB", 3) == 0)
			continue;
		if(cc_json_int(ent, "feature_type") == 0)
			continue;

		struct json_object *e = cc_json_clone(ent);
		struct json_object *egm = cc_json_obj(e, "game_meta");
		char img[1024];
		const char *icon = cc_json_str(egm, "icon_url");
		if(*icon)
			snprintf(img, sizeof(img), "%s", icon);
		else
		{
			cc_extract_cover_image(egm, img, sizeof(img));
			if(!*img)
				cc_extract_cover_image(e, img, sizeof(img));
		}
		if(*img)
			cc_json_set_str(e, "imageUrl", img);
		cc_sanitize_owned_service_type(e);
		json_object_array_add(out, e);
	}
	return out;
}

static CCOwnedResult owned_oauth(ChiakiLog *log, const char *npsso, char *out_token, size_t tok_sz)
{
	char *enc_scope = url_encode(OWNED_SCOPES);
	char *enc_redirect = url_encode(KAMAJI_REDIRECT);
	if(!enc_scope || !enc_redirect)
	{
		free(enc_scope); free(enc_redirect);
		return CC_OWNED_ERROR;
	}
	char url[1536];
	snprintf(url, sizeof(url),
		ACCOUNT_BASE "/v1/oauth/authorize?response_type=token&scope=%s&client_id=" OWNED_CLIENT_ID
		"&redirect_uri=%s&service_entity=urn%%3Aservice-entity%%3Apsn&prompt=none",
		enc_scope, enc_redirect);
	free(enc_scope); free(enc_redirect);

	char *cookie = NULL;
	cc_http_make_cookie_header(&cookie, "npsso", npsso);
	const char *headers[] = { cookie, "User-Agent: " GENERIC_UA };
	CCHttpRequest req = { 0 };
	req.url = url;
	req.headers = headers;
	req.header_count = 2;

	CCHttpResponse resp;
	ChiakiErrorCode e = cc_http_perform(log, &req, &resp);
	free(cookie);
	if(e != CHIAKI_ERR_SUCCESS)
		return CC_OWNED_ERROR;

	CCOwnedResult result = CC_OWNED_AUTH_ERROR;
	if(resp.status_code == 302 && resp.redirect_url)
	{
		char errbuf[128];
		if(extract_param(resp.redirect_url, "error", errbuf, sizeof(errbuf)))
			result = CC_OWNED_AUTH_ERROR;
		else if(extract_param(resp.redirect_url, "access_token", out_token, tok_sz))
			result = CC_OWNED_OK;
	}
	cc_http_response_fini(&resp);
	return result;
}

CCOwnedResult cc_fetch_owned(ChiakiLog *log, const char *npsso,
                             struct json_object **out_games, struct json_object **out_component_ids)
{
	*out_games = NULL;
	*out_component_ids = NULL;
	if(!npsso || !*npsso)
		return CC_OWNED_AUTH_ERROR;

	char token[2048];
	CCOwnedResult r = owned_oauth(log, npsso, token, sizeof(token));
	if(r != CC_OWNED_OK)
		return r;

	char *bearer = NULL;
	cc_http_make_bearer_header(&bearer, token);

	struct json_object *accumulated = json_object_new_array();
	int start = 0;
	CCOwnedResult result = CC_OWNED_OK;
	for(;;)
	{
		char url[512];
		snprintf(url, sizeof(url),
			"https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements"
			"?fields=game_meta&entitlement_type=5&start=%d&size=%d", start, OWNED_PAGE_SIZE);
		const char *headers[] = { bearer, "Accept: application/json" };
		CCHttpRequest req = { 0 };
		req.url = url;
		req.headers = headers;
		req.header_count = 2;

		CCHttpResponse resp;
		if(cc_http_perform(log, &req, &resp) != CHIAKI_ERR_SUCCESS)
		{
			cc_http_response_fini(&resp);
			result = CC_OWNED_ERROR;
			break;
		}
		if(resp.status_code == 401 || resp.status_code == 403)
		{
			cc_http_response_fini(&resp);
			result = CC_OWNED_AUTH_ERROR;
			break;
		}
		struct json_object *obj = parse_body(&resp);
		cc_http_response_fini(&resp);
		if(!obj)
		{
			result = CC_OWNED_ERROR;
			break;
		}
		struct json_object *page = cc_json_arr(obj, "entitlements");
		int page_count = page ? (int)json_object_array_length(page) : 0;
		for(int i = 0; i < page_count; i++)
			json_object_array_add(accumulated, cc_json_clone(json_object_array_get_idx(page, i)));
		json_object_put(obj);
		if(page_count < OWNED_PAGE_SIZE)
			break;
		start += page_count;
	}
	free(bearer);

	if(result != CC_OWNED_OK)
	{
		json_object_put(accumulated);
		return result;
	}

	// componentIdsByProductId
	struct json_object *components = json_object_new_object();
	size_t an = json_object_array_length(accumulated);
	for(size_t i = 0; i < an; i++)
	{
		struct json_object *ent = json_object_array_get_idx(accumulated, i);
		const char *pid = cc_json_str(ent, "product_id");
		const char *eid = cc_json_str(ent, "id");
		if(!*pid || !*eid)
			continue;
		struct json_object *arr = NULL;
		if(!json_object_object_get_ex(components, pid, &arr))
		{
			arr = json_object_new_array();
			json_object_object_add(components, pid, arr);
		}
		json_object_array_add(arr, json_object_new_string(eid));
	}

	*out_games = filter_owned(log, accumulated);
	*out_component_ids = components;
	json_object_put(accumulated);
	CHIAKI_LOGI(log, "[OWNED] %d entitlements -> %d games",
		(int)an, (int)json_object_array_length(*out_games));
	return CC_OWNED_OK;
}
