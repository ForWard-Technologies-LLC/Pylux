// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay.ping

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import org.json.JSONArray
import org.json.JSONObject

/**
 * Ping result structure containing RTT and MTU measurements
 * Mirrors: PingResult struct in datacenterping.h
 */
data class PingResult(
	val rttUs: Long,      // RTT in microseconds, or -1 on failure
	val mtuIn: Int,       // Inbound MTU (server to client)
	val mtuOut: Int       // Outbound MTU (client to server)
)

/**
 * DatacenterPing - Uses existing senkusha echo/ping functionality for RTT measurement
 *
 * This class reuses the existing chiaki_senkusha_run flow which performs:
 * 1. Takion connect
 * 2. Protocol version exchange (always v9 for cloud ping)
 * 3. BIG/BANG handshake
 * 4. Echo command enable
 * 5. Multiple ping/pong measurements (10 by default)
 * 6. Average RTT calculation
 *
 * Mirrors: DatacenterPing class in datacenterping.h/cpp
 */
object DatacenterPing
{
	private const val TAG = "DatacenterPing"
	private const val PING_TIMEOUT_MS = 15000L  // 15 seconds (Qt line 242)
	
	/**
	 * Ping multiple datacenters using senkusha echo/ping functionality
	 *
	 * @param datacenters JSONArray of datacenter objects with "publicIp", "port", "dataCenter", "maxBandwidth"
	 * @param sessionKey The session key from x-gaikai-session header (used for BIG message)
	 * @param serviceType Service type: "pscloud" or "psnow" (used to determine if PSN wrapper should be added)
	 * @return JSONArray of ping results. Each result has: "dataCenter", "rtt", "rtts", "mtu_in", "mtu_out", "port", "publicIp", "maxBandwidth"
	 *
	 * Mirrors: DatacenterPing::pingAllDatacentersWithTimeout (Qt lines 213-340)
	 */
	suspend fun pingAllDatacentersWithTimeout(
		datacenters: JSONArray,
		sessionKey: String,
		serviceType: String
	): JSONArray = withContext(Dispatchers.IO) {
		if (datacenters.length() == 0)
		{
			Log.w(TAG, "No datacenters to ping")
			return@withContext JSONArray()
		}
		
		Log.i(TAG, "Starting parallel ping of ${datacenters.length()} datacenters with ${PING_TIMEOUT_MS}ms timeout")
		
		try
		{
			// Ping all datacenters in parallel with timeout (Qt lines 239-273)
			withTimeout(PING_TIMEOUT_MS) {
				coroutineScope {
					val pingTasks = (0 until datacenters.length()).map { i ->
						async {
							try
							{
								val dc = datacenters.getJSONObject(i)
								val publicIp = dc.getString("publicIp")
								val port = dc.getInt("port")
								val dataCenter = dc.getString("dataCenter")
								val maxBandwidth = dc.getInt("maxBandwidth")
								
								Log.d(TAG, "Pinging datacenter: $dataCenter ($publicIp:$port)")
								
								// Perform the ping handshake (Qt line 289)
								val pingResult = performPingHandshake(publicIp, port, sessionKey, serviceType)
								val rttMs = if (pingResult.rttUs > 0) (pingResult.rttUs / 1000).toInt() else -1
								
								// Build result object (Qt lines 293-309)
								val result = JSONObject()
								result.put("dataCenter", dataCenter)
								result.put("port", port)
								result.put("publicIp", publicIp)
								result.put("maxBandwidth", maxBandwidth)
								
								if (rttMs > 0)
								{
									result.put("rtt", rttMs)
									result.put("rtts", JSONArray().put(rttMs))
									result.put("mtu_in", pingResult.mtuIn)
									result.put("mtu_out", pingResult.mtuOut)
									Log.i(TAG, "✓ $dataCenter: ${rttMs}ms (MTU in=${pingResult.mtuIn}, out=${pingResult.mtuOut})")
								}
								else
								{
									result.put("rtt", 999)
									result.put("rtts", JSONArray().put(999))
									result.put("mtu_in", 0)
									result.put("mtu_out", 0)
									Log.w(TAG, "✗ $dataCenter: Ping failed")
								}
								
								result
							}
							catch (e: Exception)
							{
								Log.e(TAG, "Error pinging datacenter ${i}: ${e.message}", e)
								null
							}
						}
					}
					
					// Wait for all pings to complete (Qt lines 320-330)
					val results = pingTasks.awaitAll().filterNotNull()
					val successCount = results.count { it.getInt("rtt") > 0 && it.getInt("rtt") < 999 }
					Log.i(TAG, "Completed ${results.size}/${datacenters.length()} pings, $successCount successful")
					
					// Convert to JSONArray
					val resultArray = JSONArray()
					results.forEach { resultArray.put(it) }
					resultArray
				}
			}
		}
		catch (e: kotlinx.coroutines.TimeoutCancellationException)
		{
			// Timeout - return whatever results we have so far (Qt lines 244-270)
			Log.w(TAG, "DatacenterPing: Timeout after ${PING_TIMEOUT_MS}ms")
			JSONArray()  // Return empty - caller will use fallback
		}
	}
	
	/**
	 * Ping a single datacenter using senkusha_run
	 *
	 * @param publicIp The datacenter's public IP address
	 * @param port The datacenter's port (typically 2053 for cloud)
	 * @param sessionKey The session key (x-gaikai-session) to use in BIG message launch_spec
	 * @param serviceType Service type: "pscloud" or "psnow" (used to determine if PSN wrapper should be added)
	 * @return PingResult containing RTT and MTU values, or rttUs=-1 on failure/timeout
	 *
	 * Mirrors: DatacenterPing::performPingHandshake (Qt lines 48-211)
	 */
	private fun performPingHandshake(
		publicIp: String,
		port: Int,
		sessionKey: String,
		serviceType: String
	): PingResult
	{
		return try
		{
			// Call native senkusha ping function
			DatacenterPingNative.performPing(publicIp, port, sessionKey, serviceType)
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Exception in performPingHandshake: ${e.message}", e)
			PingResult(rttUs = -1, mtuIn = 0, mtuOut = 0)
		}
	}
}

/**
 * Native JNI interface for datacenter pinging
 * Calls chiaki_senkusha_run from the C library
 */
private object DatacenterPingNative
{
	/**
	 * Perform a senkusha ping to a datacenter
	 *
	 * @param publicIp Datacenter IP address
	 * @param port Datacenter port
	 * @param sessionKey Session key for BIG message
	 * @param serviceType "pscloud" or "psnow"
	 * @return PingResult with RTT and MTU measurements
	 */
	external fun performPing(publicIp: String, port: Int, sessionKey: String, serviceType: String): PingResult
}

