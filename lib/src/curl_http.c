// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "curl_http.h"

#include <curl/curl.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHIAKI_HTTP_DEFAULT_TIMEOUT_MS 30000L
#define CHIAKI_HTTP_USER_AGENT "pylux-cloudcatalog/1.0"

typedef struct grow_buffer_t
{
	char *data;
	size_t size;
} GrowBuffer;

static size_t grow_buffer_write(void *ptr, size_t size, size_t nmemb, void *userdata)
{
	size_t realsize = size * nmemb;
	GrowBuffer *buf = (GrowBuffer *)userdata;
	char *tmp = realloc(buf->data, buf->size + realsize + 1);
	if(!tmp)
	{
		free(buf->data);
		buf->data = NULL;
		buf->size = 0;
		return 0;
	}
	buf->data = tmp;
	memcpy(&buf->data[buf->size], ptr, realsize);
	buf->size += realsize;
	buf->data[buf->size] = 0;
	return realsize;
}

static int cc_http_debug_cb(CURL *handle, curl_infotype type, char *data, size_t size, void *userptr)
{
	(void)handle;
	ChiakiLog *log = (ChiakiLog *)userptr;
	if(!log || !(log->level_mask & CHIAKI_LOG_VERBOSE))
		return 0;
	switch(type)
	{
		case CURLINFO_HEADER_OUT:
			CHIAKI_LOGV(log, ">>> HTTP Request Headers:");
			CHIAKI_LOGV(log, "%.*s", (int)size, data);
			break;
		case CURLINFO_DATA_OUT:
			CHIAKI_LOGV(log, ">>> HTTP Request Body:");
			CHIAKI_LOGV(log, "%.*s", (int)size, data);
			break;
		case CURLINFO_HEADER_IN:
			CHIAKI_LOGV(log, "<<< HTTP Response Headers:");
			CHIAKI_LOGV(log, "%.*s", (int)size, data);
			break;
		case CURLINFO_DATA_IN:
			CHIAKI_LOGV(log, "<<< HTTP Response Body:");
			CHIAKI_LOGV(log, "%.*s", (int)size, data);
			break;
		default:
			break;
	}
	return 0;
}

static CURL *easy_init_logged(ChiakiLog *log)
{
	CURL *curl = curl_easy_init();
	if(!curl)
		return NULL;

	// mbedTLS (Android and other non-system-trust backends) needs the CA bundle
	// path explicitly. Harmless when the env var is unset or on Secure Transport.
	const char *ca_bundle = getenv("CHIAKI_CA_BUNDLE");
	if(ca_bundle && *ca_bundle)
		curl_easy_setopt(curl, CURLOPT_CAINFO, ca_bundle);

	if(log && (log->level_mask & CHIAKI_LOG_VERBOSE))
	{
		curl_easy_setopt(curl, CURLOPT_VERBOSE, 1L);
		curl_easy_setopt(curl, CURLOPT_DEBUGFUNCTION, cc_http_debug_cb);
		curl_easy_setopt(curl, CURLOPT_DEBUGDATA, log);
	}
	return curl;
}

CHIAKI_EXPORT ChiakiErrorCode cc_http_perform(
	ChiakiLog *log,
	const CCHttpRequest *request,
	CCHttpResponse *response)
{
	if(!request || !request->url || !response)
		return CHIAKI_ERR_INVALID_DATA;

	memset(response, 0, sizeof(*response));

	CURL *curl = easy_init_logged(log);
	if(!curl)
		return CHIAKI_ERR_MEMORY;

	ChiakiErrorCode err = CHIAKI_ERR_SUCCESS;
	struct curl_slist *header_list = NULL;
	GrowBuffer body_buf = { 0 };
	GrowBuffer header_buf = { 0 };

	for(size_t i = 0; i < request->header_count; i++)
	{
		struct curl_slist *next = curl_slist_append(header_list, request->headers[i]);
		if(!next)
		{
			err = CHIAKI_ERR_MEMORY;
			goto cleanup;
		}
		header_list = next;
	}

	curl_easy_setopt(curl, CURLOPT_URL, request->url);
	curl_easy_setopt(curl, CURLOPT_USERAGENT, CHIAKI_HTTP_USER_AGENT);
	curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, request->follow_redirects ? 1L : 0L);
	curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS,
		request->timeout_ms > 0 ? request->timeout_ms : CHIAKI_HTTP_DEFAULT_TIMEOUT_MS);
	if(header_list)
		curl_easy_setopt(curl, CURLOPT_HTTPHEADER, header_list);

	if(request->method && strcmp(request->method, "POST") == 0)
	{
		curl_easy_setopt(curl, CURLOPT_POST, 1L);
		const char *body = request->body ? request->body : "";
		curl_off_t len = (curl_off_t)(request->body_len > 0 ? request->body_len : strlen(body));
		curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body);
		curl_easy_setopt(curl, CURLOPT_POSTFIELDSIZE_LARGE, len);
	}
	else if(request->method && strcmp(request->method, "GET") != 0)
	{
		curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, request->method);
	}

	curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, grow_buffer_write);
	curl_easy_setopt(curl, CURLOPT_WRITEDATA, &body_buf);
	if(request->capture_headers)
	{
		curl_easy_setopt(curl, CURLOPT_HEADERFUNCTION, grow_buffer_write);
		curl_easy_setopt(curl, CURLOPT_HEADERDATA, &header_buf);
	}

	CURLcode res = curl_easy_perform(curl);
	if(res != CURLE_OK)
	{
		if(log)
			CHIAKI_LOGE(log, "cc_http_perform: %s (%s)", curl_easy_strerror(res), request->url);
		err = CHIAKI_ERR_NETWORK;
		goto cleanup;
	}

	long status = 0;
	curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &status);
	response->status_code = status;

	char *redirect = NULL;
	curl_easy_getinfo(curl, CURLINFO_REDIRECT_URL, &redirect);
	if(redirect)
		response->redirect_url = strdup(redirect);

	response->data = body_buf.data;
	response->size = body_buf.size;
	body_buf.data = NULL;
	if(request->capture_headers)
	{
		response->headers = header_buf.data;
		response->headers_size = header_buf.size;
		header_buf.data = NULL;
	}

cleanup:
	free(body_buf.data);
	free(header_buf.data);
	if(header_list)
		curl_slist_free_all(header_list);
	curl_easy_cleanup(curl);
	return err;
}

CHIAKI_EXPORT void cc_http_response_fini(CCHttpResponse *response)
{
	if(!response)
		return;
	free(response->data);
	free(response->headers);
	free(response->redirect_url);
	memset(response, 0, sizeof(*response));
}

CHIAKI_EXPORT ChiakiErrorCode cc_http_make_bearer_header(char **out, const char *token)
{
	if(!out || !token)
		return CHIAKI_ERR_INVALID_DATA;
	static const char fmt[] = "Authorization: Bearer %s";
	size_t len = sizeof(fmt) + strlen(token);
	*out = malloc(len);
	if(!*out)
		return CHIAKI_ERR_MEMORY;
	snprintf(*out, len, fmt, token);
	return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT ChiakiErrorCode cc_http_make_cookie_header(
	char **out, const char *name, const char *value)
{
	if(!out || !name || !value)
		return CHIAKI_ERR_INVALID_DATA;
	static const char fmt[] = "Cookie: %s=%s";
	size_t len = sizeof(fmt) + strlen(name) + strlen(value);
	*out = malloc(len);
	if(!*out)
		return CHIAKI_ERR_MEMORY;
	snprintf(*out, len, fmt, name, value);
	return CHIAKI_ERR_SUCCESS;
}
