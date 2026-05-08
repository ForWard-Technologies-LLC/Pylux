// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common.ext

import android.content.Context
import android.view.View
import android.view.ViewGroup

/**
 * Recursively sets [View.isFocusableInTouchMode] = true on all focusable descendants.
 * **TV / Leanback only:** on phones/tablets this is a no-op. Enabling touch-mode focus on
 * handhelds makes the first tap only *focus* the control (highlight) and the second tap
 * activate it — bad for normal touch UI.
 */
fun View.enableFocusableInTouchModeForTv(context: Context)
{
	if (!context.isTv()) return
	if (this is ViewGroup) {
		for (i in 0 until childCount) {
			getChildAt(i).enableFocusableInTouchModeForTv(context)
		}
	}
	if (isFocusable) {
		isFocusableInTouchMode = true
	}
}
