// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.metallic.chiaki.cloudplay.repository.CloudGameRepository
import java.security.KeyStore

/**
 * Secure storage for PSN tokens using EncryptedSharedPreferences
 */
class SecureTokenManager(context: Context)
{
	// Held only to drop the lib-owned cloud catalog cache when the account changes.
	private val appContext = context.applicationContext

	companion object
	{
		private const val TAG = "SecureTokenManager"
		private const val ENCRYPTED_PREFS_FILE = "secure_tokens"
		private const val KEY_NPSSO_TOKEN = "npsso_token"
		private const val ANDROID_KEYSTORE = "AndroidKeyStore"
	}
	
	// Null when the store can't be opened even after a reset. Callers then see "no token
	// stored", i.e. signed out. That matches the other platforms: on Qt a missing
	// settings/psn_npsso_token reads back as an empty QString (gui/src/settings.cpp), and on
	// iOS SecureStore returns nil/"" when the Keychain item can't be read. Neither treats
	// unreadable token storage as fatal, and neither should this — every other method here
	// already caught and degraded, only the constructor rethrew.
	private val encryptedPrefs: SharedPreferences?

	init
	{
		encryptedPrefs = openEncryptedPrefs(context) ?: run {
			// AEADBadTagException here means the stored ciphertext no longer authenticates
			// against the Android Keystore key. The usual cause is Auto Backup restoring
			// secure_tokens.xml onto a device whose keystore never held the matching master
			// key (keystore material is device-bound and never backed up). The token is
			// unrecoverable either way, so drop the file and the alias and rebuild once.
			Log.w(TAG, "Secure token storage unreadable; resetting it")
			resetEncryptedPrefs(context)
			openEncryptedPrefs(context)
		}

		if (encryptedPrefs == null)
			Log.e(TAG, "Secure token storage unavailable; continuing signed out")
		else
			Log.i(TAG, "Secure token storage initialized successfully")
	}

	private fun openEncryptedPrefs(context: Context): SharedPreferences? =
		try
		{
			val masterKey = MasterKey.Builder(context)
				.setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
				.build()

			EncryptedSharedPreferences.create(
				context,
				ENCRYPTED_PREFS_FILE,
				masterKey,
				EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
				EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
			)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to open secure token storage", e)
			null
		}

	/** Drops the encrypted prefs file and its master key so the store can be recreated. */
	private fun resetEncryptedPrefs(context: Context)
	{
		try
		{
			context.deleteSharedPreferences(ENCRYPTED_PREFS_FILE)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to delete $ENCRYPTED_PREFS_FILE", e)
		}

		try
		{
			val keyStore = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
			if (keyStore.containsAlias(MasterKey.DEFAULT_MASTER_KEY_ALIAS))
				keyStore.deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to drop master key", e)
		}
	}
	
	/**
	 * Save NPSSO token securely
	 */
	fun saveNpssoToken(token: String)
	{
		val prefs = encryptedPrefs
		if (prefs == null)
		{
			Log.e(TAG, "Cannot save NPSSO token: secure storage unavailable")
			return
		}

		try
		{
			// Only drop the cached catalog when the token actually changes. Re-auth paths
			// can re-save the same npsso (e.g. token re-exchange after an expired access
			// token), which is not an account change and must not wipe the 24h cache.
			val changed = (prefs.getString(KEY_NPSSO_TOKEN, "") ?: "") != token
			prefs.edit()
				.putString(KEY_NPSSO_TOKEN, token)
				.apply()
			Log.i(TAG, "NPSSO token saved securely")
			if (changed)
			{
				// Account changed (login / token re-entry): drop the cached catalog so the next
				// fetch re-resolves owned games for this account instead of serving the old one's.
				CloudGameRepository.invalidateCatalogCache(appContext, "account login")
			}
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
			encryptedPrefs?.getString(KEY_NPSSO_TOKEN, "") ?: ""
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
			encryptedPrefs?.edit()
				?.remove(KEY_NPSSO_TOKEN)
				?.apply()
			Log.i(TAG, "NPSSO token cleared")
			// Logout: drop the cached catalog so a later login can't briefly show the
			// previous account's owned games from a stale cache hit.
			CloudGameRepository.invalidateCatalogCache(appContext, "account logout")
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to clear NPSSO token", e)
		}
	}
}
