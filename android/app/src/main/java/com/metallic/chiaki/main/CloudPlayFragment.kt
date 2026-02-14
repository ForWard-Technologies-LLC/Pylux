// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.app.Activity
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Toast
import androidx.appcompat.widget.SearchView
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import coil.load
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.pylux.stream.R
import com.metallic.chiaki.cloudplay.PsnLoginActivity
import com.metallic.chiaki.cloudplay.api.CloudStreamingBackend
import com.metallic.chiaki.cloudplay.model.CloudError
import com.metallic.chiaki.cloudplay.model.CloudGame
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.common.ext.viewModelFactory
import com.pylux.stream.databinding.FragmentCloudPlayBinding
import kotlinx.coroutines.launch

class CloudPlayFragment : Fragment()
{
	companion object
	{
		private const val REQUEST_PSN_LOGIN = 1001
	}
	
	private lateinit var viewModel: CloudPlayViewModel
	private lateinit var binding: FragmentCloudPlayBinding
	private lateinit var adapter: CloudGameAdapter
	private lateinit var preferences: Preferences

	/** Cloud sub-tabs hosted in the activity's toolbar (between the two pill islands) */
	private val cloudTabLayout: com.google.android.material.tabs.TabLayout
		get() = (requireActivity() as MainActivity).getCloudSubTabs()
	
	// Sort state: 0 = Default, 1 = A->Z, 2 = Z->A
	private var sortState: Int = 0
	
	override fun onCreateView(
		inflater: LayoutInflater,
		container: ViewGroup?,
		savedInstanceState: Bundle?
	): View
	{
		binding = FragmentCloudPlayBinding.inflate(inflater, container, false)
		return binding.root
	}

	override fun onResume()
	{
		super.onResume()
		// Unlock orientation when returning from StreamActivity
		// This allows the device to return to the correct orientation based on its physical position
		if (savedOrientation != -1) {
			requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
			savedOrientation = -1
			Log.i("CloudPlayFragment", "Orientation unlocked (returning to device default)")
		}
		
		// Re-check login status when returning to fragment
		// This ensures that if user logged out in settings, we show the login screen
		if (!preferences.hasNpssoToken()) {
			Log.i("CloudPlayFragment", "onResume: No token found, showing login state")
			viewModel.clearCache()
			viewModel.clearGames()
			showLoginRequiredState()
		}
	}

	override fun onDestroyView()
	{
		super.onDestroyView()
		// Unlock orientation if it was locked (e.g., dialog was showing)
		if (savedOrientation != -1) {
			requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
		}
		// Dismiss progress dialog if still showing
		allocationProgressDialog?.dismiss()
		allocationProgressDialog = null
		allocationProgressTextView = null
		allocationGameImageView = null
		savedOrientation = -1
	}

	override fun onViewCreated(view: View, savedInstanceState: Bundle?)
	{
		super.onViewCreated(view, savedInstanceState)

		preferences = Preferences(requireContext())
		
		// Load saved sort state
		sortState = preferences.getCloudSortState()
		
		// Scope ViewModel to activity so it survives tab switches and maintains cache
		viewModel = ViewModelProvider(requireActivity(), viewModelFactory {
			CloudPlayViewModel(requireContext(), preferences)
		}).get(CloudPlayViewModel::class.java)

		setupRecyclerView()
		setupCloudTabs()
		setupSearchView()
		setupSettingsFab()
		setupSwipeRefresh()
		setupScrollListener()
		setupLoginButton()

		// Check login status BEFORE observing ViewModel to prevent cached games from showing
		if(savedInstanceState == null)
		{
			checkLoginStatus()
		}
		
		observeViewModel()
	}
	
	private fun setupLoginButton()
	{
		binding.loginButton.setOnClickListener {
			launchPsnLogin()
		}
	}
	
	private fun checkLoginStatus()
	{
		if (!preferences.hasNpssoToken())
		{
			Log.i("CloudPlayFragment", "No NPSSO token found, showing login required state")
			// IMMEDIATELY clear adapter so no cached games show
			adapter.games = emptyList()
			// Clear any cached data since we don't have valid credentials
			viewModel.clearCache()
			viewModel.clearGames()
			// Show the login required UI (with button)
			showLoginRequiredState()
		}
		else
		{
			Log.i("CloudPlayFragment", "NPSSO token found, validating...")
			validateTokenAndLoadCatalog()
		}
	}
	
	private fun showLoginPrompt()
	{
		MaterialAlertDialogBuilder(requireContext())
			.setTitle(R.string.psn_login_required_title)
			.setMessage(R.string.psn_login_prompt_message)
			.setPositiveButton(R.string.psn_login_button) { _, _ ->
				launchPsnLogin()
			}
			.setNegativeButton(R.string.action_cancel) { _, _ ->
				showLoginRequiredState()
			}
			.setCancelable(false)
			.show()
	}
	
	private fun launchPsnLogin()
	{
		val intent = Intent(requireContext(), PsnLoginActivity::class.java)
		startActivityForResult(intent, REQUEST_PSN_LOGIN)
	}
	
	private fun validateTokenAndLoadCatalog()
	{
		// Test token validity by attempting authorization check
		// This uses the same check as the main library (CloudStreamingBackend.checkAuthorization)
		lifecycleScope.launch {
			try
			{
				val npssoToken = preferences.getNpssoToken()
				if (npssoToken.isEmpty())
				{
					Log.w("CloudPlayFragment", "Token is empty, clearing cache")
					viewModel.clearCache()
					viewModel.clearGames()
					showLoginRequiredState()
					return@launch
				}
				
				// For now, assume token is valid and load catalog
				// The actual validation will happen when trying to start a cloud session
				// If token is invalid, the error handler will catch it and show login button
				Log.i("CloudPlayFragment", "Token appears valid, loading catalog")
				loadCatalog()
			}
			catch (e: Exception)
			{
				Log.e("CloudPlayFragment", "Token validation failed, clearing cache", e)
				viewModel.clearCache()
				viewModel.clearGames()
				showLoginRequiredState()
			}
		}
	}
	
