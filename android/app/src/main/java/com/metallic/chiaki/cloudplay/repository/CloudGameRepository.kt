// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.repository

import android.content.Context
import android.util.Log
import com.metallic.chiaki.cloudplay.CloudLocaleBootstrap
import com.metallic.chiaki.cloudplay.api.Ps5CloudCatalogResult
import com.metallic.chiaki.cloudplay.api.PsCloudOwnership
import com.metallic.chiaki.cloudplay.api.PsnCatalogService
import com.metallic.chiaki.cloudplay.api.PsCloudCatalogService
import com.metallic.chiaki.cloudplay.model.CloudGame
import com.metallic.chiaki.cloudplay.model.PsnResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

/**
 * Repository for cloud game catalog data
 * Handles caching and data fetching
 */
class CloudGameRepository(
	private val context: Context,
	private val preferences: com.metallic.chiaki.common.Preferences
)
{
	companion object
	{
		private const val TAG = "CloudGameRepository"
		private const val CACHE_DIR = "cloud_catalog_cache_v2" // v2: catalog games carry plusCatalog tag

		fun invalidateCatalogCache(context: Context)
		{
			try
			{
				val cacheDir = File(context.cacheDir, CACHE_DIR)
				cacheDir.listFiles()?.forEach { file ->
					if (file.isFile)
						file.delete()
				}
				Log.i(TAG, "Catalog cache invalidated (locale change)")
			}
			catch (e: Exception)
			{
				Log.w(TAG, "Error invalidating catalog cache", e)
			}
		}
		private const val UNIFIED_CACHE_FILE = "unified_catalog_v5.json" // v5: Qt emitOwned productId + QMap-sorted cross-ref merge order
		private const val PS5_CATALOG_V3_CACHE_FILE = "ps5_cloud_catalog_v3.json"
		private const val CACHE_DURATION_MS = 24 * 60 * 60 * 1000L // 24 hours

		private const val OWNERSHIP_SESSION_WARNING =
			"Your PlayStation session has expired. Please log in again to see your owned games."
		private const val OWNERSHIP_NETWORK_WARNING =
			"Couldn't verify your owned games (network error). Pull to refresh to try again."
	}
	
	private val psnowCatalogService = PsnCatalogService(preferences)
	private val pscloudCatalogService = PsCloudCatalogService()
	private val cacheDir: File by lazy {
		File(context.cacheDir, CACHE_DIR).apply {
			if (!exists()) mkdirs()
		}
	}

	var lastCatalogFetchWarning: String? = null
		private set
	
	/**
	 * Unified cloud catalog: ONE merged, deduped, tagged list across PS3/PS4 (PS Now/Kamaji) and
	 * PS5 (imagic/Gaikai). Each game carries a `category` tag (owned / streamable / purchaseable).
	 *
	 * Sources:
	 *  - PS Now APOLLOROOT walk (PS3 + PS4): native via /user/stores, or public region-group
	 *    fallback when the account's region has no storefront.
	 *  - imagic browse (PS5, streamingSupported=true) = purchaseable universe.
	 * Owned entitlements (PS4 + PS5) are cross-referenced against both (supplement + aliases +
	 * conceptId recognition retained). In native mode the concept-sibling streamability gate drops
	 * owned titles with no streamable path (e.g. FOR HONOR); in fallback mode the gate is skipped
	 * so nothing is hidden when the catalog isn't authoritative.
	 */
	suspend fun fetchUnifiedCatalog(npssoToken: String, forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			lastCatalogFetchWarning = null
			CloudLocaleBootstrap.ensureConfigured(preferences, npssoToken)

			if (!forceRefresh)
			{
				loadCachedGames(UNIFIED_CACHE_FILE)?.let { cached ->
					Log.i(TAG, "Returning ${cached.size} unified games from cache")
					return@withContext PsnResult.Success(cached)
				}
			}

			val (accountCountry, _) =
				com.metallic.chiaki.cloudplay.CloudLocale.parseStorePath(preferences.getCloudLanguage())

			// --- 1) PS Now APOLLOROOT (PS3 + PS4): native, else region-group fallback ----------
			val native = psnowCatalogService.fetchNativeCatalog(npssoToken)
			var apolloGames: List<CloudGame> = emptyList()
			var nativeMode = false
			var fallbackRegion = ""
			when
			{
				native.storesAvailable && native.games.isNotEmpty() ->
				{
					apolloGames = native.games
					nativeMode = true
				}
				native.authError ->
				{
					// Expired token: can't verify owned games. Still show a public catalog.
					lastCatalogFetchWarning = OWNERSHIP_SESSION_WARNING
					apolloGames = tryApolloRootFallback(accountCountry)
				}
				else ->
				{
					// /user/stores has no storefront for this region: public region-group walk.
					apolloGames = tryApolloRootFallback(accountCountry)
					if (apolloGames.isNotEmpty())
						fallbackRegion = com.metallic.chiaki.cloudplay.KamajiClassics.classicsStoreCountry(accountCountry)
				}
			}
			preferences.setCloudFallbackRegion(fallbackRegion)
			Log.i(TAG, "PS Now APOLLOROOT: ${apolloGames.size} games (nativeMode=$nativeMode, fallbackRegion='$fallbackRegion')")

			// --- 2) imagic PS5 catalog (browse + supplement + aliases) -------------------------
			val imagic = try
			{
				fetchPs5CatalogV3(preferences.getCloudLanguage(), forceRefresh)
			}
			catch (e: Exception)
			{
				Log.e(TAG, "imagic PS5 catalog fetch failed", e)
				if (apolloGames.isEmpty())
					return@withContext PsnResult.Error("Failed to fetch catalog: ${e.message}", e)
				Ps5CloudCatalogResult(emptyList(), emptyList(), emptyMap())
			}

			// --- 3) owned cross-reference (skip on expired token) ------------------------------
			var owned: List<CloudGame> = emptyList()
			if (npssoToken.isNotEmpty() && !native.authError)
			{
				try
				{
					owned = pscloudCatalogService.getOwnedPs5CloudGames(
						npssoToken, imagic.browseGames, imagic.plusLibrarySupplement,
						imagic.productIdAliases, psnowCatalog = apolloGames
					)
				}
				catch (e: Exception)
				{
					Log.w(TAG, "Ownership cross-reference failed; showing as not owned", e)
					lastCatalogFetchWarning = ownershipFailureWarning(e)
				}
			}

			// --- 4) assemble the streamable universe (PS Now PS3/PS4 + imagic PS5) -------------
			val ps5Browse = imagic.browseGames.filter { PsCloudOwnership.streamPlatform(it) == "ps5" }
			val universe = apolloGames + ps5Browse
			var games = PsCloudOwnership.mergeOwnedIntoBrowseCatalog(universe, owned, addUnmatched = true)

			// --- 5) concept-sibling streamability gate (native mode only) ----------------------
			if (nativeMode)
			{
				val index = PsCloudOwnership.StreamabilityIndex(
					apolloCatalog = apolloGames,
					imagicBrowse = imagic.browseGames,
					imagicConceptRows = imagic.browseGames + imagic.plusLibrarySupplement
				)
				games = PsCloudOwnership.applyStreamabilityGate(games, index)
			}

			// --- 6) tag + cache ----------------------------------------------------------------
			games = games.map { it.copy(category = PsCloudOwnership.categoryFor(it)) }
			if (games.isNotEmpty() && !isOwnershipVerificationFailure(lastCatalogFetchWarning))
				cacheGames(games, UNIFIED_CACHE_FILE)
			PsnResult.Success(games)
		}
	}

	/** Best-effort public region-group APOLLOROOT walk (no session). Empty list on failure. */
	private suspend fun tryApolloRootFallback(accountCountry: String): List<CloudGame> =
		try
		{
			psnowCatalogService.fetchApolloRootCatalog(accountCountry)
		}
		catch (e: Exception)
		{
			Log.w(TAG, "APOLLOROOT region-group fallback failed", e)
			emptyList()
		}

	/**
	 * Fetch the PS5 imagic catalog, trying the store-locale fallback chain
	 * (session locale -> en-COUNTRY -> en-US) since Sony 404s unsupported locales (e.g. hu-HU).
	 * Persists the locale that works. Returns the cached v3 catalog when available.
	 */
	private suspend fun fetchPs5CatalogV3(stored: String, forceRefresh: Boolean): Ps5CloudCatalogResult
	{
		if (!forceRefresh)
			loadCachedPs5CatalogV3(stored)?.let { return it }

		lastCatalogFetchWarning = null
		var lastError: Exception? = null
		for ((canonical, imagic) in com.metallic.chiaki.cloudplay.CloudLocale.fallbackChain(stored))
		{
			try
			{
				val fetched = pscloudCatalogService.fetchPs5CloudCatalog(imagic)
				if (canonical != stored)
				{
					Log.i(TAG, "PS5 store locale settled on $canonical (was $stored)")
					preferences.setCloudLanguage(canonical)
				}
				if (fetched.shouldCacheV3)
					cachePs5CatalogV3(fetched, canonical)
				lastCatalogFetchWarning = fetched.catalogFetchWarning
				return fetched
			}
			catch (e: Exception)
			{
				Log.i(TAG, "PS5 imagic locale $imagic failed, trying next tier: ${e.message}")
				lastError = e
			}
		}
		throw (lastError ?: Exception("All imagic locales failed to load"))
	}

	private fun ownershipFailureWarning(e: Exception): String
	{
		val msg = e.message?.lowercase() ?: ""
		val isAuth = msg.contains("login_required")
			|| msg.contains("failed to extract oauth token")
			|| msg.contains("no location header in oauth")
			|| (msg.contains("oauth") && Regex("http 4\\d\\d").containsMatchIn(msg))
			|| (msg.contains("entitlements") && (msg.contains("http 401") || msg.contains("http 403")))
		return if (isAuth) OWNERSHIP_SESSION_WARNING else OWNERSHIP_NETWORK_WARNING
	}

	private fun isOwnershipVerificationFailure(warning: String?): Boolean =
		warning == OWNERSHIP_SESSION_WARNING || warning == OWNERSHIP_NETWORK_WARNING

	/**
	 * Load games from cache if valid
	 */
	private fun loadCachedGames(cacheFileName: String): List<CloudGame>?
	{
		try
		{
			val cacheFile = File(cacheDir, cacheFileName)
			
			if (!cacheFile.exists())
			{
				Log.d(TAG, "No cache file found: $cacheFileName at ${cacheFile.absolutePath}")
				Log.d(TAG, "Cache directory exists: ${cacheDir.exists()}, contents: ${cacheDir.listFiles()?.map { it.name }}")
				return null
			}
			
			// Check if cache is still valid
			val cacheAge = System.currentTimeMillis() - cacheFile.lastModified()
			if (cacheAge > CACHE_DURATION_MS)
			{
				Log.d(TAG, "Cache expired (age: ${cacheAge / 1000}s, max: ${CACHE_DURATION_MS / 1000}s)")
				cacheFile.delete()
				return null
			}
			
			// Read and parse cache
			val json = cacheFile.readText()
			val jsonArray = JSONArray(json)
			val games = mutableListOf<CloudGame>()
			
			for (i in 0 until jsonArray.length())
			{
				val obj = jsonArray.getJSONObject(i)
				// Handle landscapeImageUrl (may be missing in old cache)
				val landscapeImageUrl = obj.optString("landscapeImageUrl", obj.getString("imageUrl"))
				
				games.add(CloudGame(
					productId = obj.getString("productId"),
					name = obj.getString("name"),
					imageUrl = obj.getString("imageUrl"),
					landscapeImageUrl = landscapeImageUrl,
					thumbnailUrl = obj.optString("thumbnailUrl", obj.getString("imageUrl")),
					platform = obj.optString("platform", "ps4"),
					serviceType = obj.optString("serviceType", "psnow"),
					conceptUrl = obj.optString("conceptUrl", ""),
					conceptId = obj.optString("conceptId", ""),
					isOwned = obj.optBoolean("isOwned", false),
					entitlementId = obj.optString("entitlementId", ""),
					storeProductId = obj.optString("storeProductId", ""),
					plusCatalog = obj.optBoolean("plusCatalog", false),
					featureType = obj.optInt("featureType", 0),
					category = obj.optString("category", "")
				))
			}
			
			Log.i(TAG, "Loaded ${games.size} games from cache: $cacheFileName")
			return games
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Error loading cache: $cacheFileName", e)
			return null
		}
	}
	
	/**
	 * Save games to cache
	 */
	private fun cacheGames(games: List<CloudGame>, cacheFileName: String)
	{
		try
		{
			val jsonArray = JSONArray()
			
			for (game in games)
			{
				val obj = JSONObject()
				obj.put("productId", game.productId)
				obj.put("name", game.name)
				obj.put("imageUrl", game.imageUrl)
				obj.put("landscapeImageUrl", game.landscapeImageUrl)
				obj.put("thumbnailUrl", game.thumbnailUrl)
				obj.put("platform", game.platform)
				obj.put("serviceType", game.serviceType)
				obj.put("conceptUrl", game.conceptUrl)
				obj.put("conceptId", game.conceptId)
				obj.put("isOwned", game.isOwned)
				obj.put("entitlementId", game.entitlementId)
				obj.put("storeProductId", game.storeProductId)
				obj.put("plusCatalog", game.plusCatalog)
				obj.put("featureType", game.featureType)
				obj.put("category", game.category)
				jsonArray.put(obj)
			}
			
			val cacheFile = File(cacheDir, cacheFileName)
			cacheFile.writeText(jsonArray.toString())
			
			Log.i(TAG, "Cached ${games.size} games to: ${cacheFile.absolutePath}")
			Log.d(TAG, "Cache file size: ${cacheFile.length()} bytes, lastModified: ${cacheFile.lastModified()}")
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Error caching games to $cacheFileName", e)
		}
	}
	
	private fun loadCachedPs5CatalogV3(expectedLocale: String): Ps5CloudCatalogResult?
	{
		try
		{
			val cacheFile = File(cacheDir, PS5_CATALOG_V3_CACHE_FILE)
			if (!cacheFile.exists())
				return null

			val cacheAge = System.currentTimeMillis() - cacheFile.lastModified()
			if (cacheAge > CACHE_DURATION_MS)
			{
				cacheFile.delete()
				return null
			}

			val root = JSONObject(cacheFile.readText())
			val cachedLocale = root.optString("locale", "")
			if (cachedLocale.isNotEmpty() && cachedLocale != expectedLocale)
			{
				Log.i(TAG, "PS5 catalog v3 cache locale mismatch ($cachedLocale != $expectedLocale), refetching")
				cacheFile.delete()
				return null
			}

			val browse = parseGameArray(root.optJSONArray("games") ?: JSONArray())
			val supplement = parseGameArray(root.optJSONArray("plusLibrarySupplement") ?: JSONArray())
			val aliases = parseProductIdAliases(root.optJSONObject("productIdAliases"))
			Log.i(TAG, "Loaded PS5 catalog v3 from cache: ${browse.size} browse, ${supplement.size} supplement, ${aliases.size} aliases")
			return Ps5CloudCatalogResult(browse, supplement, aliases)
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Error loading PS5 catalog v3 cache", e)
			return null
		}
	}

	private fun cachePs5CatalogV3(catalog: Ps5CloudCatalogResult, locale: String)
	{
		try
		{
			val root = JSONObject()
			root.put("locale", locale)
			root.put("games", gamesToJsonArray(catalog.browseGames))
			root.put("plusLibrarySupplement", gamesToJsonArray(catalog.plusLibrarySupplement))
			root.put("total", catalog.browseGames.size)
			if (catalog.productIdAliases.isNotEmpty())
				root.put("productIdAliases", productIdAliasesToJson(catalog.productIdAliases))

			val cacheFile = File(cacheDir, PS5_CATALOG_V3_CACHE_FILE)
			cacheFile.writeText(root.toString())
			Log.i(TAG, "Cached PS5 catalog v3: ${catalog.browseGames.size} browse, ${catalog.plusLibrarySupplement.size} supplement, ${catalog.productIdAliases.size} aliases")
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Error caching PS5 catalog v3", e)
		}
	}

	private fun parseProductIdAliases(obj: JSONObject?): Map<String, String>
	{
		if (obj == null)
			return emptyMap()
		val aliases = linkedMapOf<String, String>()
		for (key in obj.keys())
		{
			val canonical = obj.optString(key, "")
			if (canonical.isNotEmpty())
				aliases[key] = canonical
		}
		return aliases
	}

	private fun productIdAliasesToJson(aliases: Map<String, String>): JSONObject
	{
		val obj = JSONObject()
		for ((alias, canonical) in aliases)
			obj.put(alias, canonical)
		return obj
	}

	private fun parseGameArray(jsonArray: JSONArray): List<CloudGame>
	{
		val games = mutableListOf<CloudGame>()
		for (i in 0 until jsonArray.length())
		{
			val obj = jsonArray.getJSONObject(i)
			val landscapeImageUrl = obj.optString("landscapeImageUrl", obj.getString("imageUrl"))
			games.add(
				CloudGame(
					productId = obj.getString("productId"),
					name = obj.getString("name"),
					imageUrl = obj.getString("imageUrl"),
					landscapeImageUrl = landscapeImageUrl,
					platform = obj.optString("platform", "ps5"),
					// Deliberate Qt<->mobile divergence: Qt leaves imagic browse rows with NO serviceType and derives
					// platform from the clean catalog product-id token. Mobile instead blanket-tags imagic rows "pscloud"
					// and COMPENSATES with an isOwned gate in streamPlatform (a non-owned "pscloud" row falls back to the
					// product-id token, so a non-owned PS4 imagic title still routes to PS Now, not cronos). Both reach the
					// same routing -- do NOT naively "fix" one side to match the other.
					serviceType = obj.optString("serviceType", "pscloud"),
					conceptUrl = obj.optString("conceptUrl", ""),
					conceptId = obj.optString("conceptId", ""),
					isOwned = obj.optBoolean("isOwned", false),
					entitlementId = obj.optString("entitlementId", ""),
					storeProductId = obj.optString("storeProductId", ""),
					plusCatalog = obj.optBoolean("plusCatalog", false),
					featureType = obj.optInt("featureType", 0)
				)
			)
		}
		return games
	}

	private fun gamesToJsonArray(games: List<CloudGame>): JSONArray
	{
		val jsonArray = JSONArray()
		for (game in games)
		{
			val obj = JSONObject()
			obj.put("productId", game.productId)
			obj.put("name", game.name)
			obj.put("imageUrl", game.imageUrl)
			obj.put("landscapeImageUrl", game.landscapeImageUrl)
			obj.put("platform", game.platform)
			obj.put("serviceType", game.serviceType)
			obj.put("conceptUrl", game.conceptUrl)
			obj.put("conceptId", game.conceptId)
			obj.put("isOwned", game.isOwned)
			obj.put("entitlementId", game.entitlementId)
			obj.put("storeProductId", game.storeProductId)
			obj.put("plusCatalog", game.plusCatalog)
			obj.put("featureType", game.featureType)
			jsonArray.put(obj)
		}
		return jsonArray
	}

	/**
	 * Clear all cached data
	 */
	fun clearCache()
	{
		try
		{
			cacheDir.listFiles()?.forEach { it.delete() }
			Log.i(TAG, "Cache cleared")
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Error clearing cache", e)
		}
	}
}

