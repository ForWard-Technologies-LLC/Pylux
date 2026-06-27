// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Bridge to libchiaki's unified cloud catalog (chiaki/cloudcatalog.h).
//
// The lib is the single source of truth for the cloud catalog across Qt, iOS and
// Android: it performs every OAuth/session exchange, fetch, dedup, ownership
// cross-reference and tagging, then returns ONE display-and-stream-ready JSON
// payload. iOS must not recompute category, serviceType, platform, ownership or
// stream identifiers — it just parses and renders the contract.

#ifndef CloudCatalogBridge_h
#define CloudCatalogBridge_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PyluxCloudCatalog : NSObject

/// Blocking; call from a background queue. Returns the unified catalog JSON
/// (UTF-8 string per CHIAKI_CLOUDCATALOG_SCHEMA_VERSION) or nil on hard failure.
/// On a unified-cache hit it performs no network I/O. A degraded-but-usable
/// result (e.g. expired npsso) still returns JSON with a non-empty "warning".
+ (nullable NSString *)fetchUnifiedJSONWithNpsso:(nullable NSString *)npsso
                                          locale:(nullable NSString *)locale
                                        cacheDir:(NSString *)cacheDir
                                    forceRefresh:(BOOL)forceRefresh
                                    errorMessage:(NSString * _Nullable * _Nullable)errorMessage;

/// Bare lowercase language code Gaikai expects ("de-DE" -> "de"); "en" default.
+ (NSString *)gaikaiLanguageForLocale:(nullable NSString *)locale;

/// Locales offered in the language picker (BCP-47, e.g. "en-GB").
+ (NSArray<NSString *> *)supportedCloudLanguages;

@end

NS_ASSUME_NONNULL_END

#endif /* CloudCatalogBridge_h */
