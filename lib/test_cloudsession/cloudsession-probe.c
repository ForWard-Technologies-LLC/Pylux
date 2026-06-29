// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Dev harness for the unified cloud-provisioning flow (not built on device).
//   NPSSO=... cloudsession-probe <productId> [resolve|provision]
// "resolve"   -> cc_kamaji_resolve only (OAuth + 0.5b-0.5e + step5/6); read-only
//                for an owned title, no Gaikai allocation.
// "provision" -> the full public chiaki_cloud_provision_session (reserves a slot).

#include <chiaki/cloudsession.h>
#include <chiaki/log.h>

#include "cloudsession_internal.h"  // cc_kamaji_resolve

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
	cfg.service_type = "psnow";
	cfg.game_identifier = product;
	cfg.game_name = "probe";
	cfg.npsso = npsso;
	cfg.store_country = "US";
	cfg.store_lang = "en";
	cfg.forced_datacenter = "";
	cfg.resolution = 1080;
	cfg.bitrate_kbps = 15000;

	if(strcmp(mode, "provision") == 0)
	{
		ChiakiCloudProvisionResult out;
		ChiakiErrorCode e = chiaki_cloud_provision_session(&cfg, &out, &log);
		printf("\n== PROVISION err=%d ip=%s:%d ent=%s plat=%s wrap=%u hs=%s spec=%s rtt=%llu mtu=%u/%u\n",
			e, out.server_ip, out.server_port, out.entitlement_id, out.platform, out.psn_wrapper_type,
			out.handshake_key ? "yes" : "no", out.launch_spec ? "yes" : "no",
			(unsigned long long)out.rtt_us, out.mtu_in, out.mtu_out);
		printf("   pings=%s\n", out.datacenter_pings ? out.datacenter_pings : "(none)");
		printf("   msg=%s\n", out.error_message ? out.error_message : "(none)");
		chiaki_cloud_provision_result_fini(&out);
		return e == CHIAKI_ERR_SUCCESS ? 0 : 1;
	}

	char ent[128] = "", plat[8] = "";
	char *err = NULL;
	// duid format matching the live flow: "0000000700410080" + 32 hex chars.
	char duid[64] = "00000007004100800123456789abcdef0123456789abcdef";
	ChiakiErrorCode e = cc_kamaji_resolve(&log, &cfg, duid, ent, plat, &err);
	printf("\n== KAMAJI err=%d ent=%s plat=%s err=%s\n", e, ent, plat, err ? err : "(none)");
	free(err);
	return e == CHIAKI_ERR_SUCCESS ? 0 : 1;
}
