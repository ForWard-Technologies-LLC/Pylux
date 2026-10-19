// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream.gpu

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.nio.ByteBuffer
import java.nio.ByteOrder

class HdrStaticInfoTest
{
	/** BT.2020 primaries, D65 white, 1000 / 0.005 nits mastering, MaxCLL 1000, MaxFALL 400 — typical PS5 values. */
	private fun type1(vararg values: Int): ByteArray
	{
		val b = ByteBuffer.allocate(HdrStaticInfo.TYPE1_SIZE).order(ByteOrder.LITTLE_ENDIAN)
		b.put(0)
		for(v in values) b.putShort(v.toShort())
		return b.array()
	}

	private val bt2020 = type1(35400, 14600, 8500, 39850, 6550, 2300, 15635, 16450, 1000, 50, 1000, 400)

	@Test
	fun parsesType1LittleEndian()
	{
		val info = HdrStaticInfo.parse(bt2020)!!
		assertEquals(0.708f, info.redX, 1e-4f)
		assertEquals(0.292f, info.redY, 1e-4f)
		assertEquals(0.170f, info.greenX, 1e-4f)
		assertEquals(0.797f, info.greenY, 1e-4f)
		assertEquals(0.131f, info.blueX, 1e-4f)
		assertEquals(0.046f, info.blueY, 1e-4f)
		assertEquals(0.3127f, info.whiteX, 1e-4f)
		assertEquals(0.3290f, info.whiteY, 1e-4f)
		assertEquals(1000f, info.maxLuminance, 0f)
		assertEquals(0.005f, info.minLuminance, 1e-6f)
		assertEquals(1000f, info.maxContentLightLevel, 0f)
		assertEquals(400f, info.maxFrameAverageLightLevel, 0f)
		assertFalse(info.isEmpty)
	}

	@Test
	fun rejectsOtherTypesAndShortBuffers()
	{
		assertNull(HdrStaticInfo.parse(null))
		assertNull(HdrStaticInfo.parse(bt2020.copyOf(24)))
		val other = bt2020.copyOf().also { it[0] = 1 }
		assertNull(HdrStaticInfo.parse(other))
	}

	@Test
	fun allZeroIsEmpty()
	{
		assertTrue(HdrStaticInfo.parse(ByteArray(HdrStaticInfo.TYPE1_SIZE))!!.isEmpty)
	}

	@Test
	fun extraTrailingBytesAreIgnored()
	{
		val longer = bt2020.copyOf(32)
		assertEquals(1000f, HdrStaticInfo.parse(longer)!!.maxLuminance, 0f)
	}
}
