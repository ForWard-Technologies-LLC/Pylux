// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.widget.Button
import android.widget.ProgressBar
import android.widget.TextView
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import com.google.android.material.appbar.MaterialToolbar
import com.pylux.stream.R
import com.metallic.chiaki.common.SecureTokenManager
import kotlinx.coroutines.*
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.random.Random

/**
 * PSN Login Activity using xbgamestream code flow
 * Mirrors desktop app's QR login flow from gui/src/qmlbackend.cpp
 * Reference: gui/src/qmlbackend.cpp lines 3363-3525
 */
class PsnLoginActivity : AppCompatActivity()
{
	companion object
	{
		private const val TAG = "PsnLoginActivity"
		private const val PYLUX_URL = "https://www.xbgamestream.com"
		const val EXTRA_NPSSO_TOKEN = "npsso_token"
		const val RESULT_LOGIN_SUCCESS = Activity.RESULT_OK
		const val RESULT_LOGIN_CANCELLED = Activity.RESULT_CANCELED
		const val RESULT_LOGIN_FAILED = 3
	}
	
	private lateinit var codeTextView: TextView
	private lateinit var statusTextView: TextView
	private lateinit var progressBar: ProgressBar
	private lateinit var openBrowserButton: Button
	private lateinit var checkStatusButton: Button
	private lateinit var cancelButton: Button
	private lateinit var tokenManager: SecureTokenManager
	
	private var loginCode: String = ""
	private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
	

	override fun onCreate(savedInstanceState: Bundle?)
	{
		super.onCreate(savedInstanceState)
		setContentView(R.layout.activity_psn_login)
		
		tokenManager = SecureTokenManager(this)
		
		// Setup toolbar
		val toolbar = findViewById<MaterialToolbar>(R.id.toolbar)
		setSupportActionBar(toolbar)
		supportActionBar?.apply {
			setDisplayHomeAsUpEnabled(true)
			setDisplayShowHomeEnabled(true)
			title = getString(R.string.psn_login_title)
		}
		toolbar.setNavigationOnClickListener {
			// User cancelled login
			setResult(RESULT_LOGIN_CANCELLED)
			finish()
		}
		
		// Find views
		codeTextView = findViewById(R.id.loginCodeText)
		statusTextView = findViewById(R.id.statusText)
		progressBar = findViewById(R.id.progress_bar)
		openBrowserButton = findViewById(R.id.openBrowserButton)
		checkStatusButton = findViewById(R.id.checkStatusButton)
		cancelButton = findViewById(R.id.cancelButton)
		
		// Setup buttons
		openBrowserButton.setOnClickListener {
			openPyluxInBrowser()
		}
		
		checkStatusButton.setOnClickListener {
			checkTokenStatus()
		}
		
		cancelButton.setOnClickListener {
			setResult(RESULT_LOGIN_CANCELLED)
			finish()
		}
		
		// Start login flow
		startLogin()
	}
	
	private fun startLogin()
	{
		// Generate random 6-character alphanumeric code
		val chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789" // Exclude similar looking chars (I,1,O,0)
		loginCode = (1..6).map { chars.random() }.joinToString("")
		codeTextView.text = loginCode
		
		Log.i(TAG, "Generated login code: $loginCode")
		
		// Create code on xbgamestream server
		scope.launch {
			val success = createPyluxCode(loginCode)
			if (success)
			{
				Log.i(TAG, "Code created successfully on xbgamestream")
				statusTextView.text = getString(R.string.psn_login_code_ready)
				openBrowserButton.isEnabled = true
				checkStatusButton.isEnabled = true
			}
			else
			{
				Log.e(TAG, "Failed to create code on xbgamestream")
				statusTextView.text = getString(R.string.psn_login_server_error)
				openBrowserButton.isEnabled = false
			}
		}
	}
	
	/**
	 * Create code on xbgamestream server
	 * Reference: gui/src/qmlbackend.cpp lines 3363-3440
	 */
	private suspend fun createPyluxCode(code: String): Boolean = withContext(Dispatchers.IO)
	{
		try
		{
			val url = URL("$PYLUX_URL/psstream/create-code")
			val connection = url.openConnection() as HttpURLConnection
			connection.requestMethod = "POST"
			connection.setRequestProperty("Content-Type", "application/json")
			connection.doOutput = true
			
			// Send JSON payload: {"code": "123456"}
			val jsonPayload = JSONObject().apply {
				put("code", code)
			}.toString()
			
			connection.outputStream.use { it.write(jsonPayload.toByteArray()) }
			
			val responseCode = connection.responseCode
			if (responseCode == HttpURLConnection.HTTP_OK)
			{
				val response = connection.inputStream.bufferedReader().use { it.readText() }
				val jsonResponse = JSONObject(response)
				
				if (jsonResponse.optString("result") == "success")
				{
					Log.i(TAG, "pylux code created successfully")
					return@withContext true
				}
				else
				{
					val error = jsonResponse.optString("error", "Unknown error")
					Log.e(TAG, "pylux server error: $error")
					return@withContext false
				}
			}
			else
			{
				Log.e(TAG, "HTTP error creating code: $responseCode")
				return@withContext false
			}
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Exception creating pylux code", e)
			return@withContext false
		}
	}
	
