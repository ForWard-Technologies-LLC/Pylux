// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common.ext

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.graphics.drawable.ColorDrawable
import android.util.TypedValue
import android.view.KeyEvent
import android.widget.TextView
import androidx.appcompat.app.AlertDialog
import com.google.android.material.dialog.MaterialAlertDialogBuilder

private const val TV_TITLE_SP = 28f
private const val TV_BODY_SP = 24f
private const val TV_BUTTON_SP = 20f
private const val TV_FOCUS_COLOR = 0x44FFD700.toInt()

fun Context.isTv(): Boolean
{
	val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
	return uiModeManager.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
}

/**
 * App-wide dialog builder. On phone/tablet it behaves identically to
 * [MaterialAlertDialogBuilder]. On TV it automatically:
 *
 * - Scales title, message and button text for couch-distance readability.
 * - Adds a visible blue overlay on focused buttons for D-pad navigation.
 * - Pre-highlights the positive button and intercepts the first
 *   DPAD_CENTER / ENTER so it activates with a single press even when
 *   the system is in touch mode (common on TV emulators).
 */
class AppAlertDialogBuilder(context: Context) : MaterialAlertDialogBuilder(context)
{
	override fun show(): AlertDialog
	{
		val dialog = super.show()
		if (!context.isTv()) return dialog

		dialog.findViewById<TextView>(android.R.id.message)
			?.setTextSize(TypedValue.COMPLEX_UNIT_SP, TV_BODY_SP)
		dialog.window?.decorView?.findViewById<TextView>(
			androidx.appcompat.R.id.alertTitle
		)?.setTextSize(TypedValue.COMPLEX_UNIT_SP, TV_TITLE_SP)

		val positiveBtn = dialog.getButton(AlertDialog.BUTTON_POSITIVE)

		for (which in intArrayOf(AlertDialog.BUTTON_POSITIVE, AlertDialog.BUTTON_NEGATIVE, AlertDialog.BUTTON_NEUTRAL)) {
			dialog.getButton(which)?.let { btn ->
				btn.setTextSize(TypedValue.COMPLEX_UNIT_SP, TV_BUTTON_SP)
				btn.isFocusable = true
				btn.isFocusableInTouchMode = true
				btn.setOnFocusChangeListener { v, hasFocus ->
					v.foreground = if (hasFocus) ColorDrawable(TV_FOCUS_COLOR) else null
					if (hasFocus && v != positiveBtn) positiveBtn?.foreground = null
				}
			}
		}

		positiveBtn?.foreground = ColorDrawable(TV_FOCUS_COLOR)
		positiveBtn?.requestFocusFromTouch()

		// dialog.setOnKeyListener { _, keyCode, event ->
		// 	if (event.action == KeyEvent.ACTION_UP &&
		// 		(keyCode == KeyEvent.KEYCODE_DPAD_CENTER || keyCode == KeyEvent.KEYCODE_ENTER) &&
		// 		positiveBtn != null && !positiveBtn.isFocused)
		// 	{
		// 		positiveBtn.performClick()
		// 		true
		// 	} else false
		// }

		return dialog
	}
}

/**
 * Convenience entry-point: every dialog in the app should be created via
 * `context.alertDialogBuilder()` so TV enhancements are applied automatically.
 */
fun Context.alertDialogBuilder(): AppAlertDialogBuilder = AppAlertDialogBuilder(this)
