// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream.gpu

/**
 * [PRESENT_REAL]: consume the new frame and present it. [PRESENT_GENERATED]: present an extrapolated
 * frame (the new frame, if any, stays pending). [PRESENT_INTERPOLATED]: consume the new frame, present a
 * frame interpolated between it and the previous one, and keep the new frame itself for the next vsync.
 * [PRESENT_HELD_REAL]: present that kept frame now. [SKIP]: leave the screen as it is.
 */
enum class PaceDecision { PRESENT_REAL, PRESENT_GENERATED, PRESENT_INTERPOLATED, PRESENT_HELD_REAL, SKIP }

/** Extrapolation predicts past the newest frame (lowest latency); interpolation shows the newest frame one vsync late. */
enum class GenerationMode { EXTRAPOLATE, INTERPOLATE }

/**
 * Decides, once per display vsync, whether to present a freshly decoded frame, a
 * hardware-extrapolated frame, or nothing. Pure logic, no GL, so it is unit-testable.
 *
 * Rules (priority order):
 * 1. A new decoded frame that arrives "early", less than [HOLD_THRESHOLD_INTERVALS] stream
 *    intervals after the previous real frame was presented (one 120 Hz vsync after a 60 fps
 *    frame), is held for one vsync and a generated frame is presented in its place, provided
 *    generation is possible (rule 3's conditions). Returning [PaceDecision.PRESENT_GENERATED]
 *    while `newFrameAvailable` was true therefore means "keep the real frame pending and present
 *    it at the next vsync"; the caller must not consume it. This keeps the real/generated
 *    alternation when the console's delivery drifts against the display vsync, instead of
 *    presenting two real frames on consecutive vsyncs and then holding for a vsync with nothing
 *    to generate. The added latency is bounded to one vsync.
 * 2. Otherwise a new decoded frame is presented.
 * 3. Otherwise generate one frame if generation is enabled, at least two real frames
 *    have been seen, the previously presented frame was real, and the last real frame
 *    is younger than [MAX_REAL_AGE_INTERVALS] stream intervals.
 * 4. Otherwise skip (leave the last frame on screen).
 *
 * Interpolation mode ([generationMode] = [GenerationMode.INTERPOLATE]): a new frame that follows a fresh
 * previous frame yields [PaceDecision.PRESENT_INTERPOLATED] and is itself held for the next vsync
 * ([PaceDecision.PRESENT_HELD_REAL]), so every real frame reaches the screen one vsync later than in
 * extrapolation mode and the generated frame sits between two real frames instead of beyond the last.
 * A held frame is always presented before a newer one is consumed, so the delay never grows past one vsync.
 *
 * [decide] and [reset] must be called from the render thread only (their state is not
 * volatile); only [frameGenerationEnabled] and [generationMode] may be set from another thread. [reset] leaves
 * [frameGenerationEnabled] untouched. The recorded real-frame time is the vsync at which the
 * frame was consumed (up to one vsync later than its arrival), which the 1.5-interval margin absorbs.
 */
class FramePacer(private val streamIntervalNs: Long, @Volatile var frameGenerationEnabled: Boolean,
	@Volatile var generationMode: GenerationMode = GenerationMode.EXTRAPOLATE)
{
	companion object
	{
		const val MAX_REAL_AGE_INTERVALS = 1.5
		/** A real frame younger than this (in stream intervals) since the last presented real frame is held one vsync. */
		const val HOLD_THRESHOLD_INTERVALS = 0.75
	}

	/** Consecutive real frames since the last reset or stall; exposed for stats/debugging. */
	var realFramesSeen = 0L
		private set
	private val maxRealAgeNs = (streamIntervalNs * MAX_REAL_AGE_INTERVALS).toLong()
	private val holdThresholdNs = (streamIntervalNs * HOLD_THRESHOLD_INTERVALS).toLong()
	/** Vsync time at which the last PRESENT_REAL was returned. */
	private var lastRealNs = Long.MIN_VALUE
	private var lastPresentedWasGenerated = false
	/** Interpolation mode: the newest consumed frame has not been shown yet. */
	private var heldPending = false

	fun decide(nowNs: Long, newFrameAvailable: Boolean): PaceDecision
	{
		if(heldPending)
		{
			// Applies in both modes so a mode switch cannot strand a consumed frame.
			heldPending = false
			lastPresentedWasGenerated = false
			return PaceDecision.PRESENT_HELD_REAL
		}
		if(generationMode == GenerationMode.INTERPOLATE && frameGenerationEnabled)
			return decideInterpolate(nowNs, newFrameAvailable)
		val canGenerate = frameGenerationEnabled && realFramesSeen >= 2 && !lastPresentedWasGenerated
		if(newFrameAvailable && canGenerate && (nowNs - lastRealNs) < holdThresholdNs)
		{
			// Early real frame: hold it one vsync and fill this one with a generated frame so the
			// real/generated alternation survives phase drift. The caller keeps the frame pending.
			lastPresentedWasGenerated = true
			return PaceDecision.PRESENT_GENERATED
		}
		if(newFrameAvailable)
		{
			if(lastRealNs != Long.MIN_VALUE && nowNs - lastRealNs >= maxRealAgeNs)
				realFramesSeen = 1 // stall: the previous pair is too old to extrapolate from
			else
				realFramesSeen++
			lastRealNs = nowNs
			lastPresentedWasGenerated = false
			return PaceDecision.PRESENT_REAL
		}
		val fresh = lastRealNs != Long.MIN_VALUE
			&& (nowNs - lastRealNs) < maxRealAgeNs
		if(canGenerate && fresh)
		{
			lastPresentedWasGenerated = true
			return PaceDecision.PRESENT_GENERATED
		}
		return PaceDecision.SKIP
	}

	private fun decideInterpolate(nowNs: Long, newFrameAvailable: Boolean): PaceDecision
	{
		if(!newFrameAvailable)
			return PaceDecision.SKIP
		val stalled = lastRealNs != Long.MIN_VALUE && nowNs - lastRealNs >= maxRealAgeNs
		realFramesSeen = if(stalled) 1 else realFramesSeen + 1
		lastRealNs = nowNs
		if(realFramesSeen >= 2)
		{
			heldPending = true
			lastPresentedWasGenerated = true
			return PaceDecision.PRESENT_INTERPOLATED
		}
		lastPresentedWasGenerated = false
		return PaceDecision.PRESENT_REAL
	}

	fun reset()
	{
		realFramesSeen = 0L
		lastRealNs = Long.MIN_VALUE
		lastPresentedWasGenerated = false
		heldPending = false
	}
}
