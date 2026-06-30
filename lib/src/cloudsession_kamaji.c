// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Kamaji session flow -- C port of the Qt pskamajisession.cpp async state
// machine, run as a single blocking sequence. Resolves the chosen PSNOW title's
// streaming entitlement (and acquires it via a $0 checkout when the account does
// not yet own it), then establishes the authenticated Kamaji session.
//
// Full path: 0.5b anonymous OAuth code -> 0.5c anonymous session (JSESSIONID)
// -> 0.5d productId -> entitlementId (+ platform) -> 0.5e check/acquire
// -> step5 authenticated OAuth code -> step6 authenticated session.
// Owned fast-path: skip 0.5b-0.5e, go straight to step5/6.

#include "cloudsession_internal.h"
#include "cloudcatalog_internal.h"  // cc_json_* helpers
#include "curl_http.h"
// json-c: the specific headers come via cloudcatalog_internal.h (the umbrella
// <json-c/json.h> is not present in the iOS/Android FetchContent build).

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <strings.h>

#define KM_ACCOUNT_BASE "https://ca.account.sony.com/api"
#define KM_KAMAJI_BASE  "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000"
#define KM_CLIENT_ID    CS_PSNOW_CLIENT_ID  // shared (cloudsession_internal.h)
#define KM_COMMERCE_CLIENT_ID "dc523cc2-b51b-4190-bff0-3397c06871b3"
#define KM_REDIRECT_URI CS_PSNOW_REDIRECT
#define KM_USER_AGENT   CS_PSNOW_USER_AGENT
// URL-encoded (these are spliced into OAuth query strings via %s, not re-encoded).
#define KM_PS3_SCOPES   "kamaji:commerce_native"
#define KM_PS4_SCOPES   "kamaji:commerce_native%20kamaji:commerce_container%20kamaji:lists%20kamaji:s2s.subscriptionsPremium.get"
#define KM_REFERER      "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/"
#define KM_ORIGIN       "https://psnow.playstation.com"

typedef struct
{
	ChiakiLog *log;
	const ChiakiCloudProvisionConfig *cfg;
	const char *duid;
	const char *npsso;
	char platform[8];           // ps3|ps4|ps5
	const char *scopes;         // KM_PS3_SCOPES | KM_PS4_SCOPES
	char entitlement_id[128];
	char streaming_sku[160];
	char *jsessionid;
	char *commerce_token;
} KamajiCtx;

static char *km_hdr(const char *key, const char *value)
{
	size_t n = strlen(key) + 2 + (value ? strlen(value) : 0) + 1;
	char *s = (char *)malloc(n);
	if(s) snprintf(s, n, "%s: %s", key, value ? value : "");
	return s;
}

static char *km_header_value(const char *headers, const char *name)
{
	if(!headers || !name) return NULL;
	size_t nlen = strlen(name);
	const char *p = headers;
	while(*p)
	{
		const char *eol = strpbrk(p, "\r\n");
		size_t linelen = eol ? (size_t)(eol - p) : strlen(p);
		if(linelen > nlen && strncasecmp(p, name, nlen) == 0 && p[nlen] == ':')
		{
			const char *v = p + nlen + 1;
			while(*v == ' ' || *v == '\t') v++;
			size_t vlen = (size_t)((p + linelen) - v);
			while(vlen && (v[vlen-1] == ' ' || v[vlen-1] == '\t')) vlen--;
			char *out = (char *)malloc(vlen + 1);
			if(!out) return NULL;
			memcpy(out, v, vlen); out[vlen] = '\0';
			return out;
		}
		if(!eol) break;
		p = eol + ((eol[0] == '\r' && eol[1] == '\n') ? 2 : 1);
	}
	return NULL;
}

// Extract key=<value> from a URL's query OR fragment (delimiters ? & #).
static char *km_url_param(const char *url, const char *key)
{
	if(!url) return NULL;
	size_t klen = strlen(key);
	const char *p = url;
	while((p = strstr(p, key)) != NULL)
	{
		if((p == url || p[-1] == '?' || p[-1] == '&' || p[-1] == '#') && p[klen] == '=')
		{
			const char *v = p + klen + 1;
			size_t vlen = strcspn(v, "&#");
			char *o = (char *)malloc(vlen + 1);
			if(!o) return NULL;
			memcpy(o, v, vlen); o[vlen] = '\0';
			return o;
		}
		p++;
	}
	return NULL;
}

