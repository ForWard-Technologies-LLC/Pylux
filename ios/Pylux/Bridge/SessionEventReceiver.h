// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// ObjC helper for receiving session events from C callback

#import <Foundation/Foundation.h>
#import "ChiakiSessionBridge.h"

@class SessionEventReceiver;

typedef void (^SessionEventBlock)(const void *eventPtr);

@interface SessionEventReceiver : NSObject
@property (nonatomic, copy) SessionEventBlock eventBlock;
- (void)receiveEvent:(const void *)eventPtr;
/// Returns an opaque pointer safe to pass to C code. The receiver retains itself
/// until -invalidate is called, preventing ARC from freeing it while C code holds the pointer.
- (void *)retainedOpaquePointer;
/// Release the self-retain created by retainedOpaquePointer. Call when the native session ends.
- (void)invalidate;
@end

/// C-callable event callback for ChiakiSessionBridge. Pass the pointer from -retainedOpaquePointer as user.
void pylux_session_event_callback(const ChiakiSessionBridgeEvent *event, void *user);
