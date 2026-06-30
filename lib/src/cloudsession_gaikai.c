// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Gaikai allocation flow -- C port of the Qt psgaikaistreaming.cpp async state
// machine, run as a single blocking sequence on a worker thread.
// step0 client_ids -> step7 config -> step8 start -> 8a/8b OAuth auth codes
// -> step9 authorize -> step10 lock -> step11 datacenters (ping/forced) ->
// step12 select -> step13 allocate(+wait). Produces the stream-ready result.

#include "cloudsession_internal.h"
#include "cloudcatalog_internal.h"  // cc_json_* helpers
#include "curl_http.h"

#include <chiaki/cloudcatalog.h>     // chiaki_cloud_gaikai_language
#include <chiaki/thread.h>           // parallel datacenter ping
// json-c: the specific headers come via cloudcatalog_internal.h (the umbrella
// <json-c/json.h> is not present in the iOS/Android FetchContent build).

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <strings.h>
#include <unistd.h>
#include <time.h>

#define GK_BASE        "https://cc.prod.gaikai.com/v1"
#define GK_CONFIG_BASE "https://config.cc.prod.gaikai.com/v1"
#define ACCOUNT_BASE   "https://ca.account.sony.com"
#define GK_UA_PSCLOUD  "PlayStation Portal/6.0.0-rel.444+6a9cea6f5"
#define GK_UA_PSNOW    CS_PSNOW_USER_AGENT  // shared (cloudsession_internal.h)
#define GK_REDIR_PSNOW CS_PSNOW_REDIRECT
#define GK_REDIR_PSCLOUD "gaikai://local"
#define MAX_LOCK_RETRIES 12
#define DEFAULT_ALLOC_WAIT_S 300
#define MAX_ALLOC_WAIT_S 900

typedef struct
{
	ChiakiLog *log;
	const ChiakiCloudProvisionConfig *cfg;
	bool pscloud;
	const char *platform;       // "ps3"|"ps4"|"ps5"
	const char *virt_type;      // "konan"|"kratos"|"cronos"
	const char *user_agent;
	const char *oauth_api_path; // "/api/authz/v3" | "/api/v1"
	const char *redirect_uri;
	char duid[128];             // shared client device uid (OAuth, same one Kamaji uses)
	char *config_key;           // x-gaikai-session (updates every response)
	char *lock_session_key;
	char *gaikai_session_id;
	char gk_client_id[128];
	char ps3_gk_client_id[128];
	char stream_server_client_id[128];
	char *gk_cloud_auth_code;
	char *ps3_auth_code;
	char *stream_server_auth_code;
	struct json_object *spec;          // requestGameSpecification (auth codes patched after 8b)
	struct json_object *ping_results;  // sorted array (this run's measurements; used for select/allocate)
	struct json_object *dc_picker;     // full datacenter list for the Settings picker (merged)
	struct json_object *selected_ping; // borrowed ref into ping_results
	char selected_datacenter[128];
	int selected_dc_port;
	bool ping_timeout;          // best measured RTT exceeded the auto-select gate (>80ms)
	bool forced_dc_unavailable; // settings-forced datacenter not in this title's list
} GaikaiCtx;

static void gk_progress(GaikaiCtx *c, const char *stage)
{
	if(c->cfg->progress) c->cfg->progress(stage, c->cfg->user);
}
static bool gk_cancelled(GaikaiCtx *c)
{
	return c->cfg->is_cancelled && c->cfg->is_cancelled(c->cfg->user);
}
// Sleep up to seconds, checking cancellation every 100ms. false if cancelled.
static bool gk_sleep_cancellable(GaikaiCtx *c, int seconds)
{
	for(int i = 0; i < seconds * 10; i++)
	{
		if(gk_cancelled(c)) return false;
		usleep(100000);
	}
	return true;
}

static char *gk_header_value(const char *headers, const char *name)
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

static void gk_update_session_key(GaikaiCtx *c, const CCHttpResponse *resp)
{
	char *k = gk_header_value(resp->headers, "x-gaikai-session");
	if(k && *k) { free(c->config_key); c->config_key = k; }
	else free(k);
}

// Extract a query parameter value (no URL-decoding; Gaikai codes are URL-safe).
static char *gk_query_param(const char *url, const char *key)
{
	if(!url) return NULL;
	size_t klen = strlen(key);
	const char *p = url;
	while((p = strchr(p, key[0])) != NULL)
	{
		if((p == url || p[-1] == '?' || p[-1] == '&') &&
		   strncmp(p, key, klen) == 0 && p[klen] == '=')
		{
			const char *v = p + klen + 1;
			const char *e = strpbrk(v, "&#");
			size_t vlen = e ? (size_t)(e - v) : strlen(v);
			char *out = (char *)malloc(vlen + 1);
			if(!out) return NULL;
			memcpy(out, v, vlen); out[vlen] = '\0';
			return out;
		}
		p++;
	}
	return NULL;
}

// "Key: Value" -> malloc'd. Caller frees.
static char *gk_hdr(const char *key, const char *value)
{
	size_t n = strlen(key) + 2 + (value ? strlen(value) : 0) + 1;
	char *s = (char *)malloc(n);
	if(s) snprintf(s, n, "%s: %s", key, value ? value : "");
	return s;
}

// OAuth /oauth/authorize GET (prompt=none): returns the 302 redirect's ?code=.
static ChiakiErrorCode gk_oauth_code(GaikaiCtx *c, const char *url, char **out_code)
{
	*out_code = NULL;
	char *cookie = NULL;
	if(cc_http_make_cookie_header(&cookie, "npsso", c->cfg->npsso) != CHIAKI_ERR_SUCCESS)
		return CHIAKI_ERR_MEMORY;
	char *h_ua = gk_hdr("User-Agent", c->user_agent);
	const char *hdrs[] = { h_ua, cookie };
	CCHttpRequest req = { 0 };
	req.url = url;
	req.headers = hdrs;
	req.header_count = 2;
	req.follow_redirects = false;
	req.capture_headers = true;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	free(h_ua); free(cookie);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }

	const char *loc = resp.redirect_url;
	char *loc_hdr = NULL;
	if(!loc) { loc_hdr = gk_header_value(resp.headers, "Location"); loc = loc_hdr; }
	if(resp.status_code != 302 || !loc)
	{
		CHIAKI_LOGE(c->log, "[GAIKAI] oauth: expected 302+Location, got %ld", resp.status_code);
		free(loc_hdr); cc_http_response_fini(&resp);
		return CHIAKI_ERR_UNKNOWN;
	}
	char *code = gk_query_param(loc, "code");
	free(loc_hdr);
	cc_http_response_fini(&resp);
	if(!code) return CHIAKI_ERR_UNKNOWN;
	*out_code = code;
	return CHIAKI_ERR_SUCCESS;
}

