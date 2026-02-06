// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.util.Log
import com.metallic.chiaki.cloudplay.PsnApiConstants
import com.metallic.chiaki.cloudplay.model.CloudGame
import org.json.JSONArray
import org.json.JSONObject

/**
 * PsCloudCatalogService - Handles PS5 Cloud Gaming catalog fetching
 * 
 * This service fetches PS5 cloud gaming catalogs:
 * - Public catalog of all streamable PS5 games
 * - User's owned PS5 games library
 * 
 * Mirrors: gui/src/cloudcatalogbackend.cpp (PS5 catalog functions)
 */
class PsCloudCatalogService
{
	companion object
	{
		private const val TAG = "PsCloudCatalogService"
		private const val ACCOUNT_BASE = "https://ca.account.sony.com/api"
	}
	
	/**
	 * Fetch PS5 Cloud Catalog (public list of all streamable PS5 games)
	 * Mirrors: CloudCatalogBackend::fetchPs5CloudCatalog() (Qt lines 844-973)
	 * 
	 * @param locale Language locale (e.g., "en-us", "ja-jp")
	 * @return List of CloudGame objects
	 */
	suspend fun fetchPs5CloudCatalog(locale: String): List<CloudGame>
	{
		Log.i(TAG, "=== Fetching PS5 Cloud Catalog ===")
		Log.i(TAG, "  Locale: $locale")
		
		val url = "https://www.playstation.com/bin/imagic/gameslist?locale=$locale&categoryList=all-ps5-list"
		
		val response = HttpClient.get(
			url = url,
			headers = mapOf(
				"Content-Type" to "application/json",
				"Accept" to "application/json",
				"User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
			)
		)
		
		if (response.statusCode != 200)
		{
			Log.e(TAG, "PS5 catalog fetch error: ${response.statusCode}")
			Log.e(TAG, "Response: ${response.body}")
			throw Exception("Failed to fetch PS5 catalog: HTTP ${response.statusCode}")
		}
		
		val jsonArray = JSONArray(response.body)
		Log.i(TAG, "  Received ${jsonArray.length()} categories")
		
		// Flatten all games from all categories and filter for streaming support (Qt lines 907-938)
		val allGames = mutableListOf<CloudGame>()
		var totalGames = 0
		var streamingGames = 0
		
		for (i in 0 until jsonArray.length())
		{
			val category = jsonArray.getJSONObject(i)
			val games = category.optJSONArray("games") ?: continue
			
			totalGames += games.length()
			
			for (j in 0 until games.length())
			{
				val gameObj = games.getJSONObject(j)
				
				// Filter for streamingSupported: true (Qt lines 923)
				if (gameObj.optBoolean("streamingSupported", false))
				{
				streamingGames++
				
				val productId = gameObj.optString("productId", "")
				val gameName = gameObj.optString("name", "Unknown")  // PS5 catalog uses "name", not "title"
				var imageUrl = gameObj.optString("imageUrl", "")
				
				// Extract conceptUrl (for adding game to library)
				// Try multiple possible field names
				var conceptUrl = gameObj.optString("conceptUrl", "")
				if (conceptUrl.isEmpty())
				{
					conceptUrl = gameObj.optString("concept_url", "")
				}
				if (conceptUrl.isEmpty())
				{
					conceptUrl = gameObj.optString("url", "")
				}
				if (conceptUrl.isEmpty())
				{
					conceptUrl = gameObj.optString("storeUrl", "")
				}
				if (conceptUrl.isEmpty())
				{
					conceptUrl = gameObj.optString("psStoreUrl", "")
				}
				if (conceptUrl.isEmpty())
				{
					conceptUrl = gameObj.optString("concept", "")
				}
				
				// Check nested objects (e.g., links, concept object, etc.)
				if (conceptUrl.isEmpty())
				{
					val links = gameObj.optJSONObject("links")
					if (links != null)
					{
						conceptUrl = links.optString("conceptUrl", "")
							?: links.optString("concept_url", "")
							?: links.optString("url", "")
					}
				}
				if (conceptUrl.isEmpty())
				{
					val concept = gameObj.optJSONObject("concept")
					if (concept != null)
					{
						conceptUrl = concept.optString("url", "")
							?: concept.optString("href", "")
					}
				}
				
				// Log available fields for debugging if conceptUrl is missing
				if (conceptUrl.isEmpty() && productId.isNotEmpty())
				{
					val keys = gameObj.keys()
					val keyList = mutableListOf<String>()
					while (keys.hasNext())
					{
						keyList.add(keys.next())
					}
					Log.w(TAG, "Game '${gameName}' (${productId}) - conceptUrl missing. Available fields: ${keyList.joinToString(", ")}")
					// Log all string fields that might contain URLs
					keyList.forEach { key ->
						val value = gameObj.optString(key, "")
						if (value.isNotEmpty() && (value.startsWith("http://") || value.startsWith("https://")))
						{
							Log.d(TAG, "  Found URL field '$key': $value")
						}
					}
				}
				
				// Extract both cover and landscape image URLs
				val (coverUrl, landscapeUrl) = if (imageUrl.isNotEmpty()) {
					// If imageUrl already set, use it for both (fallback)
					Pair(imageUrl, imageUrl)
				} else {
					extractImageUrls(gameObj)
				}
				
				// Convert HTTP to HTTPS for image URLs
				var finalCoverUrl = coverUrl
				var finalLandscapeUrl = landscapeUrl
				if (finalCoverUrl.startsWith("http://"))
				{
					finalCoverUrl = finalCoverUrl.replace("http://", "https://")
				}
				if (finalLandscapeUrl.startsWith("http://"))
				{
					finalLandscapeUrl = finalLandscapeUrl.replace("http://", "https://")
				}
				
				if (productId.isNotEmpty())
				{
					allGames.add(
						CloudGame(
							productId = productId,
							name = gameName,
							imageUrl = finalCoverUrl,
							landscapeImageUrl = finalLandscapeUrl,
							platform = "ps5",
							serviceType = "pscloud",
							conceptUrl = conceptUrl,
							isOwned = false  // Will be set to true during cross-reference
						)
					)
				}
			}
			}
		}
		
		Log.i(TAG, "  Total games: $totalGames")
		Log.i(TAG, "  Streaming-supported games: $streamingGames")
		
		return allGames
	}
	
