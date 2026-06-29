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