// POST a {"requestGameSpecification": spec, <extra>} body to /sessions/{id}/<action>.
// @p extra (may be NULL) is merged into the body root (ownership transferred).
static ChiakiErrorCode gk_post_session(GaikaiCtx *c, const char *action_with_query,
	struct json_object *extra, CCHttpResponse *resp_out)
{
	struct json_object *wrap = json_object_new_object();
	json_object_object_add(wrap, "requestGameSpecification", json_object_get(c->spec));
	if(extra)
	{
		json_object_object_foreach(extra, k, v)
			json_object_object_add(wrap, k, json_object_get(v));
		json_object_put(extra);
	}
	const char *body = json_object_to_json_string(wrap);

	char url[512];
	snprintf(url, sizeof(url), "%s/sessions/%s%s", GK_BASE,
		c->gaikai_session_id ? c->gaikai_session_id : "", action_with_query);
	char *h_ua = gk_hdr("User-Agent", c->user_agent);
	char *h_sid = gk_hdr("X-Gaikai-SessionId", c->gaikai_session_id ? c->gaikai_session_id : "");
	char *h_skey = gk_hdr("X-Gaikai-Session", c->config_key ? c->config_key : "");
	const char *hdrs[] = { "Content-Type: application/json", "Accept: */*", h_ua, h_sid, h_skey };

	CCHttpRequest req = { 0 };
	req.method = "POST";
	req.url = url;
	req.headers = hdrs;
	req.header_count = 5;
	req.body = body;
	req.capture_headers = true;
	ChiakiErrorCode e = cc_http_perform(c->log, &req, resp_out);
	free(h_ua); free(h_sid); free(h_skey);
	json_object_put(wrap);
	return e;
}

// Build the requestGameSpecification (auth codes empty; patched after step 8b).
static struct json_object *gk_build_spec(GaikaiCtx *c, const char *entitlement_id)
{
	char lang[16];
	chiaki_cloud_gaikai_language(c->cfg->game_language ? c->cfg->game_language : "", lang, sizeof(lang));

	int res = c->cfg->resolution;
	const char *res_set; int cw, ch;
	if(res == 720)       { res_set = "720";  cw = 1280; ch = 720; }
	else if(res == 1440) { res_set = "1440"; cw = 2560; ch = 1440; }
	else if(res == 2160) { res_set = "2160"; cw = 3840; ch = 2160; }
	else                 { res_set = "1080"; cw = 1920; ch = 1080; }

	// Timezone "UTC+HH:MM" from the system offset.
	char tz[16];
	{
		time_t t = time(NULL);
		struct tm lt;
		localtime_r(&t, &lt);
		long off = lt.tm_gmtoff;
		int oh = (int)(off / 3600);
		int om = (int)((off < 0 ? -off : off) % 3600) / 60;
		snprintf(tz, sizeof(tz), "UTC%c%02d:%02d", off >= 0 ? '+' : '-', oh < 0 ? -oh : oh, om);
	}

	struct json_object *s = json_object_new_object();
	#define S_STR(k,v)  json_object_object_add(s, k, json_object_new_string(v))
	#define S_INT(k,v)  json_object_object_add(s, k, json_object_new_int(v))
	#define S_BOOL(k,v) json_object_object_add(s, k, json_object_new_boolean(v))
	S_STR("entitlementId", entitlement_id);
	S_STR("npEnv", "np");
	S_STR("language", lang);
	S_STR("cloudEndpoint", "https://cc.prod.gaikai.com");
	S_STR("redirectUri", c->redirect_uri);
	S_STR("resolutionSetting", res_set);
	S_INT("clientWidth", cw);
	S_INT("clientHeight", ch);
	S_STR("adaptiveStreamMode", "resize");
	S_BOOL("useClientBwLadder", true);
	S_BOOL("audioUploadEnabled", true);
	S_INT("audioUploadNumChannels", 1);
	S_INT("audioUploadSamplingFrequency", 48000);
	S_STR("acceptButton", "X");
	S_BOOL("encryptionSupported", true);
	S_INT("summerTime", 0);
	S_STR("timeZone", tz);
	S_STR("httpUserAgent", c->user_agent);
	S_STR("gkCloudAuthCode", "");
	S_INT("accessibilityMarqueeSpeed", 0);
	S_INT("accessibilityLargeText", 0);
	S_INT("accessibilityBoldText", 0);
	S_INT("accessibilityContrast", 0);
	S_INT("accessibilityTtsEnable", 0);
	S_INT("accessibilityTtsSpeed", 0);
	S_INT("accessibilityTtsVolume", 0);
	S_BOOL("partyCapability", false);
	S_BOOL("homesharing", false);
	S_BOOL("isFirstBoot", false);
	S_BOOL("isPlusMember", true);
	S_INT("parentalLevel", 0);
	S_STR("yuvCoefficient", "");

	struct json_object *caps = json_object_new_array();
	json_object_array_add(caps, json_object_new_string("cloudDrivenSenkushaTest"));

