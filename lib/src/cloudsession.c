// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Cloud session provisioning -- orchestrator + public entry points.
// Mirrors cloudcatalog.c. Routes PSNOW (Kamaji resolve -> Gaikai allocate) vs
// PSCLOUD (Gaikai allocate directly on the entitlementId), threads one shared
// DUID through both, and performs the one-shot noGameForEntitlementId fallback
// (re-run the full Kamaji resolve when an owned fast-path entitlement is
// rejected by Gaikai).

#include "cloudsession_internal.h"
#include "curl_http.h"

#include <chiaki/cloudsession.h>

#ifdef _WIN32
#include <winsock2.h>
#include <ws2tcpip.h>
#else
#include <netinet/in.h>             // INET6_ADDRSTRLEN (needed by holepunch.h)
#endif
#include <chiaki/remote/holepunch.h> // chiaki_holepunch_generate_client_device_uid

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static void result_init(ChiakiCloudProvisionResult *out)
{
	memset(out, 0, sizeof(*out));
	out->err = CHIAKI_ERR_UNKNOWN;
	out->server_port = 0;
}

CHIAKI_EXPORT void chiaki_cloud_provision_result_fini(ChiakiCloudProvisionResult *out)
{
	if(!out)
		return;
	free(out->handshake_key);
	free(out->launch_spec);
	free(out->session_id);
	free(out->datacenter_pings);
	free(out->error_message);
	out->handshake_key = NULL;
	out->launch_spec = NULL;
	out->session_id = NULL;
	out->datacenter_pings = NULL;
	out->error_message = NULL;
}

// --- Pre-flight authorization check (was each platform's checkAuthorization) ---
// POST the service's authorize parameters to authorizeCheck with the npsso cookie;
// HTTP 200/204 means the NPSSO is still valid. Scopes are SPACE-separated here (they
// go in a JSON body), unlike the %20-encoded OAuth-query scopes in
// cloudsession_kamaji.c. The pscloud client id is the fixed pre-flight id the
// platforms used (distinct from the step0-fetched streaming client id).
#define CA_URL            "https://ca.account.sony.com/api/authz/v3/oauth/authorizeCheck"
#define CA_PSNOW_CLIENT   CS_PSNOW_CLIENT_ID  // shared (cloudsession_internal.h)
#define CA_PSNOW_SCOPE    "kamaji:commerce_native kamaji:commerce_container kamaji:lists kamaji:s2s.subscriptionsPremium.get"
#define CA_PSNOW_REDIR    CS_PSNOW_REDIRECT
#define CA_PSNOW_UA       CS_PSNOW_USER_AGENT
#define CA_PSCLOUD_CLIENT "19ae39c4-3f88-4d11-a792-94e4f52c996d"
#define CA_PSCLOUD_SCOPE  "id_token:psn.basic_claims kamaji:s2s.subscriptionsPremium.get id_token:duid id_token:online_id openid psn:s2s"
#define CA_PSCLOUD_REDIR  "gaikai://local"
#define CA_PSCLOUD_UA     "PlayStation Portal/6.0.0-rel.444+6a9cea6f5"

// Validate the NPSSO before any real work (silently, like the old platform pre-flight).
// Returns SUCCESS on HTTP 200/204; any other status / transport error -> failure.
static ChiakiErrorCode cc_authorize_check(ChiakiLog *log,
	const ChiakiCloudProvisionConfig *cfg, const char *duid)
{
	bool pscloud = cfg->service_type && strcmp(cfg->service_type, "pscloud") == 0;
	const char *client_id = pscloud ? CA_PSCLOUD_CLIENT : CA_PSNOW_CLIENT;
	const char *scope     = pscloud ? CA_PSCLOUD_SCOPE  : CA_PSNOW_SCOPE;
	const char *redirect  = pscloud ? CA_PSCLOUD_REDIR  : CA_PSNOW_REDIR;
	const char *ua        = pscloud ? CA_PSCLOUD_UA     : CA_PSNOW_UA;

	char body[768];
	snprintf(body, sizeof(body),
		"{\"client_id\":\"%s\",\"scope\":\"%s\",\"redirect_uri\":\"%s\","
		"\"response_type\":\"code\",\"service_entity\":\"urn:service-entity:psn\",\"duid\":\"%s\"}",
		client_id, scope, redirect, duid);

	char *h_cookie = NULL;
	if(cc_http_make_cookie_header(&h_cookie, "npsso", cfg->npsso) != CHIAKI_ERR_SUCCESS)
		return CHIAKI_ERR_UNKNOWN;
	char ua_hdr[512];
	snprintf(ua_hdr, sizeof(ua_hdr), "User-Agent: %s", ua);
	const char *hdrs[] = {
		"Content-Type: application/json; charset=UTF-8",
		ua_hdr,
		h_cookie
	};
	CCHttpRequest req = { 0 };
	req.method = "POST"; req.url = CA_URL;
	req.headers = hdrs; req.header_count = 3; req.body = body;
	CCHttpResponse resp = { 0 };
	ChiakiErrorCode e = cc_http_perform(log, &req, &resp);
	long status = resp.status_code;
	cc_http_response_fini(&resp);
	free(h_cookie);
	if(e != CHIAKI_ERR_SUCCESS)
		return e;
	if(status == 200 || status == 204)
		return CHIAKI_ERR_SUCCESS;
	CHIAKI_LOGE(log, "[CLOUDSESSION] authorizeCheck failed (HTTP %ld); NPSSO likely expired", status);
	return CHIAKI_ERR_UNKNOWN;
}

