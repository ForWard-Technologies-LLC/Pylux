// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.api

import android.util.Log
import com.metallic.chiaki.cloudplay.PsnApiConstants
import com.metallic.chiaki.cloudplay.ping.DatacenterPing
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder
import java.util.TimeZone

/**
 * Gaikai-specific constants
 * Mirrors: GaikaiConsts in psgaikaistreaming.h
 */
object GaikaiConsts
{
	const val CONFIG_BASE = "https://config.cc.prod.gaikai.com/v1"
	const val GAIKAI_BASE = "https://cc.prod.gaikai.com/v1"
	const val ACCOUNT_BASE = "https://ca.account.sony.com"
	
	// PSCLOUD URIs and headers
	const val REDIRECT_URI = "gaikai://local"
	const val USER_AGENT = "PlayStation Portal/6.0.0-rel.444+6a9cea6f5"
}

/**
 * PSGaikaiStreaming - Complete Gaikai streaming allocation flow (Steps 7-13)
 * Mirrors: gui/src/cloudstreaming/psgaikaistreaming.cpp
 * 
 * NOTE: This is a simplified implementation focusing on PSNOW PS4 games.
 * Full Qt implementation has extensive PS3/PS5/PSCLOUD support that can be added later.
 */
class PSGaikaiStreaming(
	private val duid: String,
	private val serviceType: String,  // "psnow" or "pscloud"
	private var platform: String,      // "ps3", "ps4", or "ps5"
	private val npssoToken: String,
	private val preferences: com.metallic.chiaki.common.Preferences,
	private val onProgress: ((String) -> Unit)? = null,  // Progress callback (message)
	private val isCancelled: () -> Boolean = { false }  // Cancellation check
)
{
	companion object
	{
		private const val TAG = "PSGaikaiStreaming"
		// Allocation wait limits (Qt lines 141-142)
		private const val MAX_ALLOCATION_WAIT_SECONDS = 900  // 15 minutes (max)
		private const val DEFAULT_ALLOCATION_WAIT_SECONDS = 300  // 5 minutes (fallback)
		// Lock session retry limit (Qt line 147)
		private const val MAX_LOCK_SESSION_RETRIES = 12  // Max retries for lock session
	}
	
	// Configuration
	private val virtType = when(platform)
	{
		"ps3" -> "konan"
		"ps4" -> "kratos"
		"ps5" -> "cronos"
		else -> "kratos"
	}
	
	private val accountBaseUrl = GaikaiConsts.ACCOUNT_BASE
	private val redirectUriUrl = if (serviceType == "pscloud") GaikaiConsts.REDIRECT_URI else PsnApiConstants.REDIRECT_URI
	private val userAgentString = if (serviceType == "pscloud") GaikaiConsts.USER_AGENT else PsnApiConstants.USER_AGENT
	private val oauthApiPath = if (serviceType == "pscloud") "/api/authz/v3" else "/api/v1"
	
	// State management
	private var configKey = ""
	private var gaikaiSessionId = ""
	private var gkClientId = ""
	private var ps3GkClientId = ""
	private var streamServerClientId = ""
	private var gkCloudAuthCode = ""
	private var ps3AuthCode = ""
	private var streamServerAuthCode = ""
	private var requestGameSpec = JSONObject()
	private var selectedDatacenter = ""
	private var selectedDatacenterPort = 0
	private var selectedDatacenterPingResult = JSONObject()
	
	// Allocation polling state (Qt lines 139-146)
	private var allocationWaitStartTime: Long = 0  // System.currentTimeMillis()
	private var allocationMaxWaitSeconds = 0  // Calculated from waitTimeEstimate
	private var allocationRetryCount = 0  // Counter for logging
	private var lockSessionRetryCount = 0  // Counter for lock session retries (Qt line 145)
	
	/**
	 * Result class
	 */
	data class AllocationResult(
		val success: Boolean,
		val message: String,
		val serverIp: String = "",
		val serverPort: Int = 0,
		val handshakeKey: String = "",
		val launchSpec: String = "",
		val sessionId: String = "",
		val psnWrapperType: Int = 0,
		val mtuIn: Int = 0,
		val mtuOut: Int = 0,
		val rttMs: Int = 0
	)
	
	/**
	 * Start complete allocation flow
	 * Mirrors: PSGaikaiStreaming::StartAllocationFlow()
	 */
	suspend fun startAllocationFlow(entitlementId: String): AllocationResult = withContext(Dispatchers.IO)
	{
		try
		{
			Log.i(TAG, "=== Starting Gaikai Allocation Flow ===")
			Log.i(TAG, "Entitlement ID: $entitlementId")
			
			// Check cancellation before starting
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			
			// Step 0: Get client IDs  
			onProgress?.invoke("Getting Client IDs - Step 1 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			step0_GetClientIds() ?: return@withContext AllocationResult(false, "Failed to get client IDs")
			Log.i(TAG, "✓ Step 0: Got client IDs")
			
			// Step 7: Get config
			onProgress?.invoke("Getting Configuration - Step 2 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			step7_GetConfig() ?: return@withContext AllocationResult(false, "Failed to get config")
			Log.i(TAG, "✓ Step 7: Got config")
			
			// Step 8: Start session
			onProgress?.invoke("Starting Session - Step 3 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			step8_StartSession(entitlementId) ?: return@withContext AllocationResult(false, "Failed to start session")
			Log.i(TAG, "✓ Step 8: Started session")
			
			// Step 8a: Get gkClientId auth code
			onProgress?.invoke("Getting Tokens - Step 4 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			step8a_GetAuthCode() ?: return@withContext AllocationResult(false, "Failed to get gkClientId auth code")
			Log.i(TAG, "✓ Step 8a: Got gkClientId auth code")
			
			// Step 8b: Get ps3GkClientId/streamServerClientId auth code
			onProgress?.invoke("Getting Server Tokens - Step 5 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			step8b_GetServerAuthCode() ?: return@withContext AllocationResult(false, "Failed to get server auth code")
			Log.i(TAG, "✓ Step 8b: Got server auth code")
			
			// Step 9: Authorize session
			onProgress?.invoke("Authorizing Session - Step 6 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			step9_AuthorizeSession() ?: return@withContext AllocationResult(false, "Failed to authorize session")
			Log.i(TAG, "✓ Step 9: Authorized session")
			
			// Step 10: Lock session
			onProgress?.invoke("Locking Session - Step 7 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			step10_LockSession() ?: return@withContext AllocationResult(false, "Failed to lock session")
			Log.i(TAG, "✓ Step 10: Locked session")
			
			// Step 11: Get datacenters
			onProgress?.invoke("Getting Datacenters - Step 8 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			val datacenters = step11_GetDatacenters() ?: return@withContext AllocationResult(false, "Failed to get datacenters")
			Log.i(TAG, "✓ Step 11: Got ${datacenters.length()} datacenters")
			
			// Step 12: Select datacenter (use first one for now)
			onProgress?.invoke("Pinging Datacenters - Step 8 of 10")
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			val datacenter = step12_SelectDatacenter(datacenters) ?: return@withContext AllocationResult(false, "No datacenters available")
			onProgress?.invoke("Selecting Datacenter ($datacenter) - Step 9 of 10")
			Log.i(TAG, "✓ Step 12: Selected datacenter: $datacenter")
			
			// Step 13: Allocate slot (with polling)
			if (allocationRetryCount == 0) {
				onProgress?.invoke("Allocating Streaming Slot - Step 10 of 10")
			}
			if (isCancelled()) {
				return@withContext AllocationResult(false, "Allocation cancelled")
			}
			val allocation = step13_AllocateSlot() ?: return@withContext AllocationResult(false, "Failed to allocate slot")
			Log.i(TAG, "✓ Step 13: Slot allocated!")
			
			// Parse allocation response - Match Qt exactly (lines 1694-1707)
			// Qt line 1609: allocation = jsonDoc.object() - the root JSON object IS the allocation
			val launchSlot = allocation.optJSONObject("launchSlot")
			if (launchSlot == null || launchSlot.length() == 0)
			{
				Log.e(TAG, "Allocation response missing launchSlot")
				return@withContext AllocationResult(false, "Allocation response invalid: missing launchSlot")
			}
			
			// Qt lines 1702-1707: Extract fields EXACTLY as Qt does
			val serverIp = launchSlot.optString("publicIp", "")           // Qt: allocatedServerIp = launchSlot["publicIp"].toString()
			val serverPort = launchSlot.optInt("port", 0)                 // Qt: allocatedServerPort = launchSlot["port"].toInt()
			val privateIp = launchSlot.optString("privateIp", "")         // Qt: QString privateIp = launchSlot["privateIp"].toString()
			val handshakeKey = allocation.optString("handshakeKey", "")   // Qt: allocatedHandshakeKey = allocation["handshakeKey"].toString()
			val launchSpec = allocation.optString("launchSpecification", "") // Qt: allocatedLaunchSpec = allocation["launchSpecification"].toString()
			val sessionId = allocation.optString("sessionId", "")         // Qt: allocatedSessionId = allocation["sessionId"].toString()
			
			// Log what was extracted
			Log.d(TAG, "Extracted from allocation response:")
			Log.d(TAG, "  publicIp: '$serverIp'")
			Log.d(TAG, "  port: $serverPort")
			Log.d(TAG, "  privateIp: '$privateIp'")
			Log.d(TAG, "  handshakeKey: ${if(handshakeKey.isEmpty()) "(empty/not present)" else handshakeKey.take(20) + "..."}")
			Log.d(TAG, "  sessionId: ${if(sessionId.isEmpty()) "(empty/not present)" else sessionId}")
			Log.d(TAG, "  launchSpecification length: ${launchSpec.length}")
			
			// Extract additional info (Qt lines 1734-1738)
			val timeLimit = allocation.optInt("timeLimit", 0)
			val startGameTimeout = allocation.optInt("startGameTimeout", 0)
			Log.d(TAG, "  timeLimit: $timeLimit minutes")
			Log.d(TAG, "  startGameTimeout: $startGameTimeout seconds")
			
			// Validate critical fields
			if (serverIp.isEmpty() || serverPort == 0 || launchSpec.isEmpty())
			{
				Log.e(TAG, "Allocation response missing critical fields:")
				Log.e(TAG, "  serverIp: '$serverIp'")
				Log.e(TAG, "  serverPort: $serverPort")
				Log.e(TAG, "  launchSpec length: ${launchSpec.length}")
				return@withContext AllocationResult(false, "Allocation response incomplete")
			}
			
			// Extract PSN wrapper type from private IP's last octet (Qt lines 1709-1722)
			var psnWrapperType = 0x01 // default fallback
			if (privateIp.isNotEmpty())
			{
				val lastOctet = privateIp.substringAfterLast('.')
				val octetValue = lastOctet.toIntOrNull()
				if (octetValue != null && octetValue in 0..255)
				{
					psnWrapperType = octetValue
					Log.d(TAG, "Private IP: $privateIp -> PSN wrapper type: 0x${psnWrapperType.toString(16).padStart(2, '0')}")
				}
			}
			
			// Match Qt log format exactly (lines 1724-1738)
			Log.i(TAG, "=== Gaikai Step 13: ALLOCATION SUCCESSFUL ===")
			Log.i(TAG, "Server IP: $serverIp")
			Log.i(TAG, "Server Port: $serverPort")
			Log.i(TAG, "Handshake Key: $handshakeKey")
			Log.i(TAG, "Session ID: $sessionId")
			Log.i(TAG, "Launch Spec (FULL): $launchSpec")
			Log.i(TAG, "Launch Spec Length: ${launchSpec.length}")
			Log.i(TAG, "[Allocation results stored for Takion connection]")
			Log.i(TAG, "Time Limit: $timeLimit minutes")
			Log.i(TAG, "Start Timeout: $startGameTimeout seconds")
			Log.i(TAG, "PSN Wrapper Type: 0x${psnWrapperType.toString(16).padStart(2, '0')}")
			
			AllocationResult(
				success = true,
				message = "Success",
				serverIp = serverIp,
				serverPort = serverPort,
				handshakeKey = handshakeKey,
				launchSpec = launchSpec,
				sessionId = sessionId,
				psnWrapperType = psnWrapperType,
				mtuIn = selectedDatacenterPingResult.optInt("mtu_in", 1454),
				mtuOut = selectedDatacenterPingResult.optInt("mtu_out", 1254),
				rttMs = selectedDatacenterPingResult.optInt("rtt", 20)
			)
		}
		catch (e: PsPlusSubscriptionException)
		{
			// Re-throw specific exceptions so they bubble up to UI
			throw e
		}
		catch (e: PingTimeoutException)
		{
			// Re-throw ping timeout exception so it shows proper dialog
			throw e
		}
		catch (e: GaikaiAllocationException)
		{
			// Re-throw specific exceptions so they bubble up to UI
			throw e
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Gaikai allocation error", e)
			throw GaikaiAllocationException("Unexpected error: ${e.message}")
		}
	}
	
	/**
	 * Step 0: Get client IDs
	 */
	private fun step0_GetClientIds(): Boolean?
	{
		try
		{
			val url = "${GaikaiConsts.GAIKAI_BASE}/client_ids?virtType=$virtType"
			
			Log.d(TAG, "Step 0: GET $url")
			
			val headers = mapOf(
				"User-Agent" to userAgentString,
				"Accept" to "*/*"
			)
			
			val response = HttpClient.get(url, headers)
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 0 failed: ${response.statusCode}")
				return null
			}
			
			val json = JSONObject(response.body)
			gkClientId = json.optString("gkClientId", "")
			ps3GkClientId = json.optString("ps3GkClientId", "")
			streamServerClientId = json.optString("streamServerClientId", "")
			
			if (gkClientId.isEmpty())
			{
				Log.e(TAG, "No gkClientId in response")
				return null
			}
			
			Log.d(TAG, "Step 0: Got gkClientId: $gkClientId")
			if (ps3GkClientId.isNotEmpty()) Log.d(TAG, "  ps3GkClientId: $ps3GkClientId")
			if (streamServerClientId.isNotEmpty()) Log.d(TAG, "  streamServerClientId: $streamServerClientId")
			return true
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 0 error", e)
			return null
		}
	}
	
	/**
	 * Step 7: Get config
	 */
	private fun step7_GetConfig(): Boolean?
	{
		try
		{
			val url = "${GaikaiConsts.CONFIG_BASE}/config"
			
			// Build request body
			val body = JSONObject()
			if (serviceType == "pscloud")
			{
				body.put("product", "qlite")
				body.put("platform", "qlite")
			}
			else
			{
				body.put("product", "psnow")
				body.put("platform", "PC")
			}
			body.put("sessionId", "")
			
			val bodyStr = body.toString()
			
			Log.d(TAG, "Step 7: POST $url")
			Log.d(TAG, "Body: $bodyStr")
			
			val headers = mapOf(
				"Content-Type" to "application/json",
				"User-Agent" to userAgentString,
				"Accept" to "*/*"
			)
			
			val response = HttpClient.post(url, bodyStr, headers)
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 7 failed: ${response.statusCode}")
				Log.e(TAG, "Response: ${response.body}")
				return null
			}
			
			// Extract config key from JSON response body (not header!)
			val json = JSONObject(response.body)
			configKey = json.optString("configKey", "")
			
			if (configKey.isEmpty())
			{
				Log.e(TAG, "No configKey in JSON response")
				Log.e(TAG, "Response body: ${response.body}")
				return null
			}
			
			Log.d(TAG, "Step 7: Got config key: ${configKey.take(20)}...")
			return true
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 7 error", e)
			return null
		}
	}
	
	/**
	 * Step 8: Start session
	 */
	private fun step8_StartSession(entitlementId: String): Boolean?
	{
		try
		{
			// Qt uses /sessions/start?npEnv=np
			val url = "${GaikaiConsts.GAIKAI_BASE}/sessions/start?npEnv=np"
			
			// Build game spec wrapped in requestGameSpecification
			requestGameSpec = buildRequestGameSpec(entitlementId)
			val wrapper = JSONObject()
			wrapper.put("requestGameSpecification", requestGameSpec)
			val body = wrapper.toString()
			
			Log.d(TAG, "Step 8: POST $url")
			Log.d(TAG, "Game spec: ${body.take(200)}...")
			
			val headers = mapOf(
				"Content-Type" to "application/json",
				"User-Agent" to userAgentString,
				"Accept" to "application/json",
				"X-Gaikai-Session" to configKey
			)
			
			val response = HttpClient.post(url, body, headers)
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 8 failed: ${response.statusCode}")
				Log.e(TAG, "Response: ${response.body}")
				return null
			}
			
			// Update session key
			val newKey = response.headers["x-gaikai-session"]?.firstOrNull()
			if (!newKey.isNullOrEmpty()) configKey = newKey
			
			// Extract session ID
			val json = JSONObject(response.body)
			gaikaiSessionId = json.optString("sessionId", "")
			
			if (gaikaiSessionId.isEmpty())
			{
				Log.e(TAG, "No sessionId in response")
				return null
			}
			
			Log.d(TAG, "Step 8: Session ID: $gaikaiSessionId")
			return true
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 8 error", e)
			return null
		}
	}
	
	/**
	 * Step 8a: Get auth code
	 */
	private fun step8a_GetAuthCode(): Boolean?
	{
		try
		{
			// Build OAuth URL - matches Qt PSGaikaiStreaming::step8a_GetGkAuthCode()
			val params = mutableListOf(
				"response_type" to "code",
				"client_id" to gkClientId,
				"redirect_uri" to redirectUriUrl,
				"service_entity" to "urn:service-entity:psn",  // PSN not GK!
				"prompt" to "none",
				"duid" to duid
			)
			
			// Add service-specific parameters
			if (serviceType == "pscloud")
			{
				params.add("smcid" to "qlite")
				params.add("applicationId" to "qlite")
				params.add("mid" to "qlite")
				params.add("scope" to "id_token:psn.basic_claims kamaji:s2s.subscriptionsPremium.get id_token:duid id_token:online_id openid psn:s2s")
			}
			else // psnow
			{
				params.add("smcid" to "pc:psnow")
				params.add("applicationId" to "psnow")
				params.add("mid" to "PSNOW")
				params.add("scope" to "kamaji:commerce_native versa:user_update_entitlements_first_play kamaji:lists")
				params.add("renderMode" to "mobilePortrait")
				params.add("hidePageElements" to "forgotPasswordLink")
				params.add("displayFooter" to "none")
				params.add("disableLinks" to "qriocityLink")
				params.add("layout_type" to "popup")
				params.add("service_logo" to "ps")
				params.add("tp_psn" to "true")
				params.add("noEVBlock" to "true")
			}
			
			val query = params.joinToString("&") { (key, value) ->
				"$key=${URLEncoder.encode(value, "UTF-8")}"
			}
			
			val url = "$accountBaseUrl$oauthApiPath/oauth/authorize?$query"
			
			Log.d(TAG, "Step 8a: GET $url")
			
			val headers = mapOf(
				"User-Agent" to userAgentString,
				"Cookie" to "npsso=$npssoToken"
			)
			
			val response = HttpClient.get(url, headers, followRedirects = false)
			
			if (response.statusCode != 302)
			{
				Log.e(TAG, "Step 8a failed: expected 302, got ${response.statusCode}")
				return null
			}
			
			val location = HttpClient.extractLocation(response.headers)
			if (location == null)
			{
				Log.e(TAG, "No Location header")
				return null
			}
			
			val codeRegex = Regex("[?&]code=([^&]+)")
			val match = codeRegex.find(location)
			gkCloudAuthCode = match?.groupValues?.get(1) ?: ""
			
			if (gkCloudAuthCode.isEmpty())
			{
				Log.e(TAG, "No code in redirect")
				return null
			}
			
			Log.d(TAG, "Step 8a: Got gkCloudAuthCode: ${gkCloudAuthCode.take(20)}...")
			return true
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 8a error", e)
			return null
		}
	}
	
	/**
	 * Step 8b: Get ps3GkClientId/streamServerClientId authorization code (serverAuthCode)
	 * Mirrors: PSGaikaiStreaming::step8b_GetPs3AuthCode()
	 */
	private fun step8b_GetServerAuthCode(): Boolean?
	{
		try
		{
			// Build OAuth URL - matches Qt PSGaikaiStreaming::step8b_GetPs3AuthCode()
			val params = mutableListOf(
				"response_type" to "code",
				"redirect_uri" to redirectUriUrl,
				"service_entity" to "urn:service-entity:psn",
				"prompt" to "none"
			)
			
			if (serviceType == "pscloud")
			{
				// PSCLOUD (PS5): Use streamServerClientId
				Log.d(TAG, "Step 8b: Using streamServerClientId for PSCLOUD")
				params.add("client_id" to streamServerClientId)
				params.add("smcid" to "qlite")
				params.add("applicationId" to "qlite")
				params.add("mid" to "qlite")
				params.add("scope" to "id_token:duid id_token:online_id openid oauth:create_authn_ticket_for_cloud_console_signin")
				params.add("duid" to duid)
			}
			else
			{
				// PSNOW (PS3/PS4): Use ps3GkClientId
				Log.d(TAG, "Step 8b: Using ps3GkClientId for PSNOW ($platform)")
				params.add("client_id" to ps3GkClientId)
				params.add("smcid" to "pc:psnow")
				params.add("applicationId" to "psnow")
				params.add("mid" to "PSNOW")
				
				// Platform-specific scope
				if (platform == "ps3")
				{
					params.add("scope" to "kamaji:commerce_native")
					// PS3: DO NOT include duid
				}
				else
				{
					// PS4
					params.add("scope" to "sso:none")
					params.add("duid" to duid)
				}
				
				params.add("renderMode" to "mobilePortrait")
				params.add("hidePageElements" to "forgotPasswordLink")
				params.add("displayFooter" to "none")
				params.add("disableLinks" to "qriocityLink")
				params.add("layout_type" to "popup")
				params.add("service_logo" to "ps")
				params.add("tp_psn" to "true")
				params.add("noEVBlock" to "true")
			}
			
			val query = params.joinToString("&") { (key, value) ->
				"$key=${URLEncoder.encode(value, "UTF-8")}"
			}
			
			val url = "$accountBaseUrl$oauthApiPath/oauth/authorize?$query"
			
			Log.d(TAG, "Step 8b: GET $url")
			
			val headers = mapOf(
				"User-Agent" to userAgentString,
				"Cookie" to "npsso=$npssoToken"
			)
			
			val response = HttpClient.get(url, headers, followRedirects = false)
			
			if (response.statusCode != 302)
			{
				Log.e(TAG, "Step 8b failed: expected 302, got ${response.statusCode}")
				Log.e(TAG, "Response body: ${response.body}")
				return null
			}
			
			val location = HttpClient.extractLocation(response.headers)
			if (location == null)
			{
				Log.e(TAG, "No Location header in Step 8b")
				return null
			}
			
			val codeRegex = Regex("[?&]code=([^&]+)")
			val match = codeRegex.find(location)
			val serverAuthCode = match?.groupValues?.get(1) ?: ""
			
			if (serverAuthCode.isEmpty())
			{
				Log.e(TAG, "No code in redirect for Step 8b")
				return null
			}
			
			// Set auth codes based on service type
			if (serviceType == "pscloud")
			{
				// PSCLOUD: Use serverAuthCode for streamServer, leave ps3AuthCode empty
				streamServerAuthCode = serverAuthCode
				ps3AuthCode = ""
				Log.d(TAG, "Step 8b: Got streamServerAuthCode: ${streamServerAuthCode.take(20)}...")
			}
			else
			{
				// PSNOW: Both ps3AuthCode AND streamServerAuthCode use the same code
				ps3AuthCode = serverAuthCode
				streamServerAuthCode = serverAuthCode
				Log.d(TAG, "Step 8b: Got ps3AuthCode (used for both): ${ps3AuthCode.take(20)}...")
			}
			
			return true
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 8b error", e)
			return null
		}
	}
	
	/**
	 * Step 9: Authorize session
	 * Mirrors: PSGaikaiStreaming::step9_AuthorizeSession()
	 */
	private fun step9_AuthorizeSession(): Boolean?
	{
		try
		{
			val url = "${GaikaiConsts.GAIKAI_BASE}/sessions/$gaikaiSessionId/authorize"
			
			// Update requestGameSpec with auth codes (matching Qt line 891-893)
			requestGameSpec.put("gkCloudAuthCode", gkCloudAuthCode)
			requestGameSpec.put("ps3AuthCode", ps3AuthCode)
			requestGameSpec.put("streamServerAuthCode", streamServerAuthCode)
			
			// Send requestGameSpecification (matching Qt line 916)
			val body = JSONObject()
			body.put("requestGameSpecification", requestGameSpec)
			val bodyStr = body.toString()
			
			Log.d(TAG, "Step 9: POST $url")
			Log.d(TAG, "Auth codes - gkCloud: ${gkCloudAuthCode.take(10)}..., ps3: ${ps3AuthCode.take(10)}..., streamServer: ${streamServerAuthCode.take(10)}...")
			
			val headers = mapOf(
				"Content-Type" to "application/json",
				"User-Agent" to userAgentString,
				"Accept" to "*/*",
				"X-Gaikai-Session" to configKey,
				"X-Gaikai-SessionId" to gaikaiSessionId
			)
			
			val response = HttpClient.post(url, bodyStr, headers)
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 9 failed: ${response.statusCode}")
				Log.e(TAG, "Response body: ${response.body}")
				
				// Check for PS Plus subscription error (eventCode 002.2001)
				// Mirrors: PSGaikaiStreaming::step9_AuthorizeSession() lines 948-962
				val eventHeader = response.headers["x-gaikai-event"]?.firstOrNull()
				var isPSPlusError = false
				
				if (!eventHeader.isNullOrEmpty())
				{
					Log.w(TAG, "Gaikai event header: $eventHeader")
					try
					{
						val eventJson = JSONObject(eventHeader)
						val eventCode = eventJson.optString("eventCode")
						if (eventCode == "002.2001")
						{
							isPSPlusError = true
						}
					}
					catch (e: Exception)
					{
						Log.w(TAG, "Failed to parse event header", e)
					}
				}
				
				// Parse error response body for detailed error messages
				var errorMsg = "Authorize failed with status ${response.statusCode}"
				if (response.body.isNotEmpty())
				{
					try
					{
						val errorJson = JSONObject(response.body)
						
						// Check errors array
						val errorsArray = errorJson.optJSONArray("errors")
						if (errorsArray != null && errorsArray.length() > 0)
						{
							val errorDescriptions = mutableListOf<String>()
							for (i in 0 until errorsArray.length())
							{
								val errorObj = errorsArray.optJSONObject(i)
								if (errorObj != null)
								{
									val description = errorObj.optString("description")
									val eventCode = errorObj.optString("eventCode")
									
									if (eventCode == "002.2001")
									{
										isPSPlusError = true
									}
									
									if (description.isNotEmpty())
									{
										errorDescriptions.add(description)
									}
									else if (eventCode.isNotEmpty())
									{
										errorDescriptions.add("Event: $eventCode")
									}
								}
							}
							if (errorDescriptions.isNotEmpty())
							{
								errorMsg += "\n" + errorDescriptions.joinToString("\n")
							}
						}
						else
						{
							val description = errorJson.optString("description")
							if (description.isNotEmpty())
							{
								errorMsg += ": $description"
							}
						}
					}
					catch (e: Exception)
					{
						Log.w(TAG, "Failed to parse error JSON", e)
						errorMsg += ": ${response.body}"
					}
				}
				
		Log.w(TAG, "Gaikai Step 9 failed: $errorMsg")
		
		// Throw specific exception for PS Plus error
		if (isPSPlusError)
		{
			throw PsPlusSubscriptionException(errorMsg)
		}
		
		throw GaikaiAllocationException(errorMsg)
	}
	
	// Update session key
	val newKey = response.headers["x-gaikai-session"]?.firstOrNull()
	if (!newKey.isNullOrEmpty()) configKey = newKey
	
	Log.d(TAG, "Step 9: Session authorized")
	return true
}
catch (e: PsPlusSubscriptionException)
{
	// Re-throw custom exceptions so they bubble up to UI
	Log.e(TAG, "Step 9 PS Plus error", e)
	throw e
}
catch (e: GaikaiAllocationException)
{
	// Re-throw custom exceptions so they bubble up to UI
	Log.e(TAG, "Step 9 Gaikai error", e)
	throw e
}
catch (e: Exception)
{
	// Unexpected errors return null
	Log.e(TAG, "Step 9 unexpected error", e)
	return null
}
	}
	
	/**
	 * Step 10: Lock session (with retry logic for queued sessions)
	 * Mirrors: PSGaikaiStreaming::step10_LockSession() (Qt lines 1052-1137)
	 */
	private suspend fun step10_LockSession(): Boolean?
	{
		try
		{
			if (lockSessionRetryCount == 0)
			{
				Log.i(TAG, "Gaikai Step 10: Locking session... (attempt ${lockSessionRetryCount + 1})")
			}
			else
			{
				Log.i(TAG, "Gaikai Step 10: Locking session... (attempt ${lockSessionRetryCount + 1})")
			}
			
			// Qt includes ?forceLogout=true query parameter (Qt line 1059)
			val url = "${GaikaiConsts.GAIKAI_BASE}/sessions/$gaikaiSessionId/lock?forceLogout=true"
			
			Log.d(TAG, "Step 10: POST $url")
			
			val headers = mapOf(
				"Content-Type" to "application/json",
				"User-Agent" to userAgentString,
				"Accept" to "*/*",
				"X-Gaikai-Session" to configKey,
				"X-Gaikai-SessionId" to gaikaiSessionId
			)
			
			// Qt sends requestGameSpecification in body (Qt lines 1068-1069)
			val body = JSONObject()
			body.put("requestGameSpecification", requestGameSpec)
			val bodyStr = body.toString()
			
			val response = HttpClient.post(url, bodyStr, headers)
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 10 failed: ${response.statusCode}")
				Log.e(TAG, "Response body: ${response.body}")
				throw GaikaiAllocationException("Lock failed: HTTP ${response.statusCode}")
			}
			
			// Update session key (Qt line 1087)
			val newKey = response.headers["x-gaikai-session"]?.firstOrNull()
			if (!newKey.isNullOrEmpty()) configKey = newKey
			
			// Parse response to check if lock was acquired (Qt lines 1089-1096)
			val json = JSONObject(response.body)
			val lockAcquired = json.optBoolean("lockAcquired", false)
			val pollFrequency = json.optInt("pollFrequency", 10)  // Default 10 seconds
			
			Log.i(TAG, "Gaikai Step 10 response - Lock acquired: $lockAcquired, pollFrequency: $pollFrequency")
			
			// If lock not acquired, retry with delay (Qt lines 1098-1125)
			if (!lockAcquired)
			{
				lockSessionRetryCount++
				
				// Check if max retries exceeded (Qt lines 1103-1108)
				if (lockSessionRetryCount > MAX_LOCK_SESSION_RETRIES)
				{
					Log.e(TAG, "Lock session max retries exceeded: $lockSessionRetryCount (max: $MAX_LOCK_SESSION_RETRIES)")
					throw GaikaiAllocationException("Lock session failed: Could not acquire lock after $MAX_LOCK_SESSION_RETRIES attempts")
				}
				
				// Build retry message (Qt lines 1110-1116)
				val message = "Closing old session - Attempt $lockSessionRetryCount"
				onProgress?.invoke(message)
				Log.i(TAG, message)
				Log.i(TAG, "Lock not acquired, retrying in $pollFrequency seconds... (attempt $lockSessionRetryCount of $MAX_LOCK_SESSION_RETRIES)")
				
				// Check cancellation before retry
				if (isCancelled()) {
					return null
				}
				
				// Wait and retry (Qt lines 1121-1123)
				delay(pollFrequency * 1000L)
				return step10_LockSession()  // Recursive retry
			}
			
			// Lock acquired successfully - reset retry counter (Qt lines 1127-1128)
			lockSessionRetryCount = 0
			
			Log.d(TAG, "Step 10: Session locked")
			return true
		}
		catch (e: GaikaiAllocationException)
		{
			throw e  // Re-throw custom exceptions
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 10 error", e)
			return null
		}
	}
	
	/**
	 * Step 11: Get datacenters
	 * Mirrors: PSGaikaiStreaming::step11_GetDatacenters()
	 */
	private fun step11_GetDatacenters(): JSONArray?
	{
		try
		{
			val url = "${GaikaiConsts.GAIKAI_BASE}/sessions/$gaikaiSessionId/datacenters"
			
			Log.d(TAG, "Step 11: POST $url")
			
			val headers = mapOf(
				"Content-Type" to "application/json",
				"User-Agent" to userAgentString,
				"Accept" to "*/*",
				"X-Gaikai-Session" to configKey,
				"X-Gaikai-SessionId" to gaikaiSessionId
			)
			
			// Qt sends requestGameSpecification in body
			val body = JSONObject()
			body.put("requestGameSpecification", requestGameSpec)
			val bodyStr = body.toString()
			
			val response = HttpClient.post(url, bodyStr, headers)
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 11 failed: ${response.statusCode}")
				Log.e(TAG, "Response body: ${response.body}")
				return null
			}
			
			// Update session key
			val newKey = response.headers["x-gaikai-session"]?.firstOrNull()
			if (!newKey.isNullOrEmpty()) configKey = newKey
			
			// Response is a JSON array directly (not wrapped in an object)
			val datacentersArray = JSONArray(response.body)
			
			Log.d(TAG, "Step 11: Got ${datacentersArray.length()} datacenters")
			for (i in 0 until datacentersArray.length())
			{
				val dc = datacentersArray.optJSONObject(i)
				if (dc != null)
				{
					Log.d(TAG, "  - ${dc.optString("dataCenter")} ${dc.optString("publicIp")}:${dc.optInt("port")} maxBw:${dc.optInt("maxBandwidth")}")
				}
			}
			
			return datacentersArray
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 11 error", e)
			return null
		}
	}
	
	/**
	 * Step 12: Select best datacenter (with REAL datacenter ping measurements OR manual selection)
	 * Mirrors: PSGaikaiStreaming::step12_SelectDatacenter()
	 */
	private suspend fun step12_SelectDatacenter(datacenters: JSONArray): String?
	{
		try
		{
			if (datacenters.length() == 0) return null
			
			// Save datacenters to settings (Qt lines 1194-1200)
			// This saves the raw datacenter list before pinging
			val datacentersJsonString = datacenters.toString()
			if (serviceType == "pscloud")
			{
				preferences.setCloudDatacentersJsonPscloud(datacentersJsonString)
			}
			else  // psnow
			{
				preferences.setCloudDatacentersJsonPsnow(datacentersJsonString)
			}
			
			// Check if a specific datacenter is selected (Qt lines 1203-1228)
			val selectedDatacenterSetting = if (serviceType == "pscloud")
			{
				preferences.getCloudDatacenterPscloud()
			}
			else  // psnow
			{
				preferences.getCloudDatacenterPsnow()
			}
			
			// If manual datacenter selected, use it with dummy ping (bypasses validation) (Qt lines 1210-1257)
			if (selectedDatacenterSetting != "Auto" && selectedDatacenterSetting.isNotEmpty())
			{
				Log.i(TAG, "Step 12: Using manually selected datacenter: $selectedDatacenterSetting")
				
				// Find the selected datacenter in the list
				var found = false
				var selectedDc: JSONObject? = null
				for (i in 0 until datacenters.length())
				{
					val dc = datacenters.getJSONObject(i)
					if (dc.getString("dataCenter") == selectedDatacenterSetting)
					{
						selectedDc = dc
						found = true
						break
					}
				}
				
				if (!found)
				{
					Log.w(TAG, "Selected datacenter $selectedDatacenterSetting not found in available datacenters")
					throw GaikaiAllocationException("Selected datacenter '$selectedDatacenterSetting' not available")
				}
				
				// Create dummy ping result with 20ms RTT (Qt lines 1230-1246)
				val dummyPingResult = JSONObject()
				dummyPingResult.put("dataCenter", selectedDc!!.getString("dataCenter"))
				dummyPingResult.put("rtt", 20)
				dummyPingResult.put("rtts", JSONArray().put(20))
				dummyPingResult.put("mtu_in", 1454)
				dummyPingResult.put("mtu_out", 1254)
				dummyPingResult.put("port", selectedDc.getInt("port"))
				dummyPingResult.put("publicIp", selectedDc.getString("publicIp"))
				dummyPingResult.put("maxBandwidth", selectedDc.getInt("maxBandwidth"))
				
				Log.i(TAG, "Bypassing ping tests - using manually selected datacenter: $selectedDatacenterSetting")
				Log.i(TAG, "Using dummy ping values: RTT=20ms, MTU in=1454, MTU out=1254")
				
				// Store for Step 13
				selectedDatacenterPingResult = dummyPingResult
				selectedDatacenter = selectedDatacenterSetting
				selectedDatacenterPort = selectedDc.getInt("port")
				
				// Submit to /datacenters/select (skip validation, go straight to submission)
				return submitDatacenterSelection(dummyPingResult, false)  // false = skip validation
			}
			
			// Auto-select: Ping all datacenters (Qt lines 1259-1308)
			Log.i(TAG, "Step 12: Pinging ${datacenters.length()} datacenters to find the best one...")
			
			val pingResults = DatacenterPing.pingAllDatacentersWithTimeout(
				datacenters,
				configKey,  // x-gaikai-session key used as session key for BIG message
				serviceType
			)
			
			// Save ping results to settings (Qt lines 1314-1322)
			if (pingResults.length() > 0)
			{
				val pingResultsJsonString = pingResults.toString()
				if (serviceType == "pscloud")
				{
					preferences.setCloudDatacentersJsonPscloud(pingResultsJsonString)
				}
				else  // psnow
				{
					preferences.setCloudDatacentersJsonPsnow(pingResultsJsonString)
				}
				Log.i(TAG, "Saved ${pingResults.length()} datacenter ping results to settings")
			}
			
			// Select best datacenter based on ping results (Qt lines 1310-1365)
			val bestPingResult = if (pingResults.length() > 0)
			{
				// Find datacenter with lowest RTT (Qt lines 1315-1324)
				var bestResult = pingResults.getJSONObject(0)
				var bestRtt = bestResult.getInt("rtt")
				
				for (i in 1 until pingResults.length())
				{
					val result = pingResults.getJSONObject(i)
					val rtt = result.getInt("rtt")
					if (rtt > 0 && rtt < bestRtt)
					{
						bestResult = result
						bestRtt = rtt
					}
				}
				
				Log.i(TAG, "Step 12: Best datacenter: ${bestResult.getString("dataCenter")} with ${bestRtt}ms RTT")
				bestResult
			}
			else
			{
				// Fallback to first datacenter with dummy values (Qt lines 1367-1391)
				Log.w(TAG, "Step 12: All pings failed or timed out, using first datacenter with dummy values")
				val firstDc = datacenters.getJSONObject(0)
				val fallbackResult = JSONObject()
				fallbackResult.put("dataCenter", firstDc.optString("dataCenter"))
				fallbackResult.put("rtt", 20)
				fallbackResult.put("rtts", JSONArray().put(20))
				fallbackResult.put("mtu_in", 1454)
				fallbackResult.put("mtu_out", 1254)
				fallbackResult.put("port", firstDc.optInt("port"))
				fallbackResult.put("publicIp", firstDc.optString("publicIp"))
				fallbackResult.put("maxBandwidth", firstDc.optInt("maxBandwidth"))
				fallbackResult
			}
			
			// Submit with validation (auto-selected datacenters must have <80ms ping)
			return submitDatacenterSelection(bestPingResult, true)  // true = validate ping
		}
		catch (e: PingTimeoutException)
		{
			// Re-throw PingTimeoutException so it can be caught by CloudPlayFragment and show proper dialog
			Log.e(TAG, "Step 12 error: Ping too high", e)
			throw e
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 12 error", e)
			return null
		}
	}
	
	/**
	 * Step 13: Allocate slot (with queued/data migration retry logic)
	 * Mirrors: PSGaikaiStreaming::step13_AllocateSlot() (Qt lines 1546-1688)
	 */
	private suspend fun step13_AllocateSlot(): JSONObject? = runCatching {
		// Use /allocate endpoint, not /slot (Qt line 1549)
		val url = "${GaikaiConsts.GAIKAI_BASE}/sessions/$gaikaiSessionId/allocate"
		
		Log.d(TAG, "Step 13: POST $url")
		
		val headers = mapOf(
			"Content-Type" to "application/json",
			"User-Agent" to userAgentString,
			"Accept" to "*/*",
			"X-Gaikai-Session" to configKey,
			"X-Gaikai-SessionId" to gaikaiSessionId
		)
		
		// Build request body with game spec, datacenter, and network info (Qt lines 1558-1583)
		val body = JSONObject()
		body.put("requestGameSpecification", requestGameSpec)
		body.put("dataCenter", selectedDatacenter)
		
		// Network info from ping results
		val network = JSONObject()
		network.put("bwKbpsSent", 50000)  // 50 Mbps upload
		network.put("bwLoss", 0.001)  // 0.1% packet loss
		network.put("mtu", selectedDatacenterPingResult.optInt("mtu_in", 1454))
		network.put("rtt", selectedDatacenterPingResult.optInt("rtt", 25))
		network.put("port", selectedDatacenterPort)
		network.put("bwKbpsReceived", 200000)  // 200 Mbps download
		network.put("bwLossUpstream", 0)
		network.put("mtuUpstream", selectedDatacenterPingResult.optInt("mtu_out", 1254))
		body.put("network", network)
		
		body.put("stateExecutionTime", 5974.7632)
		body.put("streamTestTime", 11262.8423)
		
		Log.d(TAG, "Step 13: Using network - RTT: ${network.getInt("rtt")}ms, MTU in: ${network.getInt("mtu")}, out: ${network.getInt("mtuUpstream")}")
		
		// Don't increment retry count here - only increment when we actually retry (matches Qt)
		Log.d(TAG, "Allocation attempt ${allocationRetryCount + 1}")
		
		val response = HttpClient.post(url, body.toString(), headers)
		
		// Update session key from response (Qt line 1605)
		val newKey = response.headers["x-gaikai-session"]?.firstOrNull()
		if (!newKey.isNullOrEmpty()) configKey = newKey
		
		if (response.statusCode != 200)
		{
			Log.e(TAG, "Allocation failed: ${response.statusCode}")
			Log.e(TAG, "Response: ${response.body}")
			return@runCatching null
		}
		
		val allocation = JSONObject(response.body)
		
		// Log EVERY top-level key in the response to match Qt exactly
		Log.d(TAG, "=== Step 13: Allocation Response - All Keys ===")
		val keys = allocation.keys()
		while (keys.hasNext())
		{
			val key = keys.next()
			val value = allocation.opt(key)
			when (value)
			{
				is JSONObject -> Log.d(TAG, "  $key: {JSONObject with ${value.length()} keys}")
				is JSONArray -> Log.d(TAG, "  $key: [JSONArray with ${value.length()} items]")
				is String -> {
					val strValue = value as String
					if (strValue.length > 100)
						Log.d(TAG, "  $key: \"${strValue.take(50)}...\" (length: ${strValue.length})")
					else
						Log.d(TAG, "  $key: \"$strValue\"")
				}
				else -> Log.d(TAG, "  $key: $value")
			}
		}
		Log.d(TAG, "================================================")
		
		// Check if we need to wait and retry (queued or data migration) - Qt lines 1616-1688
		val queued = allocation.optBoolean("queued", false)
		val dataMigration = allocation.optBoolean("dataMigration", false)
		val pollFrequency = allocation.optInt("pollFrequency", 15)  // Default 15 seconds (Qt line 1619)
		
		if (queued || dataMigration)
		{
			// Increment retry count when we actually need to retry (Qt line 1656)
			allocationRetryCount++
			
			// Initialize timer and calculate max wait time on first wait (Qt lines 1622-1639)
			if (allocationWaitStartTime == 0L)
			{
				allocationWaitStartTime = System.currentTimeMillis()
				
				// Calculate max wait time from waitTimeEstimate (multiply by 2 for safety, cap at 15 min, fallback to 5 min)
				val waitTimeEstimate = allocation.optInt("waitTimeEstimate", -1)
				if (waitTimeEstimate > 0)
				{
					allocationMaxWaitSeconds = waitTimeEstimate * 2  // Multiply by 2 for safety
					if (allocationMaxWaitSeconds > MAX_ALLOCATION_WAIT_SECONDS)
					{
						allocationMaxWaitSeconds = MAX_ALLOCATION_WAIT_SECONDS  // Cap at 15 minutes
					}
					Log.i(TAG, "Allocation queued/data migration. Using waitTimeEstimate: $waitTimeEstimate seconds (doubled to $allocationMaxWaitSeconds seconds for safety, max 15 min)")
				}
				else
				{
					allocationMaxWaitSeconds = DEFAULT_ALLOCATION_WAIT_SECONDS  // Fallback to 5 minutes
					Log.i(TAG, "Allocation queued/data migration. No waitTimeEstimate, using default: $allocationMaxWaitSeconds seconds (5 min)")
				}
			}
			
			val elapsedSeconds = (System.currentTimeMillis() - allocationWaitStartTime) / 1000
			
			// Check if we've exceeded max wait time (Qt lines 1643-1648)
			if (elapsedSeconds >= allocationMaxWaitSeconds)
			{
				Log.e(TAG, "Allocation wait timeout after $elapsedSeconds seconds (max: $allocationMaxWaitSeconds s)")
				return@runCatching null
			}
			
			var waitTime = pollFrequency
			val remainingTime = allocationMaxWaitSeconds - elapsedSeconds
			if (waitTime > remainingTime)
			{
				waitTime = remainingTime.toInt()
			}
			
			// Build retry message with queue position or migration percentage (Qt lines 1656-1678)
			val retryMessage: String
			var queuePosition = -1
			if (dataMigration)
			{
				val migrationPercent = allocation.optInt("dataMigrationPercentageComplete", 0)
				retryMessage = "Migrating data ($migrationPercent%) - Attempt $allocationRetryCount"
				Log.i(TAG, "Data migration progress: $migrationPercent%")
			}
			else
			{
				// Extract queue position (prefer displayQueuePosition, fallback to queuePosition) - Qt lines 1664-1669
				if (allocation.has("displayQueuePosition"))
				{
					queuePosition = allocation.optInt("displayQueuePosition", -1)
				}
				else if (allocation.has("queuePosition"))
				{
					queuePosition = allocation.optInt("queuePosition", -1)
				}
				
				// Build retry message with queue position if available (Qt lines 1672-1676)
				retryMessage = if (queuePosition >= 0)
				{
					"Allocating streaming slot - Queue position: $queuePosition - Attempt $allocationRetryCount"
				}
				else
				{
					"Allocating streaming slot - Attempt $allocationRetryCount"
				}
			}
			
			Log.i(TAG, "Allocation queued/data migration. Waiting $waitTime seconds before retry (elapsed: $elapsedSeconds s, remaining: $remainingTime s, max: $allocationMaxWaitSeconds s, attempt: $allocationRetryCount)")
			Log.i(TAG, retryMessage)
			
			// Emit progress message (Qt line 1678)
			onProgress?.invoke(retryMessage)
			
			// Check cancellation before retry
			if (isCancelled()) {
				return@runCatching null
			}
			
			// Wait and retry (Qt lines 1682-1686)
			delay(waitTime * 1000L)
			Log.i(TAG, "Retrying allocation request...")
			return@runCatching step13_AllocateSlot()  // Recursive retry
		}
		
		// Allocation successful - reset retry counter (Qt lines 1690-1691)
		allocationRetryCount = 0
		Log.i(TAG, "✓ Slot allocated!")
		
		return@runCatching allocation
	}.getOrNull()
	
	/**
	 * Build request game spec - Matches Qt buildRequestGameSpec exactly
	 */
	private fun buildRequestGameSpec(entitlementId: String): JSONObject
	{
		val spec = JSONObject()
		
		// Get system timezone
		val tzOffset = TimeZone.getDefault().getOffset(System.currentTimeMillis())
		val offsetHours = tzOffset / 3600000
		val offsetMinutes = kotlin.math.abs((tzOffset % 3600000) / 60000)
		val timezoneStr = if (offsetHours >= 0) {
			"UTC+%02d:%02d".format(offsetHours, offsetMinutes)
		} else {
			"UTC-%02d:%02d".format(kotlin.math.abs(offsetHours), offsetMinutes)
		}
		
		// ============================================================================
		// COMMON FIELDS (apply to both PSCLOUD and PSNOW)
		// ============================================================================
		
	// Core game configuration
	spec.put("entitlementId", entitlementId)
	spec.put("npEnv", "np")
	
	// Read language from unified settings (Qt lines 153, 161)
	// Use unified language setting for both PSCloud and PSNOW
	val language = preferences.getCloudLanguage()
	spec.put("language", language)
	
	spec.put("cloudEndpoint", "https://cc.prod.gaikai.com")
	spec.put("redirectUri", redirectUriUrl)
		
		// Video Resolution (read from settings based on service type)
		val resolution = if (serviceType == "pscloud")
		{
			preferences.getCloudResolutionPscloud()  // PSCloud supports up to 4K
		}
		else
		{
			preferences.getCloudResolutionPsnow()  // PSNOW supports up to 1080p
		}
		
		val resolutionSetting: String
		val clientWidth: Int
		val clientHeight: Int
		when (resolution) {
			720 -> {
				resolutionSetting = "720"
				clientWidth = 1280
				clientHeight = 720
			}
			1440 -> {
				resolutionSetting = "1440"
				clientWidth = 2560
				clientHeight = 1440
			}
			2160 -> {
				resolutionSetting = "2160"
				clientWidth = 3840
				clientHeight = 2160
			}
			else -> {
				resolutionSetting = "1080"
				clientWidth = 1920
				clientHeight = 1080
			}
		}
		spec.put("resolutionSetting", resolutionSetting)
		spec.put("clientWidth", clientWidth)
		spec.put("clientHeight", clientHeight)
		spec.put("adaptiveStreamMode", "resize")
		spec.put("useClientBwLadder", true)
		
		// Audio Upload (common)
		spec.put("audioUploadEnabled", true)
		spec.put("audioUploadNumChannels", 1)
		spec.put("audioUploadSamplingFrequency", 48000)
		
		// Input Configuration (common)
		spec.put("acceptButton", "X")
		
		// Protocol (common)
		spec.put("encryptionSupported", true)
		
		// Timezone (common) - automatically detected from system
		spec.put("summerTime", 0)
		spec.put("timeZone", timezoneStr)
		
		// HTTP User Agent (common)
		spec.put("httpUserAgent", userAgentString)
		
		// Auth Codes (common - updated later in step 9)
		spec.put("gkCloudAuthCode", gkCloudAuthCode)
		
		// Accessibility Features (common - all disabled)
		spec.put("accessibilityMarqueeSpeed", 0)
		spec.put("accessibilityLargeText", 0)
		spec.put("accessibilityBoldText", 0)
		spec.put("accessibilityContrast", 0)
		spec.put("accessibilityTtsEnable", 0)
		spec.put("accessibilityTtsSpeed", 0)
		spec.put("accessibilityTtsVolume", 0)
		
		// Capability Flags (common)
		spec.put("partyCapability", false)
		spec.put("homesharing", false)
		spec.put("isFirstBoot", false)
		spec.put("isPlusMember", true)
		spec.put("parentalLevel", 0)
		spec.put("yuvCoefficient", "")
		
		// Common Capabilities
		val capabilitiesArray = JSONArray()
		capabilitiesArray.put("cloudDrivenSenkushaTest")
		
		// ============================================================================
		// PSCLOUD (PS5) SPECIFIC FIELDS
		// ============================================================================
		if (serviceType == "pscloud") {
			// Video Configuration
			spec.put("videoEncoderProfile", "hw5.0")
			
			// Input Configuration
			val controllers = JSONArray()
			controllers.put("ds4")
			controllers.put("ds5")
			controllers.put("xinput")
			spec.put("connectedControllers", controllers)
			val inputObj = JSONObject()
			inputObj.put("controllers", controllers)
			spec.put("input", inputObj)
			
			// Device/Platform Info
			spec.put("model", "portal")
			spec.put("platform", "qlite")
			
			// Protocol Settings
			spec.put("gaikaiPlayer", "16.4.0")
			spec.put("protocolVersion", 12)  // CRITICAL: v12 enables PSCloud audio handling
			
			// Auth Codes
			spec.put("ps3AuthCode", "")
			spec.put("streamServerAuthCode", streamServerAuthCode)
			
			// Capabilities
			capabilitiesArray.put("cronos")
			
			// Video Stream Settings (PSCLOUD only)
			val videoStreamSettings = JSONObject()
			videoStreamSettings.put("clientHeight", clientHeight)
			videoStreamSettings.put("supportedMaxResolution", clientHeight)
			val videoProfiles = JSONArray()
			videoProfiles.put("hevc_hw4")
			videoStreamSettings.put("supportedVideoEncoderProfiles", videoProfiles)
			videoStreamSettings.put("supportedDynamicRange", "sdr")
			videoStreamSettings.put("preferredMaxResolution", clientHeight)
			videoStreamSettings.put("preferredDynamicRange", "sdr")
			videoStreamSettings.put("hqMode", 1)
			spec.put("videoStreamSettings", videoStreamSettings)
			
			// Audio Stream Settings (PSCLOUD only) - CRITICAL for PSCloud audio
			spec.put("audioChannels", "2")  // String "2" not "2.1"
			spec.put("audioEncoderProfile", "default")
			val audioStreamSettings = JSONObject()
			audioStreamSettings.put("audioEncoderProfile", "default")
			audioStreamSettings.put("maxAudioChannels", "2")
			audioStreamSettings.put("preferredNumberAudioChannels", "2")
			spec.put("audioStreamSettings", audioStreamSettings)
		}
		// ============================================================================
		// PSNOW (PS3/PS4) SPECIFIC FIELDS
		// ============================================================================
		else {
			// Audio Configuration
			spec.put("audioChannels", "2.1")
			spec.put("audioEncoderProfile", "default")
			
			// Video Configuration
			spec.put("videoEncoderProfile", "hw4.1")
			
			// Input Configuration
			val controllers = JSONArray().put("xinput")
			spec.put("connectedControllers", controllers)
			val inputObj = JSONObject()
			inputObj.put("controllers", controllers)
			spec.put("input", inputObj)
			
			// Device/Platform Info
			spec.put("model", "WINDOWS")
			spec.put("platform", "PC")
			
			// Protocol Settings
			spec.put("gaikaiPlayer", "12.5.0")
			spec.put("protocolVersion", 9)  // v9 for PSNow
			
			// Auth Codes
			spec.put("ps3AuthCode", ps3AuthCode)
			spec.put("streamServerAuthCode", ps3AuthCode)
			
			// Capabilities
			capabilitiesArray.put("kratos")
		}
		
		// Set capabilities (common, but content differs by service)
		spec.put("capabilities", capabilitiesArray)
		
		// Log the full JSON for inspection (matching Qt)
		Log.i(TAG, "=== buildRequestGameSpec - Full JSON ===")
		Log.i(TAG, "Service: $serviceType Platform: $platform")
		val formattedJson = spec.toString(2) // Pretty print with indent
		formattedJson.lines().forEach { line ->
			if (line.isNotBlank()) {
				Log.i(TAG, line)
			}
		}
		Log.i(TAG, "========================================")
		
		return spec
	}
	
	/**
	 * Helper: Submit datacenter selection to Gaikai API
	 * (Qt lines 1435-1461)
	 */
	private fun submitDatacenterSelection(pingResult: JSONObject, validatePing: Boolean): String?
	{
		try
		{
			val datacenterName = pingResult.getString("dataCenter")
			val rtt = pingResult.getInt("rtt")
			val mtuIn = pingResult.getInt("mtu_in")
			val mtuOut = pingResult.getInt("mtu_out")
			
			// Validate ping for auto-selected datacenters (Qt lines 1393-1404)
			// Manual selection bypasses this check
			if (validatePing && rtt > 80)
			{
				Log.w(TAG, "Selected datacenter ping too high: $datacenterName RTT: ${rtt}ms (max: 80ms)")
				throw PingTimeoutException("Ping must be < 80ms to start a cloud session. Selected datacenter $datacenterName has ${rtt}ms latency.")
			}
			
			// Store for Step 13
			selectedDatacenterPingResult = pingResult
			selectedDatacenter = datacenterName
			selectedDatacenterPort = pingResult.getInt("port")
			
			Log.i(TAG, "Step 12: Submitting selection - $datacenterName (RTT: ${rtt}ms, MTU in: $mtuIn, out: $mtuOut)")
			
			// Submit to /datacenters/select (Qt lines 1435-1461)
			val url = "${GaikaiConsts.GAIKAI_BASE}/sessions/$gaikaiSessionId/datacenters/select"
			
			val headers = mapOf(
				"Content-Type" to "application/json",
				"User-Agent" to userAgentString,
				"Accept" to "*/*",
				"X-Gaikai-Session" to configKey,
				"X-Gaikai-SessionId" to gaikaiSessionId
			)
			
			// Body needs BOTH requestGameSpecification AND pingResults (Qt line 1435-1436)
			val body = JSONObject()
			body.put("requestGameSpecification", requestGameSpec)
			body.put("pingResults", JSONArray().put(pingResult))
			
			val response = HttpClient.post(url, body.toString(), headers)
			
			if (response.statusCode != 200)
			{
				Log.e(TAG, "Step 12 failed: ${response.statusCode}")
				Log.e(TAG, "Response: ${response.body}")
				return null
			}
			
			// Update session key
			val newKey = response.headers["x-gaikai-session"]?.firstOrNull()
			if (!newKey.isNullOrEmpty()) configKey = newKey
			
			// Extract port from response if provided
			if (response.body.isNotEmpty())
			{
				try
				{
					val json = JSONObject(response.body)
					val portFromResponse = json.optInt("port", 0)
					if (portFromResponse > 0)
					{
						selectedDatacenterPort = portFromResponse
						Log.d(TAG, "Step 12: Using port from response: $selectedDatacenterPort")
					}
				}
				catch (e: Exception)
				{
					Log.w(TAG, "Failed to parse Step 12 response", e)
				}
			}
			
			Log.i(TAG, "Step 12: ✓ Selected $datacenterName:$selectedDatacenterPort")
			return datacenterName
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Step 12 submission error", e)
			throw e  // Re-throw to be caught by caller
		}
	}
}