	/**
	 * Fetch Owned PS5 Games (user's personal library)
	 * Mirrors: CloudCatalogBackend::fetchOwnedPs5Games() (Qt lines 976-1010)
	 * 
	 * @param npssoToken User's NPSSO token
	 * @param locale Language locale
	 * @return List of CloudGame objects that user owns
	 */
	suspend fun fetchOwnedPs5Games(npssoToken: String, locale: String): List<CloudGame>
	{
		if (npssoToken.isEmpty())
		{
			throw Exception("NPSSO token is required for PS5 cloud play. Please login to PSN and enter a valid NPSSO token.")
		}
		
		Log.i(TAG, "=== Fetching Owned PS5 Games ===")
		Log.i(TAG, "  Locale: $locale")
		
		// Step 1: Get OAuth token for entitlements API (Qt lines 1008-1009)
		val oauthToken = fetchOwnedGamesOAuthToken(npssoToken)
		
		// Step 2: Fetch entitlements (Qt lines 1099-1156)
		val entitlements = fetchEntitlements(oauthToken)
		
		// Step 3: Fetch public PS5 catalog for cross-reference (Qt lines 1157-1288)
		val publicCatalog = fetchPs5CloudCatalog(locale)
		
		// Step 4: Cross-reference owned games with catalog (Qt lines 1289-1384)
		val ownedGames = crossReferenceOwnedGames(entitlements, publicCatalog)
		
		Log.i(TAG, "  Owned streaming games: ${ownedGames.size}")
		
		return ownedGames
	}
	
	/**
	 * Fetch OAuth token for entitlements API
	 * Mirrors: CloudCatalogBackend::fetchOwnedGamesOAuthToken() (Qt lines 1012-1056)
	 */
	private suspend fun fetchOwnedGamesOAuthToken(npssoToken: String): String
	{
		Log.i(TAG, "=== Fetching OAuth token for owned games ===")
		
		// Build URL with proper query parameters (Qt lines 1032-1042)
		// IMPORTANT: Use KamajiConsts::REDIRECT_URI (PSNow redirect), not the generic remoteplay one
		val scope = "kamaji:get_internal_entitlements user:account.attributes.validate"
		val redirectUri = PsnApiConstants.REDIRECT_URI // This is the PSNow redirect URI
		
		val url = java.net.URL("$ACCOUNT_BASE/v1/oauth/authorize")
		val query = "response_type=token&scope=${java.net.URLEncoder.encode(scope, "UTF-8")}&client_id=dc523cc2-b51b-4190-bff0-3397c06871b3&redirect_uri=${java.net.URLEncoder.encode(redirectUri, "UTF-8")}&service_entity=urn:service-entity:psn&prompt=none"
		val fullUrl = "$url?$query"
		
		Log.d(TAG, "OAuth URL: $fullUrl")
		
		val response = HttpClient.get(
			url = fullUrl,
			headers = mapOf(
				"Cookie" to "npsso=$npssoToken",
				"User-Agent" to "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
			),
			followRedirects = false
		)
		
		// Should get a 302 redirect with token in Location header (Qt lines 1063-1094)
		if (response.statusCode != 302)
		{
			Log.e(TAG, "OAuth token fetch failed: ${response.statusCode}")
			Log.e(TAG, "Response body: ${response.body}")
			throw Exception("Failed to fetch OAuth token: HTTP ${response.statusCode}")
		}
		
		// Headers come as Map<String, List<String>>, get first element
		val location = (response.headers["Location"]?.firstOrNull() 
			?: response.headers["location"]?.firstOrNull() 
			?: "")
		
		Log.d(TAG, "Redirect Location header: $location")
		
		if (location.isEmpty())
		{
			Log.e(TAG, "No Location header in redirect response")
			Log.e(TAG, "Available headers: ${response.headers.keys}")
			throw Exception("No Location header in OAuth redirect")
		}
		
		// Extract access_token from URL fragment (Qt lines 1076-1094)
		val tokenPattern = Regex("[#&]access_token=([^&]+)")
		val match = tokenPattern.find(location)
		
		if (match == null)
		{
			Log.e(TAG, "Failed to extract access_token from redirect URL: $location")
			throw Exception("Failed to extract OAuth token from response")
		}
		
		val token = match.groupValues[1]
		Log.i(TAG, "✓ OAuth token obtained: ${token.take(20)}...")
		
		return token
	}
	
