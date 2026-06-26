// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.model

/**
 * One game from libchiaki's unified cloud catalog contract (chiaki/cloudcatalog.h).
 *
 * Every field is precomputed by the lib (shared with Qt and iOS); the client renders these
 * values verbatim and MUST NOT re-derive category, serviceType, platform, ownership or the
 * stream routing. See [CloudGame.fromContract] for the JSON mapping.
 */
data class CloudGame(
	val productId: String,
	val name: String,
	val imageUrl: String,  // Cover/box art - for game cards
	val landscapeImageUrl: String = imageUrl,  // Landscape - for loading dialog
	val thumbnailUrl: String = imageUrl,
	val platform: String = "ps4", // badge: "ps3", "ps4", or "ps5" (derived by lib from device[])
	val serviceType: String = "pscloud", // catalog routing: "psnow" or "pscloud"
	val conceptUrl: String = "", // purchase / add-to-library deep link
	val conceptId: String = "", // imagic conceptId (catalog dedupe key)
	val isOwned: Boolean = false,
	val entitlementId: String = "", // owned rows: entitlement id for streaming
	val storeProductId: String = "", // owned / purchaseable rows: product_id from entitlements API
	val plusCatalog: Boolean = false, // in the PS Plus subscription catalog
	// Acquisition tag (lib-assigned): "owned" / "streamable" (both Stream) / "purchaseable" (Add to Library).
	val category: String = "",
	// Stream routing precomputed by the lib: streamServiceType picks the endpoint (psnow/Kamaji vs
	// pscloud/cronos) and streamIdentifier is the exact id handed to the streaming session.
	val streamServiceType: String = serviceType,
	val streamIdentifier: String = productId
)
{
	companion object
	{
		/** Build from one element of the lib unified-catalog "games" array, or null if malformed. */
		fun fromContract(obj: org.json.JSONObject): CloudGame?
		{
			val productId = obj.optString("productId", "")
			val name = obj.optString("name", "")
			if (productId.isEmpty() || name.isEmpty())
				return null
			val imageUrl = obj.optString("imageUrl", "")
			val landscape = obj.optString("landscapeImageUrl", "")
			val streamSvc = obj.optString("streamServiceType", "")
			val streamId = obj.optString("streamIdentifier", "")
			val serviceType = obj.optString("serviceType", "pscloud")
			return CloudGame(
				productId = productId,
				name = name,
				imageUrl = imageUrl,
				landscapeImageUrl = landscape.ifEmpty { imageUrl },
				thumbnailUrl = imageUrl,
				platform = obj.optString("platform", "ps4"),
				serviceType = serviceType,
				conceptUrl = obj.optString("conceptUrl", ""),
				conceptId = obj.optString("conceptId", ""),
				isOwned = obj.optBoolean("isOwned", false),
				entitlementId = obj.optString("entitlementId", ""),
				storeProductId = obj.optString("storeProductId", ""),
				plusCatalog = obj.optBoolean("plusCatalog", false),
				category = obj.optString("category", ""),
				streamServiceType = streamSvc.ifEmpty { serviceType },
				streamIdentifier = streamId.ifEmpty { productId }
			)
		}
	}
}

/** Acquisition-tag constants matching the lib contract's "category" field (and iOS CloudCategory). */
object CloudCategory
{
	const val OWNED = "owned"
	const val STREAMABLE = "streamable"
	const val PURCHASEABLE = "purchaseable"
}

/**
 * Result wrapper for API operations
 */
sealed class PsnResult<out T>
{
	data class Success<T>(val data: T) : PsnResult<T>()
	data class Error(val message: String, val exception: Exception? = null) : PsnResult<Nothing>()
}

