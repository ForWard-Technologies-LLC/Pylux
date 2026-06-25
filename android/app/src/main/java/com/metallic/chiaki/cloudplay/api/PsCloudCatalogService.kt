// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.util.Log
import com.metallic.chiaki.cloudplay.PsnApiConstants
import com.metallic.chiaki.cloudplay.model.CloudGame
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import org.json.JSONArray
import org.json.JSONObject

data class Ps5CloudCatalogResult(
	val browseGames: List<CloudGame>,
	val plusLibrarySupplement: List<CloudGame>,
	val productIdAliases: Map<String, String> = emptyMap(),
	val catalogFetchWarning: String? = null,
	val shouldCacheV3: Boolean = true,
)

/**
 * PsCloudCatalogService - PS5 cloud catalog fetching (imagic gameslist).
 */
class PsCloudCatalogService
{
	companion object
	{
		private const val TAG = "PsCloudCatalogService"
		private const val ACCOUNT_BASE = "https://ca.account.sony.com/api"
		private const val IMAGIC_GAMESLIST_BASE =
			"https://www.playstation.com/bin/imagic/gameslist"

		private val IMAGIC_PS5_CLOUD_CATEGORY_LISTS = listOf(
			"plus-games-list",
			"ubisoft-classics-list",
			"plus-classics-list",
			"plus-monthly-games-list",
			"free-to-play-list",
			"all-ps5-list",
		)
	}
	
	suspend fun fetchPs5CloudCatalog(locale: String): Ps5CloudCatalogResult = coroutineScope {
		Log.i(TAG, "=== Fetching PS5 Game Catalog (6 imagic lists) ===")
		Log.i(TAG, "  Locale: $locale")

		val byConceptId = LinkedHashMap<String, JSONObject>()
		val plusSupplementByProductId = LinkedHashMap<String, JSONObject>()
		val productIdAliases = LinkedHashMap<String, String>()
		var totalGames = 0
		val failedLists = mutableListOf<String>()
		var allPs5ListSucceeded = false

		IMAGIC_PS5_CLOUD_CATEGORY_LISTS.map { categoryList ->
			async {
				try {
					categoryList to fetchImagicCategoryList(locale, categoryList)
				} catch (e: Exception) {
					Log.w(TAG, "Imagic list '$categoryList' failed: ${e.message}")
					categoryList to null
				}
			}
		}.awaitAll().forEach { (categoryList, jsonArray) ->
			if (jsonArray == null) {
				failedLists.add(categoryList)
				return@forEach
			}
			if (categoryList == "all-ps5-list")
				allPs5ListSucceeded = true
			totalGames += mergeImagicCategoryIntoMap(
				categoryList, jsonArray, byConceptId, plusSupplementByProductId, productIdAliases
			)
		}

		if (failedLists.size == IMAGIC_PS5_CLOUD_CATEGORY_LISTS.size)
			throw Exception("All imagic lists failed to load")

		val browseGames = byConceptId.values.mapNotNull { jsonToCloudGame(it) }
		val plusLibrarySupplement = plusSupplementByProductId.values.mapNotNull { jsonToCloudGame(it) }

		val catalogFetchWarning = if (failedLists.isEmpty()) null
			else "Some catalog lists failed to load (${failedLists.joinToString()}). Catalog may be incomplete."

		Log.i(TAG, "  Imagic rows scanned: $totalGames")
		Log.i(TAG, "  PS5 streaming games (deduped by conceptId): ${browseGames.size}")
		Log.i(TAG, "  Plus library-stream supplement (stream=false): ${plusLibrarySupplement.size}")
		Log.i(TAG, "  Product ID aliases (same conceptId): ${productIdAliases.size}")
		if (catalogFetchWarning != null)
			Log.w(TAG, "  Partial imagic fetch: $catalogFetchWarning")

		Ps5CloudCatalogResult(
			browseGames, plusLibrarySupplement, productIdAliases,
			catalogFetchWarning, allPs5ListSucceeded
		)
	}

