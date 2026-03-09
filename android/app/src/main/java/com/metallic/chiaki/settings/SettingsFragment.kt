// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.settings

import android.app.Activity
import android.content.Intent
import android.content.res.Resources
import android.os.Bundle
import android.text.InputType
import android.widget.Toast
import androidx.lifecycle.Observer
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.lifecycleScope
import androidx.preference.*
import com.metallic.chiaki.common.ext.alertDialogBuilder
import com.pylux.stream.R
import com.metallic.chiaki.cloudplay.PsnLoginActivity
import com.metallic.chiaki.cloudplay.repository.CloudGameRepository
import com.metallic.chiaki.common.LicenseAgreementActivity
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.common.PsnTokenManager
import com.metallic.chiaki.common.exportAndShareAllSettings
import com.metallic.chiaki.common.ext.viewModelFactory
import com.metallic.chiaki.common.getDatabase
import com.metallic.chiaki.common.importSettingsFromUri
import com.metallic.chiaki.discovery.PsnDiscoveryManager
import io.reactivex.disposables.CompositeDisposable
import io.reactivex.rxkotlin.addTo
import kotlinx.coroutines.launch

class DataStore(val preferences: Preferences): PreferenceDataStore()
{
	override fun getBoolean(key: String?, defValue: Boolean) = when(key)
	{
		preferences.logVerboseKey -> preferences.logVerbose
		preferences.swapCrossMoonKey -> preferences.swapCrossMoon
		preferences.rumbleEnabledKey -> preferences.rumbleEnabled
		preferences.motionEnabledKey -> preferences.motionEnabled
		preferences.buttonHapticEnabledKey -> preferences.buttonHapticEnabled
		else -> defValue
	}

	override fun putBoolean(key: String?, value: Boolean)
	{
		when(key)
		{
			preferences.logVerboseKey -> preferences.logVerbose = value
			preferences.swapCrossMoonKey -> preferences.swapCrossMoon = value
			preferences.rumbleEnabledKey -> preferences.rumbleEnabled = value
			preferences.motionEnabledKey -> preferences.motionEnabled = value
			preferences.buttonHapticEnabledKey -> preferences.buttonHapticEnabled = value
		}
	}

	override fun getString(key: String, defValue: String?) = when(key)
	{
		preferences.resolutionKey -> preferences.resolution.value
		preferences.fpsKey -> preferences.fps.value
		preferences.bitrateKey -> preferences.bitrate?.toString() ?: ""
		preferences.codecKey -> preferences.codec.value
		preferences.cloudDatacenterPsnowKey -> preferences.getCloudDatacenterPsnow()
		preferences.cloudDatacenterPscloudKey -> preferences.getCloudDatacenterPscloud()
		else -> defValue
	}

	override fun putString(key: String, value: String?)
	{
		when(key)
		{
			preferences.resolutionKey ->
			{
				val resolution = Preferences.Resolution.values().firstOrNull { it.value == value } ?: return
				preferences.resolution = resolution
			}
			preferences.fpsKey ->
			{
				val fps = Preferences.FPS.values().firstOrNull { it.value == value } ?: return
				preferences.fps = fps
			}
			preferences.bitrateKey -> preferences.bitrate = value?.toIntOrNull()
			preferences.codecKey ->
			{
				val codec = Preferences.Codec.values().firstOrNull { it.value == value } ?: return
				preferences.codec = codec
			}
			preferences.cloudDatacenterPsnowKey -> preferences.setCloudDatacenterPsnow(value ?: "Auto")
			preferences.cloudDatacenterPscloudKey -> preferences.setCloudDatacenterPscloud(value ?: "Auto")
		}
	}
}

class SettingsFragment: PreferenceFragmentCompat(), TitleFragment
{
	companion object
	{
		private const val PICK_SETTINGS_JSON_REQUEST = 1
		private const val REQUEST_PSN_LOGIN = 1002
	}

	private var disposable = CompositeDisposable()
	private var exportDisposable = CompositeDisposable().also { it.addTo(disposable) }

