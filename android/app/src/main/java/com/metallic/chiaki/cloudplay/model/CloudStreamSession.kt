// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.model

/**
 * Cloud stream session data (used to pass to StreamActivity)
 */
data class CloudStreamSession(
	val serverIp: String,
	val serverPort: Int,
	val handshakeKey: String,
	val launchSpec: String,
	val sessionId: String,
	val entitlementId: String,
	val gameName: String,
	val platform: String,
	val psnWrapperType: Int,
	val mtuIn: Int,
	val mtuOut: Int,
	val rttMs: Int,
	val serviceType: String // "psnow" or "pscloud"
)