// Scan the raw header block for JSESSIONID=<value> in any Set-Cookie line.
static char *km_jsessionid(const char *headers)
{
	if(!headers) return NULL;
	const char *p = strstr(headers, "JSESSIONID=");
	if(!p) return NULL;
	p += strlen("JSESSIONID=");
	size_t vlen = strcspn(p, ";\r\n");
	char *o = (char *)malloc(vlen + 1);
	if(!o) return NULL;
	memcpy(o, p, vlen); o[vlen] = '\0';
	return o;
}

// OAuth GET (prompt=none) -> the 302 redirect's code= (or access_token= when @p want_token).
static ChiakiErrorCode km_oauth(KamajiCtx *c, const char *url, bool want_token, char **out)
{
	*out = NULL;
	char *cookie = NULL;
	if(cc_http_make_cookie_header(&cookie, "npsso", c->npsso) != CHIAKI_ERR_SUCCESS)
		return CHIAKI_ERR_MEMORY;
	char *h_ua = km_hdr("User-Agent", KM_USER_AGENT);
	const char *hdrs[] = { h_ua, cookie };
	CCHttpRequest req = { 0 };
	req.url = url; req.headers = hdrs; req.header_count = 2;
	req.follow_redirects = false; req.capture_headers = true;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	free(h_ua); free(cookie);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	// Prefer the raw Location header (keeps the #access_token fragment curl drops from REDIRECT_URL).
	char *loc = km_header_value(resp.headers, "Location");
	const char *src = loc ? loc : resp.redirect_url;
	char *val = src ? km_url_param(src, want_token ? "access_token" : "code") : NULL;
	if(!val)
		CHIAKI_LOGE(c->log, "[KAMAJI] oauth: no %s in redirect (status %ld)", want_token ? "token" : "code", resp.status_code);
	free(loc); cc_http_response_fini(&resp);
	if(!val) return CHIAKI_ERR_UNKNOWN;
	*out = val;
	return CHIAKI_ERR_SUCCESS;
}

// POST {KAMAJI_BASE}/user/session with the "code=&client_id=&duid=" body.
// @p capture set when we need Set-Cookie (anonymous session). resp_out owned by caller.
static ChiakiErrorCode km_post_session(KamajiCtx *c, const char *code, bool capture, CCHttpResponse *resp_out)
{
	char body[512];
	snprintf(body, sizeof(body), "code=%s&client_id=%s&duid=%s", code, KM_CLIENT_ID, c->duid);
	char *h_ua = km_hdr("User-Agent", KM_USER_AGENT);
	char *h_alt = km_hdr("X-Alt-Referer", KM_REDIRECT_URI);
	const char *hdrs[] = {
		"Content-Type: text/plain;charset=UTF-8", "Accept: */*",
		"Origin: " KM_ORIGIN, "Referer: " KM_REFERER, h_ua, h_alt
	};
	CCHttpRequest req = { 0 };
	req.method = "POST"; req.url = KM_KAMAJI_BASE "/user/session";
	req.headers = hdrs; req.header_count = 6; req.body = body; req.capture_headers = capture;
	ChiakiErrorCode e = cc_http_perform(c->log, &req, resp_out);
	free(h_ua); free(h_alt);
	return e;
}

// ---- steps -----------------------------------------------------------------

static ChiakiErrorCode km_step0_5b_anon_authcode(KamajiCtx *c, char **out_code)
{
	if(c->cfg->progress) c->cfg->progress("Cloud Auth - Step 1 of 5", c->cfg->user);
	char url[2048];
	snprintf(url, sizeof(url), KM_ACCOUNT_BASE "/v1/oauth/authorize?smcid=pc:psnow&applicationId=psnow"
		"&response_type=code&scope=%s&client_id=%s&redirect_uri=%s&service_entity=urn:service-entity:psn"
		"&prompt=none&renderMode=mobilePortrait&hidePageElements=forgotPasswordLink&displayFooter=none"
		"&disableLinks=qriocityLink&mid=PSNOW&duid=%s&layout_type=popup&service_logo=ps&tp_psn=true&noEVBlock=true",
		c->scopes, KM_CLIENT_ID, KM_REDIRECT_URI, c->duid);
	return km_oauth(c, url, false, out_code);
}

