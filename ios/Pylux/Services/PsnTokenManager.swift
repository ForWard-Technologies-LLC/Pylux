// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// PSN OAuth v3 token exchange - mirrors Android's PsnTokenManager.kt exactly

import Foundation
import os.log

private let psnLog = OSLog(subsystem: "com.pylux.stream", category: "PsnToken")

// MARK: - PSN Auth Constants (matching Android's PsnAuthConstants.kt)

enum PsnAuthConstants {
    static let accountBase = "https://ca.account.sony.com"
    static let authorizeEndpoint = "\(accountBase)/api/authz/v3/oauth/authorize"
    static let tokenEndpoint = "\(accountBase)/api/authz/v3/oauth/token"
    static let clientId = "ba495a24-818c-472b-b12d-ff231c1b5745"
    static let clientSecret = "mvaiZkRsAsI1IBkY"
    static let redirectUri = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
    static let scopes = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
    static let v2TokenUrl = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
}

// MARK: - PSN Token Storage (facade over SecureStore)

class PsnTokenStore {
    static let shared = PsnTokenStore()
    private let store = SecureStore.shared

    init() {
        os_log(.info, log: psnLog, "[PsnTokenStore] init: hasTokens=%d isExpired=%d npsso.len=%d duid.len=%d accountId.len=%d",
               hasTokens ? 1 : 0, isTokenExpired ? 1 : 0, npsso.count, duid.count, accountId.count)
    }

    var authToken: String {
        get { store.authToken }
        set { store.authToken = newValue }
    }

    var refreshToken: String {
        get { store.refreshToken }
        set { store.refreshToken = newValue }
    }

    var tokenExpiry: TimeInterval {
        get { store.tokenExpiry }
        set { store.tokenExpiry = newValue }
    }

    var accountId: String {
        get { store.accountId }
        set { store.accountId = newValue }
    }

    var onlineId: String {
        get { store.onlineId }
        set { store.onlineId = newValue }
    }

    var duid: String {
        get { store.duid }
        set { store.duid = newValue }
    }

    var npsso: String {
        get { store.npsso }
        set { store.npsso = newValue }
    }

    var hasTokens: Bool { !authToken.isEmpty && !refreshToken.isEmpty }

    var isTokenExpired: Bool { Date().timeIntervalSince1970 * 1000 >= tokenExpiry }

    func clearTokens() {
        store.authToken = ""
        store.refreshToken = ""
        store.tokenExpiry = 0
        store.accountId = ""
        store.onlineId = ""
    }
}

// MARK: - PSN Token Manager (mirrors Android's PsnTokenManager.kt)

class PsnTokenManager {
    static let shared = PsnTokenManager()
    private let store = PsnTokenStore.shared

    /// Exchange OAuth authorization code for full tokens. Blocking - call on background thread.
    func exchangeAuthCodeForTokens(_ authCode: String) -> Bool {
        os_log(.info, log: psnLog, "exchangeAuthCodeForTokens: starting (code length=%d)", authCode.count)
        
        // Ensure DUID
        if store.duid.isEmpty || store.duid.count != 48 {
            store.duid = generateDuid()
            os_log(.info, log: psnLog, "Generated new DUID: %{public}s (length=%d)", store.duid, store.duid.count)
        }
        
        // Exchange auth code for tokens
        os_log(.info, log: psnLog, "Exchanging auth code for tokens...")
        guard let tokens = exchangeCodeForTokens(authCode) else {
            os_log(.error, log: psnLog, "FAILED: Could not exchange code for tokens")
            return false
        }
        os_log(.info, log: psnLog, "Got tokens (expiresIn=%ds)", tokens.expiresIn)
        
        store.authToken = tokens.accessToken
        store.refreshToken = tokens.refreshToken
        store.tokenExpiry = Date().timeIntervalSince1970 * 1000 + Double(tokens.expiresIn) * 1000
        
        os_log(.info, log: psnLog, "Tokens saved (accessToken length=%d, refreshToken length=%d)",
               tokens.accessToken.count, tokens.refreshToken.count)
        
        // Fetch account ID
        os_log(.info, log: psnLog, "Fetching account ID...")
        if let accountId = fetchAccountId(accessToken: tokens.accessToken) {
            store.accountId = accountId
            os_log(.info, log: psnLog, "Account ID saved: %{public}s", accountId)
        } else {
            os_log(.error, log: psnLog, "Could not fetch account ID (tokens still saved)")
        }
        
        return true
    }
    
