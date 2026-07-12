// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.content.Context
import android.util.Log
import com.metallic.chiaki.cloudplay.model.CloudStreamSession
import com.metallic.chiaki.common.Preferences
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * CloudStreamingBackend - Orchestrates PlayStation Plus Cloud Gaming flow
 * 
 * This class is the main entry point for cloud gaming. It:
 * - Holds shared configuration (CloudConfig namespace)
 * - Runs the whole provisioning flow (auth check, Kamaji resolve, Gaikai
 *   allocation, datacenter ping/select) in libchiaki via
 *   ChiakiNative.cloudProvisionSession, off the main thread
 * - Provides a single unified API for the frontend
 *
 * Architecture:
 *   CloudStreamingBackend (thin Kotlin wrapper)
 *     └─> libchiaki chiaki_cloud_provision_session (the unified C flow)
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
			
			// The store locale is resolved + persisted by the unified catalog fetch
			// (settledLocale -> cloud_store_locale); the streaming-language fallback reads
			// it. The C provisioning flow runs the NPSSO authorizeCheck itself as its first
			// (silent) step and returns AUTHORIZATION_FAILED if the token is expired.

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

			// Store country/language for the resolve container URL -- byte-faithful to the old
			// Kamaji step0_5d: native mode (resolvedStoreCountry empty) derives BOTH from the store
			// locale; fallback mode uses the resolved country and resolved-else-locale language.
			val (localeCountry, localeLang) = com.metallic.chiaki.cloudplay.CloudLocale.parseStorePath(preferences.getCloudStoreLocale())
			val resolvedCountry = preferences.getCloudResolvedStoreCountry()
			val resolvedLang = preferences.getCloudResolvedStoreLang()
			val storeCountry: String
			val storeLang: String
			if (resolvedCountry.isNotEmpty()) {
				storeCountry = resolvedCountry
				storeLang = resolvedLang.ifEmpty { localeLang }
			} else {
				storeCountry = localeCountry
				storeLang = localeLang
			}

			val result = com.metallic.chiaki.lib.cloudProvisionSession(
				serviceType = serviceType,
				gameIdentifier = gameIdentifier,
				gameName = gameName,
				npsso = npssoToken,
				storeCountry = storeCountry,
				storeLang = storeLang,
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
				msg.contains("AUTHORIZATION_FAILED") ->
					AuthorizationFailedException("Your NPSSO token is likely expired. Please re-login to continue using cloud streaming.")
				msg.contains("PS_PLUS_SUBSCRIPTION_REQUIRED") ->
					PsPlusSubscriptionException("PS Plus subscription required")
				msg.startsWith("GAME_NOT_FREE") ->
					// Stale catalog: a free PS+ title now costs money. Sentinel is
					// "GAME_NOT_FREE:<price>" (price may be empty).
					GameNotFreeException(msg.substringAfter("GAME_NOT_FREE:", ""))
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

}

