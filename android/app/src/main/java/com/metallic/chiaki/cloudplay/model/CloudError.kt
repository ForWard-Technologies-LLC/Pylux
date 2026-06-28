// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.model

/**
 * Sealed class representing different types of cloud streaming errors
 */
sealed class CloudError(val message: String, val exception: Exception? = null) {
	/**
	 * Authentication/authorization errors (expired token, invalid credentials, etc.)
	 */
	class AuthenticationError(message: String, exception: Exception? = null) : CloudError(message, exception)
	
	/**
	 * Network connectivity errors
	 */
	class NetworkError(message: String, exception: Exception? = null) : CloudError(message, exception)
	
	/**
	 * General/unknown errors
	 */
	class GeneralError(message: String, exception: Exception? = null) : CloudError(message, exception)
	
	companion object {
		/**
		 * Parse an error message and classify it
		 */
		fun fromMessage(message: String, exception: Exception? = null): CloudError {
			return when {
				isAuthenticationError(message) -> AuthenticationError(message, exception)
				isNetworkError(message) -> NetworkError(message, exception)
				else -> GeneralError(message, exception)
			}
		}
		
		private fun isAuthenticationError(message: String): Boolean {
			// Keep these specific to genuine auth/credential problems. Do NOT include broad words
			// like "failed", "token" or "expired": libchiaki's hard-failure detail is literally
			// "Failed to fetch cloud catalog" (returned for NON-auth/transient conditions) and
			// parse/exception messages also contain "failed" — classifying those as auth would wipe
			// a valid NPSSO token and force a needless re-login. A genuinely expired npsso is
			// surfaced by the lib as a degraded-but-usable result via the warning banner (which says
			// "expired"), NOT through this error path, so "expired" here would only ever be a false
			// positive.
			val authKeywords = listOf(
				"npsso",
				"authorization",
				"oauth",
				"authentication",
				"login",
				"unauthorized",
				"forbidden",
				"401",
				"403"
			)
			
			val lowerMessage = message.lowercase()
			// Check if message contains any auth keyword
			val hasAuthKeyword = authKeywords.any { lowerMessage.contains(it) }
			
			// Log for debugging
			android.util.Log.d("CloudError", "Checking auth error: '$message' -> hasAuthKeyword=$hasAuthKeyword")
			
			return hasAuthKeyword
		}
		
		private fun isNetworkError(message: String): Boolean {
			val networkKeywords = listOf(
				"network",
				"connection",
				"timeout",
				"unreachable",
				"no internet"
			)
			
			val lowerMessage = message.lowercase()
			return networkKeywords.any { lowerMessage.contains(it) }
		}
	}
}
