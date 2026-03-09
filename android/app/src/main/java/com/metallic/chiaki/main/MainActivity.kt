// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import com.metallic.chiaki.common.ext.alertDialogBuilder
import com.metallic.chiaki.common.ext.enableFocusableInTouchModeForTv
import com.metallic.chiaki.common.ext.isTv
import android.content.Intent
import android.content.res.ColorStateList
import android.os.Bundle
import android.view.KeyEvent
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import androidx.viewpager2.adapter.FragmentStateAdapter
import com.google.android.material.tabs.TabLayout
import com.pylux.stream.R
import com.metallic.chiaki.common.LicenseAgreementActivity
import com.metallic.chiaki.common.AppIntegrityManager
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.common.ext.viewModelFactory
import com.metallic.chiaki.common.getDatabase
import com.pylux.stream.databinding.ActivityMainBinding
import com.metallic.chiaki.settings.SettingsActivity

class MainActivity : AppCompatActivity()
{
	companion object
	{
		private const val ICON_SELECTED = 0xFF009FE3.toInt()  // Pylux blue
		private const val ICON_UNSELECTED = 0xFFFFFFFF.toInt() // Solid white
	}

	private lateinit var viewModel: MainViewModel
	private lateinit var binding: ActivityMainBinding
	private lateinit var preferences: Preferences
	private var currentPage = 0
	private var integrityManager: AppIntegrityManager? = null

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)

		// Initialize SSL CA bundle for native curl+mbedTLS (must happen before any holepunch calls)
		try { com.metallic.chiaki.lib.initNativeSsl(cacheDir.absolutePath) }
		catch(e: Exception) { android.util.Log.e("MainActivity", "Failed to init native SSL", e) }

		preferences = Preferences(this)
		
		if (!preferences.hasAgreedToLicense()) {
			val intent = Intent(this, LicenseAgreementActivity::class.java)
			startActivity(intent)
			finish()
			return
		}
		
		integrityManager = AppIntegrityManager(this)
		integrityManager?.validateAppState(this) { isValid ->
			if (isValid) {
				android.util.Log.w("MainActivity", "✓ Application integrity verified - proceeding with launch")
			} else {
				android.util.Log.e("MainActivity", "✗ Application integrity check FAILED - blocking launch")
			}
		}
		
		binding = ActivityMainBinding.inflate(layoutInflater)
		setContentView(binding.root)

		title = ""
		setSupportActionBar(binding.toolbar)
		binding.toolbar.setContentInsetsRelative(0, 0)

		viewModel = ViewModelProvider(this, viewModelFactory {
			MainViewModel(getDatabase(this), preferences)
		}).get(MainViewModel::class.java)

		setupNavigation()
		observeViewModel()
		
		// Restore last selected tab
		val lastTab = preferences.getLastMainTab()
		if (lastTab in 0..1) {
			binding.viewPager.setCurrentItem(lastTab, false)
			currentPage = lastTab
			updateModeIcons()
			updateActionIcons()
		}
	}

	private fun setupNavigation()
	{
		val adapter = ViewPagerAdapter(this)
		binding.viewPager.adapter = adapter
		// Keep both pages in memory to prevent unnecessary fragment recreation
		binding.viewPager.offscreenPageLimit = 1
		// Disable swipe - only header buttons switch tabs (avoids accidental swipes when scrolling)
		binding.viewPager.isUserInputEnabled = false

		// Mode icon click handlers (bound to FrameLayout containers for D-pad focus support)
		binding.remotePlayButton.setOnClickListener {
			binding.viewPager.setCurrentItem(0, true)
		}
		binding.cloudPlayButton.setOnClickListener {
			binding.viewPager.setCurrentItem(1, true)
		}

		// Sync ViewPager swipes back to icons
		binding.viewPager.registerOnPageChangeCallback(object : androidx.viewpager2.widget.ViewPager2.OnPageChangeCallback() {
			override fun onPageSelected(position: Int) {
				super.onPageSelected(position)
				currentPage = position
				preferences.setLastMainTab(position)
				updateModeIcons()
				updateActionIcons()
			}
		})

		// WiFi discovery toggle
		binding.wifiIcon.setOnClickListener {
			viewModel.discoveryManager.active = !(viewModel.discoveryActive.value ?: false)
		}
		
		// Settings
		binding.settingsIcon.setOnClickListener {
			Intent(this, SettingsActivity::class.java).also {
				startActivity(it)
			}
		}

		if (isTv()) {
			binding.root.enableFocusableInTouchModeForTv(this)
			val primaryFocusHighlight = View.OnFocusChangeListener { v, hasFocus ->
				if (hasFocus) {
					v.background = android.graphics.drawable.GradientDrawable().apply {
						shape = android.graphics.drawable.GradientDrawable.RECTANGLE
						cornerRadius = 50f
						setColor(0x30FFD700.toInt())
						setStroke(3, 0xCCFFD700.toInt())
					}
				} else {
					v.setBackgroundColor(0x00000000)
				}
			}
			binding.remotePlayButton.onFocusChangeListener = primaryFocusHighlight
			binding.cloudPlayButton.onFocusChangeListener = primaryFocusHighlight
			binding.wifiIcon.onFocusChangeListener = primaryFocusHighlight
			binding.settingsIcon.onFocusChangeListener = primaryFocusHighlight
		}
	}

	/**
	 * Central D-pad/keyboard/gamepad navigation routing.
	 *
	 * Per-view nextFocusUp/nextFocusDown XML and setOnKeyListener both fail at the
	 * ViewPager2 boundary, so all cross-section focus hops are handled here instead.
	 *
	 * Chain: game card row 0 ↑ secondary header ↑ primary header
	 *         primary header ↓ secondary header ↓ first game card
	 */
	override fun dispatchKeyEvent(event: KeyEvent): Boolean
	{
		if (event.action != KeyEvent.ACTION_DOWN) return super.dispatchKeyEvent(event)
		if (event.keyCode == KeyEvent.KEYCODE_BACK) return super.dispatchKeyEvent(event)
		if (!isTv()) return super.dispatchKeyEvent(event)

		val focused = currentFocus

		val cloudRv = window.decorView.findViewById<RecyclerView>(R.id.gamesRecyclerView)
		val hostRv  = window.decorView.findViewById<RecyclerView>(R.id.hostsRecyclerView)

		// If nothing has focus yet, seed it based on the active tab
		if (focused == null) {
			if (currentPage == 1) {
				val lm = cloudRv?.layoutManager as? GridLayoutManager
				lm?.findViewByPosition(lm.findFirstVisibleItemPosition())?.let {
					it.isFocusableInTouchMode = true
					it.requestFocusFromTouch()
				}
			} else {
				hostRv?.layoutManager?.findViewByPosition(0)?.let {
					it.isFocusableInTouchMode = true
					it.requestFocusFromTouch()
				}
			}
			return true
		}

		val secondaryIds = setOf(
			R.id.catalogTabButton, R.id.libraryTabButton, R.id.ownedToggleButton,
			R.id.headerFavoritesButton, R.id.headerSortButton,
			R.id.headerSearchButton, R.id.headerRefreshButton
		)
		val primaryIds = setOf(
			R.id.remotePlayButton, R.id.cloudPlayButton,
			R.id.settingsIcon, R.id.wifiIcon
		)

		val focusedInCloud = cloudRv?.findContainingItemView(focused)
		val focusedInHost  = hostRv?.findContainingItemView(focused)

		val isFab         = focused.id == R.id.floatingActionButton
		val isLoginButton = focused.id == R.id.loginButton

		val speedDialIds = setOf(
			R.id.refreshPsnButton, R.id.refreshPsnLabelButton,
			R.id.registerButton,   R.id.registerLabelButton,
			R.id.addManualButton,  R.id.addManualLabelButton
		)
		val isSpeedDialItem = focused.id in speedDialIds
		val isSpeedDialOpen = window.decorView.findViewById<View>(R.id.addManualButton)?.isShown == true

		fun focusPrimaryHeader() {
			val btn = if (currentPage == 0) binding.remotePlayButton else binding.cloudPlayButton
			btn.isFocusableInTouchMode = true
			btn.requestFocusFromTouch()
		}

		fun focusSecondaryHeader() {
			window.decorView.findViewById<View>(R.id.catalogTabButton)?.let {
				it.isFocusableInTouchMode = true
				it.requestFocusFromTouch()
			}
		}

		fun focusFab() {
			window.decorView.findViewById<View>(R.id.floatingActionButton)?.let {
				it.isFocusableInTouchMode = true
				it.requestFocusFromTouch()
			}
		}

		fun focusLastConsole() {
			val count = hostRv?.adapter?.itemCount ?: 0
			if (count <= 0) return
			val lastView = hostRv?.layoutManager?.findViewByPosition(count - 1)
			lastView?.let {
				it.isFocusableInTouchMode = true
				it.requestFocusFromTouch()
			}
		}

		fun focusLoginButton() {
			window.decorView.findViewById<View>(R.id.loginButton)?.let {
				if (it.isShown) {
					it.isFocusableInTouchMode = true
					it.requestFocusFromTouch()
				}
			}
		}

		when (event.keyCode) {

			KeyEvent.KEYCODE_DPAD_UP -> {
				when {
					// Primary header — already at top, consume so focus doesn't escape
					focused.id in primaryIds -> return true

					// Secondary header (Cloud Play) → primary header
					focused.id in secondaryIds -> { focusPrimaryHeader(); return true }

				// FAB (Remote Play) → submenu if open, else last console, else primary header
				isFab -> {
					if (isSpeedDialOpen) return super.dispatchKeyEvent(event)
					if ((hostRv?.adapter?.itemCount ?: 0) > 0) {
						focusLastConsole()
					} else {
						focusPrimaryHeader()
					}
					return true
				}

					// Login button (Cloud Play, not signed in) → secondary header
					isLoginButton -> { focusSecondaryHeader(); return true }

					// Cloud game card in first row → secondary header
					focusedInCloud != null -> {
						val pos  = cloudRv!!.getChildAdapterPosition(focusedInCloud)
						val span = (cloudRv.layoutManager as? GridLayoutManager)?.spanCount ?: 2
						if (pos in 0 until span) { focusSecondaryHeader(); return true }
						return super.dispatchKeyEvent(event)
					}

					// Console card → primary header if at first visible position
					focusedInHost != null -> {
						val lm  = hostRv!!.layoutManager
						val pos = hostRv.getChildAdapterPosition(focusedInHost)
						val firstVisible = (lm as? androidx.recyclerview.widget.LinearLayoutManager)
							?.findFirstVisibleItemPosition() ?: 0
						if (pos <= firstVisible) { focusPrimaryHeader(); return true }
					}
				}
			}

			KeyEvent.KEYCODE_DPAD_DOWN -> {
				when {
					// Primary header → first content item based on active tab
					focused.id in primaryIds -> {
						if (currentPage == 1) {
							// Cloud Play: secondary header first
							focusSecondaryHeader()
						} else {
						// Remote Play: first console, or FAB if none
						val firstHost = hostRv?.layoutManager?.findViewByPosition(0)
						if (firstHost != null && (hostRv?.adapter?.itemCount ?: 0) > 0) {
							firstHost.isFocusableInTouchMode = true
							firstHost.requestFocusFromTouch()
						} else {
							focusFab()
						}
						}
						return true
					}

				// Secondary header (Cloud Play) → first game card, or login button
				focused.id in secondaryIds -> {
					val lm    = cloudRv?.layoutManager as? GridLayoutManager
					val first = lm?.findViewByPosition(lm.findFirstVisibleItemPosition())
					if (first != null) {
						first.isFocusableInTouchMode = true
						first.requestFocusFromTouch()
						return true
					}
					focusLoginButton()
					return true
				}

					// Speed dial submenu items → bottom row goes to FAB, else natural intra-menu movement
					isSpeedDialItem -> {
						val isBottomRow = focused.id == R.id.addManualButton || focused.id == R.id.addManualLabelButton
						if (isBottomRow) { focusFab(); return true }
						return super.dispatchKeyEvent(event)
					}

					// FAB → consume (it opens the speed dial via click, not down)
					isFab -> return true

					// Login button → consume (nothing below it)
					isLoginButton -> return true

					// Cloud game card: stop at last item
					focusedInCloud != null -> {
						val pos        = cloudRv!!.getChildAdapterPosition(focusedInCloud)
						val lastLoaded = (cloudRv.adapter?.itemCount ?: 0) - 1
						if (pos < 0 || pos >= lastLoaded) return true
						return super.dispatchKeyEvent(event)
					}

					// Console card: last item → FAB, else let RecyclerView handle
					focusedInHost != null -> {
						val pos = hostRv!!.getChildAdapterPosition(focusedInHost)
						val lastPos = (hostRv.adapter?.itemCount ?: 0) - 1
						if (pos >= lastPos || lastPos <= 0) {
							focusFab()
							return true
						}
						return super.dispatchKeyEvent(event)
					}

					// Catch-all: consume so Android's focus finder can't escape to the wrong fragment
					else -> return true
				}
			}
		}

		return super.dispatchKeyEvent(event)
	}

	@Suppress("OVERRIDE_DEPRECATION")
	override fun onBackPressed()
	{
		if (!isTv()) {
			super.onBackPressed()
			return
		}

		val focused = currentFocus
		val cloudRv = window.decorView.findViewById<RecyclerView>(R.id.gamesRecyclerView)
		val hostRv  = window.decorView.findViewById<RecyclerView>(R.id.hostsRecyclerView)

		val secondaryIds = setOf(
			R.id.catalogTabButton, R.id.libraryTabButton, R.id.ownedToggleButton,
			R.id.headerFavoritesButton, R.id.headerSortButton,
			R.id.headerSearchButton, R.id.headerRefreshButton
		)
		val primaryIds = setOf(
			R.id.remotePlayButton, R.id.cloudPlayButton,
			R.id.settingsIcon, R.id.wifiIcon
		)

		val focusedInCloud = focused?.let { cloudRv?.findContainingItemView(it) }
		val focusedInHost  = focused?.let { hostRv?.findContainingItemView(it) }
		val activeHeader   = if (currentPage == 0) binding.remotePlayButton else binding.cloudPlayButton

		when {
			// Game card, console card, or secondary header → move focus up to primary header
			focusedInCloud != null || focusedInHost != null ||
			(focused != null && focused.id in secondaryIds) -> activeHeader.requestFocus()

			// Already at primary header → confirm exit
			focused == null || focused.id in primaryIds -> showExitConfirmation()

			// Anything else (dialogs etc.) → default back behavior
			else -> super.onBackPressed()
		}
	}

	private fun showExitConfirmation()
	{
		alertDialogBuilder()
			.setMessage("Exit app?")
			.setPositiveButton("Exit") { _, _ -> finish() }
			.setNegativeButton("Cancel", null)
			.show()
	}

	private fun updateModeIcons()
	{
		// Update tint colors
		binding.remotePlayIcon.imageTintList = ColorStateList.valueOf(
			if (currentPage == 0) ICON_SELECTED else ICON_UNSELECTED
		)
		binding.cloudPlayIcon.imageTintList = ColorStateList.valueOf(
			if (currentPage == 1) ICON_SELECTED else ICON_UNSELECTED
		)

		// Show circular highlight behind the selected icon
		binding.remotePlayIcon.setBackgroundResource(
			if (currentPage == 0) R.drawable.icon_island_selected else android.R.color.transparent
		)
		binding.cloudPlayIcon.setBackgroundResource(
			if (currentPage == 1) R.drawable.icon_island_selected else android.R.color.transparent
		)
	}

	private fun updateActionIcons()
	{
		// Pylux logo always visible, WiFi icon only on Remote Play
		binding.appTitle.visibility = View.VISIBLE
		binding.wifiIcon.visibility = if (currentPage == 0) View.VISIBLE else View.GONE
	}

	private fun observeViewModel()
	{
		viewModel.discoveryActive.observe(this, Observer { active ->
			binding.wifiIcon.setImageResource(
				if (active) R.drawable.ic_discover_on else R.drawable.ic_discover_off
			)
		})
	}
	
	override fun onDestroy()
	{
		super.onDestroy()
		integrityManager?.release()
	}

	private inner class ViewPagerAdapter(activity: AppCompatActivity) : FragmentStateAdapter(activity)
	{
		override fun getItemCount(): Int = 2

		override fun createFragment(position: Int): Fragment
		{
			return when(position)
			{
				0 -> RemotePlayFragment()
				1 -> CloudPlayFragment()
				else -> RemotePlayFragment()
			}
		}
	}
}
