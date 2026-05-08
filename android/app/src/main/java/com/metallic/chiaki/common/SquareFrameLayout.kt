// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.content.Context
import android.util.AttributeSet
import android.widget.FrameLayout

/**
 * A FrameLayout that maintains a square aspect ratio (width = height)
 */
class SquareFrameLayout @JvmOverloads constructor(
	context: Context,
	attrs: AttributeSet? = null,
	defStyleAttr: Int = 0
) : FrameLayout(context, attrs, defStyleAttr) {

	override fun onMeasure(widthMeasureSpec: Int, heightMeasureSpec: Int) {
		// Make height equal to width to maintain square aspect ratio
		super.onMeasure(widthMeasureSpec, widthMeasureSpec)
	}
}