	if(c->pscloud)
	{
		S_STR("videoEncoderProfile", "hw5.0");
		struct json_object *ctrls = json_object_new_array();
		json_object_array_add(ctrls, json_object_new_string("ds4"));
		json_object_array_add(ctrls, json_object_new_string("ds5"));
		json_object_array_add(ctrls, json_object_new_string("xinput"));
		json_object_object_add(s, "connectedControllers", json_object_get(ctrls));
		struct json_object *input = json_object_new_object();
		json_object_object_add(input, "controllers", ctrls);
		json_object_object_add(s, "input", input);
		S_STR("model", "portal");
		S_STR("platform", "qlite");
		S_STR("gaikaiPlayer", "16.4.0");
		S_INT("protocolVersion", 12);
		S_STR("ps3AuthCode", "");
		S_STR("streamServerAuthCode", "");
		json_object_array_add(caps, json_object_new_string("cronos"));
		struct json_object *vss = json_object_new_object();
		json_object_object_add(vss, "clientHeight", json_object_new_int(ch));
		json_object_object_add(vss, "supportedMaxResolution", json_object_new_int(ch));
		struct json_object *vprof = json_object_new_array();
		json_object_array_add(vprof, json_object_new_string("hevc_hw4"));
		json_object_object_add(vss, "supportedVideoEncoderProfiles", vprof);
		json_object_object_add(vss, "supportedDynamicRange", json_object_new_string("sdr"));
		json_object_object_add(vss, "preferredMaxResolution", json_object_new_int(ch));
		json_object_object_add(vss, "preferredDynamicRange", json_object_new_string("sdr"));
		json_object_object_add(vss, "hqMode", json_object_new_int(1));
		json_object_object_add(s, "videoStreamSettings", vss);
		S_STR("audioChannels", "2");
		S_STR("audioEncoderProfile", "default");
		struct json_object *ass = json_object_new_object();
		json_object_object_add(ass, "audioEncoderProfile", json_object_new_string("default"));
		json_object_object_add(ass, "maxAudioChannels", json_object_new_string("2"));
		json_object_object_add(ass, "preferredNumberAudioChannels", json_object_new_string("2"));
		json_object_object_add(s, "audioStreamSettings", ass);
	}
	else
	{
		S_STR("audioChannels", "2.1");
		S_STR("audioEncoderProfile", "default");
		S_STR("videoEncoderProfile", "hw4.1");
		struct json_object *ctrls = json_object_new_array();
		json_object_array_add(ctrls, json_object_new_string("xinput"));
		json_object_object_add(s, "connectedControllers", json_object_get(ctrls));
		struct json_object *input = json_object_new_object();
		json_object_object_add(input, "controllers", ctrls);
		json_object_object_add(s, "input", input);
		S_STR("model", "WINDOWS");
		S_STR("platform", "PC");
		S_STR("gaikaiPlayer", "12.5.0");
		S_INT("protocolVersion", 9);
		S_STR("ps3AuthCode", "");
		S_STR("streamServerAuthCode", "");
		json_object_array_add(caps, json_object_new_string("kratos"));
	}
	json_object_object_add(s, "capabilities", caps);
	#undef S_STR
	#undef S_INT
	#undef S_BOOL
	return s;
}

static void gk_patch_auth_codes(GaikaiCtx *c)
{
	json_object_object_add(c->spec, "gkCloudAuthCode",
		json_object_new_string(c->gk_cloud_auth_code ? c->gk_cloud_auth_code : ""));
	json_object_object_add(c->spec, "ps3AuthCode",
		json_object_new_string(c->ps3_auth_code ? c->ps3_auth_code : ""));
	json_object_object_add(c->spec, "streamServerAuthCode",
		json_object_new_string(c->stream_server_auth_code ? c->stream_server_auth_code : ""));
}

// ---- steps -----------------------------------------------------------------

static ChiakiErrorCode gk_step0_client_ids(GaikaiCtx *c)
{
	gk_progress(c, "Getting Client IDs - Step 1 of 10");
	char url[256];
	snprintf(url, sizeof(url), "%s/client_ids?virtType=%s", GK_BASE, c->virt_type);
	char *h_ua = gk_hdr("User-Agent", c->user_agent);
	const char *hdrs[] = { "Accept: */*", h_ua };
	CCHttpRequest req = { 0 };
	req.url = url; req.headers = hdrs; req.header_count = 2;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	free(h_ua);
	if(e != CHIAKI_ERR_SUCCESS || resp.status_code != 200 || !resp.data)
	{
		CHIAKI_LOGE(c->log, "[GAIKAI] step0 client_ids http %ld", resp.status_code);
		cc_http_response_fini(&resp);
		return CHIAKI_ERR_UNKNOWN;
	}
	struct json_object *j = json_tokener_parse(resp.data);
	if(j)
	{
		snprintf(c->gk_client_id, sizeof(c->gk_client_id), "%s", cc_json_str(j, "gkClientId"));
		snprintf(c->ps3_gk_client_id, sizeof(c->ps3_gk_client_id), "%s", cc_json_str(j, "ps3GkClientId"));
		snprintf(c->stream_server_client_id, sizeof(c->stream_server_client_id), "%s", cc_json_str(j, "streamServerClientId"));
		json_object_put(j);
	}
	cc_http_response_fini(&resp);
	return c->gk_client_id[0] ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_UNKNOWN;
}

static ChiakiErrorCode gk_step7_config(GaikaiCtx *c)
{
	gk_progress(c, "Getting Configuration - Step 2 of 10");
	char url[256];
	snprintf(url, sizeof(url), "%s/config", GK_CONFIG_BASE);
	char body[256];
	snprintf(body, sizeof(body), "{\"product\":\"%s\",\"platform\":\"%s\",\"sessionId\":\"\"}",
		c->pscloud ? "qlite" : "psnow", c->pscloud ? "qlite" : "PC");
	char *h_ua = gk_hdr("User-Agent", c->user_agent);
	const char *hdrs[] = { "Content-Type: application/json", "Accept: */*", h_ua };
	CCHttpRequest req = { 0 };
	req.method = "POST"; req.url = url; req.headers = hdrs; req.header_count = 3; req.body = body;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	free(h_ua);
	if(e != CHIAKI_ERR_SUCCESS || resp.status_code != 200 || !resp.data)
	{
		CHIAKI_LOGE(c->log, "[GAIKAI] step7 config http %ld", resp.status_code);
		cc_http_response_fini(&resp);
		return CHIAKI_ERR_UNKNOWN;
	}
	struct json_object *j = json_tokener_parse(resp.data);
	if(j) { const char *ck = cc_json_str(j, "configKey"); if(*ck) { free(c->config_key); c->config_key = strdup(ck); } json_object_put(j); }
	cc_http_response_fini(&resp);
	return (c->config_key && *c->config_key) ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_UNKNOWN;
}

