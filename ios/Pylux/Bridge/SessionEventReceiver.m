// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#import "SessionEventReceiver.h"
#import <os/log.h>

@implementation SessionEventReceiver {
    // Strong self-reference to prevent ARC deallocation while C code holds our pointer.
    // Set by retainedOpaquePointer, cleared by invalidate.
    SessionEventReceiver *_selfRetain;
}

- (void)receiveEvent:(const void *)eventPtr {
    if (self.eventBlock && eventPtr) {
        self.eventBlock(eventPtr);
    }
}

- (void *)retainedOpaquePointer {
    _selfRetain = self;  // prevent ARC from freeing us
    return (__bridge void *)self;
}

- (void)invalidate {
    _selfRetain = nil;  // allow ARC to free us
    self.eventBlock = nil;
}

@end

// C-callable trampoline for ChiakiSessionBridgeEventCallback
void pylux_session_event_callback(const ChiakiSessionBridgeEvent *event, void *user) {
    if (!event || !user) return;
    static os_log_t sEventLog;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sEventLog = os_log_create("com.pylux.stream", "SessionEvent");
    });
    os_log(sEventLog, "Event received: type=%d quit_reason=%d",
           (int)event->type, event->quit_reason);
    SessionEventReceiver *receiver = (__bridge SessionEventReceiver *)user;
    [receiver receiveEvent:event];
}
