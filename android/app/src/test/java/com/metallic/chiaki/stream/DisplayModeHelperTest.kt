// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class DisplayModeHelperTest
{
	private val m60 = DisplayModeInfo(id = 1, width = 2560, height = 1600, refreshRate = 60f)
	private val m120 = DisplayModeInfo(id = 2, width = 2560, height = 1600, refreshRate = 120f)
	private val m90 = DisplayModeInfo(id = 3, width = 2560, height = 1600, refreshRate = 90f)
	private val low120 = DisplayModeInfo(id = 4, width = 1920, height = 1200, refreshRate = 120f)

	@Test
	fun picksHighestRefreshAtSameResolution()
	{
		assertEquals(m120, DisplayModeHelper.pickHighestRefresh(m60, listOf(m60, m90, m120, low120)))
	}

	@Test
	fun ignoresModesWithDifferentResolution()
	{
		assertNull(DisplayModeHelper.pickHighestRefresh(m60, listOf(m60, low120)))
	}

	@Test
	fun returnsNullWhenCurrentIsAlreadyHighest()
	{
		assertNull(DisplayModeHelper.pickHighestRefresh(m120, listOf(m60, m90, m120)))
	}

	@Test
	fun treatsTinyRateDifferencesAsEqual()
	{
		val m120b = m120.copy(id = 9, refreshRate = 120.0001f)
		assertNull(DisplayModeHelper.pickHighestRefresh(m120, listOf(m120, m120b)))
	}

	@Test
	fun tolerantOfNtscRates()
	{
		val ntsc = m60.copy(refreshRate = 59.94f)
		assertNull(DisplayModeHelper.pickHighestRefresh(ntsc, listOf(ntsc, m60)))
	}

	@Test
	fun boundaryAtHalfHertz()
	{
		val a = m60.copy(id = 5, refreshRate = 60.5f)
		val b = m60.copy(id = 6, refreshRate = 60.6f)
		assertNull(DisplayModeHelper.pickHighestRefresh(m60, listOf(m60, a)))
		assertEquals(b, DisplayModeHelper.pickHighestRefresh(m60, listOf(m60, b)))
	}

	@Test
	fun emptyListReturnsNull()
	{
		assertNull(DisplayModeHelper.pickHighestRefresh(m60, emptyList()))
	}

	@Test
	fun tieKeepsFirstListed()
	{
		val first = m120.copy(id = 2)
		val second = m120.copy(id = 7)
		assertEquals(first, DisplayModeHelper.pickHighestRefresh(m60, listOf(m60, first, second)))
	}
}