// step8 start session. On entitlement rejection, the response body carries the
// {"name":"noGameForEntitlementId"} marker -> copied to out->error_message so the
// orchestrator can trigger the one-shot full-flow fallback.
static ChiakiErrorCode gk_step8_start(GaikaiCtx *c, ChiakiCloudProvisionResult *out)
{
	gk_progress(c, "Starting Session - Step 3 of 10");
	char url[256];
	snprintf(url, sizeof(url), "%s/sessions/start?npEnv=np", GK_BASE);
	struct json_object *wrap = json_object_new_object();
	json_object_object_add(wrap, "requestGameSpecification", json_object_get(c->spec));
	const char *body = json_object_to_json_string(wrap);
	char *h_ua = gk_hdr("User-Agent", c->user_agent);
	char *h_skey = gk_hdr("X-Gaikai-Session", c->config_key ? c->config_key : "");
	const char *hdrs[] = { "Content-Type: application/json", "Accept: */*", h_ua, h_skey };
	CCHttpRequest req = { 0 };
	req.method = "POST"; req.url = url; req.headers = hdrs; req.header_count = 4;
	req.body = body; req.capture_headers = true;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	free(h_ua); free(h_skey); json_object_put(wrap);
	if(e != CHIAKI_ERR_SUCCESS || resp.status_code != 200)
	{
		CHIAKI_LOGE(c->log, "[GAIKAI] step8 start http %ld: %s", resp.status_code, resp.data ? resp.data : "");
		if(resp.data) { free(out->error_message); out->error_message = strdup(resp.data); }
		cc_http_response_fini(&resp);
		return CHIAKI_ERR_UNKNOWN;
	}
	gk_update_session_key(c, &resp);
	struct json_object *j = resp.data ? json_tokener_parse(resp.data) : NULL;
	if(j) { const char *sid = cc_json_str(j, "sessionId"); if(*sid) { free(c->gaikai_session_id); c->gaikai_session_id = strdup(sid); } json_object_put(j); }
	cc_http_response_fini(&resp);
	return (c->gaikai_session_id && *c->gaikai_session_id) ? CHIAKI_ERR_SUCCESS : CHIAKI_ERR_UNKNOWN;
}

static ChiakiErrorCode gk_step8a_gk_authcode(GaikaiCtx *c)
{
	gk_progress(c, "Getting Tokens - Step 4 of 10");
	char url[2048];
	if(c->pscloud)
		snprintf(url, sizeof(url), "%s%s/oauth/authorize?response_type=code&client_id=%s&redirect_uri=%s"
			"&service_entity=urn:service-entity:psn&prompt=none&duid=%s&smcid=qlite&applicationId=qlite&mid=qlite"
			"&scope=id_token:psn.basic_claims%%20kamaji:s2s.subscriptionsPremium.get%%20id_token:duid%%20id_token:online_id%%20openid%%20psn:s2s",
			ACCOUNT_BASE, c->oauth_api_path, c->gk_client_id, GK_REDIR_PSCLOUD, c->duid);
	else
		snprintf(url, sizeof(url), "%s%s/oauth/authorize?response_type=code&client_id=%s&redirect_uri=%s"
			"&service_entity=urn:service-entity:psn&prompt=none&duid=%s&smcid=pc:psnow&applicationId=psnow&mid=PSNOW"
			"&scope=kamaji:commerce_native%%20versa:user_update_entitlements_first_play%%20kamaji:lists"
			"&renderMode=mobilePortrait&hidePageElements=forgotPasswordLink&displayFooter=none&disableLinks=qriocityLink"
			"&layout_type=popup&service_logo=ps&tp_psn=true&noEVBlock=true",
			ACCOUNT_BASE, c->oauth_api_path, c->gk_client_id, GK_REDIR_PSNOW, c->duid);
	ChiakiErrorCode e = gk_oauth_code(c, url, &c->gk_cloud_auth_code);
	if(e == CHIAKI_ERR_SUCCESS) CHIAKI_LOGI(c->log, "[GAIKAI] step8a got gkCloudAuthCode");
	return e;
}