static ChiakiErrorCode km_step0_5c_anon_session(KamajiCtx *c, const char *anon_code)
{
	if(c->cfg->progress) c->cfg->progress("Cloud Auth - Step 1 of 5", c->cfg->user);
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = km_post_session(c, anon_code, true, &resp);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	char *jsess = km_jsessionid(resp.headers);
	cc_http_response_fini(&resp);
	if(!jsess) { CHIAKI_LOGE(c->log, "[KAMAJI] 0.5c no JSESSIONID"); return CHIAKI_ERR_UNKNOWN; }
	free(c->jsessionid); c->jsessionid = jsess;
	return CHIAKI_ERR_SUCCESS;
}

// Pick a streaming entitlement (license_type==4) from one sku; returns true if found.
static bool km_pick_streaming(KamajiCtx *c, struct json_object *sku)
{
	struct json_object *ents = cc_json_arr(sku, "entitlements");
	if(!ents) return false;
	size_t n = json_object_array_length(ents);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *ent = json_object_array_get_idx(ents, i);
		if(cc_json_int(ent, "license_type") == 4)
		{
			const char *id = cc_json_str(ent, "id");
			if(id && *id)
			{
				snprintf(c->entitlement_id, sizeof(c->entitlement_id), "%s", id);
				snprintf(c->streaming_sku, sizeof(c->streaming_sku), "%s", cc_json_str(sku, "id"));
				return true;
			}
		}
	}
	return false;
}

// PS Plus catalog fallback: a full-game digital entitlement ("*GD"); optionally
// requiring the entitlement id to contain the requested title id (platform-consistent).
// The match logic lives here (non-static, unit-tested in test/cloudsession_kamaji.c);
// km_pick_fullgame records the chosen entitlement + its sku onto the context.
bool km_pick_fullgame_id(struct json_object *sku, bool require_title,
	const char *title_id, char *out_id, size_t out_sz, ChiakiLog *log)
{
	struct json_object *ents = cc_json_arr(sku, "entitlements");
	if(!ents) return false;
	size_t n = json_object_array_length(ents);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *ent = json_object_array_get_idx(ents, i);
		const char *id = cc_json_str(ent, "id");
		const char *pkg = cc_json_str(ent, "packageType");
		size_t plen = strlen(pkg);
		if(!id || !*id || plen < 2 || strcmp(pkg + plen - 2, "GD") != 0)
			continue;
		if(require_title && title_id && *title_id && !strstr(id, title_id))
			continue;
		snprintf(out_id, out_sz, "%s", id);
		if(log) CHIAKI_LOGI(log, "[KAMAJI] full-game entitlement (PS+ fallback): %s pkg=%s", id, pkg);
		return true;
	}
	return false;
}

static bool km_pick_fullgame(KamajiCtx *c, struct json_object *sku, bool require_title, const char *title_id)
{
	if(!km_pick_fullgame_id(sku, require_title, title_id, c->entitlement_id, sizeof(c->entitlement_id), c->log))
		return false;
	snprintf(c->streaming_sku, sizeof(c->streaming_sku), "%s", cc_json_str(sku, "id"));
	return true;
}

