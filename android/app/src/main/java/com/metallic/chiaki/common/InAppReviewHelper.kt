// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.util.Log
import androidx.fragment.app.FragmentActivity
import com.google.android.play.core.review.ReviewManagerFactory
import com.metallic.chiaki.common.ext.isTv

/**
 * Google Play In-App Review. Eligibility uses only [Preferences.totalStreamTimeMs]
 * (accumulated in [com.metallic.chiaki.stream.StreamActivity]); no separate timers.
 *
 * Google documents this API for phones, tablets, and **TVs with Google TV / Google Play**; we do not
 * special-case TV here — if the device or quota does not show UI, [requestReviewFlow] / launch will reflect that in logs.
 *
 * [MainActivity] invokes this only from a *fresh* activity [android.os.Bundle] (e.g. cold start, new task), not
 * on every [android.app.Activity.onResume]. Whether the system actually shows the review UI is throttled by Play
 * (quotas, prior reviews, etc.); we do not keep a “never ask again” flag in app prefs.
 */
object InAppReviewHelper
{
	private const val TAG = "InAppReview"
	private const val MIN_TOTAL_STREAM_MS = 15L * 60L * 1_000L

	/**
	 * Requests the Play in-app review flow. Call from Main once per new activity instance when stream time is enough.
	 * The Play API may or may not show a sheet; repeat calls on later app starts are expected—Play deduplicates display.
	 */
	fun tryPromptIfEligible(activity: FragmentActivity, preferences: Preferences)
	{
		val t = preferences.totalStreamTimeMs
		val isTv = activity.isTv()
		val finishing = activity.isFinishing
		Log.i(
			TAG,
			"check (app open / new Main): totalStreamTimeMs=%d (need>=%d), isTv=%s, isFinishing=%s"
				.format(t, MIN_TOTAL_STREAM_MS, isTv, finishing)
		)
		if (finishing) {
			Log.i(TAG, "skip: activity finishing")
			return
		}
		if (t < MIN_TOTAL_STREAM_MS) {
			val needSec = (MIN_TOTAL_STREAM_MS - t) / 1000L
			Log.i(
				TAG,
				"skip: not enough stream time — have ${t}ms, need at least ${MIN_TOTAL_STREAM_MS}ms (~${needSec}s more)"
			)
			return
		}

		Log.i(TAG, "eligibility OK — requesting review info from Play…")
		val manager = ReviewManagerFactory.create(activity)
		manager.requestReviewFlow().addOnCompleteListener { task ->
			if (!task.isSuccessful)
			{
				Log.w(
					TAG,
					"requestReviewFlow failed (no launch): ${task.exception?.javaClass?.simpleName}: ${task.exception?.message}"
				)
				return@addOnCompleteListener
			}
			val reviewInfo = task.result
			if (reviewInfo == null) {
				Log.w(TAG, "requestReviewFlow succeeded but ReviewInfo is null; not launching")
				return@addOnCompleteListener
			}
			if (activity.isFinishing) {
				Log.i(TAG, "skip launch: activity now finishing after request")
				return@addOnCompleteListener
			}
			Log.i(TAG, "requestReviewFlow OK — launching in-app review flow (Play throttles actual UI; we do not)…")
			manager.launchReviewFlow(activity, reviewInfo).addOnCompleteListener { _ ->
				Log.i(
					TAG,
					"launchReviewFlow finished (actual sheet/quotas: Play-controlled)"
				)
			}
		}
	}
}
