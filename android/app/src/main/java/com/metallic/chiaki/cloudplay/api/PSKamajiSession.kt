// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.util.Log
import com.metallic.chiaki.cloudplay.PsnApiConstants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.net.URL

/**
 * PSKamajiSession - Handles PlayStation Cloud Gaming Kamaji Authentication (Steps 1-6)
 * 
 * Kamaji is Sony's authentication layer for cloud gaming. This class:
 * - Creates and manages cookie-based sessions
 * - Handles OAuth2 authorization flow
 * - Integrates with Sony's account system
 * 
 * Mirrors: gui/src/cloudstreaming/pskamajisession.cpp
 */
class PSKamajiSession(
	private val duid: String,
	private val productId: String,
	private val accountBaseUrl: String,
	private val redirectUri: String,
	private val userAgent: String,
	private val preferences: com.metallic.chiaki.common.Preferences
)
{
	companion object
	{
		private const val TAG = "PSKamajiSession"
	}
	
	// Configuration
	private val kamajiBase = PsnApiConstants.KAMAJI_BASE
	private val storeBase = PsnApiConstants.STORE_BASE
	private val commerceBase = PsnApiConstants.COMMERCE_BASE
	private val kamajiClientId = PsnApiConstants.CLIENT_ID
	private var platform = "ps4" // Default, will be detected from API response
	private var scopesStr = PsnApiConstants.PS4_SCOPES // Default to PS4 scopes
	
	// State tracking
	private var anonAuthCode: String? = null      // OAuth code for anonymous session
	private var authorizationCode: String? = null // OAuth code for authenticated session
	private var jsessionId: String? = null        // JSESSIONID from anonymous session
	private var entitlementId: String? = null     // Converted from productId
	private var streamingSku: String? = null      // SKU from product ID conversion
	
	/**
	 * Data class for session result
	 */
	data class SessionResult(
		val success: Boolean,
		val message: String,
		val entitlementId: String = "",
		val platform: String = ""
	)
	
	/**
	 * Start the complete Kamaji session creation flow (Steps 0.5a-0.5d, 5-6)
	 * Mirrors: PSKamajiSession::startSessionCreation()
	 */
	suspend fun startSessionCreation(npssoToken: String): SessionResult = withContext(Dispatchers.IO)
	{
		try
		{
			Log.i(TAG, "=== Starting Kamaji Session Creation ===")
			Log.i(TAG, "Product ID: $productId")
			Log.i(TAG, "DUID: ${duid.take(20)}...")
			
			if (npssoToken.isEmpty())
			{
				return@withContext SessionResult(false, "NPSSO token is empty")
			}
			
			// Step 0.5b: Get Anonymous Auth Code
			val anonCode = step0_5b_GetAnonymousAuthCode(npssoToken)
				?: return@withContext SessionResult(false, "Failed to get anonymous auth code")
			anonAuthCode = anonCode
			Log.i(TAG, "✓ Step 0.5b complete - Got anonymous auth code")
			
			// Step 0.5c: Create Anonymous Session
			val sessionId = step0_5c_CreateAnonymousSession(anonCode)
				?: return@withContext SessionResult(false, "Failed to create anonymous session")
			jsessionId = sessionId
			Log.i(TAG, "✓ Step 0.5c complete - Got JSESSIONID: ${sessionId.take(10)}...")
			
			// Step 0.5d: Convert Product ID to Entitlement ID
			val conversionResult = step0_5d_ConvertProductId(sessionId)
				?: return@withContext SessionResult(false, "Failed to convert product ID")
		entitlementId = conversionResult.first
		platform = conversionResult.second
		streamingSku = conversionResult.third
		Log.i(TAG, "✓ Step 0.5d complete - Entitlement ID: $entitlementId, Platform: $platform")
		
		// Update scopes if PS3
		if (platform == "ps3")
		{
			scopesStr = "kamaji:commerce_native" // PS3_SCOPES
		}
		
		// Step 0.5e: Check and acquire entitlement if needed
		val entitlementCheckResult = step0_5e_CheckAndAcquireEntitlement(npssoToken, sessionId)
		if (!entitlementCheckResult)
		{
			return@withContext SessionResult(false, "Failed to check/acquire entitlement")
		}
		Log.i(TAG, "✓ Step 0.5e complete - Entitlement check/acquisition successful")
		
		// Step 5: Get Auth Code
		val authCode = step5_GetAuthCode(npssoToken)
			?: return@withContext SessionResult(false, "Failed to get auth code")
		authorizationCode = authCode
		Log.i(TAG, "✓ Step 5 complete - Got auth code")
			
			// Step 6: Create Auth Session
			val authSession = step6_CreateAuthSession(authCode)
				?: return@withContext SessionResult(false, "Failed to create authenticated session")
			Log.i(TAG, "✓ Step 6 complete - Authenticated session created")
			
			// Session complete
			Log.i(TAG, "=== Kamaji Session Complete ===")
			Log.i(TAG, "Entitlement ID: $entitlementId")
			Log.i(TAG, "Platform: $platform")
			
			SessionResult(true, "Success", entitlementId!!, platform)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Kamaji session error", e)
			SessionResult(false, "Exception: ${e.message}")
		}
	}
	
	/**
	 * Step 0.5b: Get Anonymous Auth Code
	 * GET /oauth/authorize (for anonymous session code)
	 * Mirrors: PSKamajiSession::step0_5b_GetAnonymousAuthCode()
	 */
	private fun step0_5b_GetAnonymousAuthCode(npssoToken: String): String?
	{
		try
		{
			// Build URL with query parameters (manual encoding)
			val params = listOf(
				"smcid" to "pc:psnow",
				"applicationId" to "psnow",
				"response_type" to "code",
				"scope" to scopesStr,
				"client_id" to kamajiClientId,
				"redirect_uri" to redirectUri,
				"service_entity" to "urn:service-entity:psn",
				"prompt" to "none",
				"renderMode" to "mobilePortrait",
				"hidePageElements" to "forgotPasswordLink",
				"displayFooter" to "none",
				"disableLinks" to "qriocityLink",
				"mid" to "PSNOW",
				"duid" to duid,
				"layout_type" to "popup",
				"service_logo" to "ps",
				"tp_psn" to "true",
				"noEVBlock" to "true"
			)
			
			val query = params.joinToString("&") { (key, value) ->
				"$key=${java.net.URLEncoder.encode(value, "UTF-8")}"
			}
			
			val url = "$accountBaseUrl/v1/oauth/authorize?$query"
			
			Log.d(TAG, "Step 0.5b: GET /oauth/authorize (anonymous)")
			Log.d(TAG, "URL: $url")
			
			val headers = mapOf(
				"User-Agent" to userAgent,
				"Cookie" to "npsso=$npssoToken"
			)
			
			val response = HttpClient.get(url, headers, followRedirects = false)
			
			Log.d(TAG, "Step 0.5b Response: ${response.statusCode}")
			
			if (response.statusCode != 302)
			{
				Log.e(TAG, "Expected 302 redirect, got ${response.statusCode}")
				return null
			}
			
			val location = HttpClient.extractLocation(response.headers)
			if (location == null)
			{
				Log.e(TAG, "No Location header in redirect")
				return null
			}
			
			Log.d(TAG, "Redirect location: $location")
			
			val codeRegex = Regex("[?&]code=([^&]+)")
			val match = codeRegex.find(location)
			val code = match?.groupValues?.get(1)
			
			if (code.isNullOrEmpty())
			{
				Log.e(TAG, "No code parameter in redirect URL")
				return null
			}
			
			return code
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0.5b error", e)
			return null
		}
	}
	
	/**
	 * Step 0.5c: Create Anonymous Session
	 * POST /user/session (anonymous, with OAuth code)
	 * Mirrors: PSKamajiSession::step0_5c_CreateAnonymousSession()
	 */
	private fun step0_5c_CreateAnonymousSession(authCode: String): String?
	{
		try
		{
			val url = "$kamajiBase/user/session"
			val body = "code=$authCode&client_id=$kamajiClientId&duid=$duid"
			
			Log.d(TAG, "Step 0.5c: POST /user/session (anonymous)")
			Log.d(TAG, "URL: $url")
			Log.d(TAG, "Body: $body")
			
			val headers = mapOf(
				"Content-Type" to "text/plain;charset=UTF-8",
				"User-Agent" to userAgent,
				"X-Alt-Referer" to redirectUri,
				"Accept" to "*/*",
				"Origin" to PsnApiConstants.ORIGIN,
				"Referer" to PsnApiConstants.REFERER
			)
			
			val response = HttpClient.post(url, body, headers)
			
		Log.d(TAG, "Step 0.5c Response: ${response.statusCode}")
		Log.d(TAG, "Response body: ${response.body.take(200)}")
		
		if (response.statusCode != 200)
		{
			Log.e(TAG, "Anonymous session failed: ${response.statusCode}")
			return null
		}
		
		// Extract JSESSIONID from Set-Cookie header
		val jsessionId = HttpClient.extractCookie(response.headers, "JSESSIONID")
		if (jsessionId.isNullOrEmpty())
		{
			Log.e(TAG, "No JSESSIONID in response")
			return null
		}
		
		// Save country and language from session response to settings (Qt CloudCatalogBackend lines 432-440)
		try
		{
			val json = JSONObject(response.body)
			val data = json.optJSONObject("data")
			if (data != null)
			{
				val sessionCountry = data.optString("country")
				val sessionLanguage = data.optString("language")
				
				if (!sessionCountry.isNullOrEmpty() && !sessionLanguage.isNullOrEmpty())
				{
					// Format: language-COUNTRY (e.g., "nl-NL" or "en-US")
					val locale = "$sessionLanguage-${sessionCountry.uppercase()}"
					preferences.setCloudLanguage(locale)
					Log.i(TAG, "Saved locale from session: $locale")
				}
			}
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Could not parse/save locale from session response", e)
		}
		
		return jsessionId
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0.5c error", e)
			return null
		}
	}
	
	/**
	 * Step 0.5d: Convert Product ID
	 * GET /store/api/pcnow/.../container/.../{PRODUCT_ID}
	 * Mirrors: PSKamajiSession::step0_5d_ConvertProductId()
	 * Returns: Triple<EntitlementID, Platform, StreamingSKU>
	 */
	private fun step0_5d_ConvertProductId(sessionId: String): Triple<String, String, String>?
	{
		try
		{
		// Get locale from unified language setting (Qt line 321: GetCloudLanguagePSCloud)
		// Qt uses ONE setting for both PSNow and PSCloud
		val localeSetting = preferences.getCloudLanguage() // Default "en-US"
		val locale = localeSetting.lowercase() // Convert "en-US" to "en-us"
		
		// Extract country and language from locale (e.g., "en-us" -> "US", "en")
		val localeParts = locale.split("-")
		val country = if (localeParts.size > 1) localeParts[1].uppercase() else "US"
		val language = if (localeParts.isNotEmpty()) localeParts[0].lowercase() else "en"
		
		Log.i(TAG, "Using locale from settings: $localeSetting -> country=$country, language=$language")
		
		val url = "$storeBase/container/$country/$language/19/$productId?useOffers=true&gkb=1&gkb2=1"
			
			Log.d(TAG, "Step 0.5d: Convert Product ID")
			Log.d(TAG, "URL: $url")
			
			val headers = mapOf(
				"Accept" to "application/json",
				"User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
			)
			
			val response = HttpClient.get(url, headers)
			
			Log.d(TAG, "Step 0.5d Response: ${response.statusCode}")
			
			if (response.statusCode == 404)
			{
				Log.e(TAG, "Product ID not found (404)")
				return null
			}
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Product lookup failed: ${response.statusCode}")
				return null
			}
			
			val json = JSONObject(response.body)
			
			Log.d(TAG, "Product response JSON: ${response.body.take(500)}...")
			
			// Extract entitlement ID and SKU
			var streamingEntitlementId = ""
			var sku = ""
			var detectedPlatform = "ps4" // Default
			
			// Look for streaming entitlement - check default_sku first, then skus array
			// Streaming entitlements have license_type == 4
			if (json.has("default_sku"))
			{
				val defaultSku = json.getJSONObject("default_sku")
				if (defaultSku.has("entitlements"))
				{
					val entitlements = defaultSku.getJSONArray("entitlements")
					for (i in 0 until entitlements.length())
					{
						val ent = entitlements.getJSONObject(i)
						val licenseType = ent.optInt("license_type", -1)
						
						// Streaming entitlements have license_type == 4
						if (licenseType == 4)
						{
							val entId = ent.optString("id", "")
							if (entId.isNotEmpty())
							{
								streamingEntitlementId = entId
								sku = defaultSku.optString("id", "")
								Log.i(TAG, "Found streaming Entitlement ID from default_sku: $streamingEntitlementId")
								Log.i(TAG, "License Type: $licenseType")
								Log.i(TAG, "SKU: $sku")
								break
							}
						}
					}
				}
			}
			
			// If not found in default_sku, check all SKUs in the skus array
			if (streamingEntitlementId.isEmpty() && json.has("skus"))
			{
				val skus = json.getJSONArray("skus")
				for (i in 0 until skus.length())
				{
					val skuObj = skus.getJSONObject(i)
					if (skuObj.has("entitlements"))
					{
						val entitlements = skuObj.getJSONArray("entitlements")
						for (j in 0 until entitlements.length())
						{
							val ent = entitlements.getJSONObject(j)
							val licenseType = ent.optInt("license_type", -1)
							
							// Streaming entitlements have license_type == 4
							if (licenseType == 4)
							{
								val entId = ent.optString("id", "")
								if (entId.isNotEmpty())
								{
									streamingEntitlementId = entId
									sku = skuObj.optString("id", "")
									Log.i(TAG, "Found streaming Entitlement ID from skus array: $streamingEntitlementId")
									Log.i(TAG, "License Type: $licenseType")
									Log.i(TAG, "SKU: $sku")
									break
								}
							}
						}
					}
					if (streamingEntitlementId.isNotEmpty()) break
				}
			}
			
			// Try to extract platform from playable_platform
			if (json.has("playable_platform"))
			{
				val playablePlatform = json.getJSONArray("playable_platform")
				var hasPS4 = false
				var hasPS3 = false
				for (i in 0 until playablePlatform.length())
				{
					val platformStr = playablePlatform.getString(i)
					if (platformStr.contains("PS4", ignoreCase = true))
					{
						hasPS4 = true
					}
					else if (platformStr.contains("PS3", ignoreCase = true))
					{
						hasPS3 = true
					}
				}
				detectedPlatform = when
				{
					hasPS4 -> "ps4"
					hasPS3 -> "ps3"
					else -> "ps4"
				}
				Log.i(TAG, "Detected platform from playable_platform: $detectedPlatform")
			}
			else if (json.has("metadata"))
			{
				val metadata = json.getJSONObject("metadata")
				if (metadata.has("playable_platform"))
				{
					val playablePlatformObj = metadata.getJSONObject("playable_platform")
					if (playablePlatformObj.has("values"))
					{
						val values = playablePlatformObj.getJSONArray("values")
						var hasPS4 = false
						var hasPS3 = false
						for (i in 0 until values.length())
						{
							val platformStr = values.getString(i)
							if (platformStr.contains("PS4", ignoreCase = true)) hasPS4 = true
							else if (platformStr.contains("PS3", ignoreCase = true)) hasPS3 = true
						}
						detectedPlatform = when
						{
							hasPS4 -> "ps4"
							hasPS3 -> "ps3"
							else -> "ps4"
						}
					}
				}
			}
			
			if (streamingEntitlementId.isEmpty())
			{
				Log.e(TAG, "Could not determine Entitlement ID from Product ID '$productId'. Game may not be available for cloud streaming.")
				return null
			}
			
			Log.i(TAG, "Converted Product ID: $productId -> Entitlement: $streamingEntitlementId, Platform: $detectedPlatform")
			
			return Triple(streamingEntitlementId, detectedPlatform, sku)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0.5d error", e)
			return null
		}
	}
	
	// ============================================================================
	// Step 0.5e: Check and Acquire Entitlement (entitlement_check.py flow)
	// ============================================================================
	
	private var commerceOAuthToken: String? = null
	
	/**
	 * Step 0.5e: Check and acquire entitlement if needed
	 * Mirrors: PSKamajiSession::step0_5e_CheckEntitlement()
	 */
	private fun step0_5e_CheckAndAcquireEntitlement(npssoToken: String, sessionId: String): Boolean
	{
		try
		{
			Log.i(TAG, "Kamaji Step 0.5e: Starting entitlement check/acquisition flow")
			Log.i(TAG, "  Entitlement ID: $entitlementId")
			if (!streamingSku.isNullOrEmpty())
			{
				Log.i(TAG, "  SKU: $streamingSku")
			}
			
			// Step 0.5e.1: Get Commerce OAuth token
			val commerceToken = step0_5e1_GetCommerceOAuthToken(npssoToken)
				?: return false
			commerceOAuthToken = commerceToken
			Log.i(TAG, "✓ Step 0.5e.1 complete - Got Commerce OAuth token")
			
			// Step 0.5e.2: Check if entitlement exists
			val hasEntitlement = step0_5e2_CheckEntitlementExists()
			if (hasEntitlement == null)
			{
				return false // Error occurred
			}
			else if (hasEntitlement)
			{
				// User has entitlement, continue
				Log.i(TAG, "✓ Step 0.5e.2 complete - User has entitlement")
				return true
			}
			
			// User doesn't have entitlement (404), try to acquire it
			Log.i(TAG, "Kamaji Step 0.5e.2 - Entitlement not found (404), will attempt to acquire")
			
			// Step 0.5e.3: Checkout preview
			val previewOk = step0_5e3_CheckoutPreview(sessionId)
			if (!previewOk)
			{
				return false
			}
			Log.i(TAG, "✓ Step 0.5e.3 complete - Game is free, proceeding to checkout")
			
			// Step 0.5e.4: Complete checkout
			val checkoutOk = step0_5e4_CheckoutBuynow(sessionId)
			if (!checkoutOk)
			{
				return false
			}
			Log.i(TAG, "✓ Step 0.5e.4 complete - Entitlement successfully acquired!")
			
			return true
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0.5e error", e)
			return false
		}
	}
	
	/**
	 * Step 0.5e.1: Get Commerce OAuth token
	 * Mirrors: PSKamajiSession::step0_5e_GetCommerceOAuthToken()
	 */
	private fun step0_5e1_GetCommerceOAuthToken(npssoToken: String): String?
	{
		try
		{
			Log.i(TAG, "Kamaji Step 0.5e.1: Getting OAuth token for Commerce API...")
			
			// Build URL - Uses Commerce API client ID and scopes (Qt lines 551-572)
			val params = listOf(
				"smcid" to "pc:psnow",
				"applicationId" to "psnow",
				"response_type" to "token", // Returns access_token in URL fragment, not code
				"scope" to "kamaji:get_internal_entitlements user:account.attributes.validate kamaji:get_privacy_settings user:account.settings.privacy.get kamaji:s2s.subscriptionsPremium.get",
				"client_id" to "dc523cc2-b51b-4190-bff0-3397c06871b3", // Commerce API client ID
				"redirect_uri" to redirectUri,
				"grant_type" to "authorization_code",
				"service_entity" to "urn:service-entity:psn",
				"prompt" to "none",
				"renderMode" to "mobilePortrait",
				"hidePageElements" to "forgotPasswordLink",
				"displayFooter" to "none",
				"disableLinks" to "qriocityLink",
				"mid" to "PSNOW",
				"duid" to duid,
				"layout_type" to "popup",
				"service_logo" to "ps",
				"tp_psn" to "true",
				"noEVBlock" to "true"
			)
			
			val queryString = params.joinToString("&") { (k, v) ->
				"$k=${java.net.URLEncoder.encode(v, "UTF-8")}"
			}
			// accountBaseUrl already has "/api", just add "/v1/oauth/authorize"
			val url = "${accountBaseUrl}/v1/oauth/authorize?$queryString"
			
			Log.d(TAG, "Step 0.5e.1: GET /oauth/authorize (commerce)")
			Log.d(TAG, "URL: $url")
			
			val response = HttpClient.get(
				url,
				headers = mapOf(
					"User-Agent" to userAgent,
					"Cookie" to "npsso=$npssoToken" // Only NPSSO, NOT JSESSIONID
				),
				followRedirects = false
			)
			
			Log.d(TAG, "Step 0.5e.1 Response: ${response.statusCode}")
			
			if (response.statusCode != 302)
			{
				Log.e(TAG, "Step 0.5e.1 failed: expected 302, got ${response.statusCode}")
				return null
			}
			
			// Extract access_token from redirect URL fragment (#access_token=...)
			val location = response.headers["Location"]?.firstOrNull()
				?: response.headers["location"]?.firstOrNull()
			
			if (location == null)
			{
				Log.e(TAG, "Step 0.5e.1: No Location header in redirect")
				return null
			}
			
			Log.d(TAG, "Redirect location: $location")
			
			// Extract access_token from URL fragment (Qt lines 625-633)
			// Try fragment first (#access_token=...)
			var tokenMatch = Regex("#access_token=([^&]+)").find(location)
			if (tokenMatch == null)
			{
				// Fallback to query string
				tokenMatch = Regex("[?&#]access_token=([^&]+)").find(location)
			}
			
			if (tokenMatch == null)
			{
				Log.e(TAG, "Could not extract access_token from redirect URL")
				Log.e(TAG, "Redirect URL: $location")
				return null
			}
			
			val accessToken = tokenMatch.groupValues[1]
			Log.i(TAG, "✓ Step 0.5e.1 complete - Got Commerce OAuth token: ${accessToken.take(30)}...")
			
			return accessToken
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0.5e.1 error", e)
			return null
		}
	}
	
	/**
	 * Step 0.5e.2: Check if entitlement exists
	 * Mirrors: PSKamajiSession::step0_5e_CheckEntitlementExists()
	 * Returns: true if exists, false if doesn't exist (404), null on error
	 */
	private fun step0_5e2_CheckEntitlementExists(): Boolean?
	{
		try
		{
		Log.i(TAG, "Kamaji Step 0.5e.2: Checking if entitlement exists...")
		
		val url = "$commerceBase/users/me/internal_entitlements/$entitlementId?fields=game_meta"
			
			val response = HttpClient.get(
				url,
				headers = mapOf(
					"Authorization" to "Bearer $commerceOAuthToken",
					"User-Agent" to userAgent,
					"Accept" to "application/json"
				)
			)
			
			Log.d(TAG, "Step 0.5e.2 Response: ${response.statusCode}")
			
			if (response.statusCode == 200)
			{
				// User has entitlement
				try
				{
					val json = JSONObject(response.body)
					val gameMeta = json.optJSONObject("game_meta")
					val gameName = gameMeta?.optString("name")
					if (gameName != null)
					{
						Log.i(TAG, "  Game Name: $gameName")
					}
				}
				catch (e: Exception)
				{
					Log.w(TAG, "Could not parse game meta", e)
				}
				
				return true
			}
			else if (response.statusCode == 404)
			{
				// User doesn't have entitlement
				return false
			}
			else
			{
				Log.e(TAG, "Step 0.5e.2 failed: ${response.statusCode}")
				Log.e(TAG, "Response body: ${response.body}")
				return null
			}
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0.5e.2 error", e)
			return null
		}
	}
	
	/**
	 * Step 0.5e.3: Checkout preview (verify game is free/available)
	 * Mirrors: PSKamajiSession::step0_5e_CheckoutPreview()
	 */
	private fun step0_5e3_CheckoutPreview(sessionId: String): Boolean
	{
		try
		{
		Log.i(TAG, "Kamaji Step 0.5e.3: Checking checkout preview...")
		
		if (streamingSku.isNullOrEmpty())
		{
			Log.w(TAG, "No SKU available for checkout preview, using entitlement ID")
			streamingSku = entitlementId
		}
		
		val url = "$kamajiBase/user/checkout/buynow/preview"
			
			// Build form data
			val formData = "sku=$streamingSku"
			
			val response = HttpClient.post(
				url,
				body = formData,
				headers = mapOf(
					"Content-Type" to "application/x-www-form-urlencoded",
					"User-Agent" to userAgent,
					"Accept" to "application/json",
					"Authorization" to "Bearer $commerceOAuthToken",
					"Sec-Fetch-Site" to "same-origin",
					"Sec-Fetch-Mode" to "cors",
					"Sec-Fetch-Dest" to "empty",
					"Referer" to "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/",
					"Accept-Encoding" to "identity",
					"Accept-Language" to "en-US",
					"Cookie" to "JSESSIONID=$sessionId"
				)
			)
			
			Log.d(TAG, "Step 0.5e.3 Response: ${response.statusCode}")
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 0.5e.3 failed: ${response.statusCode}")
				Log.e(TAG, "Response body: ${response.body}")
				return false
			}
			
			// Parse response
			try
			{
				val json = JSONObject(response.body)
				val header = json.getJSONObject("header")
				val statusCode = header.optString("status_code")
				
				if (statusCode != "0x0000")
				{
					Log.e(TAG, "Preview failed with status: $statusCode")
					return false
				}
				
			val data = json.getJSONObject("data")
			// Qt lines 988-991: Parse cart.total_price_value (integer)
			val cart = data.getJSONObject("cart")
			val totalPriceValue = cart.optInt("total_price_value")
			val totalPrice = cart.optString("total_price")
			
			Log.i(TAG, "  Total Price Value: $totalPriceValue")
			Log.i(TAG, "  Total Price: $totalPrice")
			
			if (totalPriceValue != 0)
			{
				Log.e(TAG, "Game is not free! Price: $totalPrice")
				return false
			}
				
			// Extract actual SKU from response (Qt lines 1002-1009: cart.items[0].sku_id)
			val items = cart.optJSONArray("items")
			if (items != null && items.length() > 0)
			{
				val firstItem = items.getJSONObject(0)
				val actualSku = firstItem.optString("sku_id")
				if (!actualSku.isNullOrEmpty() && actualSku != streamingSku)
				{
					Log.i(TAG, "Using SKU from preview response: $actualSku")
					streamingSku = actualSku
				}
			}
				
				return true
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Failed to parse preview response", e)
				return false
			}
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0.5e.3 error", e)
			return false
		}
	}
	
	/**
	 * Step 0.5e.4: Complete checkout to acquire entitlement
	 * Mirrors: PSKamajiSession::step0_5e_CheckoutBuynow()
	 */
	private fun step0_5e4_CheckoutBuynow(sessionId: String): Boolean
	{
		try
		{
		Log.i(TAG, "Kamaji Step 0.5e.4: Completing checkout to acquire entitlement...")
		
		val url = "$kamajiBase/user/checkout/buynow"
			
			// Build form data
			val formData = "sku=$streamingSku"
			
			val response = HttpClient.post(
				url,
				body = formData,
				headers = mapOf(
					"Content-Type" to "application/x-www-form-urlencoded",
					"User-Agent" to userAgent,
					"Accept" to "application/json",
					"Authorization" to "Bearer $commerceOAuthToken",
					"Cookie" to "JSESSIONID=$sessionId"
				)
			)
			
			Log.d(TAG, "Step 0.5e.4 Response: ${response.statusCode}")
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 0.5e.4 failed: ${response.statusCode}")
				Log.e(TAG, "Response body: ${response.body}")
				return false
			}
			
			// Parse response
			try
			{
				val json = JSONObject(response.body)
				val header = json.getJSONObject("header")
				val statusCode = header.optString("status_code")
				
				if (statusCode != "0x0000")
				{
					Log.e(TAG, "Checkout failed with status: $statusCode")
					val messageKey = header.optString("message_key")
					Log.e(TAG, "Message: $messageKey")
					return false
				}
				
				val data = json.getJSONObject("data")
				val transactionId = data.optString("transaction_id")
				
				Log.i(TAG, "  Transaction ID: $transactionId")
				
				return true
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Failed to parse buynow response", e)
				return false
			}
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0.5e.4 error", e)
			return false
		}
	}
	
	/**
	 * Step 5: Get Auth Code
	 * GET /oauth/authorize (for authenticated session code)
	 * Mirrors: PSKamajiSession::step5_GetAuthCode()
	 */
	private fun step5_GetAuthCode(npssoToken: String): String?
	{
		// Same as step0_5b but for authenticated session
		return step0_5b_GetAnonymousAuthCode(npssoToken)
	}
	
	/**
	 * Step 6: Create Auth Session
	 * POST /user/session (authenticated, with OAuth code)
	 * Mirrors: PSKamajiSession::step6_CreateAuthSession()
	 */
	private fun step6_CreateAuthSession(authCode: String): String?
	{
		// Same as step0_5c but using the authenticated auth code
		return step0_5c_CreateAnonymousSession(authCode)
	}
}
