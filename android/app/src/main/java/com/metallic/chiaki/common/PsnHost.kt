// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

/**
 * Represents a PlayStation console discovered via PSN (holepunch).
 * Mirrors PsnHost from the Qt desktop app (gui/include/host.h).
 */
data class PsnHost(
	val duid: String,    // Device Unique ID (hex string, 64 chars)
	val name: String,    // Console nickname
	val isPS5: Boolean   // PS5 or PS4
)
