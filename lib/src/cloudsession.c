// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Cloud session provisioning -- orchestrator + public entry points.
// Mirrors cloudcatalog.c. Phase 0: skeleton (entry points stubbed); the
// Kamaji / Gaikai / ping logic is filled in by cloudsession_{kamaji,gaikai,
// ping}.c across the following phases.

#include <chiaki/cloudsession.h>

#include <stdlib.h>
#include <string.h>

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
	// TODO(phase 4): authorization check -> Kamaji (psnow) / direct (pscloud)
	//                -> Gaikai allocation -> one-shot fallback.
	CHIAKI_LOGW(log, "[CLOUDSESSION] provision not implemented yet (skeleton)");
	out->err = CHIAKI_ERR_UNKNOWN;
	return out->err;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_cloud_ping_datacenters(
	const ChiakiCloudProvisionConfig *cfg,
	char **out_pings_json,
	ChiakiLog *log)
{
	if(!cfg || !out_pings_json)
		return CHIAKI_ERR_INVALID_DATA;
	*out_pings_json = NULL;
	// TODO(phase 1): senkusha ping of reachable datacenters.
	CHIAKI_LOGW(log, "[CLOUDSESSION] ping not implemented yet (skeleton)");
	return CHIAKI_ERR_UNKNOWN;
}
