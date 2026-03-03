// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// Bridge to Chiaki C library for Swift

#ifndef ChiakiBridge_h
#define ChiakiBridge_h

#import <Foundation/Foundation.h>
#import "ChiakiSessionBridge.h"
#import "SessionEventReceiver.h"
#import "VideoDecoder.h"
#import "DiscoveryBridge.h"
#import "RegistBridge.h"
#import "HolepunchBridge.h"

/// Returns a string from the Chiaki library (e.g. "Success" from chiaki_error_string).
/// Used to verify the app is correctly linked to the Chiaki library.
const char * _Nonnull chiaki_get_test_string(void);

#endif /* ChiakiBridge_h */
