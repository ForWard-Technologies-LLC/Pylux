// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream

import android.app.Activity
import android.os.Build
import android.util.Log
import android.view.Surface

data class DisplayModeInfo(val id: Int, val width: Int, val height: Int, val refreshRate: Float)

/**
 * Switches the stream window to the display mode with the highest refresh rate at the
 * current resolution (120 Hz on the Tab S9). The window attribute is per-window, so the
 * system default returns when the activity goes away.
 */
object DisplayModeHelper
{
	private const val TAG = "DisplayMode"

	fun pickHighestRefresh(current: DisplayModeInfo, all: List<DisplayModeInfo>): DisplayModeInfo?
	{
		val best = all
			.filter { it.width == current.width && it.height == current.height }
			.maxByOrNull { it.refreshRate } ?: return null
		return if(best.refreshRate > current.refreshRate + 0.5f) best else null
	}

	/**
	 * Requests the highest-refresh mode at the current resolution for [activity]'s window and returns
	 * the requested rate. The switch is asynchronous and the system may refuse it (peak refresh
	 * setting, power saver); use [currentRefreshRate] to read what is actually in use.
	 *
	 * When no higher mode exists (an adaptive panel may already be at its peak rate when the activity
	 * starts) the highest same-size mode is still pinned via the preferred mode id, so the panel does
	 * not drop back later. The pinned mode id and the surface hint ([hintSurfaceFrameRate], re-issued
	 * on every surfaceChanged) work together: the former selects the mode, the latter keeps it.
	 */
	fun applyHighestRefresh(activity: Activity): Float
	{
		// activity.display is nullable before the activity is attached, so defaultDisplay is used deliberately.
		@Suppress("DEPRECATION")
		val display = activity.windowManager.defaultDisplay
		val current = display.mode.let { DisplayModeInfo(it.modeId, it.physicalWidth, it.physicalHeight, it.refreshRate) }
		val all = display.supportedModes.map { DisplayModeInfo(it.modeId, it.physicalWidth, it.physicalHeight, it.refreshRate) }
		val best = pickHighestRefresh(current, all)
		val attrs = activity.window.attributes
		if(best == null)
		{
			// Already at the highest rate (or the only mode): pin it so an adaptive panel stays there.
			val pin = all
				.filter { it.width == current.width && it.height == current.height }
				.maxByOrNull { it.refreshRate } ?: current
			attrs.preferredDisplayModeId = pin.id
			activity.window.attributes = attrs
			Log.i(TAG, "Pinning ${pin.width}x${pin.height} @ ${pin.refreshRate} Hz (mode ${pin.id})")
			return pin.refreshRate
		}
		attrs.preferredDisplayModeId = best.id
		activity.window.attributes = attrs
		Log.i(TAG, "Requested ${best.width}x${best.height} @ ${best.refreshRate} Hz (mode ${best.id})")
		return best.refreshRate
	}

	/** The refresh rate of the display mode currently in use (for the stats overlay). */
	fun currentRefreshRate(activity: Activity): Float
	{
		@Suppress("DEPRECATION")
		val display = activity.windowManager.defaultDisplay
		return display.mode.refreshRate
	}

	/**
	 * Tells SurfaceFlinger the surface wants [fps]; no-op before Android 11. The renderer draws
	 * every vsync, so the source is not fixed-rate video (COMPATIBILITY_DEFAULT). On Android 12+
	 * the switch is always allowed (CHANGE_FRAME_RATE_ALWAYS).
	 */
	fun hintSurfaceFrameRate(surface: Surface, fps: Float)
	{
		if(Build.VERSION.SDK_INT < Build.VERSION_CODES.R)
			return
		try
		{
			if(Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
				surface.setFrameRate(fps, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT, Surface.CHANGE_FRAME_RATE_ALWAYS)
			else
				surface.setFrameRate(fps, Surface.FRAME_RATE_COMPATIBILITY_DEFAULT)
		}
		catch(e: RuntimeException)
		{
			Log.w(TAG, "setFrameRate($fps) failed: ${e.message}")
		}
	}
}