static ChiakiErrorCode km_step0_5d_resolve(KamajiCtx *c)
{
	if(c->cfg->progress) c->cfg->progress("Resolving Game - Step 2 of 5", c->cfg->user);
	const char *country = (c->cfg->store_country && *c->cfg->store_country) ? c->cfg->store_country : "US";
	const char *lang = (c->cfg->store_lang && *c->cfg->store_lang) ? c->cfg->store_lang : "en";
	char url[512];
	snprintf(url, sizeof(url), "https://psnow.playstation.com/store/api/pcnow/00_09_000/container/"
		"%s/%s/19/%s?useOffers=true&gkb=1&gkb2=1", country, lang, c->cfg->game_identifier);
	CHIAKI_LOGI(c->log, "[KAMAJI] 0.5d resolve %s (store %s/%s)", c->cfg->game_identifier, country, lang);

	const char *hdrs[] = { "Accept: application/json",
		"User-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36" };
	CCHttpRequest req = { 0 };
	req.url = url; req.headers = hdrs; req.header_count = 2;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	if(resp.status_code == 404)
	{
		CHIAKI_LOGE(c->log, "[KAMAJI] 0.5d product not found (404)");
		cc_http_response_fini(&resp);
		return CHIAKI_ERR_UNKNOWN;
	}
	if(resp.status_code != 200 || !resp.data) { cc_http_response_fini(&resp); return CHIAKI_ERR_UNKNOWN; }
	struct json_object *obj = json_tokener_parse(resp.data);
	cc_http_response_fini(&resp);
	if(!obj) return CHIAKI_ERR_UNKNOWN;

	struct json_object *default_sku = cc_json_obj(obj, "default_sku");
	if(default_sku) km_pick_streaming(c, default_sku);
	if(!c->entitlement_id[0])
	{
		struct json_object *skus = cc_json_arr(obj, "skus");
		if(skus) for(size_t i = 0; i < json_object_array_length(skus) && !c->entitlement_id[0]; i++)
			km_pick_streaming(c, json_object_array_get_idx(skus, i));
	}
	// Full-game fallback (PS Plus catalog titles have no license_type==4): title-match then any.
	if(!c->entitlement_id[0])
	{
		char title_id[64] = "";
		{
			const char *dash = strchr(c->cfg->game_identifier, '-');
			if(dash)
			{
				const char *t = dash + 1;
				size_t tl = strcspn(t, "_");
				if(tl < sizeof(title_id)) { memcpy(title_id, t, tl); title_id[tl] = '\0'; }
			}
		}
		struct json_object *skus = cc_json_arr(obj, "skus");
		for(int pass = 0; pass < 2 && !c->entitlement_id[0]; pass++)
		{
			bool require_title = (pass == 0);
			if(default_sku && km_pick_fullgame(c, default_sku, require_title, title_id)) break;
			if(skus) for(size_t i = 0; i < json_object_array_length(skus) && !c->entitlement_id[0]; i++)
				km_pick_fullgame(c, json_object_array_get_idx(skus, i), require_title, title_id);
		}
	}

	// Platform from playable_platform (root array, else metadata.playable_platform.values).
	struct json_object *pp = cc_json_arr(obj, "playable_platform");
	if(!pp)
	{
		struct json_object *meta = cc_json_obj(obj, "metadata");
		struct json_object *ppm = meta ? cc_json_obj(meta, "playable_platform") : NULL;
		if(ppm) pp = cc_json_arr(ppm, "values");
	}
	bool ps5 = false, ps4 = false, ps3 = false;
	if(pp) for(size_t i = 0; i < json_object_array_length(pp); i++)
	{
		const char *s = json_object_get_string(json_object_array_get_idx(pp, i));
		if(!s) continue;
		if(strcasestr(s, "PS5")) ps5 = true;
		else if(strcasestr(s, "PS4")) ps4 = true;
		else if(strcasestr(s, "PS3")) ps3 = true;
	}
	snprintf(c->platform, sizeof(c->platform), "%s", ps5 ? "ps5" : (ps4 ? "ps4" : (ps3 ? "ps3" : "ps4")));
	c->scopes = (strcmp(c->platform, "ps3") == 0) ? KM_PS3_SCOPES : KM_PS4_SCOPES;
	json_object_put(obj);

	if(!c->entitlement_id[0]) { CHIAKI_LOGE(c->log, "[KAMAJI] 0.5d no entitlement resolved"); return CHIAKI_ERR_UNKNOWN; }
	CHIAKI_LOGI(c->log, "[KAMAJI] 0.5d -> entitlement %s platform %s sku %s", c->entitlement_id, c->platform, c->streaming_sku);
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode km_get_commerce_token(KamajiCtx *c)
{
	char url[2048];
	snprintf(url, sizeof(url), KM_ACCOUNT_BASE "/v1/oauth/authorize?smcid=pc:psnow&applicationId=psnow"
		"&response_type=token&scope=kamaji:get_internal_entitlements%%20user:account.attributes.validate"
		"%%20kamaji:get_privacy_settings%%20user:account.settings.privacy.get%%20kamaji:s2s.subscriptionsPremium.get"
		"&client_id=%s&redirect_uri=%s&grant_type=authorization_code&service_entity=urn:service-entity:psn"
		"&prompt=none&renderMode=mobilePortrait&hidePageElements=forgotPasswordLink&displayFooter=none"
		"&disableLinks=qriocityLink&mid=PSNOW&duid=%s&layout_type=popup&service_logo=ps&tp_psn=true&noEVBlock=true",
		KM_COMMERCE_CLIENT_ID, KM_REDIRECT_URI, c->duid);
	char *tok = NULL;
	ChiakiErrorCode e = km_oauth(c, url, true, &tok);
	if(e != CHIAKI_ERR_SUCCESS) return e;
	free(c->commerce_token); c->commerce_token = tok;
	return CHIAKI_ERR_SUCCESS;
}

// Percent-encode per RFC 3986 (unreserved A-Za-z0-9-_.~ left as-is).
static void km_urlencode(const char *in, char *out, size_t out_size)
{
	static const char hex[] = "0123456789ABCDEF";
	size_t o = 0;
	for(const unsigned char *p = (const unsigned char *)in; *p && o + 4 < out_size; p++)
	{
		if((*p >= 'A' && *p <= 'Z') || (*p >= 'a' && *p <= 'z') ||
		   (*p >= '0' && *p <= '9') || *p == '-' || *p == '_' || *p == '.' || *p == '~')
			out[o++] = (char)*p;
		else { out[o++] = '%'; out[o++] = hex[*p >> 4]; out[o++] = hex[*p & 0xF]; }
	}
	out[o] = '\0';
}

// On an attributes failure, build the Sony "upgrade account" URL from the missing
// privacy elements (error.validationErrors[].missingElements[].name), surfaced as
// the "ACCOUNT_PRIVACY_SETTINGS:<url>" sentinel -- the platform opens it so the user
// can complete the required settings. Mirrors pskamajisession.cpp:830-882.
static char *km_build_privacy_sentinel(struct json_object *body)
{
	char elements[512] = "";
	struct json_object *err = body ? cc_json_obj(body, "error") : NULL;
	struct json_object *ve = err ? cc_json_arr(err, "validationErrors") : NULL;
	if(ve) for(size_t i = 0; i < json_object_array_length(ve); i++)
	{
		struct json_object *me = cc_json_arr(json_object_array_get_idx(ve, i), "missingElements");
		if(!me) continue;
		for(size_t k = 0; k < json_object_array_length(me); k++)
		{
			const char *name = cc_json_str(json_object_array_get_idx(me, k), "name");
			if(name && *name)
			{
				if(elements[0]) strncat(elements, ",", sizeof(elements) - strlen(elements) - 1);
				strncat(elements, name, sizeof(elements) - strlen(elements) - 1);
			}
		}
	}
	if(!elements[0]) return strdup("ACCOUNT_PRIVACY_SETTINGS");
	char enc_redir[256], enc_elem[768], url[2048];
	km_urlencode(KM_REDIRECT_URI, enc_redir, sizeof(enc_redir));
	km_urlencode(elements, enc_elem, sizeof(enc_elem));
	snprintf(url, sizeof(url),
		"ACCOUNT_PRIVACY_SETTINGS:https://id.sonyentertainmentnetwork.com/id/upgrade_account_ca/"
		"?entry=upgrade_account&pr_referer=upgrade&redirect_uri=%s&applicationId=psnow&refererPage=websso"
		"&service_logo=ps&tp_console=true&disableLinks=SENLink&renderMode=mobilePortrait&noEVBlock=true"
		"&displayFooter=none&hidePageElements=SENLogo&layout_type=popup&missing_elements=%s&response_type=code"
		"&service_entity=urn:service-entity:psn&smcid=pc:psnow&tp_psn=true&tp_social=true"
		"&elements_visibility_upgrade=no_cancel",
		enc_redir, enc_elem);
	return strdup(url);
}

static ChiakiErrorCode km_check_account_attributes(KamajiCtx *c, char **out_error)
{
	if(c->cfg->skip_account_attr_check) return CHIAKI_ERR_SUCCESS;
	const char *body = "{\"attributes\":[\"ONLINE_ID\",\"BIRTH_DATE\",\"CITY\",\"REAL_NAME\","
		"\"PRIVACY_SETTING_ACTIVITYSTREAM\",\"PRIVACY_SETTING_FRIENDSLIST\",\"PRIVACY_SETTING_FRIENDREQUESTS\","
		"\"PRIVACY_SETTING_MESSAGES\",\"PRIVACY_SETTING_TRUENAME\",\"PRIVACY_SETTING_SEARCH\","
		"\"PRIVACY_SETTING_RECOMMENDUSERS\",\"PRIVACY_SETTING_BROADCAST\"]}";
	char *h_auth = NULL; cc_http_make_bearer_header(&h_auth, c->commerce_token);
	char *h_ua = km_hdr("User-Agent", KM_USER_AGENT);
	if(!h_auth || !h_ua) { free(h_auth); free(h_ua); return CHIAKI_ERR_MEMORY; } // OOM guard (else NULL header)
	const char *hdrs[] = { h_auth, h_ua, "Accept: application/json", "Content-Type: application/json" };
	CCHttpRequest req = { 0 };
	req.method = "POST"; req.url = "https://accounts.api.playstation.com/api/v2/accounts/me/attributes";
	req.headers = hdrs; req.header_count = 4; req.body = body;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	free(h_auth); free(h_ua);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	if(resp.status_code == 200 || resp.status_code == 204) { cc_http_response_fini(&resp); return CHIAKI_ERR_SUCCESS; }
	// Privacy/account upgrade required: build the upgrade URL from the missing
	// elements and surface it as the sentinel the platform turns into the dialog.
	CHIAKI_LOGE(c->log, "[KAMAJI] account attributes failed (%ld)", resp.status_code);
	if(out_error)
	{
		struct json_object *j = resp.data ? json_tokener_parse(resp.data) : NULL;
		*out_error = km_build_privacy_sentinel(j);
		if(j) json_object_put(j);
	}
	cc_http_response_fini(&resp);
	return CHIAKI_ERR_UNKNOWN;
}

static ChiakiErrorCode km_checkout_acquire(KamajiCtx *c, char **out_error)
{
	if(c->cfg->progress) c->cfg->progress("Acquiring License - Step 3 of 5", c->cfg->user);
	char *h_auth = NULL; cc_http_make_bearer_header(&h_auth, c->commerce_token);
	char *h_ua = km_hdr("User-Agent", KM_USER_AGENT);
	char *h_cookie = NULL;
	if(c->jsessionid) cc_http_make_cookie_header(&h_cookie, "JSESSIONID", c->jsessionid);
	if(!h_auth || !h_ua) { free(h_auth); free(h_ua); free(h_cookie); return CHIAKI_ERR_MEMORY; } // OOM guard

	// --- preview: confirm $0 then take the authoritative sku ---
	char prev_body[256];
	snprintf(prev_body, sizeof(prev_body), "sku=%s", c->streaming_sku[0] ? c->streaming_sku : c->entitlement_id);
	const char *prev_hdrs[] = {
		h_auth, h_ua, h_cookie ? h_cookie : "Accept: application/json",
		"Content-Type: application/x-www-form-urlencoded; charset=UTF-8",
		"Accept: application/json, text/javascript, */*; q=0.01",
		"X-Requested-With: XMLHttpRequest", "Origin: " KM_ORIGIN, "Referer: " KM_REFERER
	};
	CCHttpRequest preq = { 0 };
	preq.method = "POST"; preq.url = KM_KAMAJI_BASE "/user/checkout/buynow/preview";
	preq.headers = prev_hdrs; preq.header_count = 8; preq.body = prev_body;
	preq.capture_headers = true; // refresh JSESSIONID from the preview Set-Cookie before buynow (parity with Qt)
	CCHttpResponse presp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &preq, &presp);
	if(e != CHIAKI_ERR_SUCCESS) { free(h_auth); free(h_ua); free(h_cookie); cc_http_response_fini(&presp); return e; }
	struct json_object *pj = presp.data ? json_tokener_parse(presp.data) : NULL;
	struct json_object *phdr = pj ? cc_json_obj(pj, "header") : NULL;
	const char *pstatus = phdr ? cc_json_str(phdr, "status_code") : "";
	if(presp.status_code != 200 || (pstatus && *pstatus && strcmp(pstatus, "0x0000") != 0))
	{
		CHIAKI_LOGE(c->log, "[KAMAJI] checkout preview failed (%ld / %s)", presp.status_code, pstatus);
		if(out_error) *out_error = strdup("PS_PLUS_SUBSCRIPTION_REQUIRED");
		if(pj) json_object_put(pj);
		free(h_auth); free(h_ua); free(h_cookie); cc_http_response_fini(&presp);
		return CHIAKI_ERR_UNKNOWN;
	}
	struct json_object *pdata = cc_json_obj(pj, "data");
	struct json_object *cart = pdata ? cc_json_obj(pdata, "cart") : NULL;
	int total = cart ? cc_json_int(cart, "total_price_value") : -1;
	if(total != 0)
	{
		const char *price = cart ? cc_json_str(cart, "total_price") : "";
		CHIAKI_LOGE(c->log, "[KAMAJI] title is not free (price %s / value %d)", price, total);
		// Reachable when the cached catalog is stale: a title that was a free PS+ offer
		// now costs money. Carry the display price in the sentinel so the UI can tell the
		// user the title is no longer free (and to refresh their game list).
		if(out_error)
		{
			char sentinel[160];
			snprintf(sentinel, sizeof(sentinel), "GAME_NOT_FREE:%s", price);
			*out_error = strdup(sentinel);
		}
		if(pj) json_object_put(pj);
		free(h_auth); free(h_ua); free(h_cookie); cc_http_response_fini(&presp);
		return CHIAKI_ERR_UNKNOWN;
	}
	struct json_object *items = cart ? cc_json_arr(cart, "items") : NULL;
	if(items && json_object_array_length(items) > 0)
	{
		const char *real = cc_json_str(json_object_array_get_idx(items, 0), "sku_id");
		if(real && *real) snprintf(c->streaming_sku, sizeof(c->streaming_sku), "%s", real);
	}
	char *js2 = km_jsessionid(presp.headers);
	if(js2) { free(c->jsessionid); c->jsessionid = js2; free(h_cookie); h_cookie = NULL; cc_http_make_cookie_header(&h_cookie, "JSESSIONID", c->jsessionid); }
	if(pj) json_object_put(pj);
	cc_http_response_fini(&presp);

	// --- buynow: complete the $0 acquire ---
	char buy_body[256];
	snprintf(buy_body, sizeof(buy_body), "sku=%s&skipEmail=true", c->streaming_sku);
	const char *buy_hdrs[] = {
		h_auth, h_ua, h_cookie ? h_cookie : "Accept: application/json", "Accept: application/json",
		"Content-Type: application/x-www-form-urlencoded"
	};
	CCHttpRequest breq = { 0 };
	breq.method = "POST"; breq.url = KM_KAMAJI_BASE "/user/checkout/buynow";
	breq.headers = buy_hdrs; breq.header_count = 5; breq.body = buy_body;
	CCHttpResponse bresp = { 0 };
	e = cc_http_perform(c->log, &breq, &bresp);
	free(h_auth); free(h_ua); free(h_cookie);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&bresp); return e; }
	struct json_object *bj = bresp.data ? json_tokener_parse(bresp.data) : NULL;
	struct json_object *bhdr = bj ? cc_json_obj(bj, "header") : NULL;
	const char *bstatus = bhdr ? cc_json_str(bhdr, "status_code") : "";
	bool ok = (bresp.status_code == 200) && bstatus && strcmp(bstatus, "0x0000") == 0;
	if(!ok) CHIAKI_LOGE(c->log, "[KAMAJI] checkout buynow failed (%ld / %s)", bresp.status_code, bstatus);
	else CHIAKI_LOGI(c->log, "[KAMAJI] entitlement acquired");
	if(bj) json_object_put(bj);
	cc_http_response_fini(&bresp);
	return ok ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_UNKNOWN;
}

