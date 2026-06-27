// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.content.Context
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.metallic.chiaki.cloudplay.CloudLocale
import com.metallic.chiaki.cloudplay.model.CloudGame
import com.metallic.chiaki.cloudplay.model.PsnResult
import com.metallic.chiaki.cloudplay.repository.CloudGameRepository
import com.metallic.chiaki.common.Preferences
import kotlinx.coroutines.launch

/**
 * ViewModel for the unified Cloud Play page.
 *
 * One catalog source (repository.fetchUnifiedCatalog) feeds a single tagged list. The UI filters
 * that list by acquisition tag (owned / streamable / purchaseable) plus the search query; an empty
 * tag set means "show all". The region-group fallback flag is surfaced for the banner.
 */
class CloudPlayViewModel(
	private val context: Context,
	val preferences: Preferences
) : ViewModel()
{
	companion object
	{
		private const val TAG = "CloudPlayViewModel"
	}

	private val repository = CloudGameRepository(context, preferences)

	private val _games = MutableLiveData<List<CloudGame>>()
	val games: LiveData<List<CloudGame>> get() = _games

	private val _loading = MutableLiveData<Boolean>()
	val loading: LiveData<Boolean> get() = _loading

	private val _error = MutableLiveData<String?>()
	val error: LiveData<String?> get() = _error

	private val _warning = MutableLiveData<String?>()
	val warning: LiveData<String?> get() = _warning

	private val _fallbackRegion = MutableLiveData<String>()
	val fallbackRegion: LiveData<String> get() = _fallbackRegion

	private val _catalogIsForeign = MutableLiveData<Boolean>()
	val catalogIsForeign: LiveData<Boolean> get() = _catalogIsForeign

	private val _searchQuery = MutableLiveData<String>()
	val searchQuery: LiveData<String> get() = _searchQuery

	private var allGames: List<CloudGame> = emptyList()

	// The lib's catalog fetch is blocking and single-threaded; never run two at once (a double-tap
	// on refresh, or a refresh during the initial load, would hit the same cache dir concurrently).
	private var fetchInProgress = false

	// Active acquisition-tag filters; empty = show all. Restored from prefs, persisted on change.
	var activeTagFilters: Set<String> = preferences.getCloudTagFilters()
		private set

	init
	{
		_loading.value = false
		_error.value = null
		_searchQuery.value = ""
		_fallbackRegion.value = preferences.getCloudResolvedStoreCountry()
		_catalogIsForeign.value = preferences.isCloudCatalogIsForeign()
	}

	/**
	 * Fetch the unified cloud catalog (PS Now PS3/PS4 + PS5), tagged by acquisition category.
	 */
	fun fetchCatalog(forceRefresh: Boolean = false)
	{
		if (fetchInProgress)
		{
			Log.i(TAG, "Catalog fetch already in progress; ignoring request")
			return
		}
		fetchInProgress = true
		viewModelScope.launch {
			try
			{
				_loading.value = true
				_error.value = null
				_warning.value = null

				val npssoToken = preferences.getNpssoToken()
				Log.i(TAG, "Fetching unified cloud catalog (forceRefresh=$forceRefresh)")

				when (val result = repository.fetchUnifiedCatalog(npssoToken, forceRefresh))
				{
					is PsnResult.Success ->
					{
						allGames = result.data
						Log.i(TAG, "Loaded ${allGames.size} unified games")
						repository.lastCatalogFetchWarning?.let { _warning.value = it }
						// Match iOS: an empty list with no warning means the fetch effectively
						// failed (e.g. network) — tell the user instead of a blank screen.
						if (allGames.isEmpty() && _warning.value.isNullOrEmpty())
							_error.value = "No cloud games found. Check your connection."
						applyFilters()
					}
					is PsnResult.Error ->
					{
						Log.e(TAG, "Failed to fetch catalog: ${result.message}", result.exception)
						_error.value = result.message
					}
				}
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Unexpected error fetching catalog", e)
				_error.value = "Unexpected error: ${e.message}"
			}
			finally
			{
				_fallbackRegion.value = preferences.getCloudResolvedStoreCountry()
		_catalogIsForeign.value = preferences.isCloudCatalogIsForeign()
				updateLocaleWarningIfNeeded()
				_loading.value = false
				fetchInProgress = false
			}
		}
	}

	fun toggleTagFilter(tag: String)
	{
		activeTagFilters = if (tag in activeTagFilters) activeTagFilters - tag else activeTagFilters + tag
		preferences.setCloudTagFilters(activeTagFilters)
		applyFilters()
	}

	fun setTagFilters(tags: Set<String>)
	{
		activeTagFilters = tags
		preferences.setCloudTagFilters(activeTagFilters)
		applyFilters()
	}

	fun isTagFilterActive(tag: String): Boolean = tag in activeTagFilters

	fun setSearchQuery(query: String)
	{
		_searchQuery.value = query
		applyFilters()
	}

	private fun applyFilters()
	{
		val query = _searchQuery.value ?: ""
		var filtered = allGames

		if (activeTagFilters.isNotEmpty())
			filtered = filtered.filter { it.category in activeTagFilters }

		if (query.isNotEmpty())
			filtered = filtered.filter { game ->
				game.name.contains(query, ignoreCase = true) ||
					game.productId.contains(query, ignoreCase = true)
			}

		_games.value = filtered
	}

	fun clearError()
	{
		_error.value = null
	}

	fun clearCache()
	{
		// repository.clearCache() runs its file I/O off-main and serializes against an in-flight fetch.
		viewModelScope.launch {
			repository.clearCache()
			Log.i(TAG, "Cache cleared")
		}
	}

	fun clearGames()
	{
		allGames = emptyList()
		_games.value = emptyList()
		Log.i(TAG, "Games list cleared")
	}

	/** Apply an externally sorted ordering (search/tag filters re-applied on top is not needed). */
	fun setSortedGames(sortedGames: List<CloudGame>)
	{
		allGames = sortedGames
		applyFilters()
	}

	fun getAllCachedGames(): List<CloudGame> = allGames

	private fun updateLocaleWarningIfNeeded()
	{
		if (!_warning.value.isNullOrEmpty())
			return
		if (!preferences.isCloudStoreLocaleConfigured())
			_warning.value = CloudLocale.unconfiguredWarning()
	}
}
