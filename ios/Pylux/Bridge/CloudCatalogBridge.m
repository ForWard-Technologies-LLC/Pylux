// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#import "CloudCatalogBridge.h"
#import "PyluxChiakiLog.h"
#include <chiaki/cloudcatalog.h>
#include <os/log.h>
#include <string.h>

static os_log_t s_cc_log;

static void cc_log_cb(ChiakiLogLevel level, const char *msg, void *user) {
    (void)user;
    os_log_type_t type = (level == CHIAKI_LOG_ERROR) ? OS_LOG_TYPE_ERROR : OS_LOG_TYPE_DEFAULT;
    os_log_with_type(s_cc_log, type, "[CloudCatalog] %{public}s", msg ? msg : "");
}

@implementation PyluxCloudCatalog

+ (void)initialize {
    if (self == [PyluxCloudCatalog class]) {
        s_cc_log = os_log_create("com.pylux.stream", "CloudCatalogLib");
    }
}

+ (NSString *)fetchUnifiedJSONWithNpsso:(NSString *)npsso
                                 locale:(NSString *)locale
                               cacheDir:(NSString *)cacheDir
                           forceRefresh:(BOOL)forceRefresh
                           errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    ChiakiLog log;
    pylux_chiaki_log_init(&log, cc_log_cb, NULL);

    ChiakiCloudCatalogConfig cfg;
    memset(&cfg, 0, sizeof(cfg));
    cfg.npsso = (npsso.length > 0) ? npsso.UTF8String : NULL;
    cfg.locale = (locale.length > 0) ? locale.UTF8String : NULL;
    cfg.cache_dir = cacheDir.UTF8String;
    cfg.force_refresh = forceRefresh ? true : false;

    ChiakiCloudCatalogResult res;
    memset(&res, 0, sizeof(res));
    ChiakiErrorCode err = chiaki_cloudcatalog_fetch_unified(&cfg, &res, &log);

    NSString *json = nil;
    if (res.json) {
        json = [NSString stringWithUTF8String:res.json];
    }
    if (!json && errorMessage) {
        *errorMessage = res.error_message
            ? [NSString stringWithUTF8String:res.error_message]
            : [NSString stringWithFormat:@"Cloud catalog fetch failed (error %d)", (int)err];
    }

    chiaki_cloudcatalog_result_fini(&res);
    return json;
}

+ (NSArray<NSString *> *)supportedCloudLanguages {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    size_t n = chiaki_cloud_supported_locale_count();
    for (size_t i = 0; i < n; i++) {
        const char *l = chiaki_cloud_supported_locale(i);
        if (l && *l)
            [out addObject:[NSString stringWithUTF8String:l]];
    }
    return out;
}

@end