static ChiakiErrorCode km_step0_5e_check_acquire(KamajiCtx *c, char **out_error)
{
	if(c->cfg->progress) c->cfg->progress("Checking License - Step 3 of 5", c->cfg->user);
	ChiakiErrorCode e = km_get_commerce_token(c);
	if(e != CHIAKI_ERR_SUCCESS) return e;
	e = km_check_account_attributes(c, out_error);
	if(e != CHIAKI_ERR_SUCCESS) return e;

	char url[256];
	snprintf(url, sizeof(url), "https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/"
		"internal_entitlements/%s?fields=game_meta", c->entitlement_id);
	char *h_auth = NULL; cc_http_make_bearer_header(&h_auth, c->commerce_token);
	char *h_ua = km_hdr("User-Agent", KM_USER_AGENT);
	if(!h_auth || !h_ua) { free(h_auth); free(h_ua); return CHIAKI_ERR_MEMORY; } // OOM guard (else NULL header)
	const char *hdrs[] = { h_auth, h_ua, "Accept: application/json" };
	CCHttpRequest req = { 0 };
	req.url = url; req.headers = hdrs; req.header_count = 3;
	CCHttpResponse resp = { 0 };
	e = cc_http_perform(c->log, &req, &resp);
	free(h_auth); free(h_ua);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	long status = resp.status_code;
	cc_http_response_fini(&resp);

	if(status == 200) { CHIAKI_LOGI(c->log, "[KAMAJI] entitlement already owned"); return CHIAKI_ERR_SUCCESS; }
	if(status == 404)
	{
		if(c->cfg->catalog_is_foreign)
		{
			CHIAKI_LOGI(c->log, "[KAMAJI] entitlement 404, fallback region -> skip acquire, let Gaikai validate");
			return CHIAKI_ERR_SUCCESS;
		}
		return km_checkout_acquire(c, out_error);
	}
	CHIAKI_LOGE(c->log, "[KAMAJI] entitlement check failed (%ld)", status);
	return CHIAKI_ERR_UNKNOWN;
}

