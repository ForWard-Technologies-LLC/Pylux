// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Dev harness for the unified cloud-provisioning flow (not built on device).
//   NPSSO=... cloudsession-probe <productId/entitlementId> [resolve|provision|ping]
// Env overrides (drive every path):
//   SERVICE=psnow|pscloud   STORE_CC=US   STORE_LANG=en
//   OWNED_ENT=<ent>  OWNED_PLAT=ps4    (owned fast-path / one-shot fallback)
//   FORCED_DC=sjca                     (bypass datacenter pinging)
//   FOREIGN=1                          (fallback region: skip $0 acquire on 404)
//   GAME_LANG=en-US   RES=1080   BITRATE=15000

#include <chiaki/cloudsession.h>
#include <chiaki/log.h>

#include "cloudsession_internal.h"  // cc_kamaji_resolve

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *env_or(const char *k, const char *def)
{
	const char *v = getenv(k);
	return (v && *v) ? v : def;
}

int main(int argc, char **argv)
{
	ChiakiLog log;
	chiaki_log_init(&log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, chiaki_log_cb_print, NULL);

	const char *npsso = getenv("NPSSO");
	if(!npsso || !*npsso) { fprintf(stderr, "set NPSSO env\n"); return 2; }
	const char *product = argc > 1 ? argv[1] : "UP0001-CUSA00339_00-CHILDOFLIGHT0001";
	const char *mode = argc > 2 ? argv[2] : "resolve";

	ChiakiCloudProvisionConfig cfg;
	memset(&cfg, 0, sizeof(cfg));
	cfg.service_type = env_or("SERVICE", "psnow");
	cfg.game_identifier = product;
	cfg.game_name = "probe";
	cfg.npsso = npsso;
	cfg.store_country = env_or("STORE_CC", "US");
	cfg.store_lang = env_or("STORE_LANG", "en");
	cfg.game_language = env_or("GAME_LANG", "en-US");
	cfg.owned_entitlement_id = env_or("OWNED_ENT", "");
	cfg.owned_platform = env_or("OWNED_PLAT", "ps4");
	cfg.forced_datacenter = env_or("FORCED_DC", "");
	cfg.catalog_is_foreign = getenv("FOREIGN") && *getenv("FOREIGN");
	cfg.resolution = atoi(env_or("RES", "1080"));
	cfg.bitrate_kbps = atoi(env_or("BITRATE", "15000"));

	printf("\n>>> mode=%s service=%s product=%s store=%s/%s ownedEnt=%s forcedDC=%s foreign=%d\n",
		mode, cfg.service_type, product, cfg.store_country, cfg.store_lang,
		cfg.owned_entitlement_id[0] ? cfg.owned_entitlement_id : "(none)",
		cfg.forced_datacenter[0] ? cfg.forced_datacenter : "(auto)", cfg.catalog_is_foreign);

	if(strcmp(mode, "ping") == 0)
	{
		char *pings = NULL;
		ChiakiErrorCode e = chiaki_cloud_ping_datacenters(&cfg, &pings, &log);
		printf("== PING err=%d pings=%s\n", e, pings ? pings : "(none)");
		free(pings);
		return e == CHIAKI_ERR_SUCCESS ? 0 : 1;
	}

	if(strcmp(mode, "provision") == 0)
	{
		ChiakiCloudProvisionResult out;
		ChiakiErrorCode e = chiaki_cloud_provision_session(&cfg, &out, &log);
		printf("\n== PROVISION err=%d ip=%s:%d ent=%s plat=%s wrap=%u hs=%s spec=%s rtt=%llu mtu=%u/%u\n",
			e, out.server_ip, out.server_port, out.entitlement_id, out.platform, out.psn_wrapper_type,
			out.handshake_key ? "yes" : "no", out.launch_spec ? "yes" : "no",
			(unsigned long long)out.rtt_us, out.mtu_in, out.mtu_out);
		printf("   msg=%s\n", out.error_message ? out.error_message : "(none)");
		chiaki_cloud_provision_result_fini(&out);
		return e == CHIAKI_ERR_SUCCESS ? 0 : 1;
	}

	char ent[128] = "", plat[8] = "";
	char *err = NULL;
	char duid[64] = "00000007004100800123456789abcdef0123456789abcdef";
	ChiakiErrorCode e = cc_kamaji_resolve(&log, &cfg, duid, ent, plat, &err);
	printf("\n== KAMAJI err=%d ent=%s plat=%s err=%s\n", e, ent, plat, err ? err : "(none)");
	free(err);
	return e == CHIAKI_ERR_SUCCESS ? 0 : 1;
}
