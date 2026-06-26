// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.repository

import android.content.Context
import android.util.Log
import com.metallic.chiaki.cloudplay.model.CloudGame
import com.metallic.chiaki.cloudplay.model.PsnResult
import com.metallic.chiaki.lib.cloudCatalogFetchUnified
import com.metallic.chiaki.lib.cloudCatalogInvalidateCache
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

/**
 * Thin wrapper over libchiaki's unified cloud catalog (chiaki/cloudcatalog.h). ALL fetching,
 * OAuth/session exchanges, dedup, ownership cross-reference and tagging happen once in the lib
 * (shared with Qt and iOS). Android supplies npsso/locale/cache dir and renders the returned
 * contract verbatim — no client-side catalog logic.
 */
class CloudGameRepository(
	private val context: Context,
	private val preferences: com.metallic.chiaki.common.Preferences
)
{
	companion object
	{
		private const val TAG = "CloudGameRepository"
		// Dir handed to the lib; the lib owns every file inside it (browse/library/unified caches).
		private const val CACHE_DIR = "cloud_catalog_cache"

		// The lib's catalog calls are documented single-threaded and it owns the cache dir; serialize
		// every fetch/clear across all repository instances so a cache invalidation can't race a
		// concurrent fetch on the same files. Shared (companion) because logout creates its own
		// repository instance to clear the cache.
		private val catalogLock = Mutex()

		private fun cacheDir(context: Context): File =
			File(context.cacheDir, CACHE_DIR).apply { if (!exists()) mkdirs() }

		/**
		 * Drop the lib-owned caches (e.g. on locale change). Synchronous on purpose: callers (e.g.
		 * [com.metallic.chiaki.common.Preferences.setCloudLanguage]) need the cache gone before the
		 * next fetch so it can't serve stale-locale data. It deliberately does NOT take [catalogLock]
		 * — that lock is held across a full fetch (including network), so a blocking acquire here
		 * could ANR. A delete racing an in-flight fetch is safe: the lib writes caches atomically
		 * (temp file + rename) and reads whole files (open fds survive unlink on POSIX), so the worst
		 * case is a benign cache miss, never a torn read or corruption.
		 */
		fun invalidateCatalogCache(context: Context)
		{
			try
			{
				cloudCatalogInvalidateCache(cacheDir(context).absolutePath)
				Log.i(TAG, "Catalog cache invalidated (locale change)")
			}
			catch (e: Exception)
			{
				Log.w(TAG, "Error invalidating catalog cache", e)
			}
		}
	}

	var lastCatalogFetchWarning: String? = null
		private set

	/**
	 * Unified cloud catalog: ONE merged, deduped, tagged list across PS3/PS4 (PS Now) and PS5
	 * (cloud). Blocking — runs on [Dispatchers.IO]. The lib serves an on-disk cache hit with no
	 * network I/O; [forceRefresh] bypasses it. A degraded-but-usable result (e.g. expired npsso)
	 * still returns games plus a non-empty warning.
	 */
	suspend fun fetchUnifiedCatalog(npssoToken: String, forceRefresh: Boolean = false): PsnResult<List<CloudGame>>
	{
		return withContext(Dispatchers.IO)
		{
			lastCatalogFetchWarning = null

			val fetched = try
			{
				catalogLock.withLock {
					cloudCatalogFetchUnified(
						npsso = npssoToken.ifEmpty { null },
						locale = preferences.getCloudLanguage(),
						cacheDir = cacheDir(context).absolutePath,
						forceRefresh = forceRefresh
					)
				}
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Unified catalog fetch threw", e)
				return@withContext PsnResult.Error("Failed to fetch catalog: ${e.message}", e)
			}

			val json = fetched.json
			if (json == null)
			{
				val detail = fetched.errorMessage ?: "Failed to fetch cloud catalog. Check your connection."
				Log.e(TAG, "Unified catalog fetch returned null: $detail")
				return@withContext PsnResult.Error(detail)
			}

			parseUnifiedCatalog(json)
		}
	}

	private fun parseUnifiedCatalog(json: String): PsnResult<List<CloudGame>>
	{
		val root = try
		{
			JSONObject(json)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to parse unified catalog JSON", e)
			return PsnResult.Error("Failed to parse cloud catalog.", e)
		}

		// The lib resolves the working store locale and region group; reflect them back so the
		// streaming path (which reads the cloud language) and the region banner agree. Persist the
		// settled locale WITHOUT wiping the cache (the lib owns its own invalidation).
		root.optString("settledLocale", "").takeIf { it.isNotEmpty() }?.let {
			preferences.noteCloudLanguageSettled(it)
		}
		preferences.setCloudFallbackRegion(root.optString("fallbackRegion", ""))

		root.optString("warning", "").takeIf { it.isNotEmpty() }?.let {
			lastCatalogFetchWarning = it
		}

		val gamesArray = root.optJSONArray("games")
		val rowCount = gamesArray?.length() ?: 0
		val games = ArrayList<CloudGame>(rowCount)
		if (gamesArray != null)
			for (i in 0 until rowCount)
				CloudGame.fromContract(gamesArray.getJSONObject(i))?.let { games.add(it) }

		val dropped = rowCount - games.size
		if (dropped > 0)
			Log.w(TAG, "Dropped $dropped malformed catalog row(s) (missing productId/name)")
		Log.i(TAG, "Unified catalog: ${games.size} games (${games.count { it.isOwned }} owned)")
		return PsnResult.Success(games)
	}

	/** Clear all lib-owned cached data. Serialized against an in-flight fetch via [catalogLock]. */
	suspend fun clearCache()
	{
		withContext(Dispatchers.IO)
		{
			try
			{
				catalogLock.withLock { cloudCatalogInvalidateCache(cacheDir(context).absolutePath) }
				Log.i(TAG, "Cache cleared")
			}
			catch (e: Exception)
			{
				Log.w(TAG, "Error clearing cache", e)
			}
		}
	}
}
