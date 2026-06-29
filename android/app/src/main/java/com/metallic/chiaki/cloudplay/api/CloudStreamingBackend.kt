// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.content.Context
import android.util.Log
import com.metallic.chiaki.cloudplay.CloudLocaleBootstrap
import com.metallic.chiaki.cloudplay.DuidUtil
import com.metallic.chiaki.cloudplay.PsnApiConstants
import com.metallic.chiaki.cloudplay.model.CloudStreamSession
import com.metallic.chiaki.common.Preferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * CloudStreamingBackend - Orchestrates PlayStation Plus Cloud Gaming flow
 * 
 * This class is the main entry point for cloud gaming. It:
 * - Holds shared configuration (CloudConfig namespace)
 * - Orchestrates Kamaji authentication (PSKamajiSession) 
 * - Orchestrates Gaikai allocation (PSGaikaiStreaming)
 * - Provides a single unified API for the frontend
 * 
 * Architecture:
 *   CloudStreamingBackend (orchestrator)
 *     └─> PSKamajiSession (Steps 1-6: Kamaji auth)
 *     └─> PSGaikaiStreaming (Steps 7-13: Gaikai allocation)
 *     
 * Mirrors: gui/src/cloudstreamingbackend.cpp
 */
class CloudStreamingBackend(
	private val context: Context,
	private val preferences: com.metallic.chiaki.common.Preferences
)
{
	companion object
	{
		private const val TAG = "CloudStreamingBackend"
	}
	
	/**
	 * Configuration - Shared settings and values used by multiple classes
	 * Mirrors: CloudConfig namespace in cloudstreamingbackend.h
	 */
	object CloudConfig
	{
		const val ACCOUNT_BASE = "https://ca.account.sony.com/api"
	}
	
	/**
	 * MAIN ENTRY POINT - Single method to complete entire flow (Steps 1-13)
	 * 
	 * Parameters:
	 *   serviceType: "psnow" or "pscloud"
	 *   gameIdentifier: Product ID (PSNOW) or Entitlement ID (PSCLOUD)
	 * Platform is automatically detected from API response for PSNOW, or hardcoded to "ps5" for PSCLOUD
	 * 
	 * Mirrors: CloudStreamingBackend::startCompleteCloudSession()
	 */
	suspend fun startCompleteCloudSession(
		serviceType: String,
		gameIdentifier: String,
		gameName: String,
		npssoToken: String,
		ownedEntitlementId: String = "",  // PSNOW owned fast-path: catalog's pre-resolved entitlement
		ownedPlatform: String = "",       // platform accompanying ownedEntitlementId
		onProgress: ((String) -> Unit)? = null,  // Progress callback
		isCancelled: () -> Boolean = { false }  // Cancellation check
	): Result<CloudStreamSession> = withContext(Dispatchers.IO)
	{
		try
		{
			Log.i(TAG, "=== Starting Complete Cloud Streaming Session ===")
			Log.i(TAG, "Service Type: $serviceType")
			Log.i(TAG, "Game Identifier: $gameIdentifier")
			Log.i(TAG, "Game Name: $gameName")
			
			// Normalize service type to lowercase
			val normalizedServiceType = serviceType.lowercase()
			
			// Validate parameters
			if (normalizedServiceType != "psnow" && normalizedServiceType != "pscloud")
			{
				Log.e(TAG, "Invalid serviceType: $normalizedServiceType. Must be 'psnow' or 'pscloud'")
				return@withContext Result.failure(Exception("Invalid serviceType: $normalizedServiceType"))
			}
			
			// Generate DUID once - shared between authorization check and session creation
			val sharedDuid = DuidUtil.generateDuid()
			Log.i(TAG, "Using DUID: ${sharedDuid.take(20)}...")
			
			// Centralized authorization check for both PSNOW and PSCLOUD (Qt lines 91-119)
			val authSuccess = checkAuthorization(normalizedServiceType, npssoToken, sharedDuid)
			if (!authSuccess)
			{
				Log.e(TAG, "Authorization check failed - NPSSO token likely expired")
				return@withContext Result.failure(AuthorizationFailedException("Your NPSSO token is likely expired. Please re-login to continue using cloud streaming."))
			}
			
			Log.i(TAG, "✓ Authorization check passed")

			// PSCloud skips Kamaji; bootstrap locale once if PSNow never ran
			if (normalizedServiceType == "pscloud")
				CloudLocaleBootstrap.ensureConfigured(preferences, npssoToken)
			
			// Continue with cloud session setup
			val result = continueCloudSessionAfterAuth(
				normalizedServiceType,
				gameIdentifier,
				gameName,
				npssoToken,
				ownedEntitlementId,
				ownedPlatform,
				onProgress = onProgress,
				isCancelled = isCancelled
			)
			
			result
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Complete cloud session error", e)
			Result.failure(e)
		}
	}
	
	/**
	 * Continue cloud session after successful authorization: run the unified C provisioning
	 * flow (chiaki_cloud_provision_session via JNI). The whole Kamaji+Gaikai flow, the owned
	 * fast-path and the one-shot noGameForEntitlementId retry all live in libchiaki now.
	 * Mirrors: gui/src/cloudstreamingbackend.cpp + ios CloudStreamingBackend.swift
	 */
	private suspend fun continueCloudSessionAfterAuth(
		serviceType: String,
		gameIdentifier: String,
		gameName: String,
		npssoToken: String,
		ownedEntitlementId: String = "",
		ownedPlatform: String = "",
		onProgress: ((String) -> Unit)? = null,
		isCancelled: () -> Boolean = { false }
	): Result<CloudStreamSession> = withContext(Dispatchers.IO)
	{
		try
		{
			val pscloud = serviceType == "pscloud"

			// Streaming language: manual picker, else the auto-detected catalog locale.
			val gameLanguage = preferences.getCloudGameLanguage().ifEmpty { preferences.getCloudStoreLocale() }
			val forcedDatacenter = if (pscloud) preferences.getCloudDatacenterPscloud() else preferences.getCloudDatacenterPsnow()
			val resolution = if (pscloud) preferences.getCloudResolutionPscloud() else preferences.getCloudResolutionPsnow()
			val bitrate = if (pscloud) preferences.getCloudBitratePscloud() else preferences.getCloudBitratePsnow()
			// Prior stored datacenters -> merged with this run's pings by the lib so the Settings
			// picker keeps previously-measured RTTs.
			val priorDatacenters = if (pscloud) preferences.getCloudDatacentersJsonPscloud() else preferences.getCloudDatacentersJsonPsnow()

			val result = com.metallic.chiaki.lib.cloudProvisionSession(
				serviceType = serviceType,
				gameIdentifier = gameIdentifier,
				gameName = gameName,
				npsso = npssoToken,
				storeCountry = preferences.getCloudResolvedStoreCountry(),
				storeLang = preferences.getCloudResolvedStoreLang(),
				gameLanguage = gameLanguage,
				ownedEntitlementId = ownedEntitlementId,
				ownedPlatform = ownedPlatform,
				forcedDatacenter = forcedDatacenter,
				priorDatacentersJson = priorDatacenters,
				catalogIsForeign = preferences.isCloudCatalogIsForeign(),
				resolution = resolution,
				bitrateKbps = bitrate,
				onProgress = onProgress,
				isCancelled = isCancelled
			)

			// Persist the merged datacenter list so Settings shows the measured RTTs
			// (whether or not allocation succeeded -- the old code saved during the ping).
			if (result.datacenterPings.isNotEmpty())
			{
				if (pscloud) preferences.setCloudDatacentersJsonPscloud(result.datacenterPings)
				else preferences.setCloudDatacentersJsonPsnow(result.datacenterPings)
			}

			if (result.err == 0)
			{
				Log.i(TAG, "✓ Cloud provisioning complete - Server: ${result.serverIp}")
				return@withContext Result.success(CloudStreamSession(
					serverIp = result.serverIp,
					serverPort = result.serverPort,
					handshakeKey = result.handshakeKey,
					launchSpec = result.launchSpec,
					sessionId = result.sessionId,
					entitlementId = result.entitlementId,
					gameName = gameName,
					platform = result.platform,
					psnWrapperType = result.psnWrapperType,
					mtuIn = result.mtuIn,
					mtuOut = result.mtuOut,
					rttMs = result.rttMs,
					serviceType = serviceType
				))
			}

			// Map the C error_message sentinels to the exceptions CloudPlayFragment catches.
			val msg = result.errorMessage.ifEmpty { "Allocation failed" }
			Log.e(TAG, "Cloud provisioning failed: $msg")
			val ex: Exception = when
			{
				msg.contains("PS_PLUS_SUBSCRIPTION_REQUIRED") ->
					PsPlusSubscriptionException("PS Plus subscription required")
				msg.startsWith("ACCOUNT_PRIVACY_SETTINGS") ->
					AccountPrivacySettingsException(msg.substringAfter("ACCOUNT_PRIVACY_SETTINGS:", ""),
						"Account privacy settings need updating")
				msg.contains("PING_TIMEOUT") ->
					PingTimeoutException("Ping must be < 80ms to start a cloud session")
				else -> GaikaiAllocationException(msg)
			}
			Result.failure(ex)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Cloud session continuation error", e)
			Result.failure(e)
		}
	}

	/**
	 * Centralized Authorization Check (used by both PSNOW and PSCLOUD)
	 * Mirrors: CloudStreamingBackend::checkAuthorization() (Qt lines 543-613)
	 */
	private suspend fun checkAuthorization(
		serviceType: String,
		npssoToken: String,
		duid: String
	): Boolean = withContext(Dispatchers.IO)
	{
		if (npssoToken.isEmpty())
		{
			Log.w(TAG, "Authorization check: NPSSO token is empty")
			return@withContext false
		}
		
		// Determine configuration based on service type
		val kamajiClientId: String
		val scopesStr: String
		val redirectUri: String
		val userAgent: String
		
		if (serviceType == "psnow")
		{
			// PSNOW configuration (matching PSKamajiSession)
			kamajiClientId = PsnApiConstants.CLIENT_ID
			scopesStr = PsnApiConstants.PS4_SCOPES
			redirectUri = PsnApiConstants.REDIRECT_URI
			userAgent = PsnApiConstants.USER_AGENT
		}
		else // pscloud
		{
			// PSCLOUD configuration (Qt lines 563-569)
			kamajiClientId = "19ae39c4-3f88-4d11-a792-94e4f52c996d"
			scopesStr = "id_token:psn.basic_claims kamaji:s2s.subscriptionsPremium.get id_token:duid id_token:online_id openid psn:s2s"
			redirectUri = GaikaiConsts.REDIRECT_URI
			userAgent = GaikaiConsts.USER_AGENT
		}
		
		try
		{
			Log.i(TAG, "=== Centralized Authorization Check ===")
			Log.i(TAG, "  Service Type: $serviceType")
			Log.i(TAG, "  Client ID: $kamajiClientId")
			
			// Create authorization check request (matching PSKamajiSession::step0_5a_AuthorizeCheck)
			val url = "${CloudConfig.ACCOUNT_BASE}/authz/v3/oauth/authorizeCheck"
			
			val body = org.json.JSONObject()
			body.put("client_id", kamajiClientId)
			body.put("scope", scopesStr)
			body.put("redirect_uri", redirectUri)
			body.put("response_type", "code")
			body.put("service_entity", "urn:service-entity:psn")
			body.put("duid", duid)
			
			val response = HttpClient.post(
				url = url,
				headers = mapOf(
					"Content-Type" to "application/json; charset=UTF-8",
					"User-Agent" to userAgent,
					"Cookie" to "npsso=$npssoToken"
				),
				body = body.toString()
			)
			
			if (response.statusCode == 200 || response.statusCode == 204)
			{
				Log.i(TAG, "✓ Authorization check passed (${response.statusCode})")
				return@withContext true
			}
			else
			{
				Log.w(TAG, "Authorization check failed: ${response.statusCode}")
				Log.w(TAG, "Response: ${response.body}")
				return@withContext false
			}
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Authorization check error", e)
			return@withContext false
		}
	}
}

