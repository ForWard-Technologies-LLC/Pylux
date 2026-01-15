// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.content.Intent
import android.os.Bundle
import androidx.appcompat.app.AppCompatActivity
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
import androidx.viewpager2.adapter.FragmentStateAdapter
import com.google.android.material.tabs.TabLayoutMediator
import com.metallic.chiaki.R
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.common.ext.viewModelFactory
import com.metallic.chiaki.common.getDatabase
import com.metallic.chiaki.databinding.ActivityMainBinding
import com.metallic.chiaki.settings.SettingsActivity

class MainActivity : AppCompatActivity()
{
	private lateinit var viewModel: MainViewModel
	private lateinit var binding: ActivityMainBinding
	private lateinit var preferences: Preferences
	private var currentPage = 0

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		binding = ActivityMainBinding.inflate(layoutInflater)
		setContentView(binding.root)

		title = ""
		setSupportActionBar(binding.toolbar)
		
		// Ensure toolbar content insets are balanced for centering
		binding.toolbar.setContentInsetsRelative(0, 0)

		preferences = Preferences(this)
		viewModel = ViewModelProvider(this, viewModelFactory {
			MainViewModel(getDatabase(this), preferences)
		}).get(MainViewModel::class.java)

		setupViewPager()
		observeViewModel()
		
		// Restore last selected tab
		val lastTab = preferences.getLastMainTab()
		if (lastTab in 0..1) {
			binding.viewPager.setCurrentItem(lastTab, false)
			currentPage = lastTab
			updateIconsVisibility()
		}
	}

	private fun setupViewPager()
	{
		val adapter = ViewPagerAdapter(this)
		binding.viewPager.adapter = adapter

		TabLayoutMediator(binding.tabLayout, binding.viewPager) { tab, position ->
			tab.text = when(position)
			{
				0 -> "Remote Play"
				1 -> "Cloud Play"
				else -> ""
			}
		}.attach()

		// Handle icon visibility based on selected tab
		binding.tabLayout.addOnTabSelectedListener(object : com.google.android.material.tabs.TabLayout.OnTabSelectedListener {
			override fun onTabSelected(tab: com.google.android.material.tabs.TabLayout.Tab?) {
				currentPage = tab?.position ?: 0
				preferences.setLastMainTab(currentPage)
				updateIconsVisibility()
			}
			override fun onTabUnselected(tab: com.google.android.material.tabs.TabLayout.Tab?) {}
			override fun onTabReselected(tab: com.google.android.material.tabs.TabLayout.Tab?) {}
		})

		// Setup WiFi icon click listener
		binding.wifiIcon.setOnClickListener {
			viewModel.discoveryManager.active = !(viewModel.discoveryActive.value ?: false)
		}
		
		// Setup Search icon click listener
		binding.searchIcon.setOnClickListener {
			// Notify CloudPlayFragment to toggle search
			val fragment = supportFragmentManager.findFragmentByTag("f${binding.viewPager.currentItem}") as? CloudPlayFragment
			fragment?.toggleSearch()
		}
		
		// Setup Settings icon click listener
		binding.settingsIcon.setOnClickListener {
			Intent(this, SettingsActivity::class.java).also {
				startActivity(it)
			}
		}
		
		// Also save tab position when swiping (not just clicking)
		binding.viewPager.registerOnPageChangeCallback(object : androidx.viewpager2.widget.ViewPager2.OnPageChangeCallback() {
			override fun onPageSelected(position: Int) {
				super.onPageSelected(position)
				currentPage = position
				preferences.setLastMainTab(position)
				updateIconsVisibility()
			}
		})
	}

	private fun updateIconsVisibility()
	{
		// Show WiFi icon on Remote Play (position 0), Search icon on Cloud Play (position 1)
		if (currentPage == 0) {
			binding.wifiIcon.visibility = android.view.View.VISIBLE
			binding.searchIcon.visibility = android.view.View.GONE
		} else {
			binding.wifiIcon.visibility = android.view.View.GONE
			binding.searchIcon.visibility = android.view.View.VISIBLE
		}
	}

	private fun observeViewModel()
	{
		viewModel.discoveryActive.observe(this, Observer { active ->
			updateWifiIcon(active)
		})
	}

	private fun updateWifiIcon(active: Boolean)
	{
		binding.wifiIcon.setImageResource(if(active) R.drawable.ic_discover_on else R.drawable.ic_discover_off)
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