static ChiakiErrorCode km_step5_authcode(KamajiCtx *c, char **out_code)
{
	if(c->cfg->progress) c->cfg->progress("Authorizing - Step 4 of 5", c->cfg->user);
	char url[2048];
	snprintf(url, sizeof(url), KM_ACCOUNT_BASE "/v1/oauth/authorize?smcid=pc:psnow&applicationId=psnow"
		"&response_type=code&scope=%s&client_id=%s&redirect_uri=%s&service_entity=urn:service-entity:psn"
		"&prompt=none&mid=PSNOW&duid=%s&layout_type=popup&service_logo=ps&tp_psn=true&noEVBlock=true",
		c->scopes, KM_CLIENT_ID, KM_REDIRECT_URI, c->duid);
	return km_oauth(c, url, false, out_code);
}

static ChiakiErrorCode km_step6_auth_session(KamajiCtx *c, const char *auth_code)
{
	if(c->cfg->progress) c->cfg->progress("Creating Session - Step 5 of 5", c->cfg->user);
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = km_post_session(c, auth_code, false, &resp);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	struct json_object *j = resp.data ? json_tokener_parse(resp.data) : NULL;
	struct json_object *hdr = j ? cc_json_obj(j, "header") : NULL;
	const char *status = hdr ? cc_json_str(hdr, "status_code") : "";
	bool ok = status && strcmp(status, "0x0000") == 0;
	if(ok)
	{
		struct json_object *data = cc_json_obj(j, "data");
		CHIAKI_LOGI(c->log, "[KAMAJI] session created (onlineId %s)", data ? cc_json_str(data, "onlineId") : "");
	}
	else CHIAKI_LOGE(c->log, "[KAMAJI] step6 session failed (%ld / %s)", resp.status_code, status);
	if(j) json_object_put(j);
	cc_http_response_fini(&resp);
	return ok ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_UNKNOWN;
}

