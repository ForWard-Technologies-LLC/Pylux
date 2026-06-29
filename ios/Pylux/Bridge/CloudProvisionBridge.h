// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Swift bridge for the unified cloud session-provisioning flow (libchiaki
// chiaki_cloud_provision_session). Mirrors CloudCatalogBridge: one blocking
// class method that runs the whole Kamaji+Gaikai flow in C and returns a
// stream-ready result. Call it off the main thread.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PyluxCloudProvisionResult : NSObject
@property (nonatomic) int err;                       // 0 == success
@property (nonatomic, copy) NSString *serverIp;
@property (nonatomic) int serverPort;
@property (nonatomic, copy) NSString *handshakeKey;
@property (nonatomic, copy) NSString *launchSpec;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *entitlementId; // the entitlement actually streamed
@property (nonatomic, copy) NSString *platform;      // ps3|ps4|ps5
@property (nonatomic) int psnWrapperType;
@property (nonatomic) int mtuIn;
@property (nonatomic) int mtuOut;
@property (nonatomic) int rttMs;
@property (nonatomic, copy, nullable) NSString *datacenterPings; // JSON, for Settings
@property (nonatomic, copy, nullable) NSString *errorMessage;    // sentinels on failure
@end

@interface PyluxCloudProvision : NSObject

/// Run the full provisioning flow (blocking — call from a background queue).
/// @c onProgress / @c isCancelled are invoked on the calling thread.
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
                                      catalogIsForeign:(BOOL)catalogIsForeign
                                            resolution:(int)resolution
                                           bitrateKbps:(int)bitrateKbps
                                            onProgress:(nullable void (^)(NSString *stage))onProgress
                                           isCancelled:(nullable BOOL (^)(void))isCancelled;

@end

NS_ASSUME_NONNULL_END
