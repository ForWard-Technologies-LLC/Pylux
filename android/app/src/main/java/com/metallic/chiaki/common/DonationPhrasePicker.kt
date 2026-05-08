// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.content.Context
import com.pylux.stream.R
import org.json.JSONObject

/**
 * Loads [R.raw.donation_prompt_phrases] copied at build time from [shared/donation_prompt_phrases.json]
 * (see `syncDonationPhrases` in `android/app/build.gradle`). Algorithm matches [shared/DONATION_PHRASE_PICKER.md].
 */
object DonationPhrasePicker
{
	/** Paywall opens 1..this many keep the default bullet list; after that, one rotating phrase replaces it. */
	const val PAYWALL_BULLET_SHOWS_BEFORE_PHRASES = 3

	private val defaultCategoryOrder = listOf("mild", "playful", "mean")

	@Volatile
	private var cachedFlat: List<String>? = null

	/** Clears cached phrases (e.g. after locale or asset change). */
	fun clearCache()
	{
		cachedFlat = null
	}

	/**
	 * 1-based call id: first phrase uses [callId] == 1, second == 2, … wraps over the flattened list.
	 */
	fun phraseForCallId(context: Context, callId: Int): String?
	{
		if (callId < 1) return null
		val flat = cachedFlat ?: loadFlat(context).also { cachedFlat = it }
		if (flat.isEmpty()) return null
		val i = floorMod(callId - 1, flat.size)
		return flat[i]
	}

	/**
	 * [showCount] = total paywall opens (1-based). First three opens → null (keep default bullets).
	 * From the 4th open, returns the rotating phrase (uses [showCount] so rotation advances each time).
	 */
	fun phraseForPaywallShowCount(context: Context, showCount: Int): String?
	{
		if (showCount <= PAYWALL_BULLET_SHOWS_BEFORE_PHRASES) return null
		val phraseCallId = showCount - PAYWALL_BULLET_SHOWS_BEFORE_PHRASES
		return phraseForCallId(context, phraseCallId)
	}

	private fun loadFlat(context: Context): List<String>
	{
		val text = context.resources.openRawResource(R.raw.donation_prompt_phrases).bufferedReader().use { it.readText() }
		val root = JSONObject(text)
		val order = root.optJSONArray("category_order")?.let { arr ->
			(0 until arr.length()).map { arr.getString(it) }
		} ?: defaultCategoryOrder
		val categories = root.optJSONObject("categories") ?: return emptyList()
		val out = ArrayList<String>()
		for (key in order)
		{
			val cat = categories.optJSONObject(key) ?: continue
			val phrases = cat.optJSONArray("phrases") ?: continue
			for (i in 0 until phrases.length())
				out.add(phrases.getString(i))
		}
		return out
	}

	private fun floorMod(a: Int, b: Int): Int
	{
		val m = a % b
		return if (m < 0) m + b else m
	}
}
