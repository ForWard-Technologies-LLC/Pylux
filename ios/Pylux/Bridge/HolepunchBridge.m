// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#import "HolepunchBridge.h"
#import "ChiakiSessionBridge.h"
#import "PyluxChiakiLog.h"
#include <arpa/inet.h>  // for INET6_ADDRSTRLEN
#include <chiaki/remote/holepunch.h>
#include <os/log.h>

static os_log_t s_hp_log;
static ChiakiLog s_hp_chiaki_log;
static dispatch_once_t s_hp_log_once;

static void hp_log_cb(ChiakiLogLevel level, const char *msg, void *user) {
    (void)user;
    // Map all log levels to INFO or ERROR so they're visible in console
    os_log_type_t type = OS_LOG_TYPE_INFO;
    if (level == CHIAKI_LOG_ERROR) type = OS_LOG_TYPE_ERROR;
    os_log_with_type(s_hp_log, type, "[Holepunch] %{public}s", msg ? msg : "");
}

static void ensure_log_init(void) {
    dispatch_once(&s_hp_log_once, ^{
        s_hp_log = os_log_create("com.pylux.stream", "Holepunch");
        pylux_chiaki_log_init(&s_hp_chiaki_log, hp_log_cb, NULL);
    });
}

// ---- PyluxHolepunchDevice ----

@implementation PyluxHolepunchDevice

- (NSString *)duidHex {
    if (!_deviceUid || _deviceUid.length == 0) return @"";
    const uint8_t *bytes = _deviceUid.bytes;
    NSMutableString *hex = [NSMutableString stringWithCapacity:_deviceUid.length * 2];
    for (NSUInteger i = 0; i < _deviceUid.length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

@end

// ---- PyluxHolepunchSession ----

@interface PyluxHolepunchSession () {
    ChiakiHolepunchSession _session;
    BOOL _valid;
}
@end

@implementation PyluxHolepunchSession

- (nullable instancetype)initWithToken:(NSString *)psnOAuth2Token {
    self = [super init];
    if (self) {
        ensure_log_init();
        chiaki_session_bridge_init();
        
        _session = chiaki_holepunch_session_init(psnOAuth2Token.UTF8String, &s_hp_chiaki_log);
        if (!_session) {
            os_log_error(s_hp_log, "Failed to init holepunch session");
            return nil;
        }
        _valid = YES;
        os_log(s_hp_log, "Holepunch session initialized");
    }
    return self;
}

+ (nullable NSArray<PyluxHolepunchDevice *> *)listDevicesWithToken:(NSString *)token
                                                       consoleType:(PyluxHolepunchConsoleType)consoleType {
    ensure_log_init();
    chiaki_session_bridge_init();
    
    ChiakiHolepunchConsoleType cType = (consoleType == PyluxHolepunchConsoleTypePS5)
        ? CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5
        : CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4;
    
    ChiakiHolepunchDeviceInfo *devices = NULL;
    size_t count = 0;
    
    ChiakiErrorCode err = chiaki_holepunch_list_devices(
        token.UTF8String, cType, &devices, &count, false, &s_hp_chiaki_log);
    
    if (err != CHIAKI_ERR_SUCCESS) {
        os_log_error(s_hp_log, "list_devices failed: %d", (int)err);
        return nil;
    }
    
    NSMutableArray<PyluxHolepunchDevice *> *result = [NSMutableArray arrayWithCapacity:count];
    for (size_t i = 0; i < count; i++) {
        PyluxHolepunchDevice *dev = [[PyluxHolepunchDevice alloc] init];
        dev.consoleType = (devices[i].type == CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5)
            ? PyluxHolepunchConsoleTypePS5 : PyluxHolepunchConsoleTypePS4;
        dev.deviceName = [NSString stringWithUTF8String:devices[i].device_name];
        dev.deviceUid = [NSData dataWithBytes:devices[i].device_uid length:32];
        dev.remoteplayEnabled = devices[i].remoteplay_enabled;
        result[i] = dev;
    }
    
    chiaki_holepunch_free_device_list(&devices);
    os_log(s_hp_log, "Listed %zu devices", count);
    return result;
}

- (int)upnpDiscover {
    if (!_valid) return -1;
    ChiakiErrorCode err = chiaki_holepunch_upnp_discover(_session);
    os_log(s_hp_log, "UPnP discover: %d", (int)err);
    return (int)err;
}

- (int)createSession {
    if (!_valid) return -1;
    ChiakiErrorCode err = chiaki_holepunch_session_create(_session);
    os_log(s_hp_log, "Session create: %d", (int)err);
    return (int)err;
}

- (int)createOffer {
    if (!_valid) return -1;
    ChiakiErrorCode err = holepunch_session_create_offer(_session);
    os_log(s_hp_log, "Create offer: %d", (int)err);
    return (int)err;
}

- (int)startWithDuid:(NSData *)duid consoleType:(PyluxHolepunchConsoleType)consoleType {
    if (!_valid) return -1;
    ChiakiHolepunchConsoleType cType = (consoleType == PyluxHolepunchConsoleTypePS5)
        ? CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS5
        : CHIAKI_HOLEPUNCH_CONSOLE_TYPE_PS4;
    ChiakiErrorCode err = chiaki_holepunch_session_start(_session, duid.bytes, cType);
    os_log(s_hp_log, "Session start: %d", (int)err);
    return (int)err;
}

- (NSString *)lastStartErrorMessage {
    if (!_session)
        return @"";
    char buf[512];
    size_t n = chiaki_holepunch_session_get_last_error(_session, buf, sizeof(buf));
    if (n == 0)
        return @"";
    return [NSString stringWithUTF8String:buf];
}

- (int)punchHole:(PyluxHolepunchPortType)portType {
    if (!_valid) return -1;
    ChiakiHolepunchPortType cType = (portType == PyluxHolepunchPortTypeCTRL)
        ? CHIAKI_HOLEPUNCH_PORT_TYPE_CTRL
        : CHIAKI_HOLEPUNCH_PORT_TYPE_DATA;
    ChiakiErrorCode err = chiaki_holepunch_session_punch_hole(_session, cType);
    os_log(s_hp_log, "Punch hole (%s): %d",
           portType == PyluxHolepunchPortTypeCTRL ? "CTRL" : "DATA", (int)err);
    return (int)err;
}

- (uintptr_t)nativePtr {
    return (uintptr_t)_session;
}

- (void)cancel {
    if (_valid && _session) {
        chiaki_holepunch_main_thread_cancel(_session, true);
    }
}

- (void)markConsumed {
    // The native chiaki session now owns the holepunch session pointer.
    // Clear our reference so dealloc/fini won't double-free.
    _session = NULL;
    _valid = NO;
    os_log(s_hp_log, "Holepunch session marked as consumed by native session");
}

- (void)fini {
    if (_valid && _session) {
        chiaki_holepunch_session_fini(_session);
        _session = NULL;
        _valid = NO;
        os_log(s_hp_log, "Holepunch session finalized");
    }
}

- (void)dealloc {
    [self fini];
}

@end
