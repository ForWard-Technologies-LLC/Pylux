// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.repository

import android.content.Context
import android.util.Log
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
		private const val CACHE_DIR = "cloud_catalog_cache"
		private const val PSNOW_CACHE_FILE = "psnow_catalog.json"
		private const val PSCLOUD_CACHE_FILE = "pscloud_catalog.json"
		private const val CACHE_DURATION_MS = 24 * 60 * 60 * 1000L // 24 hours
	}
	
	private val psnowCatalogService = PsnCatalogService(preferences)
	private val pscloudCatalogService = PsCloudCatalogService()
	private val cacheDir: File by lazy {
		File(context.cacheDir, CACHE_DIR).apply {
			if (!exists()) mkdirs()
		}
	}
	
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
			
			// Cache if successful
			if (result is PsnResult.Success)
			{
				cacheGames(result.data, PSNOW_CACHE_FILE)
			}
			
			result
		}
	}
	
	/**
	 * Fetch PS5 Cloud catalog with caching
	 */
	suspend fun fetchPs5CloudCatalog(npssoToken: String, forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			// Check cache first if not forcing refresh
			if (!forceRefresh)
			{
				val cachedGames = loadCachedGames(PSCLOUD_CACHE_FILE)
				if (cachedGames != null)
				{
					Log.i(TAG, "Returning ${cachedGames.size} PS5 games from cache (ownership already cached)")
					// Return cached games with their cached ownership status
					return@withContext PsnResult.Success(cachedGames)
				}
			}
			
		// Fetch from network
		Log.i(TAG, "Fetching fresh PS5 Cloud catalog from network")
		try
		{
			// Get locale from unified language setting and convert to lowercase (Qt lines 847-848)
			val localeSetting = preferences.getCloudLanguage()
			val locale = localeSetting.lowercase() // Convert "en-US" to "en-us"
			
			val games = pscloudCatalogService.fetchPs5CloudCatalog(locale)
			
			// Cross-reference with owned games to mark ownership status (for "All Games" view)
			val gamesWithOwnership = crossReferenceOwnership(games, npssoToken)
			
			cacheGames(gamesWithOwnership, PSCLOUD_CACHE_FILE)
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
	 * Cross-reference public catalog with owned games to mark ownership status
	 */
	private suspend fun crossReferenceOwnership(publicCatalog: List<CloudGame>, npssoToken: String): List<CloudGame>
	{
		if (npssoToken.isEmpty())
		{
			// No token, can't check ownership - return games as-is (all marked as not owned)
			return publicCatalog.map { it.copy(isOwned = false) }
		}
		
		try
		{
			// Get locale for owned games fetch
			val localeSetting = preferences.getCloudLanguage()
			val locale = localeSetting.lowercase()
			
			// Fetch owned games
			val ownedGames = pscloudCatalogService.fetchOwnedPs5Games(npssoToken, locale)
			val ownedProductIds = ownedGames.map { it.productId }.toSet()
			
			// Mark ownership status
			return publicCatalog.map { game ->
				game.copy(isOwned = ownedProductIds.contains(game.productId))
			}
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Failed to cross-reference ownership, returning games as not owned", e)
			// Return games as not owned if we can't check
			return publicCatalog.map { it.copy(isOwned = false) }
		}
	}
	
	/**
	 * Fetch owned PS5 games (user's library)
	 */
	suspend fun fetchOwnedPs5Games(npssoToken: String, forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			// Owned games cache is separate from public catalog
			val OWNED_CACHE_FILE = "pscloud_owned.json"
			
			// Check cache first if not forcing refresh
			if (!forceRefresh)
			{
				val cachedGames = loadCachedGames(OWNED_CACHE_FILE)
				if (cachedGames != null)
				{
					Log.i(TAG, "Returning ${cachedGames.size} owned PS5 games from cache")
					return@withContext PsnResult.Success(cachedGames)
				}
			}
			
		// Fetch from network
		Log.i(TAG, "Fetching owned PS5 games from network")
		try
		{
			// Get locale from unified language setting and convert to lowercase (Qt lines 847-848)
			val localeSetting = preferences.getCloudLanguage()
			val locale = localeSetting.lowercase() // Convert "en-US" to "en-us"
			
			val games = pscloudCatalogService.fetchOwnedPs5Games(npssoToken, locale)
			cacheGames(games, OWNED_CACHE_FILE)
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
	 * Load games from cache if valid
	 */
	private fun loadCachedGames(cacheFileName: String): List<CloudGame>?
	{
		try
		{
			val cacheFile = File(cacheDir, cacheFileName)
			
			if (!cacheFile.exists())
			{
				Log.d(TAG, "No cache file found: $cacheFileName")
				return null
			}
			
			// Check if cache is still valid
			val cacheAge = System.currentTimeMillis() - cacheFile.lastModified()
			if (cacheAge > CACHE_DURATION_MS)
			{
				Log.d(TAG, "Cache expired (age: ${cacheAge / 1000}s)")
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
					conceptUrl = obj.optString("conceptUrl", ""),  // Load from cache, empty if not present
					isOwned = obj.optBoolean("isOwned", false)
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
				obj.put("isOwned", game.isOwned)
				jsonArray.put(obj)
			}
			
			val cacheFile = File(cacheDir, cacheFileName)
			cacheFile.writeText(jsonArray.toString())
			
			Log.i(TAG, "Cached ${games.size} games to: $cacheFileName")
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Error caching games to $cacheFileName", e)
		}
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

