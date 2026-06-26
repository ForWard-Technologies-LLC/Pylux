// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay

object CloudLocale
{
	fun parseStorePath(stored: String): Pair<String, String>
	{
		val parts = stored.split("-", limit = 2)
		val language = parts.getOrNull(0)?.lowercase()?.takeIf { it.isNotEmpty() } ?: "en"
		val country = parts.getOrNull(1)?.uppercase()?.takeIf { it.isNotEmpty() } ?: "US"
		return country to language
	}

	fun fromSession(language: String?, country: String?): String?
	{
		val lang = language?.trim().orEmpty()
		val cty = country?.trim().orEmpty()
		if (lang.isEmpty() || cty.isEmpty())
			return null
		return "$lang-${cty.uppercase()}"
	}

	/** Non-fatal warning when locale could not be learned from Kamaji (catalog may use en-US). */
	fun unconfiguredWarning(): String =
		"Could not detect your PlayStation region. The catalog may not match your store."
}
