// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

/**
 * Custom exceptions for cloud streaming errors
 * Mirrors error handling in gui/src/cloudstreaming/psgaikaistreaming.cpp
 */

/** PS Plus subscription required error (eventCode 002.2001) */
class PsPlusSubscriptionException(message: String) : Exception(message)

/** Account privacy settings need to be updated */
class AccountPrivacySettingsException(val upgradeUrl: String, message: String) : Exception(message)

/** Ping timeout error */
class PingTimeoutException(message: String) : Exception(message)

/** Authorization failed */
class AuthorizationFailedException(message: String) : Exception(message)

/** General Gaikai allocation error */
class GaikaiAllocationException(message: String) : Exception(message)

/** Kamaji session error */
class KamajiSessionException(message: String) : Exception(message)

