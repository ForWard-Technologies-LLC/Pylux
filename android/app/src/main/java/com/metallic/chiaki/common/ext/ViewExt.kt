// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common.ext

import android.content.Context
import android.view.View
import android.view.ViewGroup

/**
 * Recursively sets [View.isFocusableInTouchMode] = true on all focusable descendants.
 * Call this on TV only so D-pad navigation works; on mobile it's a no-op and avoids
 * the double-tap-to-click behavior.
 *
 * Usage: `binding.root.enableFocusableInTouchModeForTv(context)` in Activity/Fragment
 * when isTv(). For RecyclerView items, call from onBindViewHolder/onCreateViewHolder.
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
