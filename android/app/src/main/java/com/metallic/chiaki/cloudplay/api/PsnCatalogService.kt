// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.util.Log
import com.metallic.chiaki.cloudplay.DuidUtil
import com.metallic.chiaki.cloudplay.PsnApiConstants
import com.metallic.chiaki.cloudplay.model.CloudGame
import com.metallic.chiaki.cloudplay.model.PsnResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject

/**
 * PSN Catalog Service
 * Implements the complete PSNow catalog fetch flow matching Qt implementation
 */
class PsnCatalogService(
	private val preferences: com.metallic.chiaki.common.Preferences
)
{
	companion object
	{
		private const val TAG = "PsnCatalogService"
		private val CATEGORY_PATTERNS = listOf(
			"A - B", "C - D", "E - G", "H - L", "M - O", "P - R", "S", "T", "U - Z"
		)
		private var gameLogCounter = 0
	}
	
	private var jsessionId: String? = null
	private var baseUrl: String? = null
	private var country: String? = null
	private var language: String? = null
	private val duid = DuidUtil.generateDuid()
	
	/**
	 * Fetch PSNow catalog with complete authentication flow
	 * Matches: CloudCatalogBackend::fetchPsnowCatalog()
	 */
	suspend fun fetchPsnowCatalog(npssoToken: String): PsnResult<List<CloudGame>> = withContext(Dispatchers.IO)
	{
		try
		{
			gameLogCounter = 0 // Reset counter for new catalog fetch
			Log.i(TAG, "=== Starting PSNow Catalog Fetch ===")
			
			// Step 1: OAuth authentication
			val oauthCode = fetchOAuthCode(npssoToken)
				?: return@withContext PsnResult.Error("OAuth authentication failed")
			
			// Step 2: Create Kamaji session
			val sessionId = createKamajiSession(oauthCode)
				?: return@withContext PsnResult.Error("Failed to create Kamaji session")
			
			jsessionId = sessionId
			
			// Step 3: Fetch stores to get base URL
			val storesBaseUrl = fetchStores()
				?: return@withContext PsnResult.Error("Failed to fetch stores")
			
			baseUrl = storesBaseUrl
			
			// Step 4: Fetch root container to get category links
			val categoryUrls = fetchRootContainer()
				?: return@withContext PsnResult.Error("Failed to fetch root container")
			
			// Step 5: Fetch all category pages
			val allGames = mutableListOf<CloudGame>()
			for ((categoryName, categoryUrl) in categoryUrls)
			{
				Log.i(TAG, "Fetching category: $categoryName")
				val games = fetchCategoryGames(categoryUrl)
				allGames.addAll(games)
			}
			
			Log.i(TAG, "=== PSNow Catalog Fetch Complete: ${allGames.size} games ===")
			PsnResult.Success(allGames)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Error fetching PSNow catalog", e)
			PsnResult.Error("Failed to fetch catalog: ${e.message}", e)
		}
	}
	
	/**
	 * Step 1: OAuth authentication with NPSSO token
	 * Matches: CloudCatalogBackend::fetchPsnowOAuthToken()
	 */
	private fun fetchOAuthCode(npssoToken: String): String?
	{
		try
		{
			// Build URL with proper encoding using Uri.Builder (matches Qt's QUrlQuery)
			val uri = android.net.Uri.parse("${PsnApiConstants.ACCOUNT_BASE}/v1/oauth/authorize")
				.buildUpon()
				.appendQueryParameter("smcid", "pc:psnow")
				.appendQueryParameter("applicationId", "psnow")
				.appendQueryParameter("response_type", "code")
				.appendQueryParameter("scope", PsnApiConstants.PS4_SCOPES)
				.appendQueryParameter("client_id", PsnApiConstants.CLIENT_ID)
				.appendQueryParameter("redirect_uri", PsnApiConstants.REDIRECT_URI)
				.appendQueryParameter("service_entity", "urn:service-entity:psn")
				.appendQueryParameter("prompt", "none")
				.appendQueryParameter("renderMode", "mobilePortrait")
				.appendQueryParameter("hidePageElements", "forgotPasswordLink")
				.appendQueryParameter("displayFooter", "none")
				.appendQueryParameter("disableLinks", "qriocityLink")
				.appendQueryParameter("mid", "PSNOW")
				.appendQueryParameter("duid", duid)
				.appendQueryParameter("layout_type", "popup")
				.appendQueryParameter("service_logo", "ps")
				.appendQueryParameter("tp_psn", "true")
				.appendQueryParameter("noEVBlock", "true")
				.build()
			
			val url = uri.toString()
			
			Log.d(TAG, "OAuth request URL: $url")
			
			val headers = mapOf(
				"Cookie" to "npsso=$npssoToken"
			)
			
			val response = HttpClient.get(url, headers, followRedirects = false)
			
			Log.d(TAG, "OAuth response status: ${response.statusCode}")
			
			if (response.statusCode != 302)
			{
				Log.e(TAG, "OAuth failed: expected 302, got ${response.statusCode}")
				Log.e(TAG, "Response body: ${response.body}")
				return null
			}
			
			// Extract code from Location header
			val location = HttpClient.extractLocation(response.headers)
			if (location == null)
			{
				Log.e(TAG, "No Location header in OAuth response")
				return null
			}
			
			Log.d(TAG, "OAuth redirect location: $location")
			
			val codeRegex = Regex("[?&]code=([^&]+)")
			val match = codeRegex.find(location)
			val code = match?.groupValues?.get(1)
			
			if (code.isNullOrEmpty())
			{
				Log.e(TAG, "No OAuth code in redirect location")
				return null
			}
			
			Log.i(TAG, "[PSNOW] Got OAuth code, creating session...")
			return code
		}
		catch (e: Exception)
		{
			Log.e(TAG, "OAuth error", e)
			return null
		}
	}
	
	/**
	 * Step 2: Create Kamaji session
	 * Matches: CloudCatalogBackend::fetchPsnowSession()
	 */
	private fun createKamajiSession(oauthCode: String): String?
	{
		try
		{
			val url = "${PsnApiConstants.KAMAJI_BASE}/user/session"
			val body = "code=$oauthCode&client_id=${PsnApiConstants.CLIENT_ID}&duid=$duid"
			
			Log.i(TAG, "=== Creating Kamaji Session ===")
			Log.d(TAG, "POST $url")
			Log.d(TAG, "Body: $body")
			
			val headers = mapOf(
				"Content-Type" to "text/plain;charset=UTF-8",
				"X-Alt-Referer" to PsnApiConstants.REDIRECT_URI,
				"Origin" to PsnApiConstants.ORIGIN,
				"Referer" to PsnApiConstants.REFERER,
				"Accept" to "*/*"
			)
			
			val response = HttpClient.post(url, body, headers)
			
			Log.i(TAG, "=== Session Response ===")
			Log.d(TAG, "Status: ${response.statusCode}")
			Log.d(TAG, "Body: ${response.body}")
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Session creation failed: ${response.statusCode}")
				return null
			}
			
			// Parse JSON response
			val json = JSONObject(response.body)
			val header = json.optJSONObject("header")
			val data = json.optJSONObject("data")
			
			if (header?.optString("status_code") != "0x0000")
			{
				Log.e(TAG, "Session failed with status: ${header?.optString("status_code")}")
				return null
			}
			
		// Extract country and language from session data (Qt lines 432-433)
		val sessionCountry = data?.optString("country")
		val sessionLanguage = data?.optString("language")
		
		country = sessionCountry
		language = sessionLanguage
		
		// Save country and language to settings as locale (Qt lines 435-440)
		if (!sessionCountry.isNullOrEmpty() && !sessionLanguage.isNullOrEmpty())
		{
			// Format: language-COUNTRY (e.g., "nl-NL" or "en-US")
			val locale = "$sessionLanguage-${sessionCountry.uppercase()}"
			preferences.setCloudLanguage(locale)
			Log.i(TAG, "[PSNOW] Saved locale from session: $locale")
		}
		
		Log.i(TAG, "Extracted from session - country: $country, language: $language")
			
			// Extract JSESSIONID from Set-Cookie
			val sessionId = HttpClient.extractCookie(response.headers, "JSESSIONID")
			if (sessionId.isNullOrEmpty())
			{
				Log.e(TAG, "No JSESSIONID in session response")
				return null
			}
			
			Log.i(TAG, "[PSNOW] Session created successfully, JSESSIONID: ${sessionId.take(10)}...")
			return sessionId
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Session creation error", e)
			return null
		}
	}
	
	/**
	 * Step 3: Fetch stores to get base URL
	 * Matches: CloudCatalogBackend::fetchPsnowStores()
	 */
	private fun fetchStores(): String?
	{
		try
		{
			val url = "${PsnApiConstants.KAMAJI_BASE}/user/stores"
			
			Log.i(TAG, "=== Fetching Stores ===")
			Log.d(TAG, "GET $url")
			Log.d(TAG, "Using JSESSIONID: ${jsessionId?.take(10)}...")
			
			val headers = mapOf(
				"Cookie" to "JSESSIONID=$jsessionId",
				"Origin" to PsnApiConstants.ORIGIN,
				"Referer" to PsnApiConstants.REFERER,
				"Accept" to "application/json"
			)
			
			val response = HttpClient.get(url, headers)
			
			Log.i(TAG, "=== Stores Response ===")
			Log.d(TAG, "Status: ${response.statusCode}")
			Log.d(TAG, "Full Body: ${response.body}")
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Stores fetch failed: ${response.statusCode}")
				return null
			}
			
			// Parse JSON - match Qt structure: {header: {...}, data: {base_url: "..."}}
			val json = JSONObject(response.body)
			val header = json.optJSONObject("header")
			val data = json.optJSONObject("data")
			
			if (header?.optString("status_code") != "0x0000")
			{
				Log.e(TAG, "Stores failed with status: ${header?.optString("status_code")}")
				return null
			}
			
			val baseUrl = data?.optString("base_url")
			
			if (baseUrl.isNullOrEmpty())
			{
				Log.e(TAG, "No base_url in stores response data")
				return null
			}
			
			Log.i(TAG, "[PSNOW] Stores fetched successfully")
			Log.i(TAG, "Base URL from response: $baseUrl")
			return baseUrl
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Stores fetch error", e)
			return null
		}
	}
	
	/**
	 * Step 4: Fetch root container to get category URLs
	 * Matches: CloudCatalogBackend::fetchPsnowRootContainer()
	 */
	private fun fetchRootContainer(): Map<String, String>?
	{
		try
		{
			val url = "$baseUrl?size=100"
			
			Log.i(TAG, "=== Fetching Root Container ===")
			Log.d(TAG, "GET $url")
			
			val headers = mapOf(
				"Cookie" to "JSESSIONID=$jsessionId",
				"Origin" to PsnApiConstants.ORIGIN,
				"Referer" to PsnApiConstants.REFERER,
				"Accept" to "application/json"
			)
			
			val response = HttpClient.get(url, headers)
			
			Log.i(TAG, "=== Root Container Response ===")
			Log.d(TAG, "Status: ${response.statusCode}")
			Log.d(TAG, "Full Body: ${response.body}")
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Root container fetch failed: ${response.statusCode}")
				return null
			}
			
			// Parse JSON
			val json = JSONObject(response.body)
			val links = json.optJSONArray("links")
			
			if (links == null)
			{
				Log.e(TAG, "No 'links' array in root container response")
				Log.d(TAG, "Available keys: ${json.keys().asSequence().toList()}")
				return null
			}
			
			Log.d(TAG, "Found ${links.length()} total links in response")
			
			// Extract category URLs matching the patterns
			val categoryUrls = mutableMapOf<String, String>()
			
			for (i in 0 until links.length())
			{
				val link = links.optJSONObject(i) ?: continue
				val name = link.optString("name")
				val url = link.optString("url")  // Field is "url", not "href"
				
				Log.d(TAG, "Link $i: name='$name', url='$url'")
				
				if (CATEGORY_PATTERNS.contains(name) && url.isNotEmpty())
				{
					categoryUrls[name] = url
					Log.i(TAG, "✓ Matched category: $name -> $url")
				}
			}
			
			Log.i(TAG, "[PSNOW] Found ${categoryUrls.size} matching categories out of ${links.length()} total links")
			return categoryUrls
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Root container fetch error", e)
			return null
		}
	}
	
	/**
	 * Step 5: Fetch games from a category
	 * Matches: CloudCatalogBackend::fetchPsnowCategory()
	 */
	private fun fetchCategoryGames(categoryUrl: String): List<CloudGame>
	{
		val games = mutableListOf<CloudGame>()
		
		try
		{
			// Add query parameters as Qt does (start=0&size=500)
			val url = if (!categoryUrl.contains("?")) {
				"$categoryUrl?start=0&size=500"
			} else {
				"$categoryUrl&start=0&size=500"
			}
			
			Log.i(TAG, "=== Fetching Category ===")
			Log.d(TAG, "URL: $url")
			
			val headers = mapOf(
				"Accept" to "application/json",
				"User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
			)
			
			val response = HttpClient.get(url, headers)
			
			Log.d(TAG, "Category response status: ${response.statusCode}")
			
			if (response.statusCode != 200)
			{
				Log.w(TAG, "Category fetch failed: ${response.statusCode}")
				return games
			}
			
			// Parse response - look for "links" array (matches Qt implementation)
			val json = JSONObject(response.body)
			val linksArray = json.optJSONArray("links")
			
			if (linksArray != null)
			{
				Log.d(TAG, "Found links array with ${linksArray.length()} items")
				
				for (i in 0 until linksArray.length())
				{
					val gameObj = linksArray.optJSONObject(i) ?: continue
					val game = parseGameObject(gameObj)
					if (game != null)
					{
						games.add(game)
						if (i < 3) // Log first 3 games
						{
							Log.d(TAG, "Parsed game: ${game.name} (${game.productId})")
						}
					}
				}
				Log.i(TAG, "Category complete: ${games.size} games")
			}
			else
			{
				Log.w(TAG, "No 'links' array in category response")
				Log.d(TAG, "Available keys: ${json.keys().asSequence().toList()}")
			}
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Error fetching category", e)
		}
		
		return games
	}
	
	/**
	 * Parse game object from API response
	 * Matches: CloudCatalogBackend::handlePsnowCategoryPageResponse()
	 */
	private fun parseGameObject(gameObj: JSONObject): CloudGame?
	{
		try
		{
			// Qt uses "id" field, not "product_id"
			val productId = gameObj.optString("id")
			val name = gameObj.optString("name")
			
			if (productId.isEmpty() || name.isEmpty())
				return null
			
			// Extract both cover and landscape image URLs
			val (coverUrl, landscapeUrl) = extractImageUrls(gameObj)
			
			// Fix: Replace HTTP with HTTPS to avoid Android cleartext traffic issues
			var imageUrl = coverUrl
			var landscapeImageUrl = landscapeUrl
			if (imageUrl.startsWith("http://"))
			{
				imageUrl = imageUrl.replace("http://", "https://")
				Log.d(TAG, "Converted HTTP to HTTPS for cover: $name")
			}
			if (landscapeImageUrl.startsWith("http://"))
			{
				landscapeImageUrl = landscapeImageUrl.replace("http://", "https://")
				Log.d(TAG, "Converted HTTP to HTTPS for landscape: $name")
			}
			
			// Determine platform - matches Qt CloudGameCard.qml getPlatform() function exactly
			// playable_platform is an array, not a string
			val playablePlatformArray = gameObj.optJSONArray("playable_platform")
			val platform = if (playablePlatformArray != null && playablePlatformArray.length() > 0) {
				// Check each platform in the array (matches Qt: for (let i = 0; i < platformArray.length; i++))
				var foundPlatform = "ps4" // Default to PS4
				for (i in 0 until playablePlatformArray.length()) {
					val platformStr = playablePlatformArray.optString(i, "").uppercase()
					// Qt checks: platform.indexOf("PS3") !== -1 and platform.indexOf("PS4") !== -1
					if (platformStr.contains("PS3")) {
						foundPlatform = "ps3"
						break // Qt returns immediately on PS3 match
					}
					if (platformStr.contains("PS4")) {
						foundPlatform = "ps4"
					}
				}
				foundPlatform
			} else {
				// Default to PS4 if playable_platform is missing or empty (matches Qt)
				"ps4"
			}
			
			return CloudGame(
				productId = productId,
				name = name,
				imageUrl = imageUrl,
				landscapeImageUrl = landscapeImageUrl,
				platform = platform
			)
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Error parsing game object", e)
			return null
		}
	}
	
	/**
	 * Extract image URL from game object
	 * Matches: CloudCatalogBackend::extractCoverImageFromGameObject()
	 */
	/**
	 * Extract both cover and landscape image URLs from game object
	 * Returns Pair<coverUrl, landscapeUrl>
	 */
	private fun extractImageUrls(gameObj: JSONObject): Pair<String, String>
	{
		val gameName = gameObj.optString("name", "Unknown")
		var coverUrl = ""
		var landscapeUrl = ""
		
		// Check for images array in the game object (matches Qt implementation)
		val images = gameObj.optJSONArray("images")
		if (images != null && images.length() > 0)
		{
			// Log available image types for debugging
			val availableTypes = mutableListOf<Int>()
			for (i in 0 until images.length())
			{
				val img = images.optJSONObject(i) ?: continue
				val type = img.optInt("type", -1)
				availableTypes.add(type)
				val url = img.optString("url")
				
				if (url.isEmpty()) continue
				
				// Type 10 = cover/box art
				if (type == 10 && coverUrl.isEmpty())
				{
					coverUrl = url
					Log.d(TAG, "Found type 10 (cover) image for: $gameName")
				}
				// Type 12 = landscape 1080p (preferred for landscape)
				else if (type == 12 && landscapeUrl.isEmpty())
				{
					landscapeUrl = url
					Log.d(TAG, "Found type 12 (landscape 1080p) image for: $gameName")
				}
				// Type 13 = landscape 720p (fallback for landscape)
				else if (type == 13 && landscapeUrl.isEmpty())
				{
					landscapeUrl = url
					Log.d(TAG, "Found type 13 (landscape 720p) image for: $gameName")
				}
			}
			
			// If no landscape found, try type 12 again (might have been found after type 13)
			if (landscapeUrl.isEmpty())
			{
				for (i in 0 until images.length())
				{
					val img = images.optJSONObject(i) ?: continue
					val type = img.optInt("type", -1)
					val url = img.optString("url")
					if (type == 12 && url.isNotEmpty())
					{
						landscapeUrl = url
						Log.d(TAG, "Found type 12 (landscape 1080p) image for: $gameName (second pass)")
						break
					}
				}
			}
			
			// Fallback: use cover for landscape if no landscape found
			if (landscapeUrl.isEmpty() && coverUrl.isNotEmpty())
			{
				landscapeUrl = coverUrl
				Log.d(TAG, "Using cover image as landscape fallback for: $gameName")
			}
			
			// Fallback: use landscape for cover if no cover found
			if (coverUrl.isEmpty() && landscapeUrl.isNotEmpty())
			{
				coverUrl = landscapeUrl
				Log.d(TAG, "Using landscape image as cover fallback for: $gameName")
			}
			
			if (coverUrl.isEmpty() && landscapeUrl.isEmpty())
			{
				Log.w(TAG, "No type 10/12/13 images for '$gameName', available types: $availableTypes")
			}
		}
		else
		{
			Log.w(TAG, "No images array for: $gameName")
		}
		
		// Check for direct imageUrl field as fallback
		if (coverUrl.isEmpty() && gameObj.has("imageUrl"))
		{
			val imageUrl = gameObj.optString("imageUrl")
			if (imageUrl.isNotEmpty())
			{
				coverUrl = imageUrl
				landscapeUrl = imageUrl
				Log.d(TAG, "Using direct imageUrl for both cover and landscape: $gameName")
			}
		}
		
		if (coverUrl.isEmpty() && landscapeUrl.isEmpty())
		{
			Log.w(TAG, "NO IMAGE FOUND for: $gameName")
		}
		
		return Pair(coverUrl, landscapeUrl)
	}
}

