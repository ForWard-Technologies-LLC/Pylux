// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// HTTP client for cloud streaming API calls - mirrors Android HttpClient.kt

import Foundation
import os.log

private let httpLog = OSLog(subsystem: "com.pylux.stream", category: "CloudHTTP")

/// HTTP response matching Android's HttpClient.Response
struct CloudHttpResponse {
    let statusCode: Int
    let body: String
    let headers: [String: String]  // case-insensitive header lookup
    let allHeaders: [AnyHashable: Any]  // raw headers from URLResponse

    func header(_ name: String) -> String? {
        // Case-insensitive lookup
        let lower = name.lowercased()
        for (key, value) in headers {
            if key.lowercased() == lower { return value }
        }
        return nil
    }
}

/// Simple HTTP client for PSN/Gaikai API calls - mirrors Android HttpClient.kt
enum CloudHttpClient {
    private static let timeout: TimeInterval = 15

    // MARK: - GET

    static func get(
        url urlString: String,
        headers: [String: String] = [:],
        followRedirects: Bool = true
    ) -> CloudHttpResponse? {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: httpLog, "GET: invalid URL: %{public}s", urlString)
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "GET"
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let config = URLSessionConfiguration.ephemeral
        let delegate = followRedirects ? nil : NoRedirectSessionDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        let sem = DispatchSemaphore(value: 0)
        var result: CloudHttpResponse?

        session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                os_log(.error, log: httpLog, "GET %{public}s error: %{public}s", urlString, error.localizedDescription)
                return
            }
            result = buildResponse(response: response, data: data, delegate: delegate)
        }.resume()
        sem.wait()
        session.invalidateAndCancel()
        return result
    }

    // MARK: - POST

    static func post(
        url urlString: String,
        body: String,
        headers: [String: String] = [:]
    ) -> CloudHttpResponse? {
        guard let url = URL(string: urlString) else {
            os_log(.error, log: httpLog, "POST: invalid URL: %{public}s", urlString)
            return nil
        }

        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let sem = DispatchSemaphore(value: 0)
        var result: CloudHttpResponse?

        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error = error {
                os_log(.error, log: httpLog, "POST %{public}s error: %{public}s", urlString, error.localizedDescription)
                return
            }
            result = buildResponse(response: response, data: data, delegate: nil)
        }.resume()
        sem.wait()
        session.invalidateAndCancel()
        return result
    }

    // MARK: - Cookie / Location Helpers (matching Android HttpClient)

    /// Extract cookie from Set-Cookie headers
    static func extractCookie(from response: CloudHttpResponse, name: String) -> String? {
        // Check all raw headers for Set-Cookie
        if let allHeaders = response.allHeaders as? [String: Any] {
            for (key, value) in allHeaders {
                if key.lowercased() == "set-cookie" {
                    let cookies: [String]
                    if let arr = value as? [String] { cookies = arr }
                    else if let str = value as? String { cookies = [str] }
                    else { continue }
                    for cookieStr in cookies {
                        let parts = cookieStr.split(separator: ";")
                        for part in parts {
                            let kv = part.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                            if kv.count == 2 && kv[0] == name {
                                return String(kv[1])
                            }
                        }
                    }
                }
            }
        }
        return nil
    }

    /// Extract Location header for redirects
    static func extractLocation(from response: CloudHttpResponse) -> String? {
        return response.header("Location")
    }

    // MARK: - Private

    private static func buildResponse(response: URLResponse?, data: Data?, delegate: NoRedirectSessionDelegate?) -> CloudHttpResponse {
        let httpResp = response as? HTTPURLResponse
        let statusCode = httpResp?.statusCode ?? 0
        let body = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""

        var flatHeaders: [String: String] = [:]
        if let allHeaders = httpResp?.allHeaderFields {
            for (key, value) in allHeaders {
                flatHeaders["\(key)"] = "\(value)"
            }
        }

        // If we have a redirect delegate, merge the redirect location
        if let redirectURL = delegate?.redirectURL {
            flatHeaders["Location"] = redirectURL.absoluteString
        }

        return CloudHttpResponse(
            statusCode: statusCode,
            body: body,
            headers: flatHeaders,
            allHeaders: httpResp?.allHeaderFields ?? [:]
        )
    }
}

// MARK: - URL Encoding (matches Java URLEncoder.encode behavior)

extension String {
    /// URL-encode matching Java's URLEncoder.encode (space -> "+", etc.)
    var cloudUrlEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: "%20", with: "+") ?? self
    }
}

/// Delegate that captures redirect URL without following it
private class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate {
    var redirectURL: URL?

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        redirectURL = request.url
        completionHandler(nil) // Don't follow
    }
}