	/**
	 * Fetch entitlements using OAuth token
	 * Mirrors: CloudCatalogBackend::fetchOwnedGamesPage() (Qt lines 1192-1216)
	 */
	private suspend fun fetchEntitlements(oauthToken: String): List<String>
	{
		Log.i(TAG, "=== Fetching entitlements ===")
		
		// Use the correct commerce API endpoint (Qt line 1194)
		val url = "https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements?fields=game_meta&entitlement_type=5&start=0&size=10000"
		
		Log.d(TAG, "Entitlements URL: $url")
		
		val response = HttpClient.get(
			url = url,
			headers = mapOf(
				"Authorization" to "Bearer $oauthToken",
				"Accept" to "application/json"
			)
		)
		
		if (response.statusCode != 200)
		{
			Log.e(TAG, "Entitlements fetch failed: ${response.statusCode}")
			Log.e(TAG, "Response body: ${response.body}")
			throw Exception("Failed to fetch entitlements: HTTP ${response.statusCode}")
		}
		
		val jsonObj = JSONObject(response.body)
		val entitlementsArray = jsonObj.optJSONArray("entitlements") ?: JSONArray()
		
		val productIds = mutableListOf<String>()
		
		for (i in 0 until entitlementsArray.length())
		{
			val entitlement = entitlementsArray.getJSONObject(i)
			val productId = entitlement.optString("id", "")
			
			if (productId.isNotEmpty())
			{
				productIds.add(productId)
			}
		}
		
		Log.i(TAG, "  Entitlements count: ${productIds.size}")
		
		return productIds
	}
	
	/**
	 * Cross-reference owned entitlements with public catalog
	 * Mirrors: CloudCatalogBackend::processCrossReferenceComplete() (Qt lines 1289-1384)
	 */
	private fun crossReferenceOwnedGames(entitlements: List<String>, publicCatalog: List<CloudGame>): List<CloudGame>
	{
		Log.i(TAG, "=== Cross-referencing owned games with catalog ===")
		
		val ownedGames = mutableListOf<CloudGame>()
		
		for (game in publicCatalog)
		{
			// Check if user owns this game (Qt lines 1312-1320)
			if (entitlements.contains(game.productId))
			{
				// Mark as owned
				ownedGames.add(game.copy(isOwned = true))
			}
		}
		
		Log.i(TAG, "  Matched ${ownedGames.size} owned games out of ${publicCatalog.size} catalog games")
		
		return ownedGames
	}
	
	/**
	 * Extract both cover and landscape image URLs from game object
	 * Returns Pair<coverUrl, landscapeUrl>
	 * Mirrors: CloudCatalogBackend::extractCoverImageFromGameObject()
	 */
	private fun extractImageUrls(gameObj: JSONObject): Pair<String, String>
	{
		val imagesArray = gameObj.optJSONArray("images") ?: return Pair("", "")
		
		var coverUrl = ""
		var landscapeUrl = ""
		
		// Extract both cover (type 10) and landscape (type 12/13)
		for (i in 0 until imagesArray.length())
		{
			val image = imagesArray.getJSONObject(i)
			val type = image.optInt("type", -1)
			val url = image.optString("url", "")
			
			if (url.isEmpty()) continue
			
			when (type)
			{
				10 -> if (coverUrl.isEmpty()) coverUrl = url
				12 -> if (landscapeUrl.isEmpty()) landscapeUrl = url  // Prefer 1080p landscape
				13 -> if (landscapeUrl.isEmpty()) landscapeUrl = url  // Fallback to 720p landscape
			}
		}
		
		// Fallback: use cover for landscape if no landscape found
		if (landscapeUrl.isEmpty() && coverUrl.isNotEmpty())
		{
			landscapeUrl = coverUrl
		}
		
		// Fallback: use landscape for cover if no cover found
		if (coverUrl.isEmpty() && landscapeUrl.isNotEmpty())
		{
			coverUrl = landscapeUrl
		}
		
		return Pair(coverUrl, landscapeUrl)
	}
}