	/**
	 * Check token status when user clicks the button
	 */
	private fun checkTokenStatus()
	{
		checkStatusButton.isEnabled = false
		progressBar.visibility = View.VISIBLE
		statusTextView.text = getString(R.string.psn_login_checking_status)
		
		scope.launch {
			val token = checkPyluxStatus(loginCode)
			
			progressBar.visibility = View.GONE
			checkStatusButton.isEnabled = true
			
			if (token != null)
			{
				Log.i(TAG, "NPSSO token received from xbgamestream")
				onLoginSuccess(token)
			}
			else
			{
				// Token not ready yet
				statusTextView.text = getString(R.string.psn_login_not_complete)
				Toast.makeText(
					this@PsnLoginActivity,
					R.string.psn_login_not_complete_toast,
					Toast.LENGTH_SHORT
				).show()
			}
		}
	}
	
	/**
	 * Check xbgamestream server for token status
	 * Reference: gui/src/qmlbackend.cpp lines 3442-3525
	 */
	private suspend fun checkPyluxStatus(code: String): String? = withContext(Dispatchers.IO)
	{
		try
		{
			val url = URL("$PYLUX_URL/psstream/get-tokens")
			val connection = url.openConnection() as HttpURLConnection
			connection.requestMethod = "POST"
			connection.setRequestProperty("Content-Type", "application/json")
			connection.doOutput = true
			
			// Send JSON payload: {"code": "ABC123"}
			val jsonPayload = JSONObject().apply {
				put("code", code)
			}.toString()
			
			Log.d(TAG, "Checking token status for code: $code")
			connection.outputStream.use { it.write(jsonPayload.toByteArray()) }
			
			val responseCode = connection.responseCode
			Log.d(TAG, "Response code: $responseCode")
			
			if (responseCode == HttpURLConnection.HTTP_OK)
			{
				val response = connection.inputStream.bufferedReader().use { it.readText() }
				Log.d(TAG, "Response body: $response")
				val jsonResponse = JSONObject(response)
				
				val result = jsonResponse.optString("result")
				Log.d(TAG, "Result field: $result")
				
				when (result)
				{
					"success" -> {
						// Token is ready
						val npsso = jsonResponse.optString("npsso")
						if (npsso.isNotEmpty())
						{
							Log.i(TAG, "Received NPSSO token (length: ${npsso.length})")
							return@withContext npsso
						}
						else
						{
							Log.w(TAG, "Success result but empty npsso field")
						}
					}
					"pending", "" -> {
						// Still waiting for user to complete login or code not found yet
						Log.d(TAG, "Token status: pending or not found")
						return@withContext null
					}
					"error" -> {
						val error = jsonResponse.optString("error", "Unknown error")
						Log.e(TAG, "pylux error: $error")
						return@withContext null
					}
					else -> {
						Log.w(TAG, "Unknown result value: $result")
					}
				}
			}
			else
			{
				Log.w(TAG, "HTTP response code: $responseCode")
				// Try to read error response
				try {
					val errorResponse = connection.errorStream?.bufferedReader()?.use { it.readText() }
					if (errorResponse != null) {
						Log.w(TAG, "Error response: $errorResponse")
					}
				} catch (e: Exception) {
					Log.w(TAG, "Could not read error stream", e)
				}
			}
			
			return@withContext null
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Exception checking pylux status", e)
			return@withContext null
		}
	}
	
	/**
	 * Open xbgamestream.com with the login code in browser
	 * Reference: gui/src/qml/QRLoginDialog.qml line 225
	 */
	private fun openPyluxInBrowser()
	{
		try
		{
			val pyluxUrl = "$PYLUX_URL/psstream/?psstream_code=$loginCode"
			val intent = Intent(Intent.ACTION_VIEW, Uri.parse(pyluxUrl))
			startActivity(intent)
			Log.i(TAG, "Opened pylux URL in browser: $pyluxUrl")
			statusTextView.text = getString(R.string.psn_login_browser_opened)
			
			// Highlight the Check Status button by changing it to filled style
			checkStatusButton.apply {
				setBackgroundColor(getColor(com.google.android.material.R.color.design_default_color_primary))
				setTextColor(getColor(android.R.color.white))
				elevation = 8f
			}
			
			// Dim the open browser button since it's already been used
			openBrowserButton.alpha = 0.6f
		}
		catch (e: Exception)
		{
			Log.e(TAG, "Failed to open browser", e)
			Toast.makeText(this, getString(R.string.psn_login_external_browser_error), Toast.LENGTH_SHORT).show()
		}
	}
	
	private fun onLoginSuccess(token: String)
	{
		// Save token securely
		tokenManager.saveNpssoToken(token)
		
		// Return success
		val resultIntent = Intent().apply {
			putExtra(EXTRA_NPSSO_TOKEN, token)
		}
		setResult(RESULT_LOGIN_SUCCESS, resultIntent)
		
		Toast.makeText(this, getString(R.string.psn_login_success), Toast.LENGTH_SHORT).show()
		finish()
	}
	
	override fun onDestroy()
	{
		super.onDestroy()
		scope.cancel()
	}
	
	override fun onBackPressed()
	{
		setResult(RESULT_LOGIN_CANCELLED)
		super.onBackPressed()
	}
}
