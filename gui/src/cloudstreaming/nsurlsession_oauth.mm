// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// macOS OAuth via NSURLSession — uses the platform-native Network.framework
// TLS stack. Requires NSAllowsArbitraryLoads in Info.plist so ATS doesn't
// restrict cipher suite negotiation.

#include "cloudstreaming/nsurlsession_oauth.h"

#import <Foundation/Foundation.h>

// Delegate that captures the Location header from a 3xx redirect and stops
// NSURLSession from following it (the redirect target uses a custom scheme
// like gaikai:// which NSURLSession can't load).
@interface OAuthRedirectDelegate : NSObject <NSURLSessionTaskDelegate>
@property (nonatomic, copy) NSString *locationHeader;
@property (nonatomic, assign) NSInteger statusCode;
@end

@implementation OAuthRedirectDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response
        newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest * _Nullable))completionHandler
{
    self.statusCode = response.statusCode;
    self.locationHeader = response.allHeaderFields[@"Location"];
    // Pass nil to cancel the redirect — we just want the Location header.
    completionHandler(nil);
}

@end

void performNativeOAuthGet(
    const QString &urlString,
    const QString &userAgent,
    const QString &npsso,
    std::function<void(NativeOAuthResult)> callback)
{
    @autoreleasepool {
        NSURL *url = [NSURL URLWithString:urlString.toNSString()];
        if (!url) {
            callback({0, {}, QStringLiteral("Invalid URL")});
            return;
        }

        NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];

        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        [request setHTTPMethod:@"GET"];
        [request setValue:userAgent.toNSString() forHTTPHeaderField:@"User-Agent"];
        [request setValue:@"*/*" forHTTPHeaderField:@"Accept"];

        if (!npsso.isEmpty()) {
            [request setValue:[NSString stringWithFormat:@"npsso=%@", npsso.toNSString()]
                forHTTPHeaderField:@"Cookie"];
        }

        OAuthRedirectDelegate *delegate = [[OAuthRedirectDelegate alloc] init];

        auto sharedCallback = std::make_shared<std::function<void(NativeOAuthResult)>>(std::move(callback));
        auto sharedDelegate = std::shared_ptr<void>((__bridge_retained void *)delegate, [](void *p) {
            (void)(__bridge_transfer OAuthRedirectDelegate *)p;
        });

        NSURLSession *session = [NSURLSession sessionWithConfiguration:config
            delegate:delegate
            delegateQueue:nil];

        NSURLSessionDataTask *task = [session dataTaskWithRequest:request
            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                OAuthRedirectDelegate *del = (__bridge OAuthRedirectDelegate *)sharedDelegate.get();
                NativeOAuthResult result;

                // If the delegate intercepted a redirect, use that.
                if (del.locationHeader) {
                    result.statusCode = (int)del.statusCode;
                    result.locationHeader = QString::fromNSString(del.locationHeader);
                    (*sharedCallback)(result);
                    return;
                }

                if (error) {
                    result.errorMessage = QString::fromNSString(error.localizedDescription);
                    (*sharedCallback)(result);
                    return;
                }

                NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
                result.statusCode = (int)httpResp.statusCode;

                NSString *location = httpResp.allHeaderFields[@"Location"];
                if (location)
                    result.locationHeader = QString::fromNSString(location);

                (*sharedCallback)(result);
            }];

        [task resume];
    }
}
