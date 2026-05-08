// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.main

import android.app.ActivityOptions
import android.content.Intent
import android.os.Bundle
import android.util.Log
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.core.view.isGone
import com.metallic.chiaki.common.ext.alertDialogBuilder
import com.metallic.chiaki.common.ext.enableFocusableInTouchModeForTv
import com.metallic.chiaki.common.ext.isTv
import com.pylux.stream.R
import com.metallic.chiaki.common.*
import com.metallic.chiaki.common.ext.putRevealExtra
import com.metallic.chiaki.common.PsnTokenManager
import com.metallic.chiaki.common.ext.viewModelFactory
import com.pylux.stream.databinding.FragmentRemotePlayBinding
import com.metallic.chiaki.lib.ConnectInfo
import com.metallic.chiaki.lib.DiscoveryHost
import com.metallic.chiaki.manualconsole.EditManualConsoleActivity
import com.metallic.chiaki.regist.RegistActivity
import com.metallic.chiaki.regist.PsnAutoRegistration
import com.metallic.chiaki.stream.StreamActivity
import android.widget.LinearLayout
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AlertDialog

class RemotePlayFragment : Fragment()
{
	companion object
	{
		private const val TAG = "RemotePlayFragment"
		private const val REQUEST_PSN_LOGIN = 1
	}

	private lateinit var viewModel: MainViewModel
	private lateinit var binding: FragmentRemotePlayBinding

	override fun onCreateView(
		inflater: LayoutInflater,
		container: ViewGroup?,
		savedInstanceState: Bundle?
	): View
	{
		binding = FragmentRemotePlayBinding.inflate(inflater, container, false)
		return binding.root
	}

	override fun onViewCreated(view: View, savedInstanceState: Bundle?)
	{
		super.onViewCreated(view, savedInstanceState)

		viewModel = ViewModelProvider(requireActivity(), viewModelFactory {
			MainViewModel(getDatabase(requireContext()), Preferences(requireContext()))
		}).get(MainViewModel::class.java)

		setupFloatingActionButton()
		setupRecyclerView()
		observeViewModel()
		updateRefreshButtonText()
		// Speed dial is INVISIBLE when collapsed but children stay in the tree; keep them unfocusable until expanded.
		applySpeedDialFocusWhenCollapsed(binding.floatingActionButton.isExpanded)
	}

