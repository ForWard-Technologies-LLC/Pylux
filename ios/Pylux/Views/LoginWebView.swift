
// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// OAuth v3 login WebView for Sony authentication
// Mirrors desktop app's OAuth flow

import SwiftUI
import WebKit
import os.log

private let webViewLog = OSLog(subsystem: "com.pylux.stream", category: "LoginWebView")

struct LoginWebView: UIViewRepresentable {
    let url: URL
    let onNpsso: (String) -> Void
    let onCancel: () -> Void
    
    func makeCoordinator() -> Coordinator {
        Coordinator(onNpsso: onNpsso, onCancel: onCancel)
    }
    
    func makeUIView(context: Context) -> WKWebView {
        // Configure WKWebView to behave like Safari
        let config = WKWebViewConfiguration()
        
        // Enable all Safari-like features
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        config.defaultWebpagePreferences = preferences
        
        // Configure preferences
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        
        // Media playback (Safari-like)
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        
        // Use persistent data store (matches Safari behavior)
        config.websiteDataStore = .default()
        
        // Set Safari-like application name
        config.applicationNameForUserAgent = "Version/17.0 Safari/605.1.15"
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsBackForwardNavigationGestures = true
        
        // Set custom User-Agent to match Safari on iOS
        webView.customUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let request = URLRequest(url: url)
        webView.load(request)
    }
    
    class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let onNpsso: (String) -> Void
        let onCancel: () -> Void
        private var hasExtractedNpsso = false
        
        init(onNpsso: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
            self.onNpsso = onNpsso
            self.onCancel = onCancel
        }
        
        // Handle JavaScript alerts/confirms/prompts (Safari-like behavior)
        func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
            os_log(.default, log: webViewLog, "JS Alert: %{public}s", message)
            completionHandler()
        }
        
        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
            os_log(.default, log: webViewLog, "JS Confirm: %{public}s", message)
            completionHandler(true)
        }
        
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            os_log(.default, log: webViewLog, "JS Prompt: %{public}s", prompt)
            completionHandler(defaultText)
        }
        
        // Handle popup windows (Safari-like behavior)
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            // If a popup/new window is requested, load it in the same webview
            if navigationAction.targetFrame == nil {
                os_log(.default, log: webViewLog, "Popup requested, loading in same view: %{public}s", navigationAction.request.url?.absoluteString ?? "")
                webView.load(navigationAction.request)
            }
            return nil
        }
        
        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            
            os_log(.default, log: webViewLog, "Navigation to: %{public}s", url.absoluteString)
            decisionHandler(.allow)
        }
        
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard let url = webView.url else { return }
            guard !hasExtractedNpsso else { return }
            
            os_log(.default, log: webViewLog, "Page loaded: %{public}s", url.absoluteString)
            
            // Check for successful redirect - indicates login complete
            if url.absoluteString.starts(with: "https://remoteplay.dl.playstation.net/remoteplay/redirect") {
                os_log(.info, log: webViewLog, "Login redirect detected - navigating to ssocookie endpoint")
                
                // Navigate to ssocookie endpoint to ensure NPSSO cookie is set
                if let ssoCookieURL = URL(string: "https://ca.account.sony.com/api/v1/ssocookie") {
                    webView.load(URLRequest(url: ssoCookieURL))
                }
                return
            }
            
            // If we're at the ssocookie endpoint, extract NPSSO
            if url.absoluteString.contains("ca.account.sony.com/api/v1/ssocookie") {
                hasExtractedNpsso = true
                extractNpsso(from: webView)
            }
        }
        
        private func extractNpsso(from webView: WKWebView) {
            let cookieStore = webView.configuration.websiteDataStore.httpCookieStore
            
            cookieStore.getAllCookies { cookies in
                os_log(.info, log: webViewLog, "Checking %d cookies for NPSSO", cookies.count)
                
                if let npsso = cookies.first(where: { $0.name == "npsso" })?.value {
                    os_log(.info, log: webViewLog, "Found NPSSO cookie (length=%d)", npsso.count)
                    DispatchQueue.main.async {
                        self.onNpsso(npsso)
                    }
                } else {
                    os_log(.error, log: webViewLog, "NPSSO cookie not found. Available cookies: %{public}s",
                           cookies.map { $0.name }.joined(separator: ", "))
                }
            }
        }
        
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            os_log(.error, log: webViewLog, "Navigation failed: %{public}s", error.localizedDescription)
        }
        
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            os_log(.error, log: webViewLog, "Provisional navigation failed: %{public}s", error.localizedDescription)
        }
    }
}

struct LoginWebViewContainer: View {
    let url: URL
    let onNpsso: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            LoginWebView(url: url, onNpsso: onNpsso) {
                dismiss()
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }
}