static ChiakiErrorCode gk_step8b_server_authcode(GaikaiCtx *c)
{
	gk_progress(c, "Getting Server Tokens - Step 5 of 10");
	char url[2048];
	if(c->pscloud)
		snprintf(url, sizeof(url), "%s%s/oauth/authorize?response_type=code&redirect_uri=%s"
			"&service_entity=urn:service-entity:psn&prompt=none&client_id=%s&smcid=qlite&applicationId=qlite&mid=qlite"
			"&scope=id_token:duid%%20id_token:online_id%%20openid%%20oauth:create_authn_ticket_for_cloud_console_signin&duid=%s",
			ACCOUNT_BASE, c->oauth_api_path, GK_REDIR_PSCLOUD, c->stream_server_client_id, c->duid);
	else
	{
		bool ps3 = strcmp(c->platform, "ps3") == 0;
		char duid_param[128];
		if(ps3) duid_param[0] = '\0';                              // PS3 omits duid
		else snprintf(duid_param, sizeof(duid_param), "&duid=%s", c->duid); // PS4 includes it
		snprintf(url, sizeof(url), "%s%s/oauth/authorize?response_type=code&redirect_uri=%s"
			"&service_entity=urn:service-entity:psn&prompt=none&client_id=%s&smcid=pc:psnow&applicationId=psnow&mid=PSNOW"
			"&scope=%s%s&renderMode=mobilePortrait&hidePageElements=forgotPasswordLink&displayFooter=none"
			"&disableLinks=qriocityLink&layout_type=popup&service_logo=ps&tp_psn=true&noEVBlock=true",
			ACCOUNT_BASE, c->oauth_api_path, GK_REDIR_PSNOW, c->ps3_gk_client_id,
			ps3 ? "kamaji:commerce_native" : "sso:none", duid_param);
	}
	char *code = NULL;
	ChiakiErrorCode e = gk_oauth_code(c, url, &code);
	if(e != CHIAKI_ERR_SUCCESS) return e;
	if(c->pscloud) { c->stream_server_auth_code = code; c->ps3_auth_code = strdup(""); }
	else { c->ps3_auth_code = code; c->stream_server_auth_code = strdup(code); }
	gk_patch_auth_codes(c);
	CHIAKI_LOGI(c->log, "[GAIKAI] step8b got server auth code");
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode gk_step9_authorize(GaikaiCtx *c, ChiakiCloudProvisionResult *out, bool *out_psplus_err)
{
	gk_progress(c, "Authorizing Session - Step 6 of 10");
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = gk_post_session(c, "/authorize", NULL, &resp);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	if(resp.status_code != 200)
	{
		char *ev = gk_header_value(resp.headers, "x-gaikai-event");
		bool psplus = (ev && strstr(ev, "002.2001")) || (resp.data && strstr(resp.data, "002.2001"));
		if(psplus)
			*out_psplus_err = true;
		// Otherwise forward the reject body so the orchestrator's one-shot
		// noGameForEntitlementId fallback fires when Gaikai rejects an owned entitlement
		// at authorize (step9), not just at start (step8) -- matches both originals.
		else if(resp.data) { free(out->error_message); out->error_message = strdup(resp.data); }
		CHIAKI_LOGE(c->log, "[GAIKAI] step9 authorize http %ld: %s", resp.status_code, resp.data ? resp.data : "");
		free(ev); cc_http_response_fini(&resp);
		return CHIAKI_ERR_UNKNOWN;
	}
	gk_update_session_key(c, &resp);
	cc_http_response_fini(&resp);
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode gk_step10_lock(GaikaiCtx *c)
{
	gk_progress(c, "Locking Session - Step 7 of 10");
	for(int attempt = 0; attempt <= MAX_LOCK_RETRIES; attempt++)
	{
		if(gk_cancelled(c)) return CHIAKI_ERR_CANCELED;
		CCHttpResponse resp = { 0 };
		ChiakiErrorCode e = gk_post_session(c, "/lock?forceLogout=true", NULL, &resp);
		if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
		if(resp.status_code != 200) { CHIAKI_LOGE(c->log, "[GAIKAI] step10 lock http %ld", resp.status_code); cc_http_response_fini(&resp); return CHIAKI_ERR_UNKNOWN; }
		gk_update_session_key(c, &resp);
		struct json_object *j = resp.data ? json_tokener_parse(resp.data) : NULL;
		bool acquired = j && cc_json_bool(j, "lockAcquired");
		int poll = j ? cc_json_int(j, "pollFrequency") : 10;
		if(poll <= 0) poll = 10;
		if(j) json_object_put(j);
		// Event name from the x-gaikai-event header (a JSON object) -- shown in the
		// "Closing old session (<name>) - Attempt N" loading text, like the original.
		char event_name[64] = "";
		char *evhdr = gk_header_value(resp.headers, "x-gaikai-event");
		if(evhdr)
		{
			struct json_object *ev = json_tokener_parse(evhdr);
			if(ev) { snprintf(event_name, sizeof(event_name), "%s", cc_json_str(ev, "name")); json_object_put(ev); }
			free(evhdr);
		}
		cc_http_response_fini(&resp);
		if(acquired)
		{
			free(c->lock_session_key);
			c->lock_session_key = c->config_key ? strdup(c->config_key) : NULL;
			CHIAKI_LOGI(c->log, "[GAIKAI] step10 lock acquired");
			return CHIAKI_ERR_SUCCESS;
		}
		if(attempt == MAX_LOCK_RETRIES) break;
		char prog[160];
		if(event_name[0])
			snprintf(prog, sizeof(prog), "Closing old session (%s) - Attempt %d", event_name, attempt + 1);
		else
			snprintf(prog, sizeof(prog), "Closing old session - Attempt %d", attempt + 1);
		CHIAKI_LOGI(c->log, "[GAIKAI] lock not acquired (%s); retry in %ds (attempt %d/%d)",
			event_name[0] ? event_name : "-", poll, attempt + 1, MAX_LOCK_RETRIES);
		gk_progress(c, prog);
		if(!gk_sleep_cancellable(c, poll)) return CHIAKI_ERR_CANCELED;
	}
	return CHIAKI_ERR_UNKNOWN;
}

// Build one ping-result json object {dataCenter,rtt,rtts,mtu_in,mtu_out,port,publicIp,maxBandwidth,measured}.
static struct json_object *gk_ping_obj(const char *dc, int rtt_ms, uint32_t mtu_in, uint32_t mtu_out,
	int port, const char *ip, int max_bw, bool measured)
{
	struct json_object *o = json_object_new_object();
	json_object_object_add(o, "dataCenter", json_object_new_string(dc));
	json_object_object_add(o, "rtt", json_object_new_int(rtt_ms));
	struct json_object *rtts = json_object_new_array();
	json_object_array_add(rtts, json_object_new_int(rtt_ms));
	json_object_object_add(o, "rtts", rtts);
	json_object_object_add(o, "mtu_in", json_object_new_int((int)mtu_in));
	json_object_object_add(o, "mtu_out", json_object_new_int((int)mtu_out));
	json_object_object_add(o, "port", json_object_new_int(port));
	json_object_object_add(o, "publicIp", json_object_new_string(ip ? ip : ""));
	json_object_object_add(o, "maxBandwidth", json_object_new_int(max_bw));
	json_object_object_add(o, "measured", json_object_new_boolean(measured));
	return o;
}

static int gk_cmp_rtt(const void *a, const void *b)
{
	struct json_object *oa = *(struct json_object * const *)a;
	struct json_object *ob = *(struct json_object * const *)b;
	return cc_json_int(oa, "rtt") - cc_json_int(ob, "rtt");
}

// One datacenter's ping, run on its own thread (each cc_ping_datacenter owns its
// session/socket, so they are independent). Mirrors the Qt parallel ping --
// sequential pinging made "Pinging Datacenters" take far too long.
typedef struct
{
	ChiakiLog *log;
	const char *name, *ip;       // borrowed from the datacenters json (outlives the join)
	int port, bw;
	const char *session_key, *service_type;
	int64_t rtt_us; uint32_t mtu_in, mtu_out; bool ok;
} GkPingJob;

static void *gk_ping_thread(void *arg)
{
	GkPingJob *j = (GkPingJob *)arg;
	j->rtt_us = -1; j->mtu_in = 0; j->mtu_out = 0;
	cc_ping_datacenter(j->log, j->ip, j->port, j->session_key, j->service_type,
		&j->rtt_us, &j->mtu_in, &j->mtu_out);
	j->ok = (j->rtt_us > 0);
	return NULL;
}

// Find a row by dataCenter name in a json array (borrowed ref), or NULL.
static struct json_object *gk_find_dc(struct json_object *arr, const char *name)
{
	if(!arr || json_object_get_type(arr) != json_type_array) return NULL;
	size_t n = json_object_array_length(arr);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *row = json_object_array_get_idx(arr, i);
		if(strcmp(cc_json_str(row, "dataCenter"), name) == 0) return row;
	}
	return NULL;
}

// Build the full datacenter list for the Settings picker. Three-way merge over the
// API list (@p dcs_api): this run's measurement wins, else the platform's prior
// stored RTT (cfg->prior_datacenters_json), else a 0 placeholder. Mirrors the old
// per-platform merge (keeps previously-measured RTTs for datacenters not pinged
// this run, e.g. the non-selected ones in forced-datacenter mode).
static struct json_object *gk_build_picker(GaikaiCtx *c, struct json_object *dcs_api)
{
	struct json_object *prior = (c->cfg->prior_datacenters_json && *c->cfg->prior_datacenters_json)
		? json_tokener_parse(c->cfg->prior_datacenters_json) : NULL;
	struct json_object *out = json_object_new_array();
	const char *forced = c->cfg->forced_datacenter;
	bool use_forced = forced && *forced && strcmp(forced, "Auto") != 0;
	size_t n = json_object_array_length(dcs_api);
	for(size_t i = 0; i < n; i++)
	{
		struct json_object *dc = json_object_array_get_idx(dcs_api, i);
		const char *name = cc_json_str(dc, "dataCenter");
		// In forced-DC mode the only this-run "ping" is a dummy (RTT 20) for the forced
		// datacenter; don't let it clobber a previously-measured RTT in the persisted
		// picker. Prefer prior measured data, and seed the dummy only when there's no
		// prior (mirrors the old per-platform seed-only-when-empty behavior).
		bool is_forced_dummy = use_forced && name && strcmp(name, forced) == 0;
		struct json_object *row = is_forced_dummy ? NULL : gk_find_dc(c->ping_results, name); // this run wins
		if(!row) row = gk_find_dc(prior, name);                        // else prior measured
		if(!row && is_forced_dummy) row = gk_find_dc(c->ping_results, name); // else the forced dummy
		if(row)
			json_object_array_add(out, cc_json_clone(row));
		else                                                            // else 0 placeholder
			json_object_array_add(out, gk_ping_obj(name, 0, 0, 0,
				cc_json_int(dc, "port"), cc_json_str(dc, "publicIp"), cc_json_int(dc, "maxBandwidth"), false));
	}
	if(prior) json_object_put(prior);
	return out;
}

// step11 datacenters + ping/select. Fills c->ping_results (sorted) + c->selected_*.
static ChiakiErrorCode gk_step11_datacenters(GaikaiCtx *c)
{
	gk_progress(c, "Getting Datacenters - Step 8 of 10");
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = gk_post_session(c, "/datacenters", NULL, &resp);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	if(resp.status_code != 200 || !resp.data) { CHIAKI_LOGE(c->log, "[GAIKAI] step11 http %ld", resp.status_code); cc_http_response_fini(&resp); return CHIAKI_ERR_UNKNOWN; }
	gk_update_session_key(c, &resp);
	struct json_object *dcs = json_tokener_parse(resp.data);
	cc_http_response_fini(&resp);
	if(!dcs || json_object_get_type(dcs) != json_type_array || json_object_array_length(dcs) == 0)
	{
		if(dcs) json_object_put(dcs);
		CHIAKI_LOGE(c->log, "[GAIKAI] step11 no datacenters");
		return CHIAKI_ERR_UNKNOWN;
	}
	size_t n = json_object_array_length(dcs);
	const char *forced = c->cfg->forced_datacenter;
	bool use_forced = forced && *forced && strcmp(forced, "Auto") != 0;

	c->ping_results = json_object_new_array();
	if(use_forced)
	{
		struct json_object *match = NULL;
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *dc = json_object_array_get_idx(dcs, i);
			if(strcmp(cc_json_str(dc, "dataCenter"), forced) == 0) { match = dc; break; }
		}
		if(!match) { c->forced_dc_unavailable = true; json_object_put(dcs); CHIAKI_LOGE(c->log, "[GAIKAI] forced datacenter '%s' not available", forced); return CHIAKI_ERR_UNKNOWN; }
		// dummy ping (RTT 20, MTU 1454/1254); bypass pinging entirely.
		json_object_array_add(c->ping_results, gk_ping_obj(forced, 20, 1454, 1254,
			cc_json_int(match, "port"), cc_json_str(match, "publicIp"), cc_json_int(match, "maxBandwidth"), true));
		CHIAKI_LOGI(c->log, "[GAIKAI] forced datacenter %s (ping bypassed)", forced);
	}
	else
	{
		gk_progress(c, "Pinging Datacenters - Step 8 of 10");
		if(gk_cancelled(c)) { json_object_put(dcs); return CHIAKI_ERR_CANCELED; }

		// Ping every datacenter in parallel (one thread each), then collect.
		GkPingJob *jobs = (GkPingJob *)calloc(n, sizeof(GkPingJob));
		ChiakiThread *threads = (ChiakiThread *)calloc(n, sizeof(ChiakiThread));
		bool *threaded = (bool *)calloc(n, sizeof(bool)); // which slots actually started a thread
		if(!jobs || !threads || !threaded)
		{
			free(jobs); free(threads); free(threaded);
			json_object_put(dcs);
			return CHIAKI_ERR_MEMORY;
		}
		for(size_t i = 0; i < n; i++)
		{
			struct json_object *dc = json_object_array_get_idx(dcs, i);
			jobs[i].log = c->log;
			jobs[i].name = cc_json_str(dc, "dataCenter");
			jobs[i].ip = cc_json_str(dc, "publicIp");
			jobs[i].port = cc_json_int(dc, "port");
			jobs[i].bw = cc_json_int(dc, "maxBandwidth");
			jobs[i].session_key = c->lock_session_key;
			jobs[i].service_type = c->cfg->service_type;
			if(chiaki_thread_create(&threads[i], gk_ping_thread, &jobs[i]) == CHIAKI_ERR_SUCCESS)
				threaded[i] = true;
			else
				gk_ping_thread(&jobs[i]); // fall back to inline if a thread won't start
		}
		for(size_t i = 0; i < n; i++)
		{
			if(threaded[i]) // only join slots whose thread started; a zeroed pthread_t join is UB
				chiaki_thread_join(&threads[i], NULL);
			if(jobs[i].ok)
				json_object_array_add(c->ping_results, gk_ping_obj(jobs[i].name, (int)(jobs[i].rtt_us / 1000),
					jobs[i].mtu_in, jobs[i].mtu_out, jobs[i].port, jobs[i].ip, jobs[i].bw, true));
			else
				json_object_array_add(c->ping_results, gk_ping_obj(jobs[i].name, 999, 0, 0, jobs[i].port, jobs[i].ip, jobs[i].bw, false));
			if(jobs[i].ok)
				CHIAKI_LOGI(c->log, "[GAIKAI] ping %s = %dms", jobs[i].name, (int)(jobs[i].rtt_us / 1000));
			else
				CHIAKI_LOGI(c->log, "[GAIKAI] ping %s = unreachable", jobs[i].name);
		}
		free(jobs); free(threads); free(threaded);
		// sort by RTT (skip the sort on OOM rather than crash -- leaves API order)
		size_t rn = json_object_array_length(c->ping_results);
		struct json_object **arr = (struct json_object **)malloc(rn * sizeof(*arr));
		if(arr)
		{
			for(size_t i = 0; i < rn; i++) arr[i] = json_object_get(json_object_array_get_idx(c->ping_results, i));
			qsort(arr, rn, sizeof(*arr), gk_cmp_rtt);
			struct json_object *sorted = json_object_new_array();
			for(size_t i = 0; i < rn; i++) json_object_array_add(sorted, arr[i]);
			free(arr);
			json_object_put(c->ping_results);
			c->ping_results = sorted;
		}
	}
	// Full datacenter list for the Settings picker (merged with prior stored RTTs).
	c->dc_picker = gk_build_picker(c, dcs);
	json_object_put(dcs);
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode gk_step12_select(GaikaiCtx *c)
{
	const char *forced = c->cfg->forced_datacenter;
	bool use_forced = forced && *forced && strcmp(forced, "Auto") != 0;
	size_t rn = json_object_array_length(c->ping_results);
	if(rn == 0) return CHIAKI_ERR_UNKNOWN;

	if(use_forced)
	{
		for(size_t i = 0; i < rn; i++)
		{
			struct json_object *r = json_object_array_get_idx(c->ping_results, i);
			if(strcmp(cc_json_str(r, "dataCenter"), forced) == 0) { c->selected_ping = r; break; }
		}
		if(!c->selected_ping) c->selected_ping = json_object_array_get_idx(c->ping_results, 0);
	}
	else
	{
		c->selected_ping = json_object_array_get_idx(c->ping_results, 0); // lowest RTT
		bool measured = cc_json_bool(c->selected_ping, "measured");
		int rtt_ms = cc_json_int(c->selected_ping, "rtt");
		if(measured && rtt_ms > 80)
		{
			CHIAKI_LOGE(c->log, "[GAIKAI] best datacenter RTT %dms > 80ms", rtt_ms);
			c->ping_timeout = true;
			return CHIAKI_ERR_UNKNOWN; // ping-too-high
		}
	}
	snprintf(c->selected_datacenter, sizeof(c->selected_datacenter), "%s", cc_json_str(c->selected_ping, "dataCenter"));
	int port = cc_json_int(c->selected_ping, "port");
	c->selected_dc_port = port > 0 ? port : 2053;

	char sel_prog[96];
	snprintf(sel_prog, sizeof(sel_prog), "Selecting Datacenter (%s) - Step 9 of 10", c->selected_datacenter);
	gk_progress(c, sel_prog);
	struct json_object *extra = json_object_new_object();
	json_object_object_add(extra, "pingResults", json_object_get(c->ping_results));
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = gk_post_session(c, "/datacenters/select", extra, &resp);
	if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
	if(resp.status_code != 200) { CHIAKI_LOGE(c->log, "[GAIKAI] step12 select http %ld", resp.status_code); cc_http_response_fini(&resp); return CHIAKI_ERR_UNKNOWN; }
	gk_update_session_key(c, &resp);
	struct json_object *j = resp.data ? json_tokener_parse(resp.data) : NULL;
	if(j)
	{
		int p = cc_json_int(j, "port");
		if(p <= 0) { struct json_object *net = cc_json_obj(j, "network"); if(net) p = cc_json_int(net, "port"); }
		if(p > 0) c->selected_dc_port = p;
		json_object_put(j);
	}
	cc_http_response_fini(&resp);
	CHIAKI_LOGI(c->log, "[GAIKAI] step12 selected %s:%d", c->selected_datacenter, c->selected_dc_port);
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode gk_step13_allocate(GaikaiCtx *c, ChiakiCloudProvisionResult *out)
{
	gk_progress(c, "Allocating Streaming Slot - Step 10 of 10");
	int max_wait = DEFAULT_ALLOC_WAIT_S, elapsed = 0, attempt = 0;
	bool wait_started = false;
	for(;;)
	{
		if(gk_cancelled(c)) return CHIAKI_ERR_CANCELED;
		int mtu_in = cc_json_int(c->selected_ping, "mtu_in"); if(mtu_in <= 0) mtu_in = 1454;
		int mtu_out = cc_json_int(c->selected_ping, "mtu_out"); if(mtu_out <= 0) mtu_out = 1254;
		int rtt = cc_json_int(c->selected_ping, "rtt"); if(rtt <= 0) rtt = 25;

		struct json_object *extra = json_object_new_object();
		json_object_object_add(extra, "dataCenter", json_object_new_string(c->selected_datacenter));
		struct json_object *net = json_object_new_object();
		json_object_object_add(net, "bwKbpsSent", json_object_new_int(c->cfg->bitrate_kbps));
		json_object_object_add(net, "bwLoss", json_object_new_double(0.001));
		json_object_object_add(net, "mtu", json_object_new_int(mtu_in));
		json_object_object_add(net, "rtt", json_object_new_int(rtt));
		json_object_object_add(net, "port", json_object_new_int(c->selected_dc_port));
		json_object_object_add(net, "bwKbpsReceived", json_object_new_int(c->cfg->bitrate_kbps));
		json_object_object_add(net, "bwLossUpstream", json_object_new_int(0));
		json_object_object_add(net, "mtuUpstream", json_object_new_int(mtu_out));
		json_object_object_add(extra, "network", net);
		// Fixed client-telemetry timings the allocate body schema expects (sampled from the
		// PS Portal client); the server records but doesn't act on them, so they're constant.
		json_object_object_add(extra, "stateExecutionTime", json_object_new_double(5974.7632));
		json_object_object_add(extra, "streamTestTime", json_object_new_double(11262.8423));

		CCHttpResponse resp = { 0 };
		ChiakiErrorCode e = gk_post_session(c, "/allocate", extra, &resp);
		if(e != CHIAKI_ERR_SUCCESS) { cc_http_response_fini(&resp); return e; }
		if(resp.status_code != 200) { CHIAKI_LOGE(c->log, "[GAIKAI] step13 allocate http %ld: %s", resp.status_code, resp.data ? resp.data : ""); cc_http_response_fini(&resp); return CHIAKI_ERR_UNKNOWN; }
		gk_update_session_key(c, &resp);
		struct json_object *a = resp.data ? json_tokener_parse(resp.data) : NULL;
		cc_http_response_fini(&resp);
		if(!a) return CHIAKI_ERR_UNKNOWN;

		bool queued = cc_json_bool(a, "queued");
		bool migrating = cc_json_bool(a, "dataMigration");
		if(queued || migrating)
		{
			attempt++;
			if(!wait_started)
			{
				wait_started = true;
				int est = cc_json_int(a, "waitTimeEstimate");
				max_wait = est > 0 ? (est * 2 > MAX_ALLOC_WAIT_S ? MAX_ALLOC_WAIT_S : est * 2) : DEFAULT_ALLOC_WAIT_S;
			}
			int poll = cc_json_int(a, "pollFrequency"); if(poll <= 0) poll = 15;
			// Rich progress so the user can see it is making progress (% / queue / attempt),
			// matching the old Qt loading text instead of a bare "Migrating...".
			char prog[160];
			if(migrating)
			{
				int pct = cc_json_int(a, "dataMigrationPercentageComplete");
				snprintf(prog, sizeof(prog), "Migrating data (%d%%) - Attempt %d", pct, attempt);
				CHIAKI_LOGI(c->log, "[GAIKAI] allocate attempt %d: data migration %d%% (elapsed %ds/%ds, poll %ds)",
					attempt, pct, elapsed, max_wait, poll);
			}
			else
			{
				int qpos = cc_json_has(a, "displayQueuePosition") ? cc_json_int(a, "displayQueuePosition")
					: (cc_json_has(a, "queuePosition") ? cc_json_int(a, "queuePosition") : -1);
				if(qpos >= 0)
					snprintf(prog, sizeof(prog), "Allocating streaming slot - Queue position: %d - Attempt %d", qpos, attempt);
				else
					snprintf(prog, sizeof(prog), "Allocating streaming slot - Attempt %d", attempt);
				CHIAKI_LOGI(c->log, "[GAIKAI] allocate attempt %d: queued (pos %d, elapsed %ds/%ds, poll %ds)",
					attempt, qpos, elapsed, max_wait, poll);
			}
			json_object_put(a);
			if(elapsed >= max_wait) { CHIAKI_LOGE(c->log, "[GAIKAI] allocation wait timeout (%ds)", max_wait); return CHIAKI_ERR_TIMEOUT; }
			if(poll > max_wait - elapsed) poll = max_wait - elapsed;
			gk_progress(c, prog);
			if(!gk_sleep_cancellable(c, poll)) return CHIAKI_ERR_CANCELED;
			elapsed += poll;
			continue;
		}

		// success
		struct json_object *slot = cc_json_obj(a, "launchSlot");
		if(!slot) { json_object_put(a); CHIAKI_LOGE(c->log, "[GAIKAI] allocate: no launchSlot"); return CHIAKI_ERR_UNKNOWN; }
		snprintf(out->server_ip, sizeof(out->server_ip), "%s", cc_json_str(slot, "publicIp"));
		out->server_port = cc_json_int(slot, "port");
		const char *priv = cc_json_str(slot, "privateIp");
		out->handshake_key = strdup(cc_json_str(a, "handshakeKey"));
		out->launch_spec = strdup(cc_json_str(a, "launchSpecification"));
		out->session_id = strdup(cc_json_str(a, "sessionId"));
		out->mtu_in = (uint32_t)mtu_in; out->mtu_out = (uint32_t)mtu_out;
		out->rtt_us = (uint64_t)rtt * 1000;
		out->psn_wrapper_type = 0x01;
		const char *dot = priv ? strrchr(priv, '.') : NULL;
		if(dot) { int oct = atoi(dot + 1); if(oct >= 0 && oct <= 255) out->psn_wrapper_type = (uint8_t)oct; }
		json_object_put(a);
		CHIAKI_LOGI(c->log, "[GAIKAI] ALLOCATION OK %s:%d", out->server_ip, out->server_port);
		return CHIAKI_ERR_SUCCESS;
	}
}

ChiakiErrorCode cc_gaikai_allocate(ChiakiLog *log,
	const ChiakiCloudProvisionConfig *cfg, const char *duid,
	const char *platform, const char *entitlement_id,
	ChiakiCloudProvisionResult *out)
{
	GaikaiCtx c;
	memset(&c, 0, sizeof(c));
	c.log = log;
	c.cfg = cfg;
	c.platform = (platform && *platform) ? platform : "ps4";
	c.pscloud = cfg->service_type && strcmp(cfg->service_type, "pscloud") == 0;
	c.user_agent = c.pscloud ? GK_UA_PSCLOUD : GK_UA_PSNOW;
	c.oauth_api_path = c.pscloud ? "/api/authz/v3" : "/api/v1";
	c.redirect_uri = c.pscloud ? GK_REDIR_PSCLOUD : GK_REDIR_PSNOW;
	if(strcmp(c.platform, "ps3") == 0) c.virt_type = "konan";
	else if(strcmp(c.platform, "ps5") == 0) c.virt_type = "cronos";
	else c.virt_type = "kratos";

	// Shared client device uid (same one Kamaji used), threaded into the OAuth URLs.
	snprintf(c.duid, sizeof(c.duid), "%s", duid ? duid : "");
	snprintf(out->platform, sizeof(out->platform), "%s", c.platform);
	snprintf(out->entitlement_id, sizeof(out->entitlement_id), "%s", entitlement_id ? entitlement_id : "");

	c.spec = gk_build_spec(&c, entitlement_id ? entitlement_id : "");

	bool psplus_err = false;
	ChiakiErrorCode e = gk_step0_client_ids(&c);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step7_config(&c);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step8_start(&c, out);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step8a_gk_authcode(&c);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step8b_server_authcode(&c);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step9_authorize(&c, out, &psplus_err);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step10_lock(&c);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step11_datacenters(&c);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step12_select(&c);
	if(e == CHIAKI_ERR_SUCCESS) e = gk_step13_allocate(&c, out);

	// Return the full datacenter list (merged with prior stored RTTs) for the
	// Settings picker -- the platform persists this verbatim, like the old code.
	if(c.dc_picker)
	{
		const char *s = json_object_to_json_string(c.dc_picker);
		if(s) { free(out->datacenter_pings); out->datacenter_pings = strdup(s); }
	}
	if(psplus_err && !out->error_message)
		out->error_message = strdup("PS_PLUS_SUBSCRIPTION_REQUIRED");
	if(c.ping_timeout && !out->error_message)
		out->error_message = strdup("PING_TIMEOUT");
	if(c.forced_dc_unavailable && !out->error_message)
	{
		char m[128];
		snprintf(m, sizeof(m), "Selected datacenter '%s' not available",
			cfg->forced_datacenter ? cfg->forced_datacenter : "");
		out->error_message = strdup(m);
	}

	free(c.config_key); free(c.lock_session_key); free(c.gaikai_session_id);
	free(c.gk_cloud_auth_code); free(c.ps3_auth_code); free(c.stream_server_auth_code);
	if(c.spec) json_object_put(c.spec);
	if(c.ping_results) json_object_put(c.ping_results);
	if(c.dc_picker) json_object_put(c.dc_picker);
	return e;
}