ChiakiErrorCode cc_kamaji_resolve(ChiakiLog *log,
	const ChiakiCloudProvisionConfig *cfg, const char *duid,
	char out_entitlement_id[128], char out_platform[8], char **out_error)
{
	KamajiCtx c;
	memset(&c, 0, sizeof(c));
	c.log = log;
	c.cfg = cfg;
	c.duid = (duid && *duid) ? duid : "";
	c.npsso = cfg->npsso ? cfg->npsso : "";
	snprintf(c.platform, sizeof(c.platform), "ps4");
	c.scopes = KM_PS4_SCOPES;
	if(out_error) *out_error = NULL;

	ChiakiErrorCode e;
	bool fast_path = cfg->owned_entitlement_id && *cfg->owned_entitlement_id;
	if(fast_path)
	{
		snprintf(c.entitlement_id, sizeof(c.entitlement_id), "%s", cfg->owned_entitlement_id);
		snprintf(c.platform, sizeof(c.platform), "%s",
			(cfg->owned_platform && *cfg->owned_platform) ? cfg->owned_platform : "ps4");
		c.scopes = (strcmp(c.platform, "ps3") == 0) ? KM_PS3_SCOPES : KM_PS4_SCOPES;
		CHIAKI_LOGI(log, "[KAMAJI] fast-path owned entitlement %s (%s) -> skip 0.5b-0.5e", c.entitlement_id, c.platform);
		e = CHIAKI_ERR_SUCCESS;
	}
	else
	{
		char *anon_code = NULL;
		e = km_step0_5b_anon_authcode(&c, &anon_code);
		if(e == CHIAKI_ERR_SUCCESS) e = km_step0_5c_anon_session(&c, anon_code);
		free(anon_code);
		if(e == CHIAKI_ERR_SUCCESS) e = km_step0_5d_resolve(&c);
		if(e == CHIAKI_ERR_SUCCESS) e = km_step0_5e_check_acquire(&c, out_error);
	}

	if(e == CHIAKI_ERR_SUCCESS)
	{
		char *auth_code = NULL;
		e = km_step5_authcode(&c, &auth_code);
		if(e == CHIAKI_ERR_SUCCESS) e = km_step6_auth_session(&c, auth_code);
		free(auth_code);
	}

	if(e == CHIAKI_ERR_SUCCESS)
	{
		snprintf(out_entitlement_id, 128, "%s", c.entitlement_id);
		snprintf(out_platform, 8, "%s", c.platform);
	}
	free(c.jsessionid);
	free(c.commerce_token);
	return e;
}
