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
		private const val PSNOW_CACHE_FILE = "psnow_catalog.json"
		private const val PSCLOUD_ALL_CACHE_FILE = "pscloud_catalog.json"
		private const val PSCLOUD_OWNED_CACHE_FILE = "pscloud_owned_v2.json" // v2: ft0 filter + rank dedupe + featureType
		private const val PS5_CATALOG_V3_CACHE_FILE = "ps5_cloud_catalog_v3.json"
		private const val CACHE_DURATION_MS = 24 * 60 * 60 * 1000L // 24 hours

		// Region-group-specific so an Americas/PAL switch doesn't serve stale ids (e.g. "_US"/"_GB").
		private fun ps3ClassicsCacheFile(accountCountry: String): String =
			"ps3_classics_catalog_${com.metallic.chiaki.cloudplay.KamajiClassics.classicsStoreCountry(accountCountry)}.json"
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
	 * Fetch PSNow catalog with caching
	 */
	suspend fun fetchPsnowCatalog(npssoToken: String, forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			// Check cache first if not forcing refresh
			if (!forceRefresh)
			{
				val cachedGames = loadCachedGames(PSNOW_CACHE_FILE)
				if (cachedGames != null)
				{
					Log.i(TAG, "Returning ${cachedGames.size} PSNow games from cache")
					return@withContext PsnResult.Success(cachedGames)
				}
			}
			
			// Fetch from network
			Log.i(TAG, "Fetching fresh PSNow catalog from network")
			val result = psnowCatalogService.fetchPsnowCatalog(npssoToken)

			// Cache and return only if the legacy PS Now browse store actually returned games.
			if (result is PsnResult.Success && result.data.isNotEmpty())
			{
				cacheGames(result.data, PSNOW_CACHE_FILE)
				return@withContext result
			}

			// The legacy PS Now (Kamaji) browse store is region-locked / deprecated and 404s in
			// many regions (e.g. Hungary). Fall back to the PS Plus subscription catalog (~630),
			// NOT the full ~4000 streamable universe (that is the Library "all" view).
			Log.w(TAG, "PSNow catalog unavailable/empty, falling back to PS Plus subscription catalog")
			fetchPlusCatalog(npssoToken, forceRefresh)
		}
	}

	/**
	 * Fetch the PS Plus subscription catalog (Catalog tab): plusCatalog browse titles + the
	 * library-stream supplement, NOT the full all-ps5 universe. No ownership merge — every
	 * subscription title is shown as streamable. Mirrors Qt ps5PlusCatalogGames.
	 */
	suspend fun fetchPlusCatalog(npssoToken: String, forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			CloudLocaleBootstrap.ensureConfigured(preferences, npssoToken)
			try
			{
				val stored = preferences.getCloudLanguage()
				val catalog = fetchPs5CatalogV3(stored, forceRefresh)
				var games = (catalog.browseGames.filter { it.plusCatalog } + catalog.plusLibrarySupplement)
					.sortedBy { it.name.lowercase() }
				// Mark owned subscription titles so owned -> Stream and non-owned -> Add Game.
				// addUnmatched=false keeps the Catalog the pure subscription set (mark only).
				if (npssoToken.isNotEmpty())
				{
					try
					{
						val ownedCrossRef = pscloudCatalogService.getOwnedPs5CloudGames(
							npssoToken, catalog.browseGames, catalog.plusLibrarySupplement, catalog.productIdAliases)
						games = PsCloudOwnership.mergeOwnedIntoBrowseCatalog(games, ownedCrossRef, addUnmatched = false)
					}
					catch (e: Exception)
					{
						Log.w(TAG, "Catalog ownership marking failed; showing as not owned", e)
					}
				}
				PsnResult.Success(games)
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Failed to fetch PS Plus subscription catalog", e)
				PsnResult.Error("Failed to fetch catalog: ${e.message}", e)
			}
		}
	}
	
	/**
	 * Fetch PS5 Cloud catalog with caching
	 */
	suspend fun fetchPs5CloudCatalog(npssoToken: String, forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			CloudLocaleBootstrap.ensureConfigured(preferences, npssoToken)

			if (!forceRefresh)
			{
				loadCachedGames(PSCLOUD_ALL_CACHE_FILE)?.let { cached ->
					Log.i(TAG, "Returning ${cached.size} PS5 games from cache (ownership included)")
					return@withContext PsnResult.Success(cached)
				}
			}

			try
			{
				val stored = preferences.getCloudLanguage()
				Log.i(TAG, "Fetching PS5 Cloud catalog stored=$stored forceRefresh=$forceRefresh")
				val catalog = fetchPs5CatalogV3(stored, forceRefresh)
				val gamesWithOwnership = crossReferenceOwnership(catalog, npssoToken)
				if (gamesWithOwnership.isNotEmpty())
					cacheGames(gamesWithOwnership, PSCLOUD_ALL_CACHE_FILE)
				PsnResult.Success(gamesWithOwnership)
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Failed to fetch PS5 catalog", e)
				PsnResult.Error("Failed to fetch PS5 catalog: ${e.message}", e)
			}
		}
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

	/**
	 * Cross-reference public catalog with owned games to mark ownership status
	 */
	private suspend fun crossReferenceOwnership(catalog: Ps5CloudCatalogResult, npssoToken: String): List<CloudGame>
	{
		if (npssoToken.isEmpty())
			return catalog.browseGames.map { it.copy(isOwned = false) }

		return try
		{
			val ownedCrossRef = pscloudCatalogService.getOwnedPs5CloudGames(
				npssoToken,
				catalog.browseGames,
				catalog.plusLibrarySupplement,
				catalog.productIdAliases
			)
			PsCloudOwnership.mergeOwnedIntoBrowseCatalog(catalog.browseGames, ownedCrossRef)
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Failed to cross-reference ownership, returning games as not owned", e)
			catalog.browseGames.map { it.copy(isOwned = false) }
		}
	}
	
	/**
	 * Fetch owned PS5 games (user's library)
	 */
	suspend fun fetchOwnedPs5Games(npssoToken: String, forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			CloudLocaleBootstrap.ensureConfigured(preferences, npssoToken)

			if (!forceRefresh)
			{
				loadCachedGames(PSCLOUD_OWNED_CACHE_FILE)?.let { cached ->
					Log.i(TAG, "Returning ${cached.size} owned PS5 games from cache")
					return@withContext PsnResult.Success(cached)
				}
			}

			Log.i(TAG, "Fetching owned PS5 games from network (forceRefresh=$forceRefresh)")
			try
			{
				val stored = preferences.getCloudLanguage()
				val catalog = fetchPs5CatalogV3(stored, forceRefresh)

				val games = pscloudCatalogService.getOwnedPs5CloudGames(
					npssoToken,
					catalog.browseGames,
					catalog.plusLibrarySupplement,
					catalog.productIdAliases
				)
				if (games.isNotEmpty())
					cacheGames(games, PSCLOUD_OWNED_CACHE_FILE)
				PsnResult.Success(games)
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Failed to fetch owned PS5 games", e)
				PsnResult.Error("Failed to fetch owned PS5 games: ${e.message}", e)
			}
		}
	}
	
	/**
	 * Fetch the streamable PS3 Classics (public Apollo container) with region-keyed caching.
	 * Subscription-streamable (never "owned"), so callers append these to the Catalog and the
	 * Library "all" view only. Mirrors CloudCatalogBackend::fetchPs3Catalog() (Qt).
	 */
	suspend fun fetchPs3ClassicsCatalog(forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			CloudLocaleBootstrap.ensureConfigured(preferences, preferences.getNpssoToken())
			// Account country = country part of the store locale (e.g. "en-HU" -> "HU").
			val (accountCountry, _) = com.metallic.chiaki.cloudplay.CloudLocale.parseStorePath(preferences.getCloudLanguage())
			val cacheFile = ps3ClassicsCacheFile(accountCountry)

			if (!forceRefresh)
			{
				loadCachedGames(cacheFile)?.let { cached ->
					Log.i(TAG, "Returning ${cached.size} PS3 Classics from cache ($cacheFile)")
					return@withContext PsnResult.Success(cached)
				}
			}

			try
			{
				val games = pscloudCatalogService.fetchPs3ClassicsCatalog(accountCountry)
				if (games.isNotEmpty())
					cacheGames(games, cacheFile)
				PsnResult.Success(games)
			}
			catch (e: Exception)
			{
				Log.w(TAG, "Failed to fetch PS3 Classics catalog", e)
				PsnResult.Error("Failed to fetch PS3 Classics catalog: ${e.message}", e)
			}
		}
	}

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
					featureType = obj.optInt("featureType", 0)
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

