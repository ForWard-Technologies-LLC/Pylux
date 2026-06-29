// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Gaikai allocation flow -- C port of the Qt psgaikaistreaming.cpp async state
// machine, run as a sequential blocking flow. Phase 2 (incremental):
//   [done] step0 client_ids, step7 config, x-gaikai-session threading
//   [todo] step8 start session, 8a/8b OAuth, step9 authorize, step10 lock,
//          step11 datacenters, step12 ping/select, step13 allocate + wait.

#include "cloudsession_internal.h"
#include "cloudcatalog_internal.h"  // cc_json_* helpers
#include "curl_http.h"

#include <json-c/json.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <strings.h>

#define GK_BASE        "https://cc.prod.gaikai.com/v1"
#define GK_CONFIG_BASE "https://config.cc.prod.gaikai.com/v1"
#define GK_UA_PSCLOUD  "PlayStation Portal/6.0.0-rel.444+6a9cea6f5"
#define GK_UA_PSNOW    "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) playstation-now/0.0.0 Chrome/83.0.4103.104 Electron/9.0.4 Safari/537.36 gkApollo"

typedef struct
{
	ChiakiLog *log;
	const ChiakiCloudProvisionConfig *cfg;
	bool pscloud;
	const char *platform;       // "ps3"|"ps4"|"ps5"
	const char *virt_type;      // "konan"|"kratos"|"cronos"
	const char *user_agent;
	// state filled in by the steps
	char *config_key;           // x-gaikai-session (updates every response)
	char *lock_session_key;
	char *gaikai_session_id;
	char gk_client_id[128];
	char ps3_gk_client_id[128];
	char stream_server_client_id[128];
} GaikaiCtx;

static void gk_progress(GaikaiCtx *c, const char *stage)
{
	if(c->cfg->progress)
		c->cfg->progress(stage, c->cfg->user);
}

static bool gk_cancelled(GaikaiCtx *c)
{
	return c->cfg->is_cancelled && c->cfg->is_cancelled(c->cfg->user);
}

// Extract a header value (case-insensitive name) from the raw response header
// block. Returns a malloc'd, trimmed value or NULL.
static char *gk_header_value(const char *headers, const char *name)
{
	if(!headers || !name)
		return NULL;
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
			size_t vlen = (p + linelen) - v;
			while(vlen && (v[vlen-1] == ' ' || v[vlen-1] == '\t')) vlen--;
			char *out = (char *)malloc(vlen + 1);
			if(!out) return NULL;
			memcpy(out, v, vlen);
			out[vlen] = '\0';
			return out;
		}
		if(!eol) break;
		p = eol + ((eol[0] == '\r' && eol[1] == '\n') ? 2 : 1);
	}
	return NULL;
}

// Update config_key from a response's x-gaikai-session header (if present).
static void gk_update_session_key(GaikaiCtx *c, const CCHttpResponse *resp)
{
	char *k = gk_header_value(resp->headers, "x-gaikai-session");
	if(k && *k)
	{
		free(c->config_key);
		c->config_key = k;
		CHIAKI_LOGI(c->log, "[GAIKAI] updated session key (len %zu)", strlen(k));
	}
	else
	{
		free(k);
	}
}

