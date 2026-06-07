// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay

/**
 * PSN Cloud Gaming API Constants
 * Matches KamajiConsts from gui/include/cloudstreaming/pskamajisession.h exactly
 */
object PsnApiConstants
{
	// CloudConfig constants
	const val ACCOUNT_BASE = "https://ca.account.sony.com/api"
	
	// KamajiConsts - PSNow specific
	const val KAMAJI_BASE = "https://psnow.playstation.com/kamaji/api/pcnow/00_09_000"
	const val STORE_BASE = "https://psnow.playstation.com/store/api/pcnow/00_09_000"
	const val COMMERCE_BASE = "https://commerce.api.np.km.playstation.net/commerce/api/v1"
	const val CLIENT_ID = "bc6b0777-abb5-40da-92ca-e133cf18e989"
	const val REDIRECT_URI = "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/grc-response.html"
	const val ORIGIN = "https://psnow.playstation.com"
	const val REFERER = "https://psnow.playstation.com/app/2.2.0/133/5cdcc037d/"
	const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; WOW64) AppleWebKit/537.36 (KHTML, like Gecko) playstation-now/0.0.0 Chrome/83.0.4103.104 Electron/9.0.4 Safari/537.36 gkApollo"
	
	const val PS4_SCOPES = "kamaji:commerce_native kamaji:commerce_container kamaji:lists kamaji:s2s.subscriptionsPremium.get"

	const val ROOT_CONTAINER_ID = "STORE-MSF75508-PSNOWALLGAMES"
}

/**
 * PS3 / Classics pcnow store helpers, by account region group.
 * Mirrors KamajiConsts (gui/include/cloudstreaming/pskamajisession.h) exactly.
 *
 * pcnow (the PS Plus PC "Apollo" backend) has only TWO Classics id families:
 *   - SCEA / Americas  -> store MSF192018, US-region ids (UP/NPUA/BLUS),
 *                         PS3 child container "APOLLOPS3GAMES"
 *   - SCEE / PAL (rest) -> store MSF192014, EU-region ids (EP/NPEA/NPEB/BLES),
 *                         PS3 child container "APOLLOPS3"
 * JP / Asia have no Apollo store (the PC app isn't offered there), so they fall back to
 * PAL. A PS Plus account is authorized at Gaikai only for the id family of its own region
 * group, so the catalog must be browsed + resolved in the account's group. Region is keyed
 * by the ACCOUNT's region group, NOT by parsing the product-id prefix.
 */
object KamajiClassics
{
	private val AMERICAS = setOf(
		"US", "CA", "MX", "BR", "AR", "CL", "CO", "PE", "EC", "BO", "PY", "UY",
		"CR", "GT", "HN", "NI", "PA", "SV", "DO"
	)

	fun isAmericasClassicsRegion(countryCode: String): Boolean =
		AMERICAS.contains(countryCode.uppercase())

	/** Country path to use for container/conversion calls (US for Americas, GB for PAL). */
	fun classicsStoreCountry(accountCountry: String): String =
		if (isAmericasClassicsRegion(accountCountry)) "US" else "GB"

	/** Fully-qualified PS3 catalog container id for the account's region group. */
	fun classicsPs3ContainerId(accountCountry: String): String =
		if (isAmericasClassicsRegion(accountCountry))
			"STORE-MSF192018-APOLLOPS3GAMES"
		else
			"STORE-MSF192014-APOLLOPS3"
}

