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
 * ViewModel for Cloud Play tab
 * Manages PSNow catalog data and UI state
 */
class CloudPlayViewModel(
	private val context: Context,
	val preferences: Preferences // Made public for access from CloudPlayFragment
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
	
	private val _searchQuery = MutableLiveData<String>()
	val searchQuery: LiveData<String> get() = _searchQuery
	
	private var allGames: List<CloudGame> = emptyList()
	private var currentSection: String = "psnow" // "psnow" or "pscloud"
	
	init
	{
		_loading.value = false
		_error.value = null
		_searchQuery.value = ""
		
		// Load last selected section from preferences
		currentSection = preferences.getLastCloudSection()
	}
	
	/**
	 * Fetch PSNow catalog from network/cache
	 */
	fun fetchPsnowCatalog(forceRefresh: Boolean = false, appendPs3Classics: Boolean = false)
	{
		viewModelScope.launch {
			try
			{
				_loading.value = true
				_error.value = null
				_warning.value = null

				Log.i(TAG, "Fetching PSNow catalog (forceRefresh=$forceRefresh)")

				val npssoToken = preferences.getNpssoToken()

				when (val result = repository.fetchPsnowCatalog(npssoToken, forceRefresh))
				{
					is PsnResult.Success ->
					{
						allGames = result.data
						Log.i(TAG, "Successfully loaded ${allGames.size} games")
						applySearchFilter()
						// PS3 Classics are subscription-streamable -> always shown in the Catalog.
						if (appendPs3Classics)
							fetchPs3ClassicsCatalog(forceRefresh)
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
				_loading.value = false
			}
		}
	}
	
	/**
	 * Fetch PS5 Cloud catalog from network/cache
	 * @param showOnlyOwned If true, fetches only user's owned games; if false, fetches all PS5 games
	 */
	fun fetchPs5CloudCatalog(showOnlyOwned: Boolean = false, forceRefresh: Boolean = false, appendPs3Classics: Boolean = false)
	{
		viewModelScope.launch {
			try
			{
				_loading.value = true
				_error.value = null
				_warning.value = null
				
				val npssoToken = preferences.getNpssoToken()
				
				if (showOnlyOwned)
				{
					Log.i(TAG, "Fetching owned PS5 games (forceRefresh=$forceRefresh)")
					
					when (val result = repository.fetchOwnedPs5Games(npssoToken, forceRefresh))
					{
						is PsnResult.Success ->
						{
							allGames = result.data
							Log.i(TAG, "Successfully loaded ${allGames.size} owned PS5 games")
							repository.lastCatalogFetchWarning?.let { _warning.value = it }
							applySearchFilter()
						}
						is PsnResult.Error ->
						{
							Log.e(TAG, "Failed to fetch owned PS5 games: ${result.message}", result.exception)
							_error.value = result.message
						}
					}
				}
				else
				{
					Log.i(TAG, "Fetching all PS5 Cloud catalog (forceRefresh=$forceRefresh)")
					
					when (val result = repository.fetchPs5CloudCatalog(npssoToken, forceRefresh))
					{
						is PsnResult.Success ->
						{
							allGames = result.data
							Log.i(TAG, "Successfully loaded ${allGames.size} PS5 games")
							repository.lastCatalogFetchWarning?.let { _warning.value = it }
							applySearchFilter()
							// Library "all" (streamable universe) includes PS3 Classics; "owned" does not.
							if (appendPs3Classics)
								fetchPs3ClassicsCatalog(forceRefresh)
						}
						is PsnResult.Error ->
						{
							Log.e(TAG, "Failed to fetch PS5 catalog: ${result.message}", result.exception)
							_error.value = result.message
						}
					}
				}
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Unexpected error fetching PS5 catalog", e)
				_error.value = "Unexpected error: ${e.message}"
			}
			finally
			{
				updateLocaleWarningIfNeeded()
				_loading.value = false
			}
		}
	}
	
	/**
	 * Fetch the streamable PS3 Classics (public Apollo container) and APPEND them to the
	 * already-displayed list. Additive: it never replaces the PS4/PS5 catalog already loaded,
	 * so it works whether the primary catalog came from PS Now or the imagic fallback. PS3
	 * Classics are subscription-streamable, so they belong in the Game Catalog and in the
	 * Library "all" view -- but NOT the "owned" view. Mirrors CloudPlayView.qml appendPs3Catalog().
	 */
	fun fetchPs3ClassicsCatalog(forceRefresh: Boolean = false)
	{
		viewModelScope.launch {
			try
			{
				when (val result = repository.fetchPs3ClassicsCatalog(forceRefresh))
				{
					is PsnResult.Success ->
					{
						if (result.data.isNotEmpty())
						{
							// De-dupe by productId in case of a re-entrant append.
							val existingIds = allGames.mapTo(HashSet()) { it.productId }
							val toAdd = result.data.filter { existingIds.add(it.productId) }
							if (toAdd.isNotEmpty())
							{
								allGames = allGames + toAdd
								Log.i(TAG, "Appended ${toAdd.size} PS3 Classics to catalog")
								applySearchFilter()
							}
						}
					}
					is PsnResult.Error ->
					{
						// Non-fatal: PS3 Classics are supplementary to the primary catalog.
						Log.w(TAG, "PS3 Classics catalog unavailable: ${result.message}")
					}
				}
			}
			catch (e: Exception)
			{
				Log.w(TAG, "Unexpected error fetching PS3 Classics catalog", e)
			}
		}
	}

	/**
	 * Get current section
	 */
	fun getCurrentSection(): String
	{
		return currentSection
	}
	
	/**
	 * Set current section and save to preferences
	 */
	fun setCurrentSection(section: String)
	{
		currentSection = section
		preferences.setLastCloudSection(section)
		Log.i(TAG, "Current section set to: $section")
	}
	
	/**
	 * Update search query and filter results
	 */
	fun setSearchQuery(query: String)
	{
		_searchQuery.value = query
		applySearchFilter()
	}
	
	/**
	 * Apply current search filter to games
	 */
	private fun applySearchFilter()
	{
		val query = _searchQuery.value ?: ""
		if (query.isEmpty())
		{
			_games.value = allGames
		}
		else
		{
			val filtered = allGames.filter { game ->
				game.name.contains(query, ignoreCase = true) ||
					game.productId.contains(query, ignoreCase = true)
			}
			_games.value = filtered
		}
	}
	
	/**
	 * Clear current error message
	 */
	fun clearError()
	{
		_error.value = null
	}
	
	/**
	 * Clear cached catalog data
	 */
	fun clearCache()
	{
		viewModelScope.launch {
			repository.clearCache()
			Log.i(TAG, "Cache cleared")
		}
	}
	
	/**
	 * Clear current games list (used when logging out or when token is invalid)
	 */
	fun clearGames()
	{
		allGames = emptyList()
		_games.value = emptyList()
		Log.i(TAG, "Games list cleared")
	}
	
	/**
	 * Update games with a sorted list
	 */
	fun setSortedGames(sortedGames: List<CloudGame>)
	{
		allGames = sortedGames
		applySearchFilter()
		Log.i(TAG, "Games list updated with sorted data")
	}
	
	/**
	 * Get all cached games (for filtering favorites)
	 */
	fun getAllCachedGames(): List<CloudGame>
	{
		return allGames
	}

	private fun updateLocaleWarningIfNeeded()
	{
		if (!_warning.value.isNullOrEmpty())
			return
		if (!preferences.isCloudLanguageConfigured())
			_warning.value = CloudLocale.unconfiguredWarning()
	}
}