	private fun loadCatalog()
	{
		hideLoginRequiredState()
		
		// Load based on last selected section (default to PSNow)
		val currentSection = viewModel.getCurrentSection()
		if (currentSection == "pscloud")
		{
			cloudTabLayout.selectTab(cloudTabLayout.getTabAt(1))
			adapter.showOwnershipBadge = true
			binding.sortOptionLayout.visibility = android.view.View.VISIBLE
			binding.filterOptionLayout.visibility = android.view.View.VISIBLE
			updateFilterButtonText()
			updateSortButtonText()
			
			// Fetch games based on current filter (observer will handle favorites filtering)
			val isOwnedFilter = viewModel.preferences.getPsCloudFilterOwned()
			val isFavoritesFilter = preferences.getPsCloudFilterFavorites()
			
			if (isFavoritesFilter) {
				// Fetch all games, observer will filter favorites
				viewModel.fetchPs5CloudCatalog(showOnlyOwned = false)
			} else {
				viewModel.fetchPs5CloudCatalog(showOnlyOwned = isOwnedFilter)
			}
		}
		else
		{
			cloudTabLayout.selectTab(cloudTabLayout.getTabAt(0))
			adapter.showOwnershipBadge = false
			binding.sortOptionLayout.visibility = android.view.View.VISIBLE
			binding.filterOptionLayout.visibility = android.view.View.VISIBLE
			updateFilterButtonText()
			updateSortButtonText()
			
			// Fetch catalog (observer will handle favorites filtering if active)
			viewModel.fetchPsnowCatalog()
		}
	}
	
	private fun showLoginRequiredState()
	{
		// IMMEDIATELY clear adapter and view model games
		adapter.games = emptyList()
		viewModel.clearGames()
		
		binding.loginRequiredLayout.visibility = View.VISIBLE
		binding.gamesRecyclerView.visibility = View.GONE
		binding.emptyStateLayout.visibility = View.GONE
		binding.progressBar.visibility = View.GONE
		binding.swipeRefreshLayout.isEnabled = false
	}
	
	private fun hideLoginRequiredState()
	{
		binding.loginRequiredLayout.visibility = View.GONE
		binding.swipeRefreshLayout.isEnabled = true
	}
	
	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?)
	{
		super.onActivityResult(requestCode, resultCode, data)
		
		if (requestCode == REQUEST_PSN_LOGIN)
		{
			when (resultCode)
			{
				Activity.RESULT_OK -> {
					Log.i("CloudPlayFragment", "Login successful")
					Toast.makeText(requireContext(), R.string.psn_login_success, Toast.LENGTH_SHORT).show()
					validateTokenAndLoadCatalog()
				}
				Activity.RESULT_CANCELED -> {
					Log.i("CloudPlayFragment", "Login cancelled by user")
					showLoginRequiredState()
				}
				PsnLoginActivity.RESULT_LOGIN_FAILED -> {
					Log.e("CloudPlayFragment", "Login failed")
					Toast.makeText(requireContext(), R.string.psn_login_failed, Toast.LENGTH_LONG).show()
					showLoginRequiredState()
				}
			}
		}
	}

	override fun onConfigurationChanged(newConfig: android.content.res.Configuration) {
		super.onConfigurationChanged(newConfig)
		// Update grid layout on orientation change
		// Calculate span count based on new screen dimensions
		val spanCount = calculateSpanCount()
		
		// Save current scroll position
		val layoutManager = binding.gamesRecyclerView.layoutManager as? GridLayoutManager
		val scrollPosition = layoutManager?.findFirstVisibleItemPosition() ?: 0
		
		// Clear RecyclerView's view cache to force recreation of all view holders
		binding.gamesRecyclerView.recycledViewPool.clear()
		
		// Detach and reattach adapter to force all view holders to be recreated with new layout
		val currentAdapter = binding.gamesRecyclerView.adapter
		binding.gamesRecyclerView.adapter = null
		
		// Recreate layout manager to ensure fresh state
		val newLayoutManager = GridLayoutManager(requireContext(), spanCount)
		binding.gamesRecyclerView.layoutManager = newLayoutManager
		
		// Reattach adapter
		binding.gamesRecyclerView.adapter = currentAdapter
		
		// Notify adapter to refresh all items - this ensures view holders are recreated
		adapter.notifyDataSetChanged()
		
		// Restore scroll position and invalidate after layout is complete
		binding.gamesRecyclerView.post {
			if (scrollPosition > 0 && scrollPosition < adapter.itemCount) {
				newLayoutManager.scrollToPositionWithOffset(scrollPosition, 0)
			}
			binding.gamesRecyclerView.invalidateItemDecorations()
			binding.gamesRecyclerView.requestLayout()
		}
	}

	fun toggleSearch()
	{
		isSearchExpanded = !isSearchExpanded
		
		if (isSearchExpanded) {
			// Expand search bar
			binding.searchView.visibility = android.view.View.VISIBLE
			binding.searchView.layoutParams = binding.searchView.layoutParams.apply {
				height = android.view.ViewGroup.LayoutParams.WRAP_CONTENT
			}
			binding.searchView.requestFocus()
			// Show keyboard
			val imm = requireContext().getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
			imm.showSoftInput(binding.searchView, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
		} else {
			// Collapse search bar
			collapseSearchBar()
		}
	}
	
	private fun setupScrollListener()
	{
		// Hide search bar when scrolling
		binding.gamesRecyclerView.addOnScrollListener(object : androidx.recyclerview.widget.RecyclerView.OnScrollListener() {
			override fun onScrolled(recyclerView: androidx.recyclerview.widget.RecyclerView, dx: Int, dy: Int) {
				super.onScrolled(recyclerView, dx, dy)
				if (dy > 0 && isSearchExpanded) {
					// Scrolling down - collapse search
					isSearchExpanded = false
					collapseSearchBar()
				}
			}
		})
	}
	
	private var isSearchExpanded = false
	
	private fun collapseSearchBar()
	{
		binding.searchView.visibility = android.view.View.GONE
		binding.searchView.layoutParams = binding.searchView.layoutParams.apply {
			height = 0
		}
		binding.searchView.setQuery("", false)
		binding.searchView.clearFocus()
		// Hide keyboard
		val imm = requireContext().getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
		imm.hideSoftInputFromWindow(binding.searchView.windowToken, 0)
	}
	
	private fun setupCloudTabs()
	{
		cloudTabLayout.addTab(cloudTabLayout.newTab().setText("Catalog"))
		cloudTabLayout.addTab(cloudTabLayout.newTab().setText("Library"))
		
		cloudTabLayout.addOnTabSelectedListener(object : com.google.android.material.tabs.TabLayout.OnTabSelectedListener
		{
			override fun onTabSelected(tab: com.google.android.material.tabs.TabLayout.Tab?)
			{
				when (tab?.position)
				{
					0 -> {
						// Catalog
						viewModel.setCurrentSection("psnow")
						adapter.showOwnershipBadge = false
						// Show both sort and filter options for catalog tab
						binding.sortOptionLayout.visibility = android.view.View.VISIBLE
						binding.filterOptionLayout.visibility = android.view.View.VISIBLE
						updateSortButtonText()
						updateFilterButtonText()
						// Always fetch when switching to this tab (uses cache if available)
						// Observer will handle favorites filtering if active
						viewModel.fetchPsnowCatalog()
					}
					1 -> {
						// Game Library
						viewModel.setCurrentSection("pscloud")
						adapter.showOwnershipBadge = true
						// Show both sort and filter options for game library tab
						binding.sortOptionLayout.visibility = android.view.View.VISIBLE
						binding.filterOptionLayout.visibility = android.view.View.VISIBLE
						updateSortButtonText()
						updateFilterButtonText()
						// Always fetch when switching to this tab (uses cache if available)
						// Observer will handle favorites filtering if active
						val isOwnedFilter = viewModel.preferences.getPsCloudFilterOwned()
						val isFavoritesFilter = preferences.getPsCloudFilterFavorites()
						
						if (isFavoritesFilter) {
							// Fetch all games, observer will filter favorites
							viewModel.fetchPs5CloudCatalog(showOnlyOwned = false)
						} else {
							viewModel.fetchPs5CloudCatalog(showOnlyOwned = isOwnedFilter)
						}
					}
				}
			}

			override fun onTabUnselected(tab: com.google.android.material.tabs.TabLayout.Tab?) {}
			override fun onTabReselected(tab: com.google.android.material.tabs.TabLayout.Tab?) {}
		})
	}
	
	private fun setupSettingsFab()
	{
		binding.settingsFab.setOnClickListener {
			expandSettingsFab(!binding.settingsFab.isExpanded)
		}
		
		binding.settingsDialBackground.setOnClickListener {
			expandSettingsFab(false)
		}
		
		// Refresh button and label
		binding.refreshButton.setOnClickListener { refreshGamesList() }
		binding.refreshLabelButton.setOnClickListener { refreshGamesList() }
		
		// Sort button and label
		binding.sortButton.setOnClickListener { showSortMenu(binding.sortButton) }
		binding.sortLabelButton.setOnClickListener { showSortMenu(binding.sortLabelButton) }
		
		// Filter button and label (owned/all games)
		binding.filterButton.setOnClickListener { showFilterMenu(binding.filterButton) }
		binding.filterLabelButton.setOnClickListener { showFilterMenu(binding.filterLabelButton) }
		
		updateSortButtonText()
	}
	
	private fun expandSettingsFab(expand: Boolean)
	{
		binding.settingsFab.isExpanded = expand
		binding.settingsFab.isActivated = binding.settingsFab.isExpanded
	}
	
	private fun refreshGamesList()
	{
		expandSettingsFab(false)
		
		// Keep current sort state when refreshing
		val currentSection = viewModel.getCurrentSection()
		if (currentSection == "pscloud")
		{
			val isOwnedFilter = viewModel.preferences.getPsCloudFilterOwned()
			viewModel.fetchPs5CloudCatalog(showOnlyOwned = isOwnedFilter, forceRefresh = true)
		}
		else
		{
			viewModel.fetchPsnowCatalog(forceRefresh = true)
		}
	}
	
	private fun showSortMenu(anchor: android.view.View)
	{
		expandSettingsFab(false)
		
		val currentSection = viewModel.getCurrentSection()
		val popup = androidx.appcompat.widget.PopupMenu(requireContext(), anchor)
		
		// Different default sort for Library vs Catalog
		if (currentSection == "pscloud") {
			popup.menu.add(0, 0, 0, "Owned First (Default)")
		} else {
			popup.menu.add(0, 0, 0, "Recent (Default)")
		}
		popup.menu.add(0, 1, 1, "Name: A → Z")
		popup.menu.add(0, 2, 2, "Name: Z → A")
		
		// Highlight current selection with radio button style
		popup.menu.findItem(sortState)?.isChecked = true
		popup.menu.setGroupCheckable(0, true, true)
		
		popup.setOnMenuItemClickListener { item ->
			applySortState(item.itemId)
			true
		}
		
		popup.show()
	}
	
	private fun applySortState(newSortState: Int)
	{
		sortState = newSortState
		preferences.setCloudSortState(sortState)
		updateSortButtonText()
		
		val currentGames = viewModel.games.value ?: return
		val currentSection = viewModel.getCurrentSection()
		
		when (sortState) {
			0 -> {
				// Default: Different behavior for Library vs Catalog
				if (currentSection == "pscloud") {
					// Library: Sort by ownership (owned first), then maintain order
					val sortedGames = currentGames.sortedWith(
						compareByDescending<CloudGame> { it.isOwned }
					)
					viewModel.setSortedGames(sortedGames)
				} else {
					// Catalog: Reload from cache to restore original API order
					viewModel.fetchPsnowCatalog(forceRefresh = false)
				}
			}
			1 -> {
				// A->Z
				val sortedGames = currentGames.sortedBy { it.name.lowercase() }
				viewModel.setSortedGames(sortedGames)
			}
			2 -> {
				// Z->A
				val sortedGames = currentGames.sortedByDescending { it.name.lowercase() }
				viewModel.setSortedGames(sortedGames)
			}
		}
	}
	
	private fun updateSortButtonText()
	{
		val currentSection = viewModel.getCurrentSection()
		val text = when (sortState) {
			0 -> if (currentSection == "pscloud") "Sort: Owned" else "Sort: Recent"
			1 -> "Sort: A→Z"
			2 -> "Sort: Z→A"
			else -> if (currentSection == "pscloud") "Sort: Owned" else "Sort: Recent"
		}
		binding.sortLabelButton.text = text
	}
	
	private fun showFilterMenu(anchor: android.view.View)
	{
		expandSettingsFab(false)
		
		val currentSection = viewModel.getCurrentSection()
		val popup = androidx.appcompat.widget.PopupMenu(requireContext(), anchor)
		
		if (currentSection == "pscloud") {
			// Game Library: All Games, Owned Games, Favorites
			popup.menu.add(0, 0, 0, "Show: All Games")
			popup.menu.add(0, 1, 1, "Show: Owned Only")
			popup.menu.add(0, 2, 2, "Show: Favorites")
			
			// Highlight current selection
			val currentItem = when {
				preferences.getPsCloudFilterFavorites() -> 2
				preferences.getPsCloudFilterOwned() -> 1
				else -> 0
			}
			popup.menu.findItem(currentItem)?.isChecked = true
		} else {
			// Game Catalog: All Games, Favorites
			popup.menu.add(0, 0, 0, "Show: All Games")
			popup.menu.add(0, 1, 1, "Show: Favorites")
			
			// Highlight current selection
			val currentItem = if (preferences.getPsnowFilterFavorites()) 1 else 0
			popup.menu.findItem(currentItem)?.isChecked = true
		}
		
		popup.menu.setGroupCheckable(0, true, true)
		
		popup.setOnMenuItemClickListener { item ->
			applyFilterState(currentSection, item.itemId)
			true
		}
		
		popup.show()
	}
	
	private fun applyFilterState(currentSection: String, selectedItem: Int)
	{
		if (currentSection == "pscloud") {
			// Game Library
			when (selectedItem) {
				0 -> {
					// All Games
					preferences.setPsCloudFilterFavorites(false)
					preferences.setPsCloudFilterOwned(false)
					viewModel.fetchPs5CloudCatalog(showOnlyOwned = false, forceRefresh = false)
				}
				1 -> {
					// Owned Games
					preferences.setPsCloudFilterFavorites(false)
					preferences.setPsCloudFilterOwned(true)
					viewModel.fetchPs5CloudCatalog(showOnlyOwned = true, forceRefresh = false)
				}
				2 -> {
					// Favorites
					preferences.setPsCloudFilterFavorites(true)
					preferences.setPsCloudFilterOwned(false)
					viewModel.fetchPs5CloudCatalog(showOnlyOwned = false, forceRefresh = false)
				}
			}
		} else {
			// Game Catalog
			when (selectedItem) {
				0 -> {
					// All Games
					preferences.setPsnowFilterFavorites(false)
					viewModel.fetchPsnowCatalog(forceRefresh = false)
				}
				1 -> {
					// Favorites
					preferences.setPsnowFilterFavorites(true)
					viewModel.fetchPsnowCatalog(forceRefresh = false)
				}
			}
		}
		
		updateFilterButtonText()
	}
	
	private fun updateFilterButtonText()
	{
		val currentSection = viewModel.getCurrentSection()
		val text = if (currentSection == "pscloud") {
			// Game Library
			when {
				preferences.getPsCloudFilterFavorites() -> "Show: Favorites"
				preferences.getPsCloudFilterOwned() -> "Show: Owned"
				else -> "Show: All"
			}
		} else {
			// Game Catalog
			if (preferences.getPsnowFilterFavorites()) "Show: Favorites" else "Show: All"
		}
		binding.filterLabelButton.text = text
	}
	
	private fun filterAndDisplayFavorites()
	{
		val favoriteIds = preferences.getFavoriteGames()
		val allGames = viewModel.getAllCachedGames()
		val favoriteGames = allGames.filter { favoriteIds.contains(it.productId) }
		
		// Apply current sort state
		val sortedGames = when (sortState) {
			1 -> favoriteGames.sortedBy { it.name.lowercase() }
			2 -> favoriteGames.sortedByDescending { it.name.lowercase() }
			else -> favoriteGames
		}
		
		adapter.games = sortedGames
		updateEmptyState(sortedGames.isEmpty())
		binding.swipeRefreshLayout.isRefreshing = false
	}

	private fun setupRecyclerView()
	{
		adapter = CloudGameAdapter(
			onGameClick = this::onGameClicked,
			onFavoriteClick = this::onGameFavoriteToggled,
			isFavorite = { productId -> preferences.isFavoriteGame(productId) }
		)
		binding.gamesRecyclerView.adapter = adapter
		// Calculate span count based on screen width for responsive grid
		val spanCount = calculateSpanCount()
		binding.gamesRecyclerView.layoutManager = GridLayoutManager(requireContext(), spanCount)
	}
	
	/**
	 * Calculate the number of columns based on screen width
	 * Aim for cards that are around 180dp wide for bigger cards
	 */
	private fun calculateSpanCount(): Int {
		val displayMetrics = resources.displayMetrics
		val screenWidthDp = displayMetrics.widthPixels / displayMetrics.density
		val cardWidthDp = 180 // Target card width in dp (bigger cards)
		val spanCount = (screenWidthDp / cardWidthDp).toInt()
		// Ensure at least 2 columns, maximum 4 columns for bigger cards
		return spanCount.coerceIn(2, 4)
	}
	
	private fun onGameFavoriteToggled(game: CloudGame, isFavorite: Boolean)
	{
		if (isFavorite) {
			preferences.addFavoriteGame(game.productId)
		} else {
			preferences.removeFavoriteGame(game.productId)
		}
		
		// If currently showing favorites, refresh the list
		val currentSection = viewModel.getCurrentSection()
		if (currentSection == "psnow" && preferences.getPsnowFilterFavorites()) {
			// Refresh catalog favorites
			refreshGamesList()
		} else if (currentSection == "pscloud" && preferences.getPsCloudFilterFavorites()) {
			// Refresh game library favorites
			refreshGamesList()
		}
	}

	private fun setupSearchView()
	{
		binding.searchView.setOnQueryTextListener(object : SearchView.OnQueryTextListener
		{
			override fun onQueryTextSubmit(query: String?): Boolean
			{
				return false
			}

			override fun onQueryTextChange(newText: String?): Boolean
			{
				viewModel.setSearchQuery(newText ?: "")
				return true
			}
		})
	}

	private fun setupSwipeRefresh()
	{
		binding.swipeRefreshLayout.setOnRefreshListener {
			// Refresh based on current section
			when (viewModel.getCurrentSection())
			{
				"pscloud" -> {
					val showOnlyOwned = viewModel.preferences.getPsCloudFilterOwned()
					viewModel.fetchPs5CloudCatalog(showOnlyOwned = showOnlyOwned, forceRefresh = true)
				}
				else -> viewModel.fetchPsnowCatalog(forceRefresh = true)
			}
		}
	}

	private fun observeViewModel()
	{
		viewModel.games.observe(viewLifecycleOwner, Observer { games ->
			android.util.Log.i("CloudPlayFragment", "Games LiveData updated: ${games.size} games")
			
			// Don't show games if user is not logged in
			if (!preferences.hasNpssoToken()) {
				android.util.Log.i("CloudPlayFragment", "No token, ignoring cached games")
				adapter.games = emptyList()
				return@Observer
			}
			
			// Check if favorites filter is active for current section
			val currentSection = viewModel.getCurrentSection()
			val isFavoritesFilter = if (currentSection == "pscloud") {
				preferences.getPsCloudFilterFavorites()
			} else {
				preferences.getPsnowFilterFavorites()
			}
			
			// Filter for favorites if that filter is active
			val filteredGames = if (isFavoritesFilter) {
				val favoriteIds = preferences.getFavoriteGames()
				games.filter { favoriteIds.contains(it.productId) }
			} else {
				games
			}
			
			// Apply saved sort state when games are loaded
			val sortedGames = when (sortState) {
				0 -> {
					// Default sort: Owned first for Library, original order for Catalog
					if (currentSection == "pscloud") {
						filteredGames.sortedWith(compareByDescending { it.isOwned })
					} else {
						filteredGames
					}
				}
				1 -> filteredGames.sortedBy { it.name.lowercase() } // A->Z
				2 -> filteredGames.sortedByDescending { it.name.lowercase() } // Z->A
				else -> filteredGames
			}
			adapter.games = sortedGames
			
			updateEmptyState(sortedGames.isEmpty())
			
			// Auto-focus first item after games are loaded
			if (sortedGames.isNotEmpty()) {
				focusFirstGame()
			}
		})

		viewModel.loading.observe(viewLifecycleOwner, Observer { loading ->
			android.util.Log.i("CloudPlayFragment", "Loading LiveData updated: $loading")
			binding.swipeRefreshLayout.isRefreshing = loading
			binding.progressBar.visibility = if(loading && adapter.games.isEmpty()) View.VISIBLE else View.GONE
		})

		viewModel.error.observe(viewLifecycleOwner, Observer { error ->
			if (error.isNullOrEmpty()) {
				Log.d("CloudPlayFragment", "Error is null/empty, ignoring")
				return@Observer
			}
			
			Log.w("CloudPlayFragment", "Processing error: '$error'")
			
			// Clear the error FIRST so we don't get another notification
			viewModel.clearError()
			
			// Then show the error dialog
			showError(error)
		})
	}

	private fun updateEmptyState(isEmpty: Boolean)
	{
		binding.emptyStateLayout.visibility = if(isEmpty) View.VISIBLE else View.GONE
		binding.gamesRecyclerView.visibility = if(isEmpty) View.GONE else View.VISIBLE
	}
	
	private fun focusFirstGame()
	{
		binding.gamesRecyclerView.postDelayed({
			if (adapter.itemCount > 0) {
				val layoutManager = binding.gamesRecyclerView.layoutManager as? androidx.recyclerview.widget.GridLayoutManager
				// Scroll to position first to ensure it's visible
				layoutManager?.scrollToPosition(0)
				// Then request focus with another slight delay for the view to be ready
				binding.gamesRecyclerView.postDelayed({
					val firstView = layoutManager?.findViewByPosition(0)
					firstView?.requestFocus()
				}, 50)
			}
		}, 100)
	}

	private fun showError(message: String)
	{
		Log.d("CloudPlayFragment", "showError called with: '$message'")
		val error = CloudError.fromMessage(message)
		Log.d("CloudPlayFragment", "Error classified as: ${error::class.simpleName}")
		
		when (error) {
			is CloudError.AuthenticationError -> {
				Log.i("CloudPlayFragment", "Handling as AuthenticationError")
				handleAuthenticationError(error)
			}
			is CloudError.NetworkError -> {
				Log.i("CloudPlayFragment", "Handling as NetworkError")
				handleNetworkError(error)
			}
			is CloudError.GeneralError -> {
				Log.i("CloudPlayFragment", "Handling as GeneralError")
				handleGeneralError(error)
			}
		}
	}
	
	private fun handleAuthenticationError(error: CloudError.AuthenticationError)
	{
		Log.w("CloudPlayFragment", "Authentication error: ${error.message}, clearing everything")
		
		// IMMEDIATELY clear games list first so user doesn't see cached games
		adapter.games = emptyList()
		
		// Clear cache, games, and token
		viewModel.clearCache()
		viewModel.clearGames()
		preferences.clearNpssoToken()
		
		// Show login required state
		showLoginRequiredState()
		
		// Then show authentication error dialog
		MaterialAlertDialogBuilder(requireContext())
			.setTitle(getString(R.string.psn_login_required_title))
			.setMessage(getString(R.string.psn_login_session_expired_message))
			.setPositiveButton(R.string.psn_login_button) { _, _ ->
				launchPsnLogin()
			}
			.setNegativeButton(R.string.action_cancel, null)
			.setCancelable(false)
			.show()
	}
	
	private fun handleNetworkError(error: CloudError.NetworkError)
	{
		MaterialAlertDialogBuilder(requireContext())
			.setTitle(R.string.error_network_title)
			.setMessage(error.message)
			.setPositiveButton(R.string.action_retry) { _, _ ->
				// Retry loading catalog
				loadCatalog()
			}
			.setNegativeButton(R.string.action_cancel, null)
			.show()
	}
	
	private fun handleGeneralError(error: CloudError.GeneralError)
	{
		MaterialAlertDialogBuilder(requireContext())
			.setTitle(R.string.error)
			.setMessage(error.message)
			.setPositiveButton(R.string.action_ok, null)
			.show()
	}

	private fun onGameClicked(game: CloudGame)
	{
		Log.i("CloudPlayFragment", "=== Game Clicked ===")
		Log.i("CloudPlayFragment", "Game Name: ${game.name}")
		Log.i("CloudPlayFragment", "Game ID (Product ID): ${game.productId}")
		Log.i("CloudPlayFragment", "Platform: ${game.platform}")
		Log.i("CloudPlayFragment", "Service Type: ${game.serviceType}")
		Log.i("CloudPlayFragment", "Is Owned: ${game.isOwned}")
		Log.i("CloudPlayFragment", "Concept URL: ${game.conceptUrl}")
		
		// Check if this is a non-owned PS5 game in "All Games" mode (Qt: CloudGameCard.qml lines 315-333)
		val isPscloud = game.serviceType == "pscloud"
		val isAllGamesFilter = !viewModel.preferences.getPsCloudFilterOwned()
		
		if (isPscloud && isAllGamesFilter && !game.isOwned)
		{
			// Show dialog to add game to library
			showAddToLibraryDialog(game)
		}
		else
		{
			// Start cloud streaming
			startCloudStreaming(game)
		}
	}
	
	/**
	 * Show dialog for adding non-owned PS5 game to library
	 * Mirrors: QRCodeDialog.qml (Qt)
	 */
	private fun showAddToLibraryDialog(game: CloudGame)
	{
		if (game.conceptUrl.isEmpty())
		{
			Log.e("CloudPlayFragment", "Concept URL is missing for game: ${game.name}")
			MaterialAlertDialogBuilder(requireContext())
				.setTitle("Add to Library")
				.setMessage("Unable to add this game to your library. The game URL is not available.")
				.setPositiveButton("OK", null)
				.show()
			return
		}
		
		MaterialAlertDialogBuilder(requireContext())
			.setTitle("Add to Library")
			.setMessage("This game needs to be added to your library before you can stream it.\n\nAfter adding the game, press the Refresh Games button to update your list.")
			.setPositiveButton("Add Now") { _, _ ->
				// Open concept URL in external browser
				openUrlInBrowser(game.conceptUrl)
			}
			.setNegativeButton("Cancel", null)
			.show()
	}
	
	/**
	 * Open URL in external browser via Intent
	 */
	private fun openUrlInBrowser(url: String)
	{
		try
		{
			val intent = android.content.Intent(android.content.Intent.ACTION_VIEW, android.net.Uri.parse(url))
			startActivity(intent)
			Log.i("CloudPlayFragment", "Opened URL in browser: $url")
		}
		catch (e: Exception)
		{
			Log.e("CloudPlayFragment", "Failed to open URL in browser: $url", e)
			android.widget.Toast.makeText(requireContext(), "Failed to open browser", android.widget.Toast.LENGTH_SHORT).show()
		}
	}
	
	// Allocation progress dialog state
	private var allocationProgressDialog: androidx.appcompat.app.AlertDialog? = null
	private var allocationProgressTextView: android.widget.TextView? = null
	private var allocationGameImageView: android.widget.ImageView? = null
	private var allocationCancelled = false
	private var savedOrientation: Int = -1  // Save original orientation
	
	private fun startCloudStreaming(game: CloudGame)
	{
		Log.i("CloudPlayFragment", "Starting cloud streaming for ${game.name}")
		Log.i("CloudPlayFragment", "  Service: ${game.serviceType}")
		Log.i("CloudPlayFragment", "  Product ID: ${game.productId}")
		Log.i("CloudPlayFragment", "  Platform: ${game.platform}")
		
		// Reset cancellation flag
		allocationCancelled = false
		
		// Create and show full-screen progress dialog with game image
		requireActivity().runOnUiThread {
			// Save current orientation and switch to landscape (like StreamActivity)
			savedOrientation = requireActivity().requestedOrientation
			requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_USER_LANDSCAPE
			
			val dialogView = android.view.LayoutInflater.from(requireContext()).inflate(R.layout.dialog_allocation_progress, null)
			allocationGameImageView = dialogView.findViewById(R.id.gameImageView)
			allocationProgressTextView = dialogView.findViewById(R.id.progressTextView)
			val cancelButton = dialogView.findViewById<com.google.android.material.button.MaterialButton>(R.id.cancelButton)
			
			allocationProgressTextView?.text = "Starting allocation..."
			
			// Load landscape game image using Coil (for full-screen loading dialog)
			val imageUrlToLoad = if (game.landscapeImageUrl.isNotEmpty()) {
				game.landscapeImageUrl
			} else {
				game.imageUrl  // Fallback to cover if no landscape available
			}
			
			if (imageUrlToLoad.isNotEmpty()) {
				allocationGameImageView?.load(imageUrlToLoad) {
					crossfade(true)
					error(android.R.drawable.ic_menu_report_image)
				}
				Log.d("CloudPlayFragment", "Loading landscape image: $imageUrlToLoad")
			}
			
			cancelButton.setOnClickListener {
				allocationCancelled = true
				Log.i("CloudPlayFragment", "User cancelled allocation")
				// Unlock orientation to full sensor control
				requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
				Log.i("CloudPlayFragment", "Orientation unlocked to FULL_SENSOR")
				savedOrientation = -1
				allocationProgressDialog?.dismiss()
			}
			
			allocationProgressDialog = MaterialAlertDialogBuilder(requireContext())
				.setView(dialogView)
				.setCancelable(false)
				.create()
			
			// Make dialog truly full screen (no action bar, no system UI)
			allocationProgressDialog?.window?.let { window ->
				window.setLayout(
					android.view.ViewGroup.LayoutParams.MATCH_PARENT,
					android.view.ViewGroup.LayoutParams.MATCH_PARENT
				)
				window.setBackgroundDrawableResource(android.R.color.transparent)
				// Remove dialog padding/margins
				window.decorView.setPadding(0, 0, 0, 0)
				
				// Hide system UI for true fullscreen (like StreamActivity)
				window.decorView.systemUiVisibility = (
					android.view.View.SYSTEM_UI_FLAG_IMMERSIVE
					or android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE
					or android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
					or android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
					or android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
					or android.view.View.SYSTEM_UI_FLAG_FULLSCREEN
				)
				
				// Handle orientation changes like StreamActivity
				// Allow dialog to handle orientation changes
				window.decorView.setOnSystemUiVisibilityChangeListener { visibility ->
					if (visibility and android.view.View.SYSTEM_UI_FLAG_FULLSCREEN == 0) {
						// System UI is visible, re-hide it
						window.decorView.systemUiVisibility = (
							android.view.View.SYSTEM_UI_FLAG_IMMERSIVE
							or android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE
							or android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
							or android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
							or android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
							or android.view.View.SYSTEM_UI_FLAG_FULLSCREEN
						)
					}
				}
			}
			
			allocationProgressDialog?.show()
			Log.i("CloudPlayFragment", "Full-screen progress dialog shown with game image (landscape)")
		}
		
		// Get NPSSO token from secure storage
		val npssoToken = preferences.getNpssoToken()
		
		// Start cloud session in coroutine
		lifecycleScope.launch {
			try
			{
				val backend = CloudStreamingBackend(requireContext(), viewModel.preferences)
				val result = backend.startCompleteCloudSession(
					serviceType = game.serviceType,
					gameIdentifier = game.productId,
					gameName = game.name,
					npssoToken = npssoToken,
					onProgress = { message ->
						// Update dialog message on main thread
						requireActivity().runOnUiThread {
							allocationProgressTextView?.text = message
							Log.d("CloudPlayFragment", "Progress: $message")
						}
					},
					isCancelled = { allocationCancelled }
				)
				
				result.onSuccess { session ->
					Log.i("CloudPlayFragment", "✓ Cloud session created successfully!")
					Log.i("CloudPlayFragment", "  Server IP: ${session.serverIp}")
					Log.i("CloudPlayFragment", "  Session ID: ${session.sessionId}")
					
					// Launch StreamActivity with cloud session data
					// Keep dialog visible during transition - it will be dismissed when StreamActivity starts
					launchCloudStream(session)
				}
				
				result.onFailure { error ->
					// Dismiss progress dialog and unlock orientation to full sensor control
					requireActivity().runOnUiThread {
						requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
						savedOrientation = -1
						Log.i("CloudPlayFragment", "Orientation unlocked to FULL_SENSOR on allocation failure.")
						allocationProgressDialog?.dismiss()
						allocationProgressDialog = null
						allocationProgressTextView = null
						allocationGameImageView = null
					}
					
					// Don't show error if user cancelled
					if (allocationCancelled) {
						Log.i("CloudPlayFragment", "Allocation was cancelled by user")
						return@launch
					}
					
					Log.e("CloudPlayFragment", "✗ Cloud session failed: ${error.message}")
					
					// Handle specific error types with appropriate dialogs
					when (error)
					{
						is com.metallic.chiaki.cloudplay.api.PsPlusSubscriptionException ->
						{
							showPsPlusSubscriptionErrorDialog()
						}
						is com.metallic.chiaki.cloudplay.api.AccountPrivacySettingsException ->
						{
							showAccountPrivacySettingsErrorDialog(error.upgradeUrl)
						}
						is com.metallic.chiaki.cloudplay.api.PingTimeoutException ->
						{
							showPingTimeoutErrorDialog()
						}
						is com.metallic.chiaki.cloudplay.api.AuthorizationFailedException ->
						{
							showAuthorizationFailedDialog()
						}
						else ->
						{
							// Generic error
							showError("Cloud Session Failed", error.message ?: "Unknown error")
						}
					}
				}
			}
			catch (e: Exception)
			{
				// Dismiss progress dialog and unlock orientation to full sensor control
				requireActivity().runOnUiThread {
					requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
					savedOrientation = -1
					Log.i("CloudPlayFragment", "Orientation unlocked to FULL_SENSOR on exception.")
					allocationProgressDialog?.dismiss()
					allocationProgressDialog = null
					allocationProgressTextView = null
					allocationGameImageView = null
				}
				
				// Don't show error if user cancelled
				if (allocationCancelled) {
					Log.i("CloudPlayFragment", "Allocation was cancelled by user")
					return@launch
				}
				
				Log.e("CloudPlayFragment", "Exception starting cloud session", e)
				
				// Handle specific exception types
				when (e)
				{
					is com.metallic.chiaki.cloudplay.api.PsPlusSubscriptionException ->
					{
						showPsPlusSubscriptionErrorDialog()
					}
					is com.metallic.chiaki.cloudplay.api.AccountPrivacySettingsException ->
					{
						showAccountPrivacySettingsErrorDialog(e.upgradeUrl)
					}
					is com.metallic.chiaki.cloudplay.api.PingTimeoutException ->
					{
						showPingTimeoutErrorDialog()
					}
					is com.metallic.chiaki.cloudplay.api.AuthorizationFailedException ->
					{
						showAuthorizationFailedDialog()
					}
					else ->
					{
						showError("Error", e.message ?: "Unknown error")
					}
				}
			}
		}
	}
	
	/**
	 * Show PS Plus subscription error dialog
	 * Mirrors: CloudStreamingBackend Qt signals
	 */
	private fun showPsPlusSubscriptionErrorDialog()
	{
		MaterialAlertDialogBuilder(requireContext())
			.setTitle("PlayStation Plus Required")
			.setMessage("You need an active PlayStation Plus Premium subscription to stream games from the cloud, or this service may not be available in your region.")
			.setPositiveButton("OK", null)
			.show()
	}
	
	/**
	 * Show account privacy settings error dialog
	 */
	private fun showAccountPrivacySettingsErrorDialog(upgradeUrl: String)
	{
		MaterialAlertDialogBuilder(requireContext())
			.setTitle("Account Settings Update Required")
			.setMessage("Your account privacy settings need to be updated to use cloud streaming.\n\nUpgrade URL: $upgradeUrl")
			.setPositiveButton("OK", null)
			.show()
	}
	
	/**
	 * Show ping timeout error dialog
	 */
	private fun showPingTimeoutErrorDialog()
	{
		MaterialAlertDialogBuilder(requireContext())
			.setTitle("Ping Too High")
			.setMessage("Ping must be less than 80ms to start a cloud session.\n\nTo continue anyway, go to Settings → Cloud and manually select a datacenter for your service (PSNow Catalog).")
			.setPositiveButton("OK", null)
			.show()
	}
	
	/**
	 * Show authorization failed dialog
	 */
	private fun showAuthorizationFailedDialog()
	{
		MaterialAlertDialogBuilder(requireContext())
			.setTitle("Authorization Failed")
			.setMessage("Failed to authorize your PlayStation Network account. Please check your NPSSO token and try again.")
			.setPositiveButton("OK", null)
			.show()
	}
	
	/**
	 * Show generic error dialog
	 */
	private fun showError(title: String, message: String)
	{
		MaterialAlertDialogBuilder(requireContext())
			.setTitle(title)
			.setMessage(message)
			.setPositiveButton("OK", null)
			.show()
	}
	
	/**
	 * Launch StreamActivity with cloud stream session
	 */
	private fun launchCloudStream(session: com.metallic.chiaki.cloudplay.model.CloudStreamSession)
	{
		Log.i("CloudPlayFragment", "Launching cloud stream session")
		Log.i("CloudPlayFragment", "  Server: ${session.serverIp}:${session.serverPort}")
		Log.i("CloudPlayFragment", "  Service: ${session.serviceType}")
		Log.i("CloudPlayFragment", "  Platform: ${session.platform}")
		
		// Set codec based on service type (Qt lines 344-353):
		// - PSCLOUD: H.265/HEVC
		// - PSNOW: H.264
		val codec = if (session.serviceType == "pscloud")
		{
			com.metallic.chiaki.lib.Codec.CODEC_H265
		}
		else
		{
			com.metallic.chiaki.lib.Codec.CODEC_H264
		}
		
		Log.i("CloudPlayFragment", "  Codec: ${if (codec == com.metallic.chiaki.lib.Codec.CODEC_H265) "H.265/HEVC" else "H.264"}")
		
		// Get resolution from preferences based on service type
		val resolutionValue = if (session.serviceType == "pscloud")
		{
			preferences.getCloudResolutionPscloud()
		}
		else
		{
			preferences.getCloudResolutionPsnow()
		}
		
		Log.i("CloudPlayFragment", "  Resolution: ${resolutionValue}p")
		
		// Create video profile based on resolution with higher bitrates for cloud streaming
		val videoProfile = when (resolutionValue) {
			720 -> com.metallic.chiaki.lib.ConnectVideoProfile(
				width = 1280,
				height = 720,
				maxFPS = 60,
				bitrate = 20000,  // 20 Mbps for 720p
				codec = codec
			)
			1080 -> com.metallic.chiaki.lib.ConnectVideoProfile(
				width = 1920,
				height = 1080,
				maxFPS = 60,
				bitrate = 20000,  // 20 Mbps for 1080p
				codec = codec
			)
			1440 -> com.metallic.chiaki.lib.ConnectVideoProfile(
				width = 2560,
				height = 1440,
				maxFPS = 60,
				bitrate = 30000,  // 30 Mbps for 1440p
				codec = codec
			)
			2160 -> com.metallic.chiaki.lib.ConnectVideoProfile(
				width = 3840,
				height = 2160,
				maxFPS = 60,
				bitrate = 50000,  // 50 Mbps for 4K
				codec = codec
			)
			else -> com.metallic.chiaki.lib.ConnectVideoProfile(
				width = 1280,
				height = 720,
				maxFPS = 60,
				bitrate = 20000,  // 20 Mbps default
				codec = codec
			)
		}
		
		// Create ConnectInfo with cloud parameters
		val connectInfo = com.metallic.chiaki.lib.ConnectInfo(
			ps5 = session.platform == "ps5",
			host = session.serverIp,  // Cloud mode: Just the IP address (port is in cloudPort)
			registKey = ByteArray(0x10),  // Empty for cloud (not used)
			morning = ByteArray(0x10),  // Empty for cloud (not used)
			videoProfile = videoProfile,
			serviceType = session.serviceType,
			cloudLaunchSpec = session.launchSpec,
			cloudHandshakeKey = session.handshakeKey,
			cloudSessionId = session.sessionId,
			cloudPort = session.serverPort,
			cloudPsnWrapperType = session.psnWrapperType,
			cloudMtuIn = session.mtuIn,
			cloudMtuOut = session.mtuOut,
			cloudRttUs = session.rttMs.toLong() * 1000L  // Convert ms to microseconds
		)
		
		// Launch StreamActivity
		val intent = android.content.Intent(requireContext(), com.metallic.chiaki.stream.StreamActivity::class.java)
		intent.putExtra(com.metallic.chiaki.stream.StreamActivity.EXTRA_CONNECT_INFO, connectInfo)
		startActivity(intent)
		
		// Unlock orientation to full sensor control (StreamActivity will handle its own orientation)
		// We'll also restore it in onResume() when returning from StreamActivity
		requireActivity().runOnUiThread {
			requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
			savedOrientation = -1
			Log.i("CloudPlayFragment", "Orientation unlocked to FULL_SENSOR before launching StreamActivity")
		}
		
		// Dismiss dialog after StreamActivity starts (prevents flash back to games list)
		requireActivity().runOnUiThread {
			// Small delay to ensure StreamActivity is visible before dismissing
			android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
				allocationProgressDialog?.dismiss()
				allocationProgressDialog = null
				allocationProgressTextView = null
				allocationGameImageView = null
			}, 300) // 300ms delay to ensure smooth transition
		}
	}
}

