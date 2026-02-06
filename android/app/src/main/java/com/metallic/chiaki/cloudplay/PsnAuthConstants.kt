// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay

/**
 * PSN OAuth v3 Authentication Constants
 * Mirrors gui/src/psnaccountid_v3.cpp and gui/src/qmlbackend.cpp
 */
object PsnAuthConstants
{
	// OAuth v3 endpoints
	const val ACCOUNT_BASE = "https://ca.account.sony.com"
	const val AUTHORIZE_ENDPOINT_V3 = "$ACCOUNT_BASE/api/authz/v3/oauth/authorize"
	const val TOKEN_ENDPOINT_V3 = "$ACCOUNT_BASE/api/authz/v3/oauth/token"
	const val SSOCOOKIE_ENDPOINT = "$ACCOUNT_BASE/api/v1/ssocookie"
	
	// OAuth v3 configuration (matching desktop Remote Play app)
	const val CLIENT_ID = "ba495a24-818c-472b-b12d-ff231c1b5745"
	const val REDIRECT_URI = "https://remoteplay.dl.playstation.net/remoteplay/redirect"
	const val SCOPES = "psn:clientapp referenceDataService:countryConfig.read pushNotification:webSocket.desktop.connect sessionManager:remotePlaySession.system.update"
	
	// User agent for requests
	const val USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36"
	
	// Cookie domain for NPSSO extraction
	const val COOKIE_DOMAIN = "ca.account.sony.com"
	const val NPSSO_COOKIE_NAME = "npsso"
}