    /// Exchange NPSSO cookie for full OAuth v3 tokens. Blocking - call on background thread.
    func exchangeNpssoForTokens(_ npsso: String) -> Bool {
        os_log(.info, log: psnLog, "exchangeNpssoForTokens: starting (npsso length=%d)", npsso.count)

        // Ensure DUID (matches Android DuidUtil: prefix + 16 random bytes = 48 hex chars)
        // Force regenerate if stored DUID has wrong length (bug in earlier code generated 64 chars)
        if store.duid.isEmpty || store.duid.count != 48 {
            store.duid = generateDuid()
            os_log(.info, log: psnLog, "Generated new DUID: %{public}s (length=%d)", store.duid, store.duid.count)
        } else {
            os_log(.info, log: psnLog, "Using stored DUID: %{public}s (length=%d)", store.duid, store.duid.count)
        }

        // Step 1: Get authorization code by hitting authorize endpoint with npsso cookie
        os_log(.info, log: psnLog, "Step 1: Getting authorization code...")
        guard let authCode = getAuthorizationCode(npsso: npsso, duid: store.duid) else {
            os_log(.error, log: psnLog, "Step 1 FAILED: Could not get authorization code")
            return false
        }
        os_log(.info, log: psnLog, "Step 1 OK: Got auth code (length=%d)", authCode.count)

        // Step 2: Exchange auth code for tokens
        os_log(.info, log: psnLog, "Step 2: Exchanging auth code for tokens...")
        guard let tokens = exchangeCodeForTokens(authCode) else {
            os_log(.error, log: psnLog, "Step 2 FAILED: Could not exchange code for tokens")
            return false
        }
        os_log(.info, log: psnLog, "Step 2 OK: Got tokens (expiresIn=%ds)", tokens.expiresIn)

        store.authToken = tokens.accessToken
        store.refreshToken = tokens.refreshToken
        store.tokenExpiry = Date().timeIntervalSince1970 * 1000 + Double(tokens.expiresIn) * 1000
        store.npsso = npsso

        os_log(.info, log: psnLog, "Tokens saved (accessToken length=%d, refreshToken length=%d)",
               tokens.accessToken.count, tokens.refreshToken.count)

        // Step 3: Fetch account ID
        os_log(.info, log: psnLog, "Step 3: Fetching account ID...")
        if let accountId = fetchAccountId(accessToken: tokens.accessToken) {
            store.accountId = accountId
            os_log(.info, log: psnLog, "Step 3 OK: Account ID saved: %{public}s", accountId)
        } else {
            os_log(.error, log: psnLog, "Step 3 FAILED: Could not fetch account ID (tokens still saved)")
        }

        return true
    }

    /// Refresh expired access token. Blocking.
    func refreshToken() -> Bool {
        let refreshTok = store.refreshToken
        guard !refreshTok.isEmpty else {
            os_log(.error, log: psnLog, "refreshToken: no refresh token stored")
            return false
        }

        os_log(.info, log: psnLog, "Refreshing access token...")

        var body = "grant_type=refresh_token"
        body += "&refresh_token=\(refreshTok.urlEncoded)"
        body += "&scope=\(PsnAuthConstants.scopes.urlEncoded)"
        body += "&redirect_uri=\(PsnAuthConstants.redirectUri.urlEncoded)"
        body += "&client_id=\(PsnAuthConstants.clientId.urlEncoded)"
        body += "&client_secret=\(PsnAuthConstants.clientSecret.urlEncoded)"

        guard let (responseBody, statusCode) = httpPost(url: PsnAuthConstants.tokenEndpoint, body: body) else {
            os_log(.error, log: psnLog, "Token refresh: network request failed")
            return false
        }
        guard statusCode == 200 else {
            os_log(.error, log: psnLog, "Token refresh failed: HTTP %d - %{public}s", statusCode, responseBody)
            return false
        }
        guard let json = try? JSONSerialization.jsonObject(with: Data(responseBody.utf8)) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            os_log(.error, log: psnLog, "Token refresh: no access_token in response: %{public}s", responseBody)
            return false
        }