	override fun onCreatePreferences(savedInstanceState: Bundle?, rootKey: String?)
	{
		val context = context ?: return

		val viewModel = ViewModelProvider(this, viewModelFactory { SettingsViewModel(getDatabase(context), Preferences(context)) })
			.get(SettingsViewModel::class.java)

		val preferences = viewModel.preferences
		preferenceManager.preferenceDataStore = DataStore(preferences)
		setPreferencesFromResource(R.xml.preferences, rootKey)

		preferenceScreen.findPreference<ListPreference>(getString(R.string.preferences_resolution_key))?.let {
			it.entryValues = Preferences.resolutionAll.map { res -> res.value }.toTypedArray()
			it.entries = Preferences.resolutionAll.map { res -> getString(res.title) }.toTypedArray()
		}

		preferenceScreen.findPreference<ListPreference>(getString(R.string.preferences_fps_key))?.let {
			it.entryValues = Preferences.fpsAll.map { fps -> fps.value }.toTypedArray()
			it.entries = Preferences.fpsAll.map { fps -> getString(fps.title) }.toTypedArray()
		}

		// Populate cloud datacenter dropdowns dynamically from saved ping results
		populateCloudDatacenterPreference(
			preferenceScreen.findPreference(getString(R.string.preferences_cloud_datacenter_psnow_key)),
			preferences.getCloudDatacentersJsonPsnow()
		)
		populateCloudDatacenterPreference(
			preferenceScreen.findPreference(getString(R.string.preferences_cloud_datacenter_pscloud_key)),
			preferences.getCloudDatacentersJsonPscloud()
		)

		val bitratePreference = preferenceScreen.findPreference<EditTextPreference>(getString(R.string.preferences_bitrate_key))
		val bitrateSummaryProvider = Preference.SummaryProvider<EditTextPreference> {
			preferences.bitrate?.toString() ?: getString(R.string.preferences_bitrate_auto, preferences.bitrateAuto)
		}
		bitratePreference?.let {
			it.summaryProvider = bitrateSummaryProvider
			it.setOnBindEditTextListener { editText ->
				editText.hint = getString(R.string.preferences_bitrate_auto, preferences.bitrateAuto)
				editText.inputType = InputType.TYPE_CLASS_NUMBER
				editText.setText(preferences.bitrate?.toString() ?: "")
			}
		}
		viewModel.bitrateAuto.observe(this, Observer {
			bitratePreference?.summaryProvider = bitrateSummaryProvider
		})

		preferenceScreen.findPreference<ListPreference>(getString(R.string.preferences_codec_key))?.let {
			it.entryValues = Preferences.codecAll.map { codec -> codec.value }.toTypedArray()
			it.entries = Preferences.codecAll.map { codec -> getString(codec.title) }.toTypedArray()
		}

		val registeredHostsPreference = preferenceScreen.findPreference<Preference>("registered_hosts")
		viewModel.registeredHostsCount.observe(this, Observer {
			registeredHostsPreference?.summary = getString(R.string.preferences_registered_hosts_summary, it)
		})

		preferenceScreen.findPreference<Preference>(getString(R.string.preferences_export_settings_key))?.setOnPreferenceClickListener { exportSettings(); true }
		preferenceScreen.findPreference<Preference>(getString(R.string.preferences_import_settings_key))?.setOnPreferenceClickListener { importSettings(); true }
		
		// View License
		preferenceScreen.findPreference<Preference>("view_license")?.setOnPreferenceClickListener { viewLicense(); true }
		
		// Unified PSN Login (for both cloud streaming and remote play)
		val psnLoginPreference = preferenceScreen.findPreference<Preference>("psn_login")
		updatePsnLoginSummary(psnLoginPreference, preferences)
		psnLoginPreference?.setOnPreferenceClickListener {
			if (preferences.hasNpssoToken() || preferences.hasPsnRemotePlayTokens)
			{
				// User is logged in, show logout option
				showLogoutDialog(preferences, psnLoginPreference)
			}
			else
			{
				// User is not logged in, launch login activity
				launchPsnLogin()
			}
			true
		}
	}

	override fun onDestroy()
	{
		super.onDestroy()
		disposable.dispose()
	}

	override fun getTitle(resources: Resources): String = resources.getString(R.string.title_settings)

	private fun exportSettings()
	{
		val activity = activity ?: return
		exportDisposable.clear()
		exportAndShareAllSettings(activity).addTo(exportDisposable)
	}

