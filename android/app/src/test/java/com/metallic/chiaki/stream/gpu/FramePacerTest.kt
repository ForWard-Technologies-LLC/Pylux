// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream.gpu

import org.junit.Assert.assertEquals
import org.junit.Test

class FramePacerTest
{
	private val interval60 = 16_666_667L
	private val vsync120 = 8_333_333L

	private fun pacer(framegen: Boolean = true) = FramePacer(interval60, framegen)
	private fun interp(framegen: Boolean = true) = FramePacer(interval60, framegen, GenerationMode.INTERPOLATE)

	@Test
	fun interpolateFirstFrameIsPresentedDirectly()
	{
		val p = interp()
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(0L, true))
		assertEquals(PaceDecision.SKIP, p.decide(vsync120, false))
	}

	@Test
	fun interpolateSteadyStateAlternatesInterpolatedAndHeldReal()
	{
		val p = interp()
		p.decide(0L, true)
		assertEquals(PaceDecision.PRESENT_INTERPOLATED, p.decide(interval60, true))
		assertEquals(PaceDecision.PRESENT_HELD_REAL, p.decide(interval60 + vsync120, false))
		assertEquals(PaceDecision.PRESENT_INTERPOLATED, p.decide(2 * interval60, true))
		assertEquals(PaceDecision.PRESENT_HELD_REAL, p.decide(2 * interval60 + vsync120, false))
		assertEquals(PaceDecision.SKIP, p.decide(2 * interval60 + 2 * vsync120, false))
	}

	@Test
	fun interpolateHeldFrameIsShownBeforeANewerOneIsConsumed()
	{
		val p = interp()
		p.decide(0L, true)
		assertEquals(PaceDecision.PRESENT_INTERPOLATED, p.decide(interval60, true))
		// the next frame is already there: show the held one first, the delay never exceeds one vsync
		assertEquals(PaceDecision.PRESENT_HELD_REAL, p.decide(interval60 + vsync120, true))
		assertEquals(PaceDecision.PRESENT_INTERPOLATED, p.decide(interval60 + 2 * vsync120, true))
	}

	@Test
	fun interpolateAfterStallPresentsDirectlyThenResumes()
	{
		val p = interp()
		p.decide(0L, true)
		p.decide(interval60, true)
		p.decide(interval60 + vsync120, false)
		val late = interval60 + 3 * interval60
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(late, true))
		assertEquals(PaceDecision.PRESENT_INTERPOLATED, p.decide(late + interval60, true))
	}

	@Test
	fun interpolateModeWithGenerationDisabledBehavesLikePlainPresentation()
	{
		val p = interp(framegen = false)
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(0L, true))
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(interval60, true))
		assertEquals(PaceDecision.SKIP, p.decide(interval60 + vsync120, false))
	}

	@Test
	fun switchingToExtrapolateStillShowsTheHeldFrame()
	{
		val p = interp()
		p.decide(0L, true)
		assertEquals(PaceDecision.PRESENT_INTERPOLATED, p.decide(interval60, true))
		p.generationMode = GenerationMode.EXTRAPOLATE
		assertEquals(PaceDecision.PRESENT_HELD_REAL, p.decide(interval60 + vsync120, false))
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(2 * interval60, true))
	}

	@Test
	fun resetClearsHeldFrame()
	{
		val p = interp()
		p.decide(0L, true)
		p.decide(interval60, true)
		p.reset()
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(2 * interval60, true))
	}

	@Test
	fun realFrameAlwaysPresented()
	{
		val p = pacer()
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(0L, true))
	}

	@Test
	fun noGenerationBeforeTwoRealFrames()
	{
		val p = pacer()
		p.decide(0L, true)
		assertEquals(PaceDecision.SKIP, p.decide(vsync120, false))
	}

	@Test
	fun steadyStateAlternatesRealAndGenerated()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(interval60 + vsync120, false))
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(2 * interval60, true))
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(2 * interval60 + vsync120, false))
	}

	@Test
	fun neverTwoGeneratedInARow()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(interval60 + vsync120, false))
		assertEquals(PaceDecision.SKIP, p.decide(interval60 + 2 * vsync120, false))
	}

	@Test
	fun noGenerationWhenLastRealFrameIsStale()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		// two intervals after the last real frame: too old to predict from
		assertEquals(PaceDecision.SKIP, p.decide(interval60 + 2 * interval60, false))
	}

	@Test
	fun generationDisabledMeansSkip()
	{
		val p = pacer(framegen = false)
		p.decide(0L, true)
		p.decide(interval60, true)
		assertEquals(PaceDecision.SKIP, p.decide(interval60 + vsync120, false))
	}

	@Test
	fun realFrameWinsOverGenerationWhenBothPossible()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		// 13 ms after the last real frame: past the one-vsync hold window, still fresh enough to generate
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(interval60 + 13_000_000L, true))
	}

	@Test
	fun resetForgetsHistory()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		p.reset()
		assertEquals(PaceDecision.SKIP, p.decide(interval60 + vsync120, false))
		p.decide(3 * interval60, true)
		assertEquals(PaceDecision.SKIP, p.decide(3 * interval60 + vsync120, false))
		p.decide(4 * interval60, true)
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(4 * interval60 + vsync120, false))
	}

	@Test
	fun thirtyFpsIntervalAllowsLaterGeneration()
	{
		val interval30 = 33_333_333L
		val p = FramePacer(interval30, true)
		p.decide(0L, true)
		p.decide(interval30, true)
		// 25 ms after the last real frame is still < 1.5 * 33 ms
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(interval30 + 25_000_000L, false))
	}

	@Test
	fun noGenerationFromStalePairAfterStall()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		p.decide(2_000_000_000L, true)
		assertEquals(PaceDecision.SKIP, p.decide(2_000_000_000L + vsync120, false))
		p.decide(2_000_000_000L + interval60, true)
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(2_000_000_000L + interval60 + vsync120, false))
	}

	@Test
	fun flagFlippedAfterConstructionTakesEffect()
	{
		val p = pacer(framegen = false)
		p.decide(0L, true)
		p.decide(interval60, true)
		p.frameGenerationEnabled = true
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(interval60 + vsync120, false))
		p.decide(2 * interval60, true)
		p.frameGenerationEnabled = false
		assertEquals(PaceDecision.SKIP, p.decide(2 * interval60 + vsync120, false))
	}

	@Test
	fun negativeTimestampsWork()
	{
		val o = -5_000_000_000L
		val p = pacer()
		p.decide(o, true)
		p.decide(o + interval60, true)
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(o + interval60 + vsync120, false))
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(o + 2 * interval60, true))
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(o + 2 * interval60 + vsync120, false))
	}

	@Test
	fun earlyRealFrameIsHeldForOneVsync()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(interval60 + vsync120, true))
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(interval60 + 2 * vsync120, true))
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(interval60 + 3 * vsync120, false))
	}

	@Test
	fun realFrameAfterTwoVsyncsIsPresentedImmediately()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(interval60 + vsync120, false))
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(2 * interval60, true))
	}

	@Test
	fun holdDoesNotApplyBeforeTwoRealFrames()
	{
		val p = pacer()
		p.decide(0L, true)
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(vsync120, true))
	}

	@Test
	fun holdDoesNotApplyWhenGenerationDisabled()
	{
		val p = pacer(framegen = false)
		p.decide(0L, true)
		p.decide(interval60, true)
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(interval60 + vsync120, true))
	}

	@Test
	fun noDoubleGenerationWhenHeldFrameArrives()
	{
		val p = pacer()
		p.decide(0L, true)
		p.decide(interval60, true)
		assertEquals(PaceDecision.PRESENT_GENERATED, p.decide(interval60 + vsync120, true))
		assertEquals(PaceDecision.PRESENT_REAL, p.decide(interval60 + 2 * vsync120, true))
	}
}
