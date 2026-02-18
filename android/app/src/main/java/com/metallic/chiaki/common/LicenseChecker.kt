// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.app.Activity
import android.content.Context
import android.util.Log
import androidx.appcompat.app.AlertDialog
import com.android.billingclient.api.*
import com.pylux.stream.BuildConfig
import kotlinx.coroutines.*

/**
 * Application feature access validator
 */
class AppIntegrityManager(private val context: Context)
{
	companion object
	{
		private const val TAG = "AppIntegrity"
		private const val PREF_NAME = "app_state"
		private const val KEY_LAST_CHECK = "last_verify"
		private const val KEY_IS_VALID = "state_valid"
		private const val CHECK_INTERVAL_MS = 7 * 24 * 60 * 60 * 1000L
	}
	
	private var billingClient: BillingClient? = null
	private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
	
	/**
	 * Validate application state
	 */
	fun validateAppState(activity: Activity, onResult: (Boolean) -> Unit)
	{
		// Skip validation in debug builds
		if (BuildConfig.DEBUG)
		{
			Log.d(TAG, "Debug build detected, skipping validation")
			onResult(true)
			return
		}
		
		scope.launch {
			try
			{
				if (canUseCachedResult())
				{
					val cachedValid = getCachedValidity()
					Log.v(TAG, "Using cached state: $cachedValid")
					onResult(cachedValid)
					return@launch
				}
				
				Log.v(TAG, "Performing state validation...")
				val isValid = performValidation()
				
				cacheResult(isValid)
				
				if (isValid)
				{
					Log.v(TAG, "State validation successful")
					onResult(true)
				}
				else
				{
					Log.w(TAG, "State validation failed")
					showValidationFailureDialog(activity)
					onResult(false)
				}
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Validation error", e)
				val fallback = getCachedValidity()
				Log.v(TAG, "Using fallback state: $fallback")
				onResult(fallback)
			}
		}
	}
	
	private suspend fun performValidation(): Boolean = withContext(Dispatchers.IO)
	{
		return@withContext suspendCancellableCoroutine { continuation ->
			billingClient = BillingClient.newBuilder(context)
				.setListener { _, _ -> }
				.enablePendingPurchases(
					PendingPurchasesParams.newBuilder()
						.enableOneTimeProducts()
						.build()
				)
				.build()
			
			billingClient?.startConnection(object : BillingClientStateListener {
				override fun onBillingSetupFinished(billingResult: BillingResult)
				{
					if (billingResult.responseCode == BillingClient.BillingResponseCode.OK)
					{
						Log.v(TAG, "Service connected")
						
						scope.launch(Dispatchers.IO) {
							try
							{
								val result = billingClient?.queryPurchasesAsync(
									QueryPurchasesParams.newBuilder()
										.setProductType(BillingClient.ProductType.INAPP)
										.build()
								)
								
								val isValid = result?.billingResult?.responseCode == BillingClient.BillingResponseCode.OK
								
								Log.v(TAG, "Validation result: $isValid")
								continuation.resume(isValid) { }
							}
							catch (e: Exception)
							{
								Log.e(TAG, "Query error", e)
								continuation.resume(false) { }
							}
							finally
							{
								billingClient?.endConnection()
							}
						}
					}
					else
					{
						Log.e(TAG, "Setup failed: ${billingResult.responseCode}")
						continuation.resume(false) { }
					}
				}
				
				override fun onBillingServiceDisconnected()
				{
					Log.w(TAG, "Service disconnected")
					continuation.resume(true) { }
				}
			})
			
			scope.launch {
				delay(30000)
				if (continuation.isActive)
				{
					Log.w(TAG, "Validation timeout")
					continuation.resume(true) { }
				}
			}
		}
	}
	
	private fun canUseCachedResult(): Boolean
	{
		val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
		val lastCheck = prefs.getLong(KEY_LAST_CHECK, 0)
		val age = System.currentTimeMillis() - lastCheck
		return age < CHECK_INTERVAL_MS
	}
	
	private fun getCachedValidity(): Boolean
	{
		val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
		return prefs.getBoolean(KEY_IS_VALID, true)
	}
	
	private fun cacheResult(isValid: Boolean)
	{
		val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
		prefs.edit()
			.putLong(KEY_LAST_CHECK, System.currentTimeMillis())
			.putBoolean(KEY_IS_VALID, isValid)
			.apply()
		Log.v(TAG, "State cached: $isValid")
	}
	
	private fun showValidationFailureDialog(activity: Activity)
	{
		activity.runOnUiThread {
			AlertDialog.Builder(activity)
				.setTitle("Verification Required")
				.setMessage("Unable to verify application source. Please ensure you have an active internet connection and the app was installed from an official source.")
				.setPositiveButton("Retry") { _, _ ->
					context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
						.edit()
						.clear()
						.apply()
					activity.recreate()
				}
				.setNegativeButton("Exit") { _, _ ->
					activity.finish()
				}
				.setCancelable(false)
				.show()
		}
	}
	
	fun release()
	{
		scope.cancel()
		billingClient?.endConnection()
	}
}
