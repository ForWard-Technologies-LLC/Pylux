// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#import "RegistBridge.h"
#import "ChiakiSessionBridge.h"
#include <chiaki/regist.h>
#include <chiaki/log.h>
#include <os/log.h>
#include <string.h>

static os_log_t s_regist_log;

// ---- PyluxRegisteredHostData ----

@implementation PyluxRegisteredHostData
@end

// ---- PyluxRegistInfo ----

@implementation PyluxRegistInfo
@end

// ---- PyluxRegistService ----

@interface PyluxRegistService () {
    ChiakiRegist _regist;
    ChiakiLog _log;
    BOOL _running;
}
@property (nonatomic, copy) PyluxRegistCallback callback;
@property (nonatomic, strong) NSMutableString *logBuffer;
@end

static void regist_log_cb(ChiakiLogLevel level, const char *msg, void *user) {
    PyluxRegistService *svc = (__bridge PyluxRegistService *)user;
    NSString *line = msg ? [NSString stringWithUTF8String:msg] : @"";
    os_log_type_t type = OS_LOG_TYPE_DEFAULT;
    if (level == CHIAKI_LOG_ERROR) type = OS_LOG_TYPE_ERROR;
    os_log_with_type(s_regist_log, type, "[Regist] %{public}s", msg ? msg : "");
    @synchronized (svc) {
        [svc.logBuffer appendFormat:@"%@\n", line];
    }
}

static void regist_cb(ChiakiRegistEvent *event, void *user) {
    PyluxRegistService *svc = (__bridge PyluxRegistService *)user;
    PyluxRegistResult result;
    PyluxRegisteredHostData *hostData = nil;
    
    switch (event->type) {
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_SUCCESS:
            result = PyluxRegistResultSuccess;
            if (event->registered_host) {
                hostData = [[PyluxRegisteredHostData alloc] init];
                ChiakiRegisteredHost *h = event->registered_host;
                hostData.target = (NSInteger)h->target;
                hostData.apSsid = [NSString stringWithUTF8String:h->ap_ssid];
                hostData.apBssid = [NSString stringWithUTF8String:h->ap_bssid];
                hostData.apKey = [NSString stringWithUTF8String:h->ap_key];
                hostData.apName = [NSString stringWithUTF8String:h->ap_name];
                hostData.serverMac = [NSData dataWithBytes:h->server_mac length:6];
                hostData.serverNickname = strlen(h->server_nickname) > 0 ? [NSString stringWithUTF8String:h->server_nickname] : nil;
                hostData.rpRegistKey = [NSData dataWithBytes:h->rp_regist_key length:CHIAKI_SESSION_AUTH_SIZE];
                hostData.rpKeyType = h->rp_key_type;
                hostData.rpKey = [NSData dataWithBytes:h->rp_key length:0x10];
            }
            break;
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_FAILED:
            result = PyluxRegistResultFailed;
            break;
        case CHIAKI_REGIST_EVENT_TYPE_FINISHED_CANCELED:
        default:
            result = PyluxRegistResultCanceled;
            break;
    }
    
    NSString *logText;
    @synchronized (svc) {
        logText = [svc.logBuffer copy];
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (svc.callback) {
            svc.callback(result, hostData, logText);
        }
    });
}

@implementation PyluxRegistService

+ (void)initialize {
    if (self == [PyluxRegistService class]) {
        s_regist_log = os_log_create("com.pylux.stream", "Registration");
    }
}

- (instancetype)initWithInfo:(PyluxRegistInfo *)info callback:(PyluxRegistCallback)callback {
    self = [super init];
    if (self) {
        _callback = callback;
        _running = NO;
        self.logBuffer = [NSMutableString new];
        
        chiaki_session_bridge_init();
        chiaki_log_init(&_log, CHIAKI_LOG_ALL & ~CHIAKI_LOG_VERBOSE, regist_log_cb, (__bridge void *)self);
        
        ChiakiRegistInfo ci;
        memset(&ci, 0, sizeof(ci));
        ci.target = (ChiakiTarget)info.target;
        ci.host = info.host.UTF8String;
        ci.broadcast = info.broadcast;
        ci.pin = info.pin;
        
        if (info.psnOnlineId && info.psnOnlineId.length > 0) {
            ci.psn_online_id = info.psnOnlineId.UTF8String;
        } else {
            ci.psn_online_id = NULL;
        }
        
        if (info.psnAccountId && info.psnAccountId.length == CHIAKI_PSN_ACCOUNT_ID_SIZE) {
            memcpy(ci.psn_account_id, info.psnAccountId.bytes, CHIAKI_PSN_ACCOUNT_ID_SIZE);
        }
        
        ci.holepunch_info = NULL;
        memset(&ci.rudp, 0, sizeof(ci.rudp));
        
        ChiakiErrorCode err = chiaki_regist_start(&_regist, &_log, &ci, regist_cb, (__bridge void *)self);
        if (err == CHIAKI_ERR_SUCCESS) {
            _running = YES;
            os_log(s_regist_log, "Registration started for %{public}s", info.host.UTF8String);
        } else {
            os_log_error(s_regist_log, "Failed to start registration: %d", (int)err);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (self.callback) {
                    self.callback(PyluxRegistResultFailed, nil, @"Failed to start registration");
                }
            });
        }
    }
    return self;
}

- (void)stop {
    if (_running) {
        chiaki_regist_stop(&_regist);
        chiaki_regist_fini(&_regist);
        _running = NO;
    }
}

- (void)dealloc {
    [self stop];
}

@end
