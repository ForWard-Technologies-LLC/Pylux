// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.model

/**
 * Represents a game in the cloud catalog (PSNow or PSCloud)
 */
data class CloudGame(
	val productId: String,
	val name: String,
	val imageUrl: String,  // Cover/box art (type 10) - for game cards
	val landscapeImageUrl: String = imageUrl,  // Landscape (type 12/13) - for loading dialog
	val thumbnailUrl: String = imageUrl,
	val platform: String = "ps4", // "ps4", "ps3", or "ps5"
	val serviceType: String = "psnow", // "psnow" or "pscloud"
	val conceptUrl: String = "", // URL to add game to library (PS5 games)
	val isOwned: Boolean = false // Whether user owns this game (PS5 games)
)

/**
 * Internal session state for PSN authentication
 */
internal data class PsnSession(
	val oauthCode: String,
	val jsessionId: String,
	val baseUrl: String
)

/**
 * Result wrapper for API operations
 */
sealed class PsnResult<out T>
{
	data class Success<T>(val data: T) : PsnResult<T>()
	data class Error(val message: String, val exception: Exception? = null) : PsnResult<Nothing>()
}

