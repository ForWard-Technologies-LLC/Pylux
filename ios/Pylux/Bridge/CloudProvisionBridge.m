// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#import "CloudProvisionBridge.h"
#import "PyluxChiakiLog.h"
#include <chiaki/cloudsession.h>
#include <os/log.h>
#include <string.h>

static os_log_t s_cp_log;

static void cp_log_cb(ChiakiLogLevel level, const char *msg, void *user) {
    (void)user;
    os_log_type_t type = (level == CHIAKI_LOG_ERROR) ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT;
    os_log_with_type(s_cp_log, type, "[CloudProvision] %{public}s", msg ? msg : "");
}

// Callbacks reach the Obj-C blocks via cfg.user. The provision call is synchronous
// and only ever calls these from the calling thread, so unretained refs to blocks
// that outlive the call are safe.
typedef struct {
    __unsafe_unretained void (^onProgress)(NSString *);
    __unsafe_unretained BOOL (^isCancelled)(void);
} CPCallbacks;

static void cp_progress(const char *stage, void *user) {
    CPCallbacks *cb = (CPCallbacks *)user;
    if (cb && cb->onProgress && stage)
        cb->onProgress([NSString stringWithUTF8String:stage]);
}

static bool cp_is_cancelled(void *user) {
    CPCallbacks *cb = (CPCallbacks *)user;
    return (cb && cb->isCancelled) ? (cb->isCancelled() ? true : false) : false;
}

@implementation PyluxCloudProvisionResult
@end

@implementation PyluxCloudProvision

+ (void)initialize {
    if (self == [PyluxCloudProvision class]) {
        s_cp_log = os_log_create("com.pylux.stream", "CloudProvisionLib");
    }
}

+ (PyluxCloudProvisionResult *)provisionWithServiceType:(NSString *)serviceType
                                        gameIdentifier:(NSString *)gameIdentifier
                                              gameName:(NSString *)gameName
                                                 npsso:(NSString *)npsso
                                          storeCountry:(NSString *)storeCountry
                                             storeLang:(NSString *)storeLang
                                          gameLanguage:(NSString *)gameLanguage
                                    ownedEntitlementId:(NSString *)ownedEntitlementId
                                         ownedPlatform:(NSString *)ownedPlatform
                                      forcedDatacenter:(NSString *)forcedDatacenter
                                  priorDatacentersJson:(NSString *)priorDatacentersJson
                                      catalogIsForeign:(BOOL)catalogIsForeign
                                            resolution:(int)resolution
                                           bitrateKbps:(int)bitrateKbps
                                            onProgress:(void (^)(NSString *))onProgress
                                           isCancelled:(BOOL (^)(void))isCancelled {
    ChiakiLog log;
    pylux_chiaki_log_init(&log, cp_log_cb, NULL);

    CPCallbacks cb;
    cb.onProgress = onProgress;
    cb.isCancelled = isCancelled;

    ChiakiCloudProvisionConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.service_type = serviceType.UTF8String;
    cfg.game_identifier = gameIdentifier.UTF8String;
    cfg.game_name = gameName.UTF8String;
    cfg.npsso = npsso.UTF8String;
    cfg.store_country = storeCountry.UTF8String;
    cfg.store_lang = storeLang.UTF8String;
    cfg.game_language = gameLanguage.UTF8String;
    cfg.owned_entitlement_id = ownedEntitlementId.UTF8String;
    cfg.owned_platform = ownedPlatform.UTF8String;
    cfg.forced_datacenter = forcedDatacenter.UTF8String;
    cfg.prior_datacenters_json = priorDatacentersJson.UTF8String;
    cfg.cache_dir = "";
    cfg.catalog_is_foreign = catalogIsForeign ? true : false;
    cfg.skip_account_attr_check = false;  // iOS has no "ignore forever" flag
    cfg.resolution = resolution;
    cfg.bitrate_kbps = bitrateKbps;
    cfg.progress = cp_progress;
    cfg.is_cancelled = cp_is_cancelled;
    cfg.user = &cb;

    ChiakiCloudProvisionResult res;
    memset(&res, 0, sizeof(res));
    ChiakiErrorCode err = chiaki_cloud_provision_session(&cfg, &res, &log);

    PyluxCloudProvisionResult *out = [PyluxCloudProvisionResult new];
    out.err = (int)err;
    out.serverIp = res.server_ip[0] ? [NSString stringWithUTF8String:res.server_ip] : @"";
    out.serverPort = res.server_port;
    out.handshakeKey = res.handshake_key ? [NSString stringWithUTF8String:res.handshake_key] : @"";
    out.launchSpec = res.launch_spec ? [NSString stringWithUTF8String:res.launch_spec] : @"";
    out.sessionId = res.session_id ? [NSString stringWithUTF8String:res.session_id] : @"";
    out.entitlementId = res.entitlement_id[0] ? [NSString stringWithUTF8String:res.entitlement_id] : @"";
    out.platform = res.platform[0] ? [NSString stringWithUTF8String:res.platform] : @"";
    out.psnWrapperType = res.psn_wrapper_type;
    out.mtuIn = (int)res.mtu_in;
    out.mtuOut = (int)res.mtu_out;
    out.rttMs = (int)(res.rtt_us / 1000);
    out.datacenterPings = res.datacenter_pings ? [NSString stringWithUTF8String:res.datacenter_pings] : nil;
    out.errorMessage = res.error_message ? [NSString stringWithUTF8String:res.error_message] : nil;

    chiaki_cloud_provision_result_fini(&res);
    return out;
}

@end