	override fun onResume()
	{
		super.onResume()
		updateRefreshButtonText()
	}

	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?)
	{
		super.onActivityResult(requestCode, resultCode, data)
		if (requestCode == REQUEST_PSN_LOGIN && resultCode == android.app.Activity.RESULT_OK)
		{
			updateRefreshButtonText()
			Toast.makeText(requireContext(), "PSN login successful", Toast.LENGTH_SHORT).show()
		}
	}

	private fun launchPsnLogin()
	{
		val intent = Intent(requireContext(), com.metallic.chiaki.cloudplay.PsnLoginActivity::class.java)
		startActivityForResult(intent, REQUEST_PSN_LOGIN)
	}

	private fun updateRefreshButtonText()
	{
		val prefs = Preferences(requireContext())
		val isLoggedIn = prefs.hasPsnRemotePlayTokens || prefs.hasNpssoToken()
		
		binding.refreshPsnLabelButton.text = if (isLoggedIn) {
			"Refresh Consoles"
		} else {
			"Login to Add Consoles"
		}
	}

	private fun setupFloatingActionButton()
	{
		binding.floatingActionButton.setOnClickListener {
			expandFloatingActionButton(!binding.floatingActionButton.isExpanded)
		}
		binding.floatingActionButtonDialBackground.setOnClickListener {
			expandFloatingActionButton(false)
		}

		binding.addManualButton.setOnClickListener { addManualConsole() }
		binding.addManualLabelButton.setOnClickListener { addManualConsole() }

		binding.refreshPsnButton.setOnClickListener { refreshPsnConsoles() }
		binding.refreshPsnLabelButton.setOnClickListener { refreshPsnConsoles() }

		binding.registerButton.setOnClickListener { showRegistration() }
		binding.registerLabelButton.setOnClickListener { showRegistration() }

		binding.root.enableFocusableInTouchModeForTv(requireContext())
		val fabFocus = View.OnFocusChangeListener { v, hasFocus ->
			v.foreground = if (hasFocus)
				android.graphics.drawable.GradientDrawable().apply {
					shape = android.graphics.drawable.GradientDrawable.OVAL
					setColor(0x33FFD700.toInt())
					setStroke(3, 0xCCFFD700.toInt())
				}
			else null
		}
		binding.floatingActionButton.onFocusChangeListener = fabFocus
		binding.refreshPsnButton.onFocusChangeListener = fabFocus
		binding.registerButton.onFocusChangeListener = fabFocus
		binding.addManualButton.onFocusChangeListener = fabFocus

		val labelFocus = View.OnFocusChangeListener { v, hasFocus ->
			v.foreground = if (hasFocus)
				android.graphics.drawable.GradientDrawable().apply {
					shape = android.graphics.drawable.GradientDrawable.RECTANGLE
					cornerRadius = 16f
					setColor(0x33FFD700.toInt())
					setStroke(3, 0xCCFFD700.toInt())
				}
			else null
		}
		binding.refreshPsnLabelButton.onFocusChangeListener = labelFocus
		binding.registerLabelButton.onFocusChangeListener = labelFocus
		binding.addManualLabelButton.onFocusChangeListener = labelFocus
	}

	private fun setupRecyclerView()
	{
		val recyclerViewAdapter = DisplayHostRecyclerViewAdapter(
			this::hostTriggered,
			this::wakeupHost,
			this::editHost,
			this::deleteHost
		)
		binding.hostsRecyclerView.adapter = recyclerViewAdapter
		binding.hostsRecyclerView.layoutManager = LinearLayoutManager(requireContext())
		binding.hostsRecyclerView.isFocusable = false
		binding.hostsRecyclerView.isFocusableInTouchMode = false
		binding.hostsRecyclerView.descendantFocusability = ViewGroup.FOCUS_AFTER_DESCENDANTS

		viewModel.displayHosts.observe(viewLifecycleOwner, Observer { hosts ->
			val top = binding.hostsRecyclerView.computeVerticalScrollOffset() == 0
			recyclerViewAdapter.hosts = hosts
			if (top)
				binding.hostsRecyclerView.scrollToPosition(0)
			updateEmptyInfo()
		})
	}

	private fun observeViewModel()
	{
		viewModel.discoveryActive.observe(viewLifecycleOwner, Observer { active ->
			updateEmptyInfo()
		})
	}

	override fun onStart()
	{
		super.onStart()
		viewModel.discoveryManager.resume()
		// Also refresh PSN hosts if tokens are available
		val hasPsnTokens = Preferences(requireContext()).hasPsnRemotePlayTokens
		Log.i(TAG, "onStart: hasPsnTokens=$hasPsnTokens")
		if(hasPsnTokens)
			viewModel.refreshPsnHosts()
	}

	override fun onStop()
	{
		super.onStop()
		viewModel.discoveryManager.pause()
	}

	private fun updateEmptyInfo()
	{
		if(viewModel.displayHosts.value?.isEmpty() ?: true)
		{
			binding.emptyInfoLayout.visibility = View.VISIBLE
			val discoveryActive = viewModel.discoveryActive.value ?: false
			binding.emptyInfoImageView.setImageResource(if(discoveryActive) R.drawable.ic_discover_on else R.drawable.ic_discover_off)
			binding.emptyInfoTextView.setText(if(discoveryActive) R.string.display_hosts_empty_discovery_on_info else R.string.display_hosts_empty_discovery_off_info)
		}
		else
			binding.emptyInfoLayout.visibility = View.GONE
	}

	private fun expandFloatingActionButton(expand: Boolean)
	{
		binding.floatingActionButton.isExpanded = expand
		binding.floatingActionButton.isActivated = binding.floatingActionButton.isExpanded
		applySpeedDialFocusWhenCollapsed(expand)
	}

	/** Collapsed speed-dial uses INVISIBLE (not GONE); keep hidden actions out of focus traversal. */
	private fun applySpeedDialFocusWhenCollapsed(expanded: Boolean)
	{
		val dial = binding.floatingActionButtonDial
		val ids = intArrayOf(
			R.id.refreshPsnButton, R.id.refreshPsnLabelButton,
			R.id.registerButton, R.id.registerLabelButton,
			R.id.addManualButton, R.id.addManualLabelButton,
		)
		for (id in ids)
		{
			dial.findViewById<View>(id)?.apply {
				isFocusable = expanded
				// On phones, focusableInTouchMode makes the first tap only focus (yellow) and the second
				// tap click — same issue as [enableFocusableInTouchModeForTv]. TV D-pad still works with
				// isFocusable=true; touch-mode focus is for Leanback / TV remote edge cases.
				isFocusableInTouchMode = expanded && requireContext().isTv()
			}
		}
		dial.isFocusable = false
		dial.isFocusableInTouchMode = false
		binding.floatingActionButtonDialBackground.isFocusable = false
		binding.floatingActionButtonDialBackground.isFocusableInTouchMode = false
	}

	private fun addManualConsole()
	{
		Intent(requireContext(), EditManualConsoleActivity::class.java).also {
			it.putRevealExtra(binding.addManualButton, binding.rootLayout)
			startActivity(it, ActivityOptions.makeSceneTransitionAnimation(requireActivity()).toBundle())
		}
	}

	private fun showRegistration()
	{
		Intent(requireContext(), RegistActivity::class.java).also {
			it.putRevealExtra(binding.registerButton, binding.rootLayout)
			startActivity(it, ActivityOptions.makeSceneTransitionAnimation(requireActivity()).toBundle())
		}
	}

	private fun refreshPsnConsoles()
	{
		val prefs = Preferences(requireContext())
		if(prefs.hasPsnRemotePlayTokens)
		{
			Toast.makeText(requireContext(), "Refreshing consoles list...", Toast.LENGTH_SHORT).show()
			viewModel.refreshPsnHosts()
			expandFloatingActionButton(false)
			return
		}
		// Have NPSSO (e.g. signed in via Cloud Play) but no Remote Play tokens yet – exchange now
		if(prefs.hasNpssoToken())
		{
			Toast.makeText(requireContext(), "Setting up PSN for Remote Play...", Toast.LENGTH_SHORT).show()
			expandFloatingActionButton(false)
			Thread {
				val tokenManager = PsnTokenManager(prefs)
				val npsso = prefs.getNpssoToken()
				val ok = tokenManager.exchangeNpssoForTokens(npsso)
				activity?.runOnUiThread {
					if(ok)
					{
						Toast.makeText(requireContext(), "Refreshing consoles list...", Toast.LENGTH_SHORT).show()
						viewModel.refreshPsnHosts()
						updateRefreshButtonText()
					}
					else
					{
						Toast.makeText(requireContext(), "Token exchange failed. Try logging in again in Settings.", Toast.LENGTH_LONG).show()
					}
				}
			}.start()
			return
		}
		// Not logged in - show login dialog
		expandFloatingActionButton(false)
		requireContext().alertDialogBuilder()
			.setTitle("PSN Login Required")
			.setMessage("Login to automatically discover and add your PS5 consoles.")
			.setPositiveButton("Login") { _, _ ->
				launchPsnLogin()
			}
			.setNegativeButton("Cancel", null)
			.create()
			.show()
	}

	private fun hostTriggered(host: DisplayHost)
	{
		Log.i(TAG, "hostTriggered: type=${host.javaClass.simpleName}, name=${host.name}, host=${host.host}, registered=${host.isRegistered}")

		// PSN host handling
		if(host is PsnDisplayHost)
		{
			handlePsnHostTriggered(host)
			return
		}

		val registeredHost = host.registeredHost
		if(registeredHost != null)
		{
			fun connect() {
				val connectInfo = ConnectInfo(host.isPS5, host.host, registeredHost.rpRegistKey, registeredHost.rpKey, Preferences(requireContext()).videoProfile)
				Intent(requireContext(), StreamActivity::class.java).let {
					it.putExtra(StreamActivity.EXTRA_CONNECT_INFO, connectInfo)
					startActivity(it)
				}
			}

			if(host is DiscoveredDisplayHost && host.discoveredHost.state == DiscoveryHost.State.STANDBY)
			{
				requireContext().alertDialogBuilder()
					.setMessage(R.string.alert_message_standby_wakeup)
					.setPositiveButton(R.string.action_wakeup) { _, _ ->
						wakeupHost(host)
					}
					.setNeutralButton(R.string.action_connect_immediately) { _, _ ->
						connect()
					}
					.setNegativeButton(R.string.action_connect_cancel_connect) { _, _ -> }
					.create()
					.show()
			}
			else
				connect()
		}
		else
		{
			// Not registered - check if we can offer automatic registration
			val prefs = Preferences(requireContext())
			val isPsnLoggedIn = prefs.hasPsnRemotePlayTokens
			// Check if this locally-discovered host also has a PSN DUID
			val duid = (host as? DiscoveredDisplayHost)?.psnDuid
			Log.i(TAG, "Unregistered host: isPsnLoggedIn=$isPsnLoggedIn, duid=$duid, hostType=${host.javaClass.simpleName}")

			if(!isPsnLoggedIn)
			{
		// Not logged in to PSN - ask if they want to login or do manual registration
		// Matches Qt: onRegistDialogRequested when !isPsnLoggedIn
		requireContext().alertDialogBuilder()
			.setTitle("Console Setup")
			.setMessage("Login for automatic console setup or enter console information manually.")
			.setPositiveButton("Login") { _, _ ->
				launchPsnLogin()
			}
			.setNegativeButton("Manual") { _, _ ->
				launchManualRegistration(host)
			}
			.create()
			.show()
			}
			else if(duid != null)
			{
				// Logged in to PSN and host has a matching DUID - offer auto or manual
				// Matches Qt: onRegistDialogRequested when isPsnLoggedIn && duid
				Log.i(TAG, "Discovered host has PSN DUID=$duid, showing auto/manual dialog")
				val message = if(host.isPS5)
					"Would you like to use automatic registration?"
				else
					"Would you like to use automatic registration (must be main PS4 console registered to your account)?"

				requireContext().alertDialogBuilder()
					.setTitle("Registration Type")
					.setMessage(message)
					.setPositiveButton("Automatic") { _, _ ->
						Log.i(TAG, "User chose automatic PSN registration for discovered host")
						showAutoRegistrationDialog(duid, host.name ?: "Console", host.isPS5)
					}
					.setNegativeButton("Manual") { _, _ ->
						launchManualRegistration(host)
					}
					.create()
					.show()
			}
			else
			{
				// Logged in to PSN but no DUID match - manual only
				launchManualRegistration(host)
			}
		}
	}

	private var autoRegistration: PsnAutoRegistration? = null

	private fun showAutoRegistrationDialog(duid: String, hostName: String, isPS5: Boolean)
	{
		val ctx = requireContext()

		// Build a simple layout with progress + status
		val layout = LinearLayout(ctx).apply {
			orientation = LinearLayout.VERTICAL
			setPadding(64, 48, 64, 16)
		}
		val progressBar = ProgressBar(ctx).apply {
			isIndeterminate = true
		}
		val statusText = TextView(ctx).apply {
			textSize = 14f
			setPadding(0, 24, 0, 0)
			text = "Starting registration..."
		}
		layout.addView(progressBar)
		layout.addView(statusText)

		var dialog: AlertDialog? = null
		val registration = PsnAutoRegistration(
			context = ctx,
			duid = duid,
			hostName = hostName,
			isPS5 = isPS5,
			onStatus = { msg ->
				statusText.text = msg
			},
			onSuccess = { nickname ->
				dialog?.dismiss()
				autoRegistration = null
				Toast.makeText(ctx, "$nickname registered successfully", Toast.LENGTH_SHORT).show()
			},
			onError = { msg ->
				progressBar.visibility = View.GONE
				statusText.text = msg
				// Replace the cancel button with a close button
				dialog?.getButton(AlertDialog.BUTTON_NEGATIVE)?.text = "Close"
			}
		)
		autoRegistration = registration

		dialog = ctx.alertDialogBuilder()
			.setTitle("Registering $hostName")
			.setView(layout)
			.setNegativeButton("Cancel") { _, _ ->
				registration.cancel()
				autoRegistration = null
			}
			.setOnDismissListener {
				// If dismissed without completing, clean up
				registration.dispose()
				autoRegistration = null
			}
			.setCancelable(true)
			.create()

		dialog.show()
		registration.start()
	}

	private fun launchManualRegistration(host: DisplayHost)
	{
		Intent(requireContext(), RegistActivity::class.java).let {
			it.putExtra(RegistActivity.EXTRA_HOST, host.host)
			it.putExtra(RegistActivity.EXTRA_BROADCAST, false)
			if(host is ManualDisplayHost)
				it.putExtra(RegistActivity.EXTRA_ASSIGN_MANUAL_HOST_ID, host.manualHost.id)
			startActivity(it)
		}
	}

	/**
	 * Handle tapping a PSN-discovered host.
	 * If registered: start PSN holepunch connection.
	 * If not registered: launch PSN remote registration.
	 */
	private fun handlePsnHostTriggered(host: PsnDisplayHost)
	{
		Log.i(TAG, "handlePsnHostTriggered: name=${host.name}, duid=${host.duid}, isPS5=${host.isPS5}, registered=${host.isRegistered}")
		val prefs = Preferences(requireContext())

		// Check for valid PSN tokens
		if(!prefs.hasPsnRemotePlayTokens)
		{
			Log.w(TAG, "No PSN tokens available, showing login prompt")
			requireContext().alertDialogBuilder()
				.setTitle("PSN Login Required")
				.setMessage("You need to log in with your PSN account to connect to consoles over the internet. Please log in from Settings or the Cloud Play tab.")
				.setPositiveButton(android.R.string.ok, null)
				.show()
			return
		}

		val registeredHost = host.registeredHost
		if(registeredHost != null)
		{
			// Console is registered - connect via PSN holepunch
			Log.i(TAG, "PSN host registered, starting PSN connection (duid=${host.duid}, accountId=${prefs.psnAccountId.take(8)}...)")
			val connectInfo = ConnectInfo(
				ps5 = host.isPS5,
				host = "", // No direct IP for PSN connections
				registKey = registeredHost.rpRegistKey,
				morning = registeredHost.rpKey,
				videoProfile = prefs.videoProfile,
				duid = host.duid,
				psnToken = prefs.psnAuthToken,
				psnAccountId = prefs.psnAccountId
			)
			Intent(requireContext(), StreamActivity::class.java).let {
				it.putExtra(StreamActivity.EXTRA_CONNECT_INFO, connectInfo)
				startActivity(it)
			}
		}
		else
		{
			// Console not registered - ask automatic or manual
			// Matches Qt: onRegistDialogRequested when isPsnLoggedIn && duid
			Log.i(TAG, "PSN host NOT registered, showing auto/manual dialog (duid=${host.duid})")
			val message = if(host.isPS5)
				"Would you like to use automatic registration?"
			else
				"Would you like to use automatic registration (must be main PS4 console registered to your account)?"

			requireContext().alertDialogBuilder()
				.setTitle("Registration Type")
				.setMessage(message)
				.setPositiveButton("Automatic") { _, _ ->
					Log.i(TAG, "User chose automatic PSN registration")
					showAutoRegistrationDialog(host.duid, host.name ?: "Console", host.isPS5)
				}
				.setNegativeButton("Manual") { _, _ ->
					Log.i(TAG, "User chose manual registration")
					// For PSN hosts, we don't have a local IP, so launch with broadcast
					Intent(requireContext(), RegistActivity::class.java).let {
						it.putExtra(RegistActivity.EXTRA_HOST, "")
						it.putExtra(RegistActivity.EXTRA_BROADCAST, true)
						startActivity(it)
					}
				}
				.create()
				.show()
		}
	}

	private fun wakeupHost(host: DisplayHost)
	{
		val registeredHost = host.registeredHost ?: return
		viewModel.discoveryManager.sendWakeup(host.host, registeredHost.rpRegistKey, registeredHost.target.isPS5)
	}

	private fun editHost(host: DisplayHost)
	{
		if(host !is ManualDisplayHost)
			return
		Intent(requireContext(), EditManualConsoleActivity::class.java).also {
			it.putExtra(EditManualConsoleActivity.EXTRA_MANUAL_HOST_ID, host.manualHost.id)
			startActivity(it)
		}
	}

	private fun deleteHost(host: DisplayHost)
	{
		if(host !is ManualDisplayHost)
			return
		requireContext().alertDialogBuilder()
			.setMessage(getString(R.string.alert_message_delete_manual_host, host.manualHost.host))
			.setPositiveButton(R.string.action_delete) { _, _ ->
				viewModel.deleteManualHost(host.manualHost)
			}
			.setNegativeButton(R.string.action_keep) { _, _ -> }
			.create()
			.show()
	}
}

