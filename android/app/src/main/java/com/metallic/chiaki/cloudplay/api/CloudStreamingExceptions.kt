// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

/**
 * Custom exceptions for cloud streaming errors -- mapped from the libchiaki
 * provisioning error sentinels (chiaki_cloud_provision_session).
 */

/** PS Plus subscription required error (eventCode 002.2001) */
class PsPlusSubscriptionException(message: String) : Exception(message)

/** A cached free PS+ title now costs money (stale catalog); price may be empty. */
class GameNotFreeException(val price: String) : Exception(
	if (price.isBlank()) "This game is no longer free to stream. Your game list may be out of date — refresh it and try again."
	else "This game is no longer free to stream (price: $price). Your game list may be out of date — refresh it and try again.")

/** Account privacy settings need to be updated */
class AccountPrivacySettingsException(val upgradeUrl: String, message: String) : Exception(message)

/** Ping timeout error */
class PingTimeoutException(message: String) : Exception(message)

/** Authorization failed */
class AuthorizationFailedException(message: String) : Exception(message)

/** General Gaikai allocation error */
class GaikaiAllocationException(message: String) : Exception(message)

