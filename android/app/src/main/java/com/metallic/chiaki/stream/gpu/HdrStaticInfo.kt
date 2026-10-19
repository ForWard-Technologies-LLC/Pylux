// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream.gpu

import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * SMPTE ST 2086 mastering display colour volume plus CTA-861.3 content light levels, as parsed
 * from Android's MediaFormat "hdr-static-info" buffer. Chromaticities are CIE 1931 x/y,
 * luminances in cd/m².
 */
data class HdrStaticInfo(
	val redX: Float, val redY: Float,
	val greenX: Float, val greenY: Float,
	val blueX: Float, val blueY: Float,
	val whiteX: Float, val whiteY: Float,
	val maxLuminance: Float,
	val minLuminance: Float,
	val maxContentLightLevel: Float,
	val maxFrameAverageLightLevel: Float)
{
	companion object
	{
		/** Type 1 layout: 1 byte type (0) followed by 12 little-endian uint16 values. */
		const val TYPE1_SIZE = 25
		private const val CHROMATICITY_UNIT = 0.00002f
		private const val MIN_LUMINANCE_UNIT = 0.0001f

		/**
		 * Parses the Type 1 struct (type byte 0, then R.x R.y G.x G.y B.x B.y W.x W.y in 0.00002 units,
		 * max display luminance in cd/m², min display luminance in 0.0001 cd/m², MaxCLL and MaxFALL in
		 * cd/m², each a little-endian uint16). Returns null for any other type or a short buffer.
		 */
		fun parse(bytes: ByteArray?): HdrStaticInfo?
		{
			if(bytes == null || bytes.size < TYPE1_SIZE || bytes[0] != 0.toByte()) return null
			val b = ByteBuffer.wrap(bytes, 1, TYPE1_SIZE - 1).order(ByteOrder.LITTLE_ENDIAN)
			fun u16() = b.short.toInt() and 0xffff
			return HdrStaticInfo(
				redX = u16() * CHROMATICITY_UNIT, redY = u16() * CHROMATICITY_UNIT,
				greenX = u16() * CHROMATICITY_UNIT, greenY = u16() * CHROMATICITY_UNIT,
				blueX = u16() * CHROMATICITY_UNIT, blueY = u16() * CHROMATICITY_UNIT,
				whiteX = u16() * CHROMATICITY_UNIT, whiteY = u16() * CHROMATICITY_UNIT,
				maxLuminance = u16().toFloat(),
				minLuminance = u16() * MIN_LUMINANCE_UNIT,
				maxContentLightLevel = u16().toFloat(),
				maxFrameAverageLightLevel = u16().toFloat())
		}
	}

	/** All fields zero means the stream carried the struct but no real values; treat as absent. */
	val isEmpty get() = maxLuminance == 0f && maxContentLightLevel == 0f && redX == 0f
}
