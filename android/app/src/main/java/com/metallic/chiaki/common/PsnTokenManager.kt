// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.util.Base64
import android.util.Log
import com.metallic.chiaki.cloudplay.DuidUtil
import com.metallic.chiaki.cloudplay.PsnAuthConstants
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStreamWriter
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.UUID

/**
 * Manages PSN OAuth v3 tokens for Remote Play (holepunch) connections.
 * Mirrors the desktop Qt app's PSNAccountIDV3 and PSNToken classes.
 *
 * Flow:
 * 1. exchangeNpssoForTokens(npsso) -> gets auth code via redirect, exchanges for tokens, fetches account ID
 * 2. refreshToken() -> refreshes expired access token using refresh token
 * 3. getValidToken() -> returns valid token, auto-refreshing if needed
 */
class PsnTokenManager(private val preferences: Preferences)
{
	companion object
	{
		private const val TAG = "PsnTokenManager"
		private const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"

		// v2 endpoint for account info lookup (still needed even with v3 auth)
		private const val V2_TOKEN_URL = "https://auth.api.sonyentertainmentnetwork.com/2.0/oauth/token"
	}

	/**
	 * Exchange an NPSSO cookie token for full OAuth v3 tokens and account ID.
	 * This is a blocking call - run on a background thread.
	 *
	 * Mimics PSNAccountIDV3::GetPsnAccountIdFromNpsso() from the Qt app.
	 *
	 * @return true on success, false on failure
	 */
	fun exchangeNpssoForTokens(npsso: String): Boolean
	{
		Log.i(TAG, "exchangeNpssoForTokens: starting (npsso length=${npsso.length})")
		try
		{
			// Ensure we have a client DUID (generate once and store)
			var duid = preferences.psnDuid
			if(duid.isEmpty())
			{
				duid = DuidUtil.generateDuid()
				preferences.psnDuid = duid
				Log.i(TAG, "Generated new DUID: $duid")
			}

			// Step 1: Get authorization code by hitting authorize endpoint with npsso cookie
			Log.i(TAG, "Step 1: Getting authorization code...")
			val authCode = getAuthorizationCode(npsso, duid)
			if(authCode == null)
			{
				Log.e(TAG, "Step 1 FAILED: Could not get authorization code")
				return false
			}
			Log.i(TAG, "Step 1 OK: Got auth code (length=${authCode.length})")

			// Step 2: Exchange auth code for tokens
			Log.i(TAG, "Step 2: Exchanging auth code for tokens...")
			val tokens = exchangeCodeForTokens(authCode)
			if(tokens == null)
			{
				Log.e(TAG, "Step 2 FAILED: Could not exchange code for tokens")
				return false
			}
			Log.i(TAG, "Step 2 OK: Got tokens (accessToken length=${tokens.accessToken.length}, expiresIn=${tokens.expiresIn}s)")

			// Save tokens
			preferences.psnAuthToken = tokens.accessToken
			preferences.psnRefreshToken = tokens.refreshToken
			preferences.psnAuthTokenExpiry = System.currentTimeMillis() + (tokens.expiresIn * 1000L)

			// Also save NPSSO for future re-auth
			preferences.setNpssoToken(npsso)

			Log.i(TAG, "Tokens saved successfully (expires in ${tokens.expiresIn}s)")

			// Step 3: Fetch account ID
			val accountId = fetchAccountId(tokens.accessToken)
			if(accountId != null)
			{
				preferences.psnAccountId = accountId
				Log.i(TAG, "Account ID saved: $accountId")
			}
			else
			{
				Log.w(TAG, "Failed to fetch account ID (tokens still saved)")
			}

			return true
		}
		catch(e: Exception)
		{
			Log.e(TAG, "exchangeNpssoForTokens failed", e)
			return false
		}
	}

