// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// ObjC bridge to Chiaki registration for iOS

#ifndef RegistBridge_h
#define RegistBridge_h

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stdint.h>

NS_ASSUME_NONNULL_BEGIN

/// Console target version for registration
typedef NS_ENUM(NSInteger, PyluxRegistTarget) {
    PyluxRegistTargetPS4_LT7 = 800,
    PyluxRegistTargetPS4_GE7 = 900,
    PyluxRegistTargetPS4_GE8 = 1000,
    PyluxRegistTargetPS5 = 1000100,
};

/// Registration result event
typedef NS_ENUM(NSInteger, PyluxRegistResult) {
    PyluxRegistResultCanceled = 0,
    PyluxRegistResultFailed = 1,
    PyluxRegistResultSuccess = 2,
};

/// Registered host data returned on success
@interface PyluxRegisteredHostData : NSObject
@property (nonatomic, assign) NSInteger target;
@property (nonatomic, strong) NSString *apSsid;
@property (nonatomic, strong) NSString *apBssid;
@property (nonatomic, strong) NSString *apKey;
@property (nonatomic, strong) NSString *apName;
@property (nonatomic, strong) NSData *serverMac; // 6 bytes
@property (nonatomic, strong, nullable) NSString *serverNickname;
@property (nonatomic, strong) NSData *rpRegistKey; // CHIAKI_SESSION_AUTH_SIZE (16) bytes
@property (nonatomic, assign) uint32_t rpKeyType;
@property (nonatomic, strong) NSData *rpKey; // 16 bytes
@end

/// Registration info to start registration
@interface PyluxRegistInfo : NSObject
@property (nonatomic, assign) PyluxRegistTarget target;
@property (nonatomic, strong) NSString *host;
@property (nonatomic, assign) BOOL broadcast;
@property (nonatomic, strong, nullable) NSString *psnOnlineId;
@property (nonatomic, strong, nullable) NSData *psnAccountId; // 8 bytes
@property (nonatomic, assign) uint32_t pin;
@end

/// Callback for registration events
typedef void (^PyluxRegistCallback)(PyluxRegistResult result, PyluxRegisteredHostData * _Nullable host, NSString * _Nullable logText);

/// Registration service
@interface PyluxRegistService : NSObject

- (instancetype)initWithInfo:(PyluxRegistInfo *)info callback:(PyluxRegistCallback)callback;
- (void)stop;

@end

NS_ASSUME_NONNULL_END

#endif /* RegistBridge_h */
