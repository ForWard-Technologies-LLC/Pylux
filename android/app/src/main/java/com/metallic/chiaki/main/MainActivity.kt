// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.content.Intent
import android.content.res.ColorStateList
import android.os.Bundle
import android.view.View
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
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
		private const val ICON_SELECTED = 0xFFFFFFFF.toInt()
		private const val ICON_UNSELECTED = 0x55FFFFFF
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

		// Mode icon click handlers
		binding.remotePlayIcon.setOnClickListener {
			binding.viewPager.setCurrentItem(0, true)
		}
		binding.cloudPlayIcon.setOnClickListener {
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
		
		// Search toggle (Cloud Play)
		binding.searchIcon.setOnClickListener {
			val fragment = supportFragmentManager.findFragmentByTag("f${binding.viewPager.currentItem}") as? CloudPlayFragment
			fragment?.toggleSearch()
		}
		
		// Settings
		binding.settingsIcon.setOnClickListener {
			Intent(this, SettingsActivity::class.java).also {
				startActivity(it)
			}
		}
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
		if (currentPage == 0) {
			binding.wifiIcon.visibility = View.VISIBLE
			binding.searchIcon.visibility = View.GONE
			binding.cloudSubTabs.visibility = View.GONE
			binding.appTitle.visibility = View.VISIBLE
		} else {
			binding.wifiIcon.visibility = View.GONE
			binding.searchIcon.visibility = View.VISIBLE
			binding.cloudSubTabs.visibility = View.VISIBLE
			binding.appTitle.visibility = View.GONE
		}
	}

	/** Provides the cloud sub-tabs TabLayout for CloudPlayFragment to use */
	fun getCloudSubTabs(): TabLayout = binding.cloudSubTabs

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
