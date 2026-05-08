// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.discovery

import android.util.Log
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.metallic.chiaki.common.Preferences
import com.metallic.chiaki.common.PsnHost
import com.metallic.chiaki.common.PsnTokenManager
import com.metallic.chiaki.lib.HolepunchConsoleType
import com.metallic.chiaki.lib.HolepunchSession

/**
 * Manages PSN console discovery via the holepunch API.
 * Mirrors QmlBackend::updatePsnHosts() from the Qt desktop app.
 *
 * Discovers consoles registered to the PSN account that support Remote Play.
 * These consoles can be connected to over the internet (not just local network).
 */
class PsnDiscoveryManager(private val preferences: Preferences)
{
	companion object
	{
		private const val TAG = "PsnDiscoveryManager"
		private const val MAX_TRIES = 3
	}

	private val tokenManager = PsnTokenManager(preferences)
	private val _psnHosts = MutableLiveData<List<PsnHost>>(emptyList())
	val psnHosts: LiveData<List<PsnHost>> get() = _psnHosts

	private val _isRefreshing = MutableLiveData(false)
	val isRefreshing: LiveData<Boolean> get() = _isRefreshing

	@Volatile
	private var updating = false

	/**
	 * Refresh the list of PSN-discovered consoles.
	 * This is a blocking call - run on a background thread.
	 *
	 * Mimics QmlBackend::updatePsnHostsThread() from the Qt app.
	 */
	fun refreshPsnHosts()
	{
		if(updating)
		{
			Log.i(TAG, "Already updating PSN hosts, skipping...")
			return
		}
		updating = true
		_isRefreshing.postValue(true)

		try
		{
			Log.i(TAG, "Starting PSN host discovery...")
			val token = tokenManager.getValidToken()
			if(token == null)
			{
				Log.w(TAG, "No valid PSN token for host discovery")
				_psnHosts.postValue(emptyList())
				return
			}
			Log.i(TAG, "Got valid PSN token (length=${token.length})")

			val hosts = mutableListOf<PsnHost>()

			// List PS5 devices
			var ps5Success = false
			for(i in 0 until MAX_TRIES)
			{
				val ps5Devices = HolepunchSession.listDevices(token, HolepunchConsoleType.PS5, false)
				if(ps5Devices != null)
				{
					for(device in ps5Devices)
					{
						if(!device.remoteplayEnabled)
						{
							Log.i(TAG, "Skipping PS5 device with remote play disabled: ${device.deviceName}")
							continue
						}
						val duid = device.duidHex
						val name = device.deviceName
						Log.i(TAG, "Found PS5 PSN host: $name (duid=$duid)")
						hosts.add(PsnHost(duid, name, isPS5 = true))
					}
					ps5Success = true
					break
				}
				else
				{
					Log.w(TAG, "Failed to get PS5 devices (attempt ${i + 1}/$MAX_TRIES)")
				}
			}

			if(!ps5Success)
			{
				Log.w(TAG, "Failed to get PS5 devices after $MAX_TRIES tries")
			}

			// The Qt app adds a "Main PS4 Console" placeholder with a dummy DUID.
			// It only displays this in psn_hosts if GetPS4RegisteredHostsRegistered() > 0.
			// We always emit it here; the ViewModel's combine() filters it out
			// if there are no registered PS4 hosts (matching Qt behavior).
			val ps4DuidBytes = ByteArray(32) { 0x41 } // 'A'
			val ps4Duid = ps4DuidBytes.joinToString("") { "%02x".format(it) }
			hosts.add(PsnHost(ps4Duid, "Main PS4 Console", isPS5 = false))

			_psnHosts.postValue(hosts)
			Log.i(TAG, "Updated PSN hosts: ${hosts.size} total")
		}
		catch(e: Exception)
		{
			Log.e(TAG, "refreshPsnHosts failed", e)
			_psnHosts.postValue(emptyList())
		}
		finally
		{
			updating = false
			_isRefreshing.postValue(false)
		}
	}

	/**
	 * Start a background refresh of PSN hosts.
	 */
	fun refreshAsync()
	{
		Thread {
			refreshPsnHosts()
		}.start()
	}
}