	/**
	 * Refresh the access token using the stored refresh token.
	 * This is a blocking call - run on a background thread.
	 *
	 * Mimics PSNToken::RefreshPsnToken() from the Qt app.
	 *
	 * @return true on success, false on failure
	 */
	fun refreshToken(): Boolean
	{
		val refreshToken = preferences.psnRefreshToken
		if(refreshToken.isEmpty())
		{
			Log.w(TAG, "No refresh token available")
			return false
		}

		try
		{
			val body = buildString {
				append("grant_type=refresh_token")
				append("&refresh_token=").append(URLEncoder.encode(refreshToken, "UTF-8"))
				append("&scope=").append(URLEncoder.encode(PsnAuthConstants.SCOPES, "UTF-8"))
				append("&redirect_uri=").append(URLEncoder.encode(PsnAuthConstants.REDIRECT_URI, "UTF-8"))
			}

			// v3 token exchange doesn't use Basic Auth - credentials in body
			val bodyWithCreds = body +
				"&client_id=" + URLEncoder.encode(PsnAuthConstants.CLIENT_ID, "UTF-8") +
				"&client_secret=" + URLEncoder.encode(CLIENT_SECRET, "UTF-8")

			val response = httpPost(PsnAuthConstants.TOKEN_ENDPOINT_V3, bodyWithCreds, null)
			if(response == null)
			{
				Log.e(TAG, "Token refresh request failed")
				return false
			}

			val json = JSONObject(response)
			val accessToken = json.optString("access_token", "")
			val newRefreshToken = json.optString("refresh_token", "")
			val expiresIn = json.optInt("expires_in", 0)

			if(accessToken.isEmpty())
			{
				Log.e(TAG, "No access token in refresh response")
				return false
			}

			preferences.psnAuthToken = accessToken
			if(newRefreshToken.isNotEmpty())
				preferences.psnRefreshToken = newRefreshToken
			preferences.psnAuthTokenExpiry = System.currentTimeMillis() + (expiresIn * 1000L)

			Log.i(TAG, "Token refreshed successfully (expires in ${expiresIn}s)")
			return true
		}
		catch(e: Exception)
		{
			Log.e(TAG, "refreshToken failed", e)
			return false
		}
	}

	/**
	 * Get a valid PSN access token, refreshing if needed.
	 * This is a blocking call - run on a background thread.
	 *
	 * @return valid access token, or null if unable to obtain one
	 */
	fun getValidToken(): String?
	{
		if(!preferences.hasPsnRemotePlayTokens)
		{
			Log.i(TAG, "getValidToken: no stored tokens")
			return null
		}

		if(preferences.isPsnTokenExpired)
		{
			Log.i(TAG, "Token expired, attempting refresh...")
			if(!refreshToken())
			{
				// Try re-auth with stored NPSSO
				val npsso = preferences.getNpssoToken()
				if(npsso.isNotEmpty())
				{
					Log.i(TAG, "Refresh failed, trying NPSSO re-exchange...")
					if(!exchangeNpssoForTokens(npsso))
					{
						Log.e(TAG, "Failed to refresh or re-exchange tokens")
						return null
					}
				}
				else
				{
					Log.e(TAG, "No NPSSO token for re-auth")
					return null
				}
			}
		}

		val token = preferences.psnAuthToken.ifEmpty { null }
		Log.i(TAG, "getValidToken: returning token (length=${token?.length ?: 0})")
		return token
	}

	// ================== Private helpers ==================

	// CLIENT_SECRET is same as CLIENT_ID pair from PsnAuthConstants (matching desktop)
	private val CLIENT_SECRET = "mvaiZkRsAsI1IBkY"

	/**
	 * Step 1: GET authorize endpoint with npsso cookie to get auth code via redirect.
	 * Mimics PSNAccountIDV3::GetPsnAccountIdFromNpsso() step 1.
	 */
	private fun getAuthorizationCode(npsso: String, duid: String): String?
	{
		val params = buildString {
			append("client_id=").append(URLEncoder.encode(PsnAuthConstants.CLIENT_ID, "UTF-8"))
			append("&redirect_uri=").append(URLEncoder.encode(PsnAuthConstants.REDIRECT_URI, "UTF-8"))
			append("&scope=").append(URLEncoder.encode(PsnAuthConstants.SCOPES, "UTF-8"))
			append("&response_type=code")
			append("&service_entity=").append(URLEncoder.encode("urn:service-entity:psn", "UTF-8"))
			append("&access_type=offline") // CRITICAL: Requests refresh token!
			append("&duid=").append(URLEncoder.encode(duid, "UTF-8")) // CRITICAL: Required for push notification WebSocket
			append("&smcid=remoteplay")
			append("&layout_type=popup")
			append("&PlatformPrivacyWs1=minimal")
			append("&no_captcha=true")
			append("&cid=").append(UUID.randomUUID().toString())
		}

		val url = URL("${PsnAuthConstants.AUTHORIZE_ENDPOINT_V3}?$params")
		val connection = url.openConnection() as HttpURLConnection
		try
		{
			connection.requestMethod = "GET"
			connection.setRequestProperty("User-Agent", USER_AGENT)
			connection.setRequestProperty("Cookie", "npsso=$npsso")
			connection.instanceFollowRedirects = false // We need to capture the redirect

			val responseCode = connection.responseCode
			Log.d(TAG, "Auth response code: $responseCode")

			// Check for redirect (302)
			if(responseCode == HttpURLConnection.HTTP_MOVED_TEMP || responseCode == HttpURLConnection.HTTP_MOVED_PERM)
			{
				val location = connection.getHeaderField("Location") ?: ""
				return extractCodeFromUrl(location)
			}

			// Some servers return 200 with the redirect in the URL
			val finalUrl = connection.url.toString()
			val code = extractCodeFromUrl(finalUrl)
			if(code != null) return code

			Log.e(TAG, "No redirect or code in auth response (code=$responseCode)")
			return null
		}
		finally
		{
			connection.disconnect()
		}
	}

	private fun extractCodeFromUrl(urlString: String): String?
	{
		val regex = Regex("[?&]code=([^&]+)")
		val match = regex.find(urlString)
		return match?.groupValues?.get(1)
	}

	/**
	 * Step 2: Exchange authorization code for tokens.
	 * Mimics PSNAccountIDV3 token exchange.
	 */
	private fun exchangeCodeForTokens(authCode: String): TokenResponse?
	{
		val body = buildString {
			append("grant_type=authorization_code")
			append("&code=").append(URLEncoder.encode(authCode, "UTF-8"))
			append("&client_id=").append(URLEncoder.encode(PsnAuthConstants.CLIENT_ID, "UTF-8"))
			append("&client_secret=").append(URLEncoder.encode(CLIENT_SECRET, "UTF-8"))
			append("&redirect_uri=").append(URLEncoder.encode(PsnAuthConstants.REDIRECT_URI, "UTF-8"))
			append("&scope=").append(URLEncoder.encode(PsnAuthConstants.SCOPES, "UTF-8"))
		}

		// OAuth v3 doesn't use Basic Auth - credentials go in body
		val response = httpPost(PsnAuthConstants.TOKEN_ENDPOINT_V3, body, null)
		if(response == null)
		{
			Log.e(TAG, "Token exchange request failed")
			return null
		}

		val json = JSONObject(response)
		val accessToken = json.optString("access_token", "")
		val refreshToken = json.optString("refresh_token", "")
		val expiresIn = json.optInt("expires_in", 0)

		if(accessToken.isEmpty())
		{
			Log.e(TAG, "No access token in exchange response: $response")
			return null
		}

		return TokenResponse(accessToken, refreshToken, expiresIn)
	}

	/**
	 * Step 3: Fetch PSN account ID using the v2 token info endpoint.
	 * Mimics PSNAccountIDV3::handleAccountIdResponse().
	 */
	private fun fetchAccountId(accessToken: String): String?
	{
		// Basic auth header for v2 API
		val credentials = "${PsnAuthConstants.CLIENT_ID}:$CLIENT_SECRET"
		val basicAuth = "Basic " + Base64.encodeToString(credentials.toByteArray(), Base64.NO_WRAP)

		val url = URL("$V2_TOKEN_URL/$accessToken")
		val connection = url.openConnection() as HttpURLConnection
		try
		{
			connection.requestMethod = "GET"
			connection.setRequestProperty("Authorization", basicAuth)
			connection.setRequestProperty("Accept", "application/json")

			if(connection.responseCode != HttpURLConnection.HTTP_OK)
			{
				Log.e(TAG, "Account info request failed: ${connection.responseCode}")
				return null
			}

			val response = BufferedReader(InputStreamReader(connection.inputStream)).use { it.readText() }
			val json = JSONObject(response)
			val userId = json.optString("user_id", "")

			if(userId.isEmpty())
			{
				Log.e(TAG, "No user_id in account info response")
				return null
			}

			// Convert user ID to little-endian bytes and base64 encode
			// Mimics PSNAccountIDV3::to_bytes_little_endian()
			val userIdLong = userId.toLong()
			val buffer = ByteBuffer.allocate(8).order(ByteOrder.LITTLE_ENDIAN)
			buffer.putLong(userIdLong)
			return Base64.encodeToString(buffer.array(), Base64.NO_WRAP)
		}
		catch(e: Exception)
		{
			Log.e(TAG, "fetchAccountId failed", e)
			return null
		}
		finally
		{
			connection.disconnect()
		}
	}

	/**
	 * Simple HTTP POST helper.
	 */
	private fun httpPost(urlString: String, body: String, authHeader: String?): String?
	{
		val url = URL(urlString)
		val connection = url.openConnection() as HttpURLConnection
		try
		{
			connection.requestMethod = "POST"
			connection.setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
			connection.setRequestProperty("User-Agent", USER_AGENT)
			if(authHeader != null && authHeader.isNotEmpty())
				connection.setRequestProperty("Authorization", authHeader)
			connection.doOutput = true

			OutputStreamWriter(connection.outputStream).use { writer ->
				writer.write(body)
				writer.flush()
			}

			if(connection.responseCode != HttpURLConnection.HTTP_OK)
			{
				val errorStream = connection.errorStream
				val errorBody = if(errorStream != null)
					BufferedReader(InputStreamReader(errorStream)).use { it.readText() }
				else
					"(no error body)"
				Log.e(TAG, "POST $urlString failed: ${connection.responseCode} - $errorBody")
				return null
			}

			return BufferedReader(InputStreamReader(connection.inputStream)).use { it.readText() }
		}
		finally
		{
			connection.disconnect()
		}
	}

	private data class TokenResponse(
		val accessToken: String,
		val refreshToken: String,
		val expiresIn: Int
	)
}