	private suspend fun fetchImagicCategoryList(locale: String, categoryList: String): JSONArray
	{
		val url = "$IMAGIC_GAMESLIST_BASE?locale=$locale&categoryList=$categoryList"
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
			Log.e(TAG, "Imagic list '$categoryList' fetch error: ${response.statusCode}")
			throw Exception("Failed to fetch imagic list $categoryList: HTTP ${response.statusCode}")
		}

		return JSONArray(response.body)
	}

	private fun mergeImagicCategoryIntoMap(
		categoryList: String,
		jsonArray: JSONArray,
		byConceptId: LinkedHashMap<String, JSONObject>,
		plusSupplementByProductId: LinkedHashMap<String, JSONObject>,
		productIdAliases: LinkedHashMap<String, String>,
	): Int
	{
		val plusCatalog = isPlusCatalogList(categoryList) // subscription catalog vs all-ps5 universe
		var rows = 0
		for (i in 0 until jsonArray.length())
		{
			val games = jsonArray.getJSONObject(i).optJSONArray("games") ?: continue
			rows += games.length()
			for (j in 0 until games.length())
			{
				val gameObj = games.getJSONObject(j)
				// Accept PS4 and PS5; the old PS5-only gate dropped PS4-only PS-Plus-catalog
				// titles (e.g. God of War 2018) before they could reach the supplement below.
				if (!isCloudDeviceGame(gameObj))
					continue

				// Subscription-catalog titles with streamingSupported=false → library-stream
				// supplement, captured from EVERY subscription list (not just plus-games-list).
				if (plusCatalog && !gameObj.optBoolean("streamingSupported", false))
				{
					val productId = gameObj.optString("productId", "")
					if (productId.isNotEmpty())
					{
						gameObj.put("plusCatalog", true)
						plusSupplementByProductId.putIfAbsent(productId, gameObj)
					}
					continue
				}

				if (!isCloudStreamingGame(gameObj))
					continue
				val key = editionKey(gameObj) // per game per platform (cross-gen split)
				val productId = gameObj.optString("productId", "")
				if (key.isEmpty() || productId.isEmpty())
					continue

				if (byConceptId.containsKey(key))
				{
					val existing = byConceptId[key]
					val canonicalProductId = existing?.optString("productId", "") ?: ""
					if (canonicalProductId.isNotEmpty() && productId != canonicalProductId
						&& !productIdAliases.containsKey(productId))
					{
						productIdAliases[productId] = canonicalProductId
					}
					// Lists fetch in parallel; upgrade the flag so subscription membership wins
					// regardless of arrival order.
					if (plusCatalog && existing != null && !existing.optBoolean("plusCatalog", false))
						existing.put("plusCatalog", true)
					continue
				}

				gameObj.put("plusCatalog", plusCatalog)
				byConceptId[key] = gameObj
			}
		}
		return rows
	}

	// PS Plus cloud streaming covers PS4 and PS5 titles (PS3 is not in these imagic lists).
	// A PS4-only title such as God of War (2018) is streamable when owned even though it
	// carries device ["PS4"], so the catalog must not discard it.
	// The PS Plus subscription catalog = these curated lists (≈ what Sony lists). all-ps5-list is
	// the full streamable universe and must NOT count as subscription catalog.
	private fun isPlusCatalogList(categoryList: String): Boolean =
		categoryList == "plus-games-list" || categoryList == "plus-classics-list" ||
			categoryList == "ubisoft-classics-list" || categoryList == "plus-monthly-games-list"

	private fun isCloudDeviceGame(gameObj: JSONObject): Boolean
	{
		val devices = gameObj.optJSONArray("device") ?: return false
		for (i in 0 until devices.length())
		{
			val d = devices.optString(i)
			if (d == "PS5" || d == "PS4")
				return true
		}
		return false
	}

	private fun isCloudStreamingGame(gameObj: JSONObject): Boolean
	{
		if (!gameObj.optBoolean("streamingSupported", false))
			return false
		return isCloudDeviceGame(gameObj)
	}

	private fun conceptKey(gameObj: JSONObject): String
	{
		if (gameObj.has("conceptId") && !gameObj.isNull("conceptId"))
		{
			when (val raw = gameObj.get("conceptId"))
			{
				is Number -> return raw.toLong().toString()
				is String -> if (raw.isNotEmpty()) return raw
			}
		}
		return gameObj.optString("productId", "")
	}

	// Platform token from a product id (CUSA = PS4, PPSA = PS5).
	private fun ps5PlatformToken(productId: String): String = when
	{
		productId.contains("PPSA") -> "ps5"
		productId.contains("CUSA") -> "ps4"
		else -> ""
	}

	// Dedupe identity: one entry per game PER PLATFORM, so cross-gen PS4/PS5 editions (e.g. Deliver
	// Us The Moon) both appear, while duplicate same-platform SKUs still collapse.
	private fun editionKey(gameObj: JSONObject): String
	{
		val c = conceptKey(gameObj)
		if (c.isEmpty()) return ""
		return c + "|" + ps5PlatformToken(gameObj.optString("productId", ""))
	}

	private fun jsonToCloudGame(gameObj: JSONObject): CloudGame?
	{
		val productId = gameObj.optString("productId", "")
		if (productId.isEmpty())
			return null

		val gameName = gameObj.optString("name", "Unknown")
		var imageUrl = gameObj.optString("imageUrl", "")
		var conceptUrl = gameObj.optString("conceptUrl", "")
		if (conceptUrl.isEmpty())
			conceptUrl = gameObj.optString("concept_url", "")
		if (conceptUrl.isEmpty())
			conceptUrl = gameObj.optString("url", "")
		if (conceptUrl.isEmpty())
			conceptUrl = gameObj.optString("storeUrl", "")
		if (conceptUrl.isEmpty())
			conceptUrl = gameObj.optString("psStoreUrl", "")
		if (conceptUrl.isEmpty())
			conceptUrl = gameObj.optString("concept", "")
		if (conceptUrl.isEmpty())
		{
			val links = gameObj.optJSONObject("links")
			if (links != null)
			{
				conceptUrl = links.optString("conceptUrl", "")
					.ifEmpty { links.optString("concept_url", "") }
					.ifEmpty { links.optString("url", "") }
			}
		}
		if (conceptUrl.isEmpty())
		{
			val concept = gameObj.optJSONObject("concept")
			if (concept != null)
			{
				conceptUrl = concept.optString("url", "")
					.ifEmpty { concept.optString("href", "") }
			}
		}

		val (coverUrl, landscapeUrl) = if (imageUrl.isNotEmpty())
			Pair(imageUrl, imageUrl)
		else
			extractImageUrls(gameObj)

		var finalCoverUrl = coverUrl
		var finalLandscapeUrl = landscapeUrl
		if (finalCoverUrl.startsWith("http://"))
			finalCoverUrl = finalCoverUrl.replace("http://", "https://")
		if (finalLandscapeUrl.startsWith("http://"))
			finalLandscapeUrl = finalLandscapeUrl.replace("http://", "https://")

		return CloudGame(
			productId = productId,
			name = gameName,
			imageUrl = finalCoverUrl,
			landscapeImageUrl = finalLandscapeUrl,
			platform = ps5PlatformToken(productId).ifEmpty { "ps5" },
			serviceType = "pscloud",
			conceptUrl = conceptUrl,
			conceptId = conceptKey(gameObj),
			isOwned = false,
			plusCatalog = gameObj.optBoolean("plusCatalog", false),
			// Authoritative PS5-platform membership from the imagic `device` array (NOT the CUSA/PPSA
			// token). A cross-gen title with a PS4 CUSA SKU but "PS5" in `device` is a PS5 browse row
			// and must enter the streamable universe (mirrors Qt isPs5PlatformGame).
			isPs5Platform = isPs5PlatformGame(gameObj)
		)
	}

	// PS5-platform membership for an imagic browse object: a PPSA product id OR "PS5" in the
	// authoritative `device` array. Mirrors Qt isPs5PlatformGame() (cloudcatalogbackend.cpp).
	private fun isPs5PlatformGame(gameObj: JSONObject): Boolean
	{
		val pid = gameObj.optString("productId", "")
		if (pid.contains("PPSA")) return true
		val devices = gameObj.optJSONArray("device") ?: return false
		for (i in 0 until devices.length())
			if (devices.optString(i) == "PS5") return true
		return false
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
			throw Exception("NPSSO token is required for cloud play. Please login and enter a valid NPSSO token.")
		}
		
		Log.i(TAG, "=== Fetching Owned PS5 Games ===")
		Log.i(TAG, "  Locale: $locale")
		
		val catalog = fetchPs5CloudCatalog(locale)
		val ownedGames = getOwnedPs5CloudGames(
			npssoToken,
			catalog.browseGames,
			catalog.plusLibrarySupplement,
			catalog.productIdAliases
		)
		
		Log.i(TAG, "  Owned streaming games: ${ownedGames.size}")
		return ownedGames
	}

	/**
	 * Mirrors CloudCatalogBackend::getOwnedPs5CloudGames cross-reference (network).
	 *
	 * @param psnowCatalog the PS Now APOLLOROOT catalog (PS3 + PS4). Prepended to the imagic
	 *        publicCatalog so owned PS4/PS3 entitlements resolve to their (psnow) catalog row and
	 *        keep the Kamaji streaming route; imagic still provides PS5 rows + conceptIds.
	 */
	suspend fun getOwnedPs5CloudGames(
		npssoToken: String,
		publicCatalog: List<CloudGame>,
		plusLibrarySupplement: List<CloudGame> = emptyList(),
		productIdAliases: Map<String, String> = emptyMap(),
		psnowCatalog: List<CloudGame> = emptyList(),
	): List<CloudGame>
	{
		if (npssoToken.isEmpty()) return emptyList()
		
		val oauthToken = fetchOwnedGamesOAuthToken(npssoToken)
		kotlinx.coroutines.delay(PsCloudOwnership.PAGE_COOLDOWN_MS)
		
		val rawEntitlements = fetchEntitlementsPaginated(oauthToken)
		val filtered = PsCloudOwnership.filterOwnedPs5Games(rawEntitlements)
		
		// Map each bundle product_id -> the entitlement ids sharing it, so a bundle (e.g. RE7 Gold)
		// expands to its component games during cross-reference (upstream PR #15 bundle-sibling match).
		val componentIds = mutableMapOf<String, MutableList<String>>()
		for (ent in rawEntitlements)
			if (ent.productId.isNotEmpty() && ent.id.isNotEmpty())
				componentIds.getOrPut(ent.productId) { mutableListOf() }.add(ent.id)

		val combinedCatalog = if (psnowCatalog.isEmpty()) publicCatalog else psnowCatalog + publicCatalog
		return PsCloudOwnership.crossReferenceOwnedGames(
			filtered, combinedCatalog, plusLibrarySupplement, productIdAliases, componentIds
		)
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
	 * Fetch entitlements using OAuth token (paginated).
	 * Mirrors: CloudCatalogBackend::fetchOwnedGamesPage()
	 */
	private suspend fun fetchEntitlementsPaginated(oauthToken: String): List<PsCloudOwnership.Entitlement>
	{
		Log.i(TAG, "=== Fetching entitlements (paginated) ===")
		
		val all = mutableListOf<PsCloudOwnership.Entitlement>()
		var start = 0
		
		while (true)
		{
			val url = "https://commerce.api.np.km.playstation.net/commerce/api/v1/users/me/internal_entitlements?fields=game_meta&entitlement_type=5&start=$start&size=${PsCloudOwnership.PAGE_SIZE}"
			
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
				throw Exception("Failed to fetch entitlements: HTTP ${response.statusCode}")
			}
			
			val jsonObj = JSONObject(response.body)
			val entitlementsArray = jsonObj.optJSONArray("entitlements") ?: JSONArray()
			val pageSize = entitlementsArray.length()
			
			for (i in 0 until pageSize)
			{
				PsCloudOwnership.parseEntitlement(entitlementsArray.getJSONObject(i))?.let { all.add(it) }
			}
			
			if (pageSize < PsCloudOwnership.PAGE_SIZE) break
			start += pageSize
			kotlinx.coroutines.delay(PsCloudOwnership.PAGE_COOLDOWN_MS)
		}
		
		Log.i(TAG, "  Entitlements count: ${all.size}")
		return all
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


