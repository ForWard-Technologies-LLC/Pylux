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
		private const val CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000L // 24 hours
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
			Log.w(TAG, "=== DEBUG BUILD: Validation bypassed ===")
			onResult(true)
			return
		}
		
		Log.w(TAG, "=== Starting integrity validation (Release Build) ===")
		
		scope.launch {
			try
			{
				if (canUseCachedResult())
				{
					val cachedValid = getCachedValidity()
					val prefs = context.getSharedPreferences(PREF_NAME, Context.MODE_PRIVATE)
					val lastCheck = prefs.getLong(KEY_LAST_CHECK, 0)
					val age = System.currentTimeMillis() - lastCheck
					val ageHours = age / (1000 * 60 * 60)
					
					Log.w(TAG, "Using cached result: VALID=$cachedValid (cached $ageHours hours ago)")
					Log.w(TAG, "=== Integrity check result: ${if (cachedValid) "PASSED" else "FAILED"} (cached) ===")
					onResult(cachedValid)
					return@launch
				}
				
				Log.w(TAG, "Cache expired or missing, performing fresh validation...")
				val isValid = performValidation()
				
				cacheResult(isValid)
				
				if (isValid)
				{
					Log.w(TAG, "Fresh validation completed: PASSED")
					Log.w(TAG, "=== Integrity check result: PASSED (fresh) ===")
					onResult(true)
				}
				else
				{
					Log.e(TAG, "Fresh validation completed: FAILED")
					Log.e(TAG, "=== Integrity check result: FAILED ===")
					showValidationFailureDialog(activity)
					onResult(false)
				}
			}
			catch (e: Exception)
			{
				Log.e(TAG, "Validation exception occurred: ${e.message}", e)
				val fallback = getCachedValidity()
				Log.w(TAG, "Exception fallback: using cached state=$fallback")
				Log.w(TAG, "=== Integrity check result: ${if (fallback) "PASSED" else "FAILED"} (fallback) ===")
				onResult(fallback)
			}
		}
	}
	
	private suspend fun performValidation(): Boolean = withContext(Dispatchers.IO)
	{
		Log.w(TAG, "Initializing billing client...")
		
		return@withContext suspendCancellableCoroutine { continuation ->
			billingClient = BillingClient.newBuilder(context)
				.setListener { _, _ -> }
				.enablePendingPurchases(
					PendingPurchasesParams.newBuilder()
						.enableOneTimeProducts()
						.build()
				)
				.build()
			
			Log.w(TAG, "Connecting to Play Store billing service...")
			
			billingClient?.startConnection(object : BillingClientStateListener {
				override fun onBillingSetupFinished(billingResult: BillingResult)
				{
					val responseCode = billingResult.responseCode
					val responseName = getResponseCodeName(responseCode)
					
					if (responseCode == BillingClient.BillingResponseCode.OK)
					{
						Log.w(TAG, "Billing service connected successfully (code: $responseName)")
						
						scope.launch(Dispatchers.IO) {
							try
							{
								Log.w(TAG, "Querying purchases from Play Store...")
								val result = billingClient?.queryPurchasesAsync(
									QueryPurchasesParams.newBuilder()
										.setProductType(BillingClient.ProductType.INAPP)
										.build()
								)
								
								val queryResponseCode = result?.billingResult?.responseCode ?: -1
								val queryResponseName = getResponseCodeName(queryResponseCode)
								val isValid = queryResponseCode == BillingClient.BillingResponseCode.OK
								
								Log.w(TAG, "Purchase query completed: code=$queryResponseName, valid=$isValid")
								
								if (isValid) {
									Log.w(TAG, "Play Store verification: AUTHORIZED")
								} else {
									Log.e(TAG, "Play Store verification: UNAUTHORIZED (code=$queryResponseName)")
								}
								
								continuation.resume(isValid) { }
							}
							catch (e: Exception)
							{
								Log.e(TAG, "Purchase query exception: ${e.message}", e)
								continuation.resume(false) { }
							}
							finally
							{
								billingClient?.endConnection()
								Log.w(TAG, "Billing client disconnected")
							}
						}
					}
					else
					{
						Log.e(TAG, "Billing setup FAILED: code=$responseName ($responseCode)")
						Log.e(TAG, "Reason: ${billingResult.debugMessage}")
						continuation.resume(false) { }
					}
				}
				
				override fun onBillingServiceDisconnected()
				{
					Log.w(TAG, "Billing service disconnected during connection")
					Log.w(TAG, "Treating disconnect as VALID (network issue)")
					continuation.resume(true) { }
				}
			})
			
			scope.launch {
				delay(30000)
				if (continuation.isActive)
				{
					Log.e(TAG, "Validation TIMEOUT after 30 seconds")
					Log.w(TAG, "Treating timeout as VALID (network issue)")
					continuation.resume(true) { }
				}
			}
		}
	}
	
	private fun getResponseCodeName(code: Int): String = when(code) {
		BillingClient.BillingResponseCode.OK -> "OK"
		BillingClient.BillingResponseCode.USER_CANCELED -> "USER_CANCELED"
		BillingClient.BillingResponseCode.SERVICE_UNAVAILABLE -> "SERVICE_UNAVAILABLE"
		BillingClient.BillingResponseCode.BILLING_UNAVAILABLE -> "BILLING_UNAVAILABLE"
		BillingClient.BillingResponseCode.ITEM_UNAVAILABLE -> "ITEM_UNAVAILABLE"
		BillingClient.BillingResponseCode.DEVELOPER_ERROR -> "DEVELOPER_ERROR"
		BillingClient.BillingResponseCode.ERROR -> "ERROR"
		BillingClient.BillingResponseCode.ITEM_ALREADY_OWNED -> "ITEM_ALREADY_OWNED"
		BillingClient.BillingResponseCode.ITEM_NOT_OWNED -> "ITEM_NOT_OWNED"
		BillingClient.BillingResponseCode.SERVICE_DISCONNECTED -> "SERVICE_DISCONNECTED"
		BillingClient.BillingResponseCode.FEATURE_NOT_SUPPORTED -> "FEATURE_NOT_SUPPORTED"
		else -> "UNKNOWN($code)"
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
		Log.w(TAG, "Validation result cached: VALID=$isValid (expires in 24 hours)")
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
