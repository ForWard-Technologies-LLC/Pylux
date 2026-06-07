// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay

object CloudLocale
{
	const val DEFAULT = "en-US"

	fun toImagicLocale(stored: String): String = stored.lowercase()

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

	/**
	 * Ordered store locales to try when fetching the catalog. Sony serves a fixed set of
	 * language-COUNTRY combinations: the country is always valid but the language may not be
	 * (a Hungarian-language account yields "hu-HU", which 404s, while "en-HU" works). Fall back
	 * to English for the same country, then en-US, so the catalog loads in every region.
	 * Each pair is (canonical "ll-CC" for storage, lowercased "ll-cc" for the imagic URL).
	 */
	fun fallbackChain(stored: String): List<Pair<String, String>>
	{
		val (country, language) = parseStorePath(stored)
		val seen = LinkedHashSet<String>()
		val chain = mutableListOf<Pair<String, String>>()
		fun add(lang: String, ctry: String)
		{
			val canonical = "$lang-$ctry"
			val imagic = canonical.lowercase()
			if (seen.add(imagic))
				chain.add(canonical to imagic)
		}
		add(language, country)
		add("en", country)
		add("en", "US")
		return chain
	}

	/** Non-fatal warning when locale could not be learned from Kamaji (catalog may use en-US). */
	fun unconfiguredWarning(): String =
		"Could not detect your PlayStation region. The catalog may not match your store."
}
