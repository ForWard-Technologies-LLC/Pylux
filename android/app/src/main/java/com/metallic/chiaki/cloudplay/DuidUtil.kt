// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay

import java.security.SecureRandom

/**
 * Device Unique Identifier (DUID) Utility
 * 
 * Generates unique device identifiers for PlayStation cloud gaming authentication.
 * Matches the C implementation in lib/src/remote/holepunch.c exactly.
 */
object DuidUtil
{
	private const val DUID_PREFIX = "0000000700410080"
	private const val RANDOM_BYTES_COUNT = 16
	
	/**
	 * Generate a unique device identifier for the client
	 * 
	 * Format: [PREFIX][32 hex characters from 16 random bytes]
	 * Example: "000000070041008012ab34cd56ef78901234567890abcdef"
	 * 
	 * Matches: chiaki_holepunch_generate_client_device_uid() in lib/src/remote/holepunch.c
	 */
	fun generateDuid(): String
	{
		val random = SecureRandom()
		val randomBytes = ByteArray(RANDOM_BYTES_COUNT)
		random.nextBytes(randomBytes)
		
		// Build DUID: prefix + hex representation of random bytes
		val builder = StringBuilder(DUID_PREFIX)
		for (byte in randomBytes)
		{
			builder.append(String.format("%02x", byte))
		}
		
		return builder.toString()
	}
}