// One provisioning attempt: PSNOW resolves via Kamaji then allocates via Gaikai;
// PSCLOUD allocates directly (game_identifier is already the PS5 entitlementId).
static ChiakiErrorCode provision_once(ChiakiLog *log,
	const ChiakiCloudProvisionConfig *cfg, const char *duid,
	ChiakiCloudProvisionResult *out)
{
	bool pscloud = cfg->service_type && strcmp(cfg->service_type, "pscloud") == 0;
	char entitlement[128] = "";
	char platform[8] = "ps4";

	if(pscloud)
	{
		snprintf(entitlement, sizeof(entitlement), "%s", cfg->game_identifier ? cfg->game_identifier : "");
		snprintf(platform, sizeof(platform), "ps5");
	}
	else
	{
		char *kerr = NULL;
		ChiakiErrorCode e = cc_kamaji_resolve(log, cfg, duid, entitlement, platform, &kerr);
		if(e != CHIAKI_ERR_SUCCESS)
		{
			if(kerr) { free(out->error_message); out->error_message = kerr; }
			return e;
		}
		free(kerr);
	}

	return cc_gaikai_allocate(log, cfg, duid, platform, entitlement, out);
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_cloud_provision_session(
	const ChiakiCloudProvisionConfig *cfg,
	ChiakiCloudProvisionResult *out,
	ChiakiLog *log)
{
	if(!cfg || !out)
		return CHIAKI_ERR_INVALID_DATA;
	result_init(out);
	if(!cfg->npsso || !*cfg->npsso)
	{
		out->err = CHIAKI_ERR_INVALID_DATA;
		return out->err;
	}

	// One shared client device uid for the Kamaji + Gaikai OAuth exchanges.
	char duid[64];
	size_t duid_size = sizeof(duid);
	if(chiaki_holepunch_generate_client_device_uid(duid, &duid_size) != CHIAKI_ERR_SUCCESS)
	{
		out->err = CHIAKI_ERR_UNKNOWN;
		return out->err;
	}

	// Pre-flight: validate the NPSSO before any real work (silently, like the old
	// per-platform checkAuthorization) so an expired token fails fast with no progress
	// UI. Platforms map AUTHORIZATION_FAILED -> "token expired, please re-login".
	if(cc_authorize_check(log, cfg, duid) != CHIAKI_ERR_SUCCESS)
	{
		out->error_message = strdup("AUTHORIZATION_FAILED");
		out->err = CHIAKI_ERR_UNKNOWN;
		return out->err;
	}

	ChiakiErrorCode e = provision_once(log, cfg, duid, out);

	// One-shot fallback: an owned fast-path entitlement that Gaikai rejects
	// (noGameForEntitlementId) -> re-run the full Kamaji resolve/acquire once.
	bool used_fast_path = cfg->owned_entitlement_id && *cfg->owned_entitlement_id;
	if(e != CHIAKI_ERR_SUCCESS && used_fast_path && out->error_message &&
	   strstr(out->error_message, "noGameForEntitlement"))
	{
		CHIAKI_LOGW(log, "[CLOUDSESSION] owned entitlement rejected by Gaikai; retrying full resolve flow");
		chiaki_cloud_provision_result_fini(out);
		result_init(out);
		ChiakiCloudProvisionConfig cfg2 = *cfg;
		cfg2.owned_entitlement_id = "";
		cfg2.owned_platform = "";
		e = provision_once(log, &cfg2, duid, out);
	}

	out->err = e;
	return e;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_cloud_ping_datacenters(
	const ChiakiCloudProvisionConfig *cfg,
	char **out_pings_json,
	ChiakiLog *log)
{
	if(!cfg || !out_pings_json)
		return CHIAKI_ERR_INVALID_DATA;
	*out_pings_json = NULL;
	// The datacenter list is only available inside an authenticated Gaikai
	// session (step11), so per-region latency comes back as result.datacenter_pings
	// from chiaki_cloud_provision_session. A standalone ping-only path (auth ->
	// step11 -> ping -> stop) can be added when the Settings refresh button needs it.
	CHIAKI_LOGW(log, "[CLOUDSESSION] standalone datacenter ping not wired; use provision result.datacenter_pings");
	return CHIAKI_ERR_UNKNOWN;
}
