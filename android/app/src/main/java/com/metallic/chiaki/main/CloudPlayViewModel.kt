// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.content.Context
import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.metallic.chiaki.cloudplay.CloudLocale
import com.metallic.chiaki.cloudplay.api.PsCloudOwnership
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

	private val _searchQuery = MutableLiveData<String>()
	val searchQuery: LiveData<String> get() = _searchQuery

	private var allGames: List<CloudGame> = emptyList()

	// Active acquisition-tag filters; empty = show all. Restored from prefs, persisted on change.
	var activeTagFilters: Set<String> = preferences.getCloudTagFilters()
		private set

	init
	{
		_loading.value = false
		_error.value = null
		_searchQuery.value = ""
		_fallbackRegion.value = preferences.getCloudFallbackRegion()
	}

	/**
	 * Fetch the unified cloud catalog (PS Now PS3/PS4 + PS5), tagged by acquisition category.
	 */
	fun fetchCatalog(forceRefresh: Boolean = false)
	{
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
				_fallbackRegion.value = preferences.getCloudFallbackRegion()
				updateLocaleWarningIfNeeded()
				_loading.value = false
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
		if (!preferences.isCloudLanguageConfigured())
			_warning.value = CloudLocale.unconfiguredWarning()
	}
}