// Step 0: GET /client_ids?virtType=... -> gkClientId / ps3GkClientId / streamServerClientId.
static ChiakiErrorCode gk_step0_client_ids(GaikaiCtx *c)
{
	gk_progress(c, "Getting Client IDs - Step 1 of 10");
	char url[256];
	snprintf(url, sizeof(url), "%s/client_ids?virtType=%s", GK_BASE, c->virt_type);
	const char *headers[] = { "Accept: */*", NULL };
	char ua[512];
	snprintf(ua, sizeof(ua), "User-Agent: %s", c->user_agent);
	const char *hdrs[] = { headers[0], ua };

	CCHttpRequest req = { 0 };
	req.url = url;
	req.headers = hdrs;
	req.header_count = 2;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	if(e != CHIAKI_ERR_SUCCESS || resp.status_code != 200 || !resp.data)
	{
		CHIAKI_LOGE(c->log, "[GAIKAI] step0 client_ids failed (http %ld)", resp.status_code);
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
	if(!c->gk_client_id[0])
		return CHIAKI_ERR_UNKNOWN;
	CHIAKI_LOGI(c->log, "[GAIKAI] step0: gkClientId=%s", c->gk_client_id);
	return CHIAKI_ERR_SUCCESS;
}

// Step 7: POST /config -> configKey (first x-gaikai-session).
static ChiakiErrorCode gk_step7_config(GaikaiCtx *c)
{
	gk_progress(c, "Getting Configuration - Step 2 of 10");
	char url[256];
	snprintf(url, sizeof(url), "%s/config", GK_CONFIG_BASE);
	char body[256];
	snprintf(body, sizeof(body), "{\"product\":\"%s\",\"platform\":\"%s\",\"sessionId\":\"\"}",
		c->pscloud ? "qlite" : "psnow", c->pscloud ? "qlite" : "PC");
	char ua[512];
	snprintf(ua, sizeof(ua), "User-Agent: %s", c->user_agent);
	const char *hdrs[] = { "Content-Type: application/json", "Accept: */*", ua };

	CCHttpRequest req = { 0 };
	req.method = "POST";
	req.url = url;
	req.headers = hdrs;
	req.header_count = 3;
	req.body = body;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(c->log, &req, &resp);
	if(e != CHIAKI_ERR_SUCCESS || resp.status_code != 200 || !resp.data)
	{
		CHIAKI_LOGE(c->log, "[GAIKAI] step7 config failed (http %ld)", resp.status_code);
		cc_http_response_fini(&resp);
		return CHIAKI_ERR_UNKNOWN;
	}
	struct json_object *j = json_tokener_parse(resp.data);
	if(j)
	{
		const char *ck = cc_json_str(j, "configKey");
		if(*ck)
		{
			free(c->config_key);
			c->config_key = strdup(ck);
		}
		json_object_put(j);
	}
	cc_http_response_fini(&resp);
	if(!c->config_key || !*c->config_key)
		return CHIAKI_ERR_UNKNOWN;
	CHIAKI_LOGI(c->log, "[GAIKAI] step7: got configKey (len %zu)", strlen(c->config_key));
	return CHIAKI_ERR_SUCCESS;
}

ChiakiErrorCode cc_gaikai_allocate(ChiakiLog *log,
	const ChiakiCloudProvisionConfig *cfg,
	const char *platform, const char *entitlement_id,
	ChiakiCloudProvisionResult *out)
{
	(void)entitlement_id; (void)out;
	GaikaiCtx c;
	memset(&c, 0, sizeof(c));
	c.log = log;
	c.cfg = cfg;
	c.platform = platform ? platform : "";
	c.pscloud = cfg->service_type && strcmp(cfg->service_type, "pscloud") == 0;
	c.user_agent = c.pscloud ? GK_UA_PSCLOUD : GK_UA_PSNOW;
	if(strcmp(c.platform, "ps3") == 0) c.virt_type = "konan";
	else if(strcmp(c.platform, "ps5") == 0) c.virt_type = "cronos";
	else c.virt_type = "kratos"; // ps4 / default

	ChiakiErrorCode e = gk_step0_client_ids(&c);
	if(e == CHIAKI_ERR_SUCCESS && !gk_cancelled(&c))
		e = gk_step7_config(&c);

	// TODO(phase 2 cont.): step8 start session, OAuth 8a/8b, step9 authorize,
	// step10 lock, step11 datacenters, step12 ping/select, step13 allocate.
	if(e == CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGW(log, "[GAIKAI] steps 8-13 not implemented yet");
		e = CHIAKI_ERR_UNKNOWN;
	}

	free(c.config_key);
	free(c.lock_session_key);
	free(c.gaikai_session_id);
	return e;
}