	private fun importSettings()
	{
		val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
			addCategory(Intent.CATEGORY_OPENABLE)
			type = "application/json"
		}
		startActivityForResult(intent, PICK_SETTINGS_JSON_REQUEST)
	}
	
	private fun viewLicense()
	{
		val intent = Intent(requireContext(), LicenseAgreementActivity::class.java)
		intent.putExtra(LicenseAgreementActivity.EXTRA_VIEW_ONLY, true)
		startActivity(intent)
	}

	override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?)
	{
		android.util.Log.i("SettingsFragment", "onActivityResult: requestCode=$requestCode, resultCode=$resultCode, hasData=${data != null}")
		if(requestCode == PICK_SETTINGS_JSON_REQUEST && resultCode == Activity.RESULT_OK)
		{
			val activity = activity ?: return
			data?.data?.also {
				importSettingsFromUri(activity, it, disposable)
			}
		}
		else if (requestCode == REQUEST_PSN_LOGIN)
		{
			val context = context ?: return
			val preferences = Preferences(context)
			android.util.Log.i("SettingsFragment", "PSN Login result: resultCode=$resultCode")

			when (resultCode)
			{
				Activity.RESULT_OK -> {
					// PsnLoginActivity already exchanged for Remote Play tokens (unified flow)
					android.util.Log.i("SettingsFragment", "PSN login successful (NPSSO + Remote Play tokens saved)")
					Toast.makeText(context, R.string.psn_login_success, Toast.LENGTH_SHORT).show()
					val psnLoginPreference = preferenceScreen.findPreference<Preference>("psn_login")
					updatePsnLoginSummary(psnLoginPreference, preferences)
				}
				Activity.RESULT_CANCELED -> {
					// User cancelled login
				}
				PsnLoginActivity.RESULT_LOGIN_FAILED -> {
					Toast.makeText(context, R.string.psn_login_failed, Toast.LENGTH_LONG).show()
				}
			}
		}
	}
	
	private fun launchPsnLogin()
	{
		val intent = Intent(requireContext(), PsnLoginActivity::class.java)
		startActivityForResult(intent, REQUEST_PSN_LOGIN)
	}
	
	private fun updatePsnLoginSummary(preference: Preference?, preferences: Preferences)
	{
		val hasNpsso = preferences.hasNpssoToken()
		val hasRemotePlay = preferences.hasPsnRemotePlayTokens
		
		preference?.summary = when {
			hasNpsso && hasRemotePlay -> {
				val accountId = preferences.psnAccountId
				if(accountId.isNotEmpty())
					"Logged in (Account: ${accountId.take(8)}...)"
				else
					getString(R.string.preferences_psn_login_summary_logged_in)
			}
			hasNpsso -> getString(R.string.preferences_psn_login_summary_logged_in)
			hasRemotePlay -> "Logged in (Remote Play only)"
			else -> getString(R.string.preferences_psn_login_summary)
		}
	}

	private fun showLogoutDialog(preferences: Preferences, loginPreference: Preference?)
	{
		val context = context ?: return
		context.alertDialogBuilder()
			.setTitle(R.string.preferences_psn_logout_title)
			.setMessage("Are you sure you want to log out? This will clear both cloud streaming and remote play credentials.")
			.setPositiveButton(R.string.preferences_psn_logout_confirm) { _, _ ->
				// Clear both NPSSO token and remote play tokens
				preferences.clearNpssoToken()
				preferences.clearPsnRemotePlayTokens()
				
				// Clear cached cloud game data
				lifecycleScope.launch {
					try {
						val repository = CloudGameRepository(context, preferences)
						repository.clearCache()
						android.util.Log.i("SettingsFragment", "Cleared cloud game cache on logout")
					} catch (e: Exception) {
						android.util.Log.e("SettingsFragment", "Failed to clear cache on logout", e)
					}
				}
				
				updatePsnLoginSummary(loginPreference, preferences)
				Toast.makeText(context, R.string.preferences_psn_logout_success, Toast.LENGTH_SHORT).show()
			}
		.setNegativeButton(R.string.action_cancel, null)
		.show()
	}

	/**
	 * Populate cloud datacenter dropdown from saved ping results JSON
	 * Matches Qt behavior of showing discovered datacenters with their ping times
	 */
	private fun populateCloudDatacenterPreference(preference: ListPreference?, datacentersJson: String)
	{
		if (preference == null) return

		try
		{
			if (datacentersJson.isEmpty())
			{
				// No saved datacenters, use default "Auto" only
				preference.entries = arrayOf("Auto (Best Ping)")
				preference.entryValues = arrayOf("Auto")
				return
			}

			// Parse the JSON array of datacenter ping results
			val datacenters = org.json.JSONArray(datacentersJson)
			val entries = mutableListOf<String>()
			val values = mutableListOf<String>()

			// Always add "Auto" as first option
			entries.add("Auto (Best Ping)")
			values.add("Auto")

			// Add each datacenter with its ping time (no IP)
			for (i in 0 until datacenters.length())
			{
				val dc = datacenters.getJSONObject(i)
				val name = dc.optString("dataCenter", "")
				val rtt = dc.optInt("rtt", 0)

				if (name.isNotEmpty())
				{
					// Format: "sjca (36ms)" - just name and ping, no IP
					val displayName = if (rtt > 0 && rtt < 999)
					{
						"$name (${rtt}ms)"
					}
					else
					{
						name
					}

					entries.add(displayName)
					values.add(name)  // Store just the datacenter name as the value
				}
			}

			preference.entries = entries.toTypedArray()
			preference.entryValues = values.toTypedArray()
		}
		catch (e: Exception)
		{
			// If JSON parsing fails, fall back to Auto only
			preference.entries = arrayOf("Auto (Best Ping)")
			preference.entryValues = arrayOf("Auto")
		}
	}
}