// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.app.Activity
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Bundle
import android.util.Log
import android.view.Gravity
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.animation.LinearInterpolator
import android.view.animation.RotateAnimation
import android.widget.ImageView
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.widget.SearchView
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.qrcode.QRCodeWriter
import com.metallic.chiaki.common.ext.enableFocusableInTouchModeForTv
import com.metallic.chiaki.common.ext.isTv
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import coil.load
import com.metallic.chiaki.common.ext.alertDialogBuilder
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
		private const val TAG = "CloudPlayFragment"
		private const val REQUEST_PSN_LOGIN = 1001
	}
	
	private lateinit var viewModel: CloudPlayViewModel
	private lateinit var binding: FragmentCloudPlayBinding
	private lateinit var adapter: CloudGameAdapter
	private lateinit var preferences: Preferences
	private lateinit var fastScrollerHelper: FastScrollerHelper

	// Cloud sub-tabs now in secondary header (binding.cloudSubHeader)
	
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
			Log.i(TAG, "Orientation unlocked")
		}
		
		// Re-check login status when returning to fragment
		// This ensures proper UI state whether user logged in/out
		if (!preferences.hasNpssoToken()) {
			Log.i(TAG, "onResume: No token, showing login state")
			viewModel.clearCache()
			viewModel.clearGames()
			showLoginRequiredState()
		} else {
			// Token exists - check if we need to load catalog (e.g., user just logged in from another tab)
			if (adapter.itemCount == 0 && binding.loginButton.visibility == View.VISIBLE) {
				Log.i(TAG, "onResume: Token found, loading catalog")
				validateTokenAndLoadCatalog()
			}
		}
	}

	override fun onDestroyView()
	{
		super.onDestroyView()
		// Cleanup fast scroller
		if (::fastScrollerHelper.isInitialized) {
			fastScrollerHelper.cleanup()
		}
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
		binding.loginButton.onFocusChangeListener = View.OnFocusChangeListener { v, hasFocus ->
			v.foreground = if (hasFocus)
				android.graphics.drawable.GradientDrawable().apply {
					shape = android.graphics.drawable.GradientDrawable.RECTANGLE
					cornerRadius = 24f
					setColor(0x33FFD700.toInt())
					setStroke(3, 0xCCFFD700.toInt())
				}
			else null
		}
	}
	
	private fun checkLoginStatus()
	{
		if (!preferences.hasNpssoToken())
		{
			Log.i(TAG, "No NPSSO token found")
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
			Log.i(TAG, "Validating NPSSO token")
			validateTokenAndLoadCatalog()
		}
	}
	
	private fun showLoginPrompt()
	{
		requireContext().alertDialogBuilder()
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
					Log.w(TAG, "Token empty, clearing cache")
					viewModel.clearCache()
					viewModel.clearGames()
					showLoginRequiredState()
					return@launch
				}
				
				// For now, assume token is valid and load catalog
				// The actual validation will happen when trying to start a cloud session
				// If token is invalid, the error handler will catch it and show login button
				Log.i(TAG, "Token valid, loading catalog")
				loadCatalog()
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Token validation failed", e)
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
			selectLibraryTab()
		}
		else
		{
			selectCatalogTab()
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
	}
	
	private fun hideLoginRequiredState()
	{
		binding.loginRequiredLayout.visibility = View.GONE
	}
	
	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?)
	{
		super.onActivityResult(requestCode, resultCode, data)
		
		if (requestCode == REQUEST_PSN_LOGIN)
		{
			when (resultCode)
			{
				Activity.RESULT_OK -> {
					Log.i(TAG, "Login successful")
					Toast.makeText(requireContext(), R.string.psn_login_success, Toast.LENGTH_SHORT).show()
					validateTokenAndLoadCatalog()
				}
				Activity.RESULT_CANCELED -> {
					Log.i(TAG, "Login cancelled")
					showLoginRequiredState()
				}
				PsnLoginActivity.RESULT_LOGIN_FAILED -> {
					Log.e(TAG, "Login failed")
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
			binding.searchView.visibility = android.view.View.VISIBLE
			binding.searchView.layoutParams = binding.searchView.layoutParams.apply {
				height = android.view.ViewGroup.LayoutParams.WRAP_CONTENT
			}
			// Focus the inner EditText directly so TV DPad can reach it
			val queryEditText = binding.searchView.findViewById<android.view.View>(androidx.appcompat.R.id.search_src_text)
				?: binding.searchView
			queryEditText.isFocusableInTouchMode = true
			queryEditText.requestFocus()
			val imm = requireContext().getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
			imm.showSoftInput(queryEditText, android.view.inputmethod.InputMethodManager.SHOW_IMPLICIT)
			binding.headerSearchButton.setColorFilter(resources.getColor(android.R.color.white, null))
			binding.headerSearchButton.alpha = 1.0f
		} else {
			collapseSearchBar()
			binding.headerSearchButton.setColorFilter(resources.getColor(android.R.color.white, null))
			binding.headerSearchButton.alpha = 0.45f
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
		// Do NOT clear the query - keep the search filter active so the list stays filtered
		binding.searchView.clearFocus()
		// Hide keyboard
		val imm = requireContext().getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as android.view.inputmethod.InputMethodManager
		imm.hideSoftInputFromWindow(binding.searchView.windowToken, 0)
	}
	
	private fun setupCloudTabs()
	{
		// Catalog tab button
		binding.catalogTabButton.setOnClickListener {
			selectCatalogTab()
		}
		
		// Library tab button
		binding.libraryTabButton.setOnClickListener {
			selectLibraryTab()
		}
		
		// All/Owned toggle (Library only)
		binding.ownedToggleButton.setOnClickListener {
			val currentlyOwned = viewModel.preferences.getPsCloudFilterOwned()
			viewModel.preferences.setPsCloudFilterOwned(!currentlyOwned)
			updateOwnedToggleButton()
			// Re-fetch with new filter
			viewModel.fetchPs5CloudCatalog(showOnlyOwned = !currentlyOwned)
		}
		
		// Icon buttons in header
		binding.headerFavoritesButton.setOnClickListener {
			toggleFavoritesFilter()
		}
		
		binding.headerSortButton.setOnClickListener {
			showSortMenu()
		}
		
		binding.headerSearchButton.setOnClickListener {
			toggleSearch()
		}
		
		binding.headerRefreshButton.setOnClickListener {
			refreshCurrentSection()
		}

		binding.root.enableFocusableInTouchModeForTv(requireContext())
		fun highlightButton(v: View, hasFocus: Boolean) {
			if (hasFocus) {
				v.background = android.graphics.drawable.GradientDrawable().apply {
					shape = android.graphics.drawable.GradientDrawable.RECTANGLE
					cornerRadius = 24f
					setColor(0x30FFD700.toInt())
					setStroke(2, 0xCCFFD700.toInt())
				}
			} else {
				v.background = null
			}
		}
		val focusHighlight = View.OnFocusChangeListener { v, hasFocus -> highlightButton(v, hasFocus) }
		binding.catalogTabButton.onFocusChangeListener = focusHighlight
		binding.libraryTabButton.onFocusChangeListener = focusHighlight
		binding.ownedToggleButton.onFocusChangeListener = focusHighlight
		binding.headerFavoritesButton.onFocusChangeListener = focusHighlight
		binding.headerSortButton.onFocusChangeListener = focusHighlight
		binding.headerSearchButton.onFocusChangeListener = focusHighlight
		binding.headerRefreshButton.onFocusChangeListener = focusHighlight
		
		// Initialize icon colors
		updateHeaderIconColors()
	}

	private fun updateHeaderIconColors()
	{
		val whiteTranslucent = resources.getColor(android.R.color.white, null)
		
		// Update favorites icon
		updateFavoritesIcon()
		
		// Other icons - default white translucent
		binding.headerSortButton.setColorFilter(whiteTranslucent)
		binding.headerSortButton.alpha = 0.45f
		binding.headerSearchButton.setColorFilter(whiteTranslucent)
		binding.headerSearchButton.alpha = 0.45f
		binding.headerRefreshButton.setColorFilter(whiteTranslucent)
		binding.headerRefreshButton.alpha = 0.45f
	}
	
	private fun updateFavoritesIcon()
	{
		val currentSection = viewModel.getCurrentSection()
		val favActive = if (currentSection == "pscloud") {
			preferences.getPsCloudFilterFavorites()
		} else {
			preferences.getPsnowFilterFavorites()
		}
		
		binding.headerFavoritesButton.setImageResource(
			if (favActive) R.drawable.ic_star else R.drawable.ic_star_outline
		)
		binding.headerFavoritesButton.setColorFilter(
			if (favActive) resources.getColor(android.R.color.holo_orange_light, null)
			else resources.getColor(android.R.color.white, null)
		)
		binding.headerFavoritesButton.alpha = if (favActive) 1.0f else 0.45f
	}
	
	private fun selectCatalogTab()
	{
		// Update button styles (selected)
		binding.catalogTabButton.setTextColor(resources.getColor(android.R.color.white, null))
		binding.catalogTabButton.setTypeface(null, android.graphics.Typeface.BOLD)
		binding.catalogTabButton.setBackgroundResource(R.drawable.cloud_tab_selected)
		binding.catalogTabButton.alpha = 1.0f
		
		// Unselected style
		binding.libraryTabButton.setTextColor(resources.getColor(android.R.color.white, null))
		binding.libraryTabButton.setTypeface(null, android.graphics.Typeface.NORMAL)
		binding.libraryTabButton.alpha = 0.45f
		binding.libraryTabButton.setBackgroundColor(android.graphics.Color.TRANSPARENT)
		
		// Hide All/Owned toggle for Catalog
		binding.ownedToggleButton.visibility = android.view.View.GONE
		
		// Update section
		viewModel.setCurrentSection("psnow")
		adapter.showOwnershipBadge = false
		binding.sortOptionLayout.visibility = android.view.View.VISIBLE
		binding.filterOptionLayout.visibility = android.view.View.VISIBLE
		updateSortButtonText()
		updateFilterButtonText()
		
		// Update favorites icon to match new section
		updateFavoritesIcon()
		
		viewModel.fetchPsnowCatalog()
	}
	
	private fun selectLibraryTab()
	{
		// Update button styles (selected)
		binding.libraryTabButton.setTextColor(resources.getColor(android.R.color.white, null))
		binding.libraryTabButton.setTypeface(null, android.graphics.Typeface.BOLD)
		binding.libraryTabButton.setBackgroundResource(R.drawable.cloud_tab_selected)
		binding.libraryTabButton.alpha = 1.0f
		
		// Unselected style
		binding.catalogTabButton.setTextColor(resources.getColor(android.R.color.white, null))
		binding.catalogTabButton.setTypeface(null, android.graphics.Typeface.NORMAL)
		binding.catalogTabButton.alpha = 0.45f
		binding.catalogTabButton.setBackgroundColor(android.graphics.Color.TRANSPARENT)
		
		// Show All/Owned toggle for Library
		binding.ownedToggleButton.visibility = android.view.View.VISIBLE
		updateOwnedToggleButton()
		
		// Update section
		viewModel.setCurrentSection("pscloud")
		adapter.showOwnershipBadge = true
		binding.sortOptionLayout.visibility = android.view.View.VISIBLE
		binding.filterOptionLayout.visibility = android.view.View.VISIBLE
		updateSortButtonText()
		updateFilterButtonText()
		
		// Update favorites icon to match new section
		updateFavoritesIcon()
		
		val isOwnedFilter = viewModel.preferences.getPsCloudFilterOwned()
		val isFavoritesFilter = preferences.getPsCloudFilterFavorites()
		
		if (isFavoritesFilter) {
			viewModel.fetchPs5CloudCatalog(showOnlyOwned = false)
		} else {
			viewModel.fetchPs5CloudCatalog(showOnlyOwned = isOwnedFilter)
		}
	}
	
	private fun updateOwnedToggleButton()
	{
		val isOwned = viewModel.preferences.getPsCloudFilterOwned()
		binding.ownedToggleButton.text = if (isOwned) "Owned" else "All"
		binding.ownedToggleButton.setTextColor(
			if (isOwned) resources.getColor(android.R.color.holo_green_light, null)
			else resources.getColor(android.R.color.white, null)
		)
		binding.ownedToggleButton.alpha = if (isOwned) 1.0f else 0.6f
		binding.ownedToggleButton.setBackgroundResource(
			if (isOwned) R.drawable.cloud_tab_owned_selected
			else R.drawable.cloud_tab_owned_unselected
		)
	}
	
	private fun toggleFavoritesFilter()
	{
		val currentSection = viewModel.getCurrentSection()
		val currentlyActive = if (currentSection == "pscloud") {
			preferences.getPsCloudFilterFavorites()
		} else {
			preferences.getPsnowFilterFavorites()
		}
		
		// Toggle the preference
		val newState = !currentlyActive
		if (currentSection == "pscloud") {
			preferences.setPsCloudFilterFavorites(newState)
		} else {
			preferences.setPsnowFilterFavorites(newState)
		}
		
		// Update icon to match new state
		updateFavoritesIcon()
		
		// Re-filter games - use correct item IDs
		if (currentSection == "pscloud") {
			// Library: 0=All, 1=Owned, 2=Favorites
			val selectedItem = if (newState) 2 else 0
			applyFilterState(currentSection, selectedItem)
		} else {
			// Catalog: 0=All, 1=Favorites
			val selectedItem = if (newState) 1 else 0
			applyFilterState(currentSection, selectedItem)
		}
	}
	
	private fun refreshCurrentSection()
	{
		val currentSection = viewModel.getCurrentSection()
		if (currentSection == "pscloud") {
			val isOwnedFilter = viewModel.preferences.getPsCloudFilterOwned()
			viewModel.fetchPs5CloudCatalog(showOnlyOwned = isOwnedFilter, forceRefresh = true)
		} else {
			viewModel.fetchPsnowCatalog(forceRefresh = true)
		}
	}
	
	private fun showSortMenu()
	{
		val currentSection = viewModel.getCurrentSection()
		val sortOptions = when (currentSection) {
			"pscloud" -> arrayOf("Owned First", "Name: A → Z", "Name: Z → A")
			else -> arrayOf("Recent", "Name: A → Z", "Name: Z → A")
		}
		
		requireContext().alertDialogBuilder()
			.setTitle("Sort")
			.setSingleChoiceItems(sortOptions, sortState) { dialog, which ->
				applySortState(which)
				dialog.dismiss()
			}
			.show()
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
		updateFavoritesIcon()
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
		updateFastScrollerVisibility()
	}

	private fun setupRecyclerView()
	{
		adapter = CloudGameAdapter(
			onGameClick = this::onGameClicked,
			onFavoriteClick = this::onGameFavoriteToggled,
			isFavorite = { productId -> preferences.isFavoriteGame(productId) }
		)
		binding.gamesRecyclerView.adapter = adapter
		binding.gamesRecyclerView.setHasFixedSize(true)
		binding.gamesRecyclerView.setItemViewCacheSize(20)
		binding.gamesRecyclerView.descendantFocusability = android.view.ViewGroup.FOCUS_AFTER_DESCENDANTS
		val spanCount = calculateSpanCount()
		binding.gamesRecyclerView.layoutManager = GridLayoutManager(requireContext(), spanCount)

		// Setup fast scroller
		setupFastScroller()
	}
	
	private fun setupFastScroller()
	{
		fastScrollerHelper = FastScrollerHelper(
			recyclerView = binding.gamesRecyclerView,
			thumbView = binding.fastScrollerThumb,
			touchZone = binding.fastScrollerTouchZone,
			sectionIndicator = binding.sectionIndicator,
			gameCountText = binding.gameCountText,
			adapter = adapter,
			gamesProvider = { adapter.games }
		)
		fastScrollerHelper.setup()
	}
	
	private fun updateFastScrollerVisibility()
	{
		fastScrollerHelper.updateVisibility()
	}

	/** Column count from screen width (~180dp per card, 2–4 columns). */
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

	private fun observeViewModel()
	{
		viewModel.games.observe(viewLifecycleOwner, Observer { games ->
			if (!preferences.hasNpssoToken()) {
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
			updateFastScrollerVisibility()
			
			// Auto-focus first item after games are loaded, but not while search bar is active
			if (sortedGames.isNotEmpty() && !isSearchExpanded) {
				focusFirstGame()
			}
		})

		viewModel.loading.observe(viewLifecycleOwner, Observer { loading ->
			binding.progressBar.visibility = if(loading && adapter.games.isEmpty()) View.VISIBLE else View.GONE
			if (loading) {
				val rotate = RotateAnimation(0f, 360f, RotateAnimation.RELATIVE_TO_SELF, 0.5f, RotateAnimation.RELATIVE_TO_SELF, 0.5f).apply {
					duration = 800
					repeatCount = RotateAnimation.INFINITE
					interpolator = LinearInterpolator()
				}
				binding.headerRefreshButton.startAnimation(rotate)
			} else {
				binding.headerRefreshButton.clearAnimation()
			}
		})

		viewModel.error.observe(viewLifecycleOwner, Observer { error ->
			if (error.isNullOrEmpty()) return@Observer
			viewModel.clearError()
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
		val error = CloudError.fromMessage(message)
		when (error) {
			is CloudError.AuthenticationError -> handleAuthenticationError(error)
			is CloudError.NetworkError -> handleNetworkError(error)
			is CloudError.GeneralError -> handleGeneralError(error)
		}
	}
	
	private fun handleAuthenticationError(error: CloudError.AuthenticationError)
	{
		Log.w(TAG, "Authentication error, clearing session")
		
		// IMMEDIATELY clear games list first so user doesn't see cached games
		adapter.games = emptyList()
		
		// Clear cache, games, and token
		viewModel.clearCache()
		viewModel.clearGames()
		preferences.clearNpssoToken()
		
		// Show login required state
		showLoginRequiredState()
		
		// Then show authentication error dialog
		requireContext().alertDialogBuilder()
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
		requireContext().alertDialogBuilder()
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
		requireContext().alertDialogBuilder()
			.setTitle(R.string.error)
			.setMessage(error.message)
			.setPositiveButton(R.string.action_ok, null)
			.show()
	}

	private fun onGameClicked(game: CloudGame)
	{
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
			Log.e(TAG, "Missing concept URL for: ${game.name}")
			requireContext().alertDialogBuilder()
				.setTitle("Add to Library")
				.setMessage("Unable to add this game to your library. The game URL is not available.")
				.setPositiveButton("OK", null)
				.show()
			return
		}

		if (requireContext().isTv()) {
			showAddToLibraryQrDialog(game)
		} else {
			requireContext().alertDialogBuilder()
				.setTitle("Add to Library")
				.setMessage("This game needs to be added to your library before you can stream it.\n\nAfter adding the game, press the Refresh Games button to update your list.")
				.setPositiveButton("Add Now") { _, _ ->
					openUrlInBrowser(game.conceptUrl)
				}
				.setNegativeButton("Cancel", null)
				.show()
		}
	}

	private fun showAddToLibraryQrDialog(game: CloudGame)
	{
		val ctx = requireContext()
		val qrBitmap = generateQrCode(game.conceptUrl, 512)

		val dp = ctx.resources.displayMetrics.density
		fun Int.dp() = (this * dp).toInt()

		val layout = LinearLayout(ctx).apply {
			orientation = LinearLayout.VERTICAL
			gravity = Gravity.CENTER_HORIZONTAL
			setPadding(32.dp(), 16.dp(), 32.dp(), 8.dp())
		}

		val message = TextView(ctx).apply {
			text = "Scan this QR code on your phone or tablet to add \"${game.name}\" to your PlayStation library.\n\nAfter adding the game, press Refresh Games."
			textSize = 18f
			setTextColor(Color.WHITE)
			gravity = Gravity.CENTER
			layoutParams = LinearLayout.LayoutParams(
				LinearLayout.LayoutParams.MATCH_PARENT,
				LinearLayout.LayoutParams.WRAP_CONTENT
			).apply { bottomMargin = 24.dp() }
		}

		val qrImage = ImageView(ctx).apply {
			setImageBitmap(qrBitmap)
			scaleType = ImageView.ScaleType.FIT_CENTER
			layoutParams = LinearLayout.LayoutParams(320.dp(), 320.dp()).apply {
				gravity = Gravity.CENTER_HORIZONTAL
			}
		}

		layout.addView(message)
		layout.addView(qrImage)

		val scroll = ScrollView(ctx).apply { addView(layout) }

		ctx.alertDialogBuilder()
			.setTitle("Add to Library")
			.setView(scroll)
			.setPositiveButton("Done", null)
			.show()
	}

	private fun generateQrCode(content: String, size: Int): Bitmap
	{
		val hints = mapOf(EncodeHintType.MARGIN to 1)
		val bitMatrix = QRCodeWriter().encode(content, BarcodeFormat.QR_CODE, size, size, hints)
		val bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
		for (x in 0 until size) {
			for (y in 0 until size) {
				bitmap.setPixel(x, y, if (bitMatrix[x, y]) Color.BLACK else Color.WHITE)
			}
		}
		return bitmap
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
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to open URL: $url", e)
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
		Log.i(TAG, "Starting cloud streaming: ${game.name} (${game.serviceType}/${game.platform})")
		
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
			}
			
			cancelButton.setOnClickListener {
				allocationCancelled = true
				requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
				savedOrientation = -1
				allocationProgressDialog?.dismiss()
			}
			
			allocationProgressDialog = requireContext().alertDialogBuilder()
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
						requireActivity().runOnUiThread {
							allocationProgressTextView?.text = message
						}
					},
					isCancelled = { allocationCancelled }
				)
				
				result.onSuccess { session ->
					launchCloudStream(session)
				}
				
				result.onFailure { error ->
					requireActivity().runOnUiThread {
						requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
						savedOrientation = -1
						allocationProgressDialog?.dismiss()
						allocationProgressDialog = null
						allocationProgressTextView = null
						allocationGameImageView = null
					}
					
					if (allocationCancelled) return@launch
					
					Log.e(TAG, "Cloud session failed: ${error.message}")
					
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
				requireActivity().runOnUiThread {
					requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
					savedOrientation = -1
					allocationProgressDialog?.dismiss()
					allocationProgressDialog = null
					allocationProgressTextView = null
					allocationGameImageView = null
				}
				
				if (allocationCancelled) return@launch
				
				Log.e(TAG, "Exception starting cloud session", e)
				
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
		requireContext().alertDialogBuilder()
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
		requireContext().alertDialogBuilder()
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
		requireContext().alertDialogBuilder()
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
		requireContext().alertDialogBuilder()
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
		requireContext().alertDialogBuilder()
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
		
		// Get resolution from preferences based on service type
		val resolutionValue = if (session.serviceType == "pscloud")
		{
			preferences.getCloudResolutionPscloud()
		}
		else
		{
			preferences.getCloudResolutionPsnow()
		}
		
		// Create video profile based on resolution
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
		
		requireActivity().runOnUiThread {
			requireActivity().requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_FULL_SENSOR
			savedOrientation = -1
		}
		
		requireActivity().runOnUiThread {
			android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
				allocationProgressDialog?.dismiss()
				allocationProgressDialog = null
				allocationProgressTextView = null
				allocationGameImageView = null
			}, 300)
		}
	}
}