        store.authToken = accessToken
        if let newRefresh = json["refresh_token"] as? String, !newRefresh.isEmpty {
            store.refreshToken = newRefresh
        }
        let expiresIn = json["expires_in"] as? Int ?? 0
        store.tokenExpiry = Date().timeIntervalSince1970 * 1000 + Double(expiresIn) * 1000
        os_log(.info, log: psnLog, "Token refreshed (expires in %ds)", expiresIn)
        return true
    }

    /// Get a valid PSN access token, refreshing if needed. Blocking.
    func getValidToken() -> String? {
        guard store.hasTokens else {
            os_log(.info, log: psnLog, "getValidToken: no stored tokens")
            return nil
        }
        if store.isTokenExpired {
            os_log(.info, log: psnLog, "Token expired, attempting refresh...")
            if !refreshToken() {
                let npsso = store.npsso
                if !npsso.isEmpty {
                    os_log(.info, log: psnLog, "Refresh failed, trying NPSSO re-exchange...")
                    if !exchangeNpssoForTokens(npsso) { return nil }
                } else {
                    os_log(.error, log: psnLog, "No NPSSO for re-auth")
                    return nil
                }
            }
        }
        let token = store.authToken
        os_log(.info, log: psnLog, "getValidToken: returning token (length=%d)", token.count)
        return token.isEmpty ? nil : token
    }

    // MARK: - Private helpers

    /// Generate DUID matching Android's DuidUtil.generateDuid() exactly:
    /// prefix "0000000700410080" (16 chars) + 16 random bytes as hex (32 chars) = 48 chars total
    private func generateDuid() -> String {
        let prefix = "0000000700410080"
        var randomBytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &randomBytes)
        let randomHex = randomBytes.map { String(format: "%02x", $0) }.joined()
        return prefix + randomHex  // 16 + 32 = 48 characters
    }

    /// Step 1: GET authorize endpoint with npsso cookie to get auth code via redirect.
    /// Matches Android's PsnTokenManager.getAuthorizationCode()
    private func getAuthorizationCode(npsso: String, duid: String) -> String? {
        var params = "client_id=\(PsnAuthConstants.clientId.urlEncoded)"
        params += "&redirect_uri=\(PsnAuthConstants.redirectUri.urlEncoded)"
        params += "&scope=\(PsnAuthConstants.scopes.urlEncoded)"
        params += "&response_type=code"
        params += "&service_entity=\("urn:service-entity:psn".urlEncoded)"
        params += "&access_type=offline"
        params += "&duid=\(duid.urlEncoded)"
        params += "&smcid=remoteplay"
        params += "&layout_type=popup"
        params += "&PlatformPrivacyWs1=minimal"
        params += "&no_captcha=true"
        params += "&cid=\(UUID().uuidString)"

        let urlString = "\(PsnAuthConstants.authorizeEndpoint)?\(params)"
        guard let url = URL(string: urlString) else {
            os_log(.error, log: psnLog, "getAuthCode: invalid URL")
            return nil
        }
        // Log the FULL URL so we can compare with Android exactly
        os_log(.info, log: psnLog, "getAuthCode: FULL URL = %{public}s", urlString)

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(PsnAuthConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("npsso=\(npsso)", forHTTPHeaderField: "Cookie")

        // Don't follow redirects - capture the redirect URL via the delegate
        let config = URLSessionConfiguration.ephemeral
        let delegate = NoRedirectDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let sem = DispatchSemaphore(value: 0)
        var authCode: String?
        var httpStatus: Int = 0

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: psnLog, "getAuthCode: network error: %{public}s", error.localizedDescription)
                sem.signal()
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                os_log(.error, log: psnLog, "getAuthCode: no HTTP response")
                sem.signal()
                return
            }
            httpStatus = httpResponse.statusCode
            os_log(.info, log: psnLog, "getAuthCode: HTTP %d", httpStatus)

            // Primary: check the redirect URL captured by the delegate
            // (URLSession strips Location header when delegate cancels redirect)
            if let redirectUrl = delegate.redirectURL?.absoluteString {
                os_log(.info, log: psnLog, "getAuthCode: delegate captured redirect URL = %{public}s",
                       redirectUrl.prefix(300).description)
                authCode = self.extractCode(from: redirectUrl)
            }

            // Fallback: check Location header (some URLSession versions may preserve it)
            if authCode == nil, let location = httpResponse.value(forHTTPHeaderField: "Location") {
                os_log(.info, log: psnLog, "getAuthCode: Location header = %{public}s", location.prefix(300).description)
                authCode = self.extractCode(from: location)
            }

            // Fallback: check response URL
            if authCode == nil, let finalUrl = httpResponse.url?.absoluteString {
                os_log(.debug, log: psnLog, "getAuthCode: response URL = %{public}s", finalUrl.prefix(300).description)
                authCode = self.extractCode(from: finalUrl)
            }

            // If still no code, log headers and body for debugging
            if authCode == nil {
                for (key, value) in httpResponse.allHeaderFields {
                    os_log(.debug, log: psnLog, "getAuthCode: header %{public}s = %{public}s",
                           String(describing: key), String(describing: value).prefix(200).description)
                }
                if let data = data, let body = String(data: data, encoding: .utf8) {
                    os_log(.error, log: psnLog, "getAuthCode: no code found. Body: %{public}s", body.prefix(500).description)
                }
            }

            sem.signal()
        }
        task.resume()
        sem.wait()
        session.invalidateAndCancel()

        if authCode == nil {
            os_log(.error, log: psnLog, "getAuthCode: FAILED (HTTP status=%d)", httpStatus)
        }
        return authCode
    }

    private func extractCode(from urlString: String) -> String? {
        guard let comps = URLComponents(string: urlString) else { return nil }
        // Check for error response first
        if let error = comps.queryItems?.first(where: { $0.name == "error" })?.value {
            let errorCode = comps.queryItems?.first(where: { $0.name == "error_code" })?.value ?? ""
            let errorDesc = comps.queryItems?.first(where: { $0.name == "error_description" })?.value ?? ""
            os_log(.error, log: psnLog, "PSN auth error: %{public}s (code=%{public}s): %{public}s",
                   error, errorCode, errorDesc)
            return nil
        }
        guard let code = comps.queryItems?.first(where: { $0.name == "code" })?.value else { return nil }
        return code
    }

    /// Step 2: Exchange authorization code for tokens.
    /// Matches Android's PsnTokenManager.exchangeCodeForTokens()
    private func exchangeCodeForTokens(_ authCode: String) -> TokenResponse? {
        var body = "grant_type=authorization_code"
        body += "&code=\(authCode.urlEncoded)"
        body += "&client_id=\(PsnAuthConstants.clientId.urlEncoded)"
        body += "&client_secret=\(PsnAuthConstants.clientSecret.urlEncoded)"
        body += "&redirect_uri=\(PsnAuthConstants.redirectUri.urlEncoded)"
        body += "&scope=\(PsnAuthConstants.scopes.urlEncoded)"

        guard let (responseBody, statusCode) = httpPost(url: PsnAuthConstants.tokenEndpoint, body: body) else {
            os_log(.error, log: psnLog, "exchangeCodeForTokens: network request failed")
            return nil
        }
        guard statusCode == 200 else {
            os_log(.error, log: psnLog, "exchangeCodeForTokens: HTTP %d - %{public}s", statusCode, responseBody)
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: Data(responseBody.utf8)) as? [String: Any],
              let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            os_log(.error, log: psnLog, "exchangeCodeForTokens: no access_token in: %{public}s", String(responseBody.prefix(500)))
            return nil
        }

        return TokenResponse(
            accessToken: accessToken,
            refreshToken: json["refresh_token"] as? String ?? "",
            expiresIn: json["expires_in"] as? Int ?? 0
        )
    }

    /// Step 3: Fetch PSN account ID using the v2 token info endpoint.
    /// Matches Android's PsnTokenManager.fetchAccountId()
    private func fetchAccountId(accessToken: String) -> String? {
        let creds = "\(PsnAuthConstants.clientId):\(PsnAuthConstants.clientSecret)"
        let basicAuth = "Basic " + Data(creds.utf8).base64EncodedString()

        let urlString = "\(PsnAuthConstants.v2TokenUrl)/\(accessToken)"
        guard let url = URL(string: urlString) else {
            os_log(.error, log: psnLog, "fetchAccountId: invalid URL")
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(basicAuth, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let sem = DispatchSemaphore(value: 0)
        var result: String?

        URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                os_log(.error, log: psnLog, "fetchAccountId: network error: %{public}s", error.localizedDescription)
                return
            }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data = data else {
                os_log(.error, log: psnLog, "fetchAccountId: no data (HTTP %d)", statusCode)
                return
            }
            guard statusCode == 200 else {
                let body = String(data: data, encoding: .utf8) ?? ""
                os_log(.error, log: psnLog, "fetchAccountId: HTTP %d - %{public}s", statusCode, body.prefix(500).description)
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                os_log(.error, log: psnLog, "fetchAccountId: invalid JSON")
                return
            }

            // user_id can be a String or a Number
            let userId: String
            if let s = json["user_id"] as? String {
                userId = s
            } else if let n = json["user_id"] as? NSNumber {
                userId = n.stringValue
            } else {
                os_log(.error, log: psnLog, "fetchAccountId: no user_id in response: %{public}s",
                       String(data: data, encoding: .utf8)?.prefix(300).description ?? "")
                return
            }

            guard !userId.isEmpty, let userIdLong = Int64(userId) else {
                os_log(.error, log: psnLog, "fetchAccountId: invalid user_id: %{public}s", userId)
                return
            }

            // Convert to little-endian bytes and base64 encode (matches Android)
            var le = userIdLong.littleEndian
            let bytes = Data(bytes: &le, count: 8)
            result = bytes.base64EncodedString()
            os_log(.info, log: psnLog, "fetchAccountId: userId=%{public}s -> accountId=%{public}s",
                   userId, result ?? "nil")

            // Also grab online_id (PSN gamertag) if present in the response
            if let onlineId = json["online_id"] as? String, !onlineId.isEmpty {
                self.store.onlineId = onlineId
                os_log(.info, log: psnLog, "fetchAccountId: onlineId=%{public}s", onlineId)
            }
        }.resume()
        sem.wait()
        return result
    }

    /// HTTP POST helper - returns (responseBody, statusCode), or nil on network failure.
    /// Always returns the body even on non-200 responses for error logging.
    private func httpPost(url urlString: String, body: String) -> (String, Int)? {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: psnLog, "httpPost: invalid URL: %{public}s", urlString)
            return nil
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue(PsnAuthConstants.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data(body.utf8)

        let sem = DispatchSemaphore(value: 0)
        var resultBody: String?
        var resultStatus: Int?

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error = error {
                os_log(.error, log: psnLog, "httpPost %{public}s: error: %{public}s",
                       urlString, error.localizedDescription)
                sem.signal()
                return
            }
            let httpResp = response as? HTTPURLResponse
            resultStatus = httpResp?.statusCode
            if let data = data {
                resultBody = String(data: data, encoding: .utf8) ?? "(binary data)"
            }
            sem.signal()
        }.resume()
        sem.wait()

        guard let statusCode = resultStatus, let body = resultBody else {
            return nil
        }
        return (body, statusCode)
    }

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
    }
}

// MARK: - Helpers

/// Delegate that prevents URLSession from following redirects, capturing the redirect URL.
/// URLSession strips the Location header when redirect is cancelled, so we must capture it in the delegate.
private class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    /// The redirect URL captured from the 302 response
    var redirectURL: URL?

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Capture the redirect target URL (the newRequest URL is where PSN is trying to redirect)
        redirectURL = request.url
        os_log(.info, log: psnLog, "NoRedirectDelegate: captured redirect to %{public}s",
               request.url?.absoluteString.prefix(300).description ?? "nil")
        // Don't follow redirect
        completionHandler(nil)
    }
}

private extension String {
    /// Form URL encoding matching Java's URLEncoder.encode(s, "UTF-8") exactly.
    /// Only alphanumerics and -._* are left unencoded. Spaces become +. Everything else is %XX.
    var urlEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? self
    }
}
