// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Minimal blocking HTTP helper built on libcurl, shared by the cloud catalog
// module. Self-contained: handles mbedTLS CA-bundle (CHIAKI_CA_BUNDLE) and
// verbose request/response logging internally, so it does not depend on the
// holepunch.c curl glue (which is left untouched).

#ifndef CHIAKI_CC_HTTP_H
#define CHIAKI_CC_HTTP_H

#include <chiaki/common.h>
#include <chiaki/log.h>

#include <stdbool.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/** Growable response buffer (NUL-terminated body). */
typedef struct cc_http_response_t
{
	char *data;        /**< response body, NUL-terminated (may be NULL on empty) */
	size_t size;       /**< body length in bytes (excluding terminating NUL) */
	char *headers;     /**< raw response headers if request.capture_headers (else NULL) */
	size_t headers_size;
	char *redirect_url; /**< CURLINFO_REDIRECT_URL (the Location target), or NULL */
	long status_code;  /**< HTTP status code */
} CCHttpResponse;

/** One blocking HTTP request. */
typedef struct cc_http_request_t
{
	const char *method;             /**< "GET", "POST", ... (defaults to GET if NULL) */
	const char *url;
	const char *const *headers;     /**< array of "Key: Value" strings */
	size_t header_count;
	const char *body;               /**< request body (POST); NULL for none */
	size_t body_len;                /**< if 0 and body != NULL, strlen(body) is used */
	bool follow_redirects;          /**< CURLOPT_FOLLOWLOCATION */
	bool capture_headers;           /**< capture raw response headers into response */
	long timeout_ms;                /**< total timeout; 0 = library default (30s) */
} CCHttpRequest;

/**
 * Perform one blocking HTTP request. On success the caller owns @p response and
 * must release it with cc_http_response_fini(). Returns CHIAKI_ERR_SUCCESS
 * even for non-2xx HTTP status codes (inspect response->status_code); only
 * transport/setup failures return an error code.
 */
CHIAKI_EXPORT ChiakiErrorCode cc_http_perform(
	ChiakiLog *log,
	const CCHttpRequest *request,
	CCHttpResponse *response);

/** Release a response populated by cc_http_perform(). Safe on zeroed struct. */
CHIAKI_EXPORT void cc_http_response_fini(CCHttpResponse *response);

/** Build "Authorization: Bearer <token>". Caller frees *out. */
CHIAKI_EXPORT ChiakiErrorCode cc_http_make_bearer_header(char **out, const char *token);

/** Build "Cookie: <name>=<value>" (e.g. name="npsso"). Caller frees *out. */
CHIAKI_EXPORT ChiakiErrorCode cc_http_make_cookie_header(
	char **out, const char *name, const char *value);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_CC_HTTP_H
