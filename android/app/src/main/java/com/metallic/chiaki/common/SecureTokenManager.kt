// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Secure storage for PSN tokens using EncryptedSharedPreferences
 */
class SecureTokenManager(context: Context)
{
	companion object
	{
		private const val TAG = "SecureTokenManager"
		private const val ENCRYPTED_PREFS_FILE = "secure_tokens"
		private const val KEY_NPSSO_TOKEN = "npsso_token"
	}
	
	private val encryptedPrefs: SharedPreferences
	
	init
	{
		try
		{
			// Create or retrieve the master key for encryption
			val masterKey = MasterKey.Builder(context)
				.setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
				.build()
			
			// Create encrypted shared preferences
			encryptedPrefs = EncryptedSharedPreferences.create(
				context,
				ENCRYPTED_PREFS_FILE,
				masterKey,
				EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
				EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
			)
			
			Log.i(TAG, "Secure token storage initialized successfully")
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to initialize secure token storage", e)
			throw e
		}
	}
	
	/**
	 * Save NPSSO token securely
	 */
	fun saveNpssoToken(token: String)
	{
		try
		{
			encryptedPrefs.edit()
				.putString(KEY_NPSSO_TOKEN, token)
				.apply()
			Log.i(TAG, "NPSSO token saved securely")
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to save NPSSO token", e)
		}
	}
	
	/**
	 * Retrieve NPSSO token
	 */
	fun getNpssoToken(): String
	{
		return try
		{
			encryptedPrefs.getString(KEY_NPSSO_TOKEN, "") ?: ""
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to retrieve NPSSO token", e)
			""
		}
	}
	
	/**
	 * Check if NPSSO token exists
	 */
	fun hasNpssoToken(): Boolean
	{
		return getNpssoToken().isNotEmpty()
	}
	
	/**
	 * Clear NPSSO token (logout)
	 */
	fun clearNpssoToken()
	{
		try
		{
			encryptedPrefs.edit()
				.remove(KEY_NPSSO_TOKEN)
				.apply()
			Log.i(TAG, "NPSSO token cleared")
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to clear NPSSO token", e)
		}
	}
}
