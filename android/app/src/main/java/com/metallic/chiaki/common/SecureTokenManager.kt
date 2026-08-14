// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.metallic.chiaki.cloudplay.repository.CloudGameRepository
import java.security.GeneralSecurityException
import java.security.KeyStore

/**
 * Secure storage for PSN tokens using EncryptedSharedPreferences.
 *
 * The store itself is process-wide state held in the companion object: SecureTokenManager is
 * constructed freely (Preferences() builds one per screen, some on background threads), so the
 * open — and especially the destructive corruption reset — must happen at most once per
 * process. Two instances concurrently opening-and-resetting could delete the Keystore master
 * key the other just recreated, and a stale SharedPreferencesImpl kept alive by an earlier
 * instance could then rewrite the file with old keysets wrapped by a deleted key, recreating
 * the very AEADBadTagException-on-next-launch this class exists to prevent.
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

		private val storeLock = Any()
		@Volatile private var store: SharedPreferences? = null
		// The reset deletes user data (the stored token), so it is allowed exactly once per
		// process, and only for a proven crypto failure — never for transient errors.
		private var resetAttempted = false

		/**
		 * Opens (or returns the cached) process-wide encrypted store. Returns null when the
		 * store cannot be opened; callers then see "no token stored", i.e. signed out. That
		 * matches the other platforms: on Qt a missing settings/psn_npsso_token reads back as
		 * an empty QString (gui/src/settings.cpp), and on iOS SecureStore returns nil/"" when
		 * the Keychain item can't be read. Neither treats unreadable token storage as fatal.
		 *
		 * A null result from a transient failure is not cached, so a later instantiation
		 * retries; only a successful open is cached.
		 */
		private fun obtainStore(context: Context): SharedPreferences?
		{
			store?.let { return it }
			synchronized(storeLock)
			{
				store?.let { return it }
				try
				{
					store = openEncryptedPrefs(context)
					Log.i(TAG, "Secure token storage initialized successfully")
				}
				catch (e: Exception)
				{
					if (!resetAttempted && isUnrecoverableCryptoFailure(e))
					{
						// AEADBadTagException (or kin) means the stored ciphertext no longer
						// authenticates against the Android Keystore key. The usual cause is
						// Auto Backup restoring secure_tokens.xml onto a device whose keystore
						// never held the matching master key (keystore material is
						// device-bound and never backed up). The token is unrecoverable, so
						// drop the file and the alias and rebuild — once.
						Log.w(TAG, "Secure token storage unreadable (crypto failure); resetting it", e)
						resetAttempted = true
						resetEncryptedPrefs(context)
						try
						{
							store = openEncryptedPrefs(context)
							Log.i(TAG, "Secure token storage rebuilt after reset")
						}
						catch (e2: Exception)
						{
							Log.e(TAG, "Secure token storage unavailable after reset; continuing signed out", e2)
						}
					}
					else
					{
						// Transient failure (Keystore hiccup, I/O): do NOT delete anything.
						// The old behavior was to throw (crashing the app); degrading to
						// signed-out for this attempt preserves the token for the next one.
						Log.e(TAG, "Failed to open secure token storage (not resetting)", e)
					}
				}
				return store
			}
		}

		private fun openEncryptedPrefs(context: Context): SharedPreferences
		{
			val masterKey = MasterKey.Builder(context)
				.setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
				.build()

			return EncryptedSharedPreferences.create(
				context,
				ENCRYPTED_PREFS_FILE,
				masterKey,
				EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
				EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
			)
		}

		/**
		 * True only for failures that mean the stored ciphertext/keysets can never be read
		 * again (wrong or missing master key, corrupted keyset) — the cases where deleting
		 * the store is recovery rather than data loss.
		 */
		private fun isUnrecoverableCryptoFailure(e: Throwable): Boolean
		{
			var cause: Throwable? = e
			while (cause != null)
			{
				if (cause is GeneralSecurityException)
					return true
				// Tink's shaded protobuf exception for a corrupted keyset; matched by name to
				// avoid depending on the shaded package.
				if (cause.javaClass.name.contains("InvalidProtocolBuffer"))
					return true
				cause = cause.cause
			}
			return false
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
	}

	private val encryptedPrefs: SharedPreferences?
		get() = obtainStore(appContext)

	/**
	 * Save NPSSO token securely.
	 *
	 * @return true when the token is durably stored; false when secure storage is
	 * unavailable or the write failed — callers should surface that instead of reporting a
	 * successful login the app will have forgotten by the next screen.
	 */
	fun saveNpssoToken(token: String): Boolean
	{
		val prefs = encryptedPrefs
		if (prefs == null)
		{
			Log.e(TAG, "Cannot save NPSSO token: secure storage unavailable")
			return false
		}

		return try
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
			true
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to save NPSSO token", e)
			false
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
