// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.util.Log
import com.metallic.chiaki.cloudplay.PsnApiConstants
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import javax.net.ssl.HttpsURLConnection

/**
 * Simple HTTP client for PSN API calls
 * Uses HttpURLConnection for reliability (SSL works out of box on Android)
 */
internal object HttpClient
{
	private const val TAG = "PsnHttpClient"
	private const val TIMEOUT_MS = 10000
	
	data class Response(
		val statusCode: Int,
		val body: String,
		val headers: Map<String, List<String>>
	)
	
	/**
	 * Perform GET request
	 */
	fun get(
		url: String,
		headers: Map<String, String> = emptyMap(),
		followRedirects: Boolean = true
	): Response
	{
		Log.d(TAG, "GET: $url")
		
		val connection = URL(url).openConnection() as HttpURLConnection
		try
		{
			connection.requestMethod = "GET"
			connection.connectTimeout = TIMEOUT_MS
			connection.readTimeout = TIMEOUT_MS
			connection.instanceFollowRedirects = followRedirects
			
			// Set headers
			connection.setRequestProperty("User-Agent", PsnApiConstants.USER_AGENT)
			headers.forEach { (key, value) ->
				connection.setRequestProperty(key, value)
			}
			
			val statusCode = connection.responseCode
			Log.d(TAG, "Response: $statusCode")
			
			val body = try {
				connection.inputStream.bufferedReader().use { it.readText() }
			} catch (e: Exception) {
				connection.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
			}
			
			return Response(statusCode, body, connection.headerFields)
		}
		finally
		{
			connection.disconnect()
		}
	}
	
	/**
	 * Perform POST request
	 */
	fun post(
		url: String,
		body: String,
		headers: Map<String, String> = emptyMap()
	): Response
	{
		Log.d(TAG, "POST: $url")
		
		val connection = URL(url).openConnection() as HttpURLConnection
		try
		{
			connection.requestMethod = "POST"
			connection.connectTimeout = TIMEOUT_MS
			connection.readTimeout = TIMEOUT_MS
			connection.doOutput = true
			
			// Set headers
			connection.setRequestProperty("User-Agent", PsnApiConstants.USER_AGENT)
			headers.forEach { (key, value) ->
				connection.setRequestProperty(key, value)
			}
			
			// Write body
			OutputStreamWriter(connection.outputStream).use { writer ->
				writer.write(body)
				writer.flush()
			}
			
			val statusCode = connection.responseCode
			Log.d(TAG, "Response: $statusCode")
			
			val responseBody = try {
				connection.inputStream.bufferedReader().use { it.readText() }
			} catch (e: Exception) {
				connection.errorStream?.bufferedReader()?.use { it.readText() } ?: ""
			}
			
			return Response(statusCode, responseBody, connection.headerFields)
		}
		finally
		{
			connection.disconnect()
		}
	}
	
	/**
	 * Extract cookie value from response headers
	 */
	fun extractCookie(headers: Map<String, List<String>>, cookieName: String): String?
	{
		val setCookieHeaders = headers["Set-Cookie"] ?: headers["set-cookie"] ?: return null
		
		for (header in setCookieHeaders)
		{
			val cookies = header.split(";")
			for (cookie in cookies)
			{
				val parts = cookie.trim().split("=", limit = 2)
				if (parts.size == 2 && parts[0] == cookieName)
				{
					return parts[1]
				}
			}
		}
		
		return null
	}
	
	/**
	 * Extract Location header for redirects
	 */
	fun extractLocation(headers: Map<String, List<String>>): String?
	{
		return headers["Location"]?.firstOrNull() ?: headers["location"]?.firstOrNull()
	}
}

