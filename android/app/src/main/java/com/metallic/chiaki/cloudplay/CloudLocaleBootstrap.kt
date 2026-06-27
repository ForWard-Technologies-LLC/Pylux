// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.cloudplay

import android.util.Log
import com.metallic.chiaki.cloudplay.api.HttpClient
import com.metallic.chiaki.common.Preferences
import org.json.JSONObject

object CloudLocaleBootstrap
{
	private const val TAG = "CloudLocaleBootstrap"
	private val lock = Any()

	fun ensureConfigured(preferences: Preferences, npssoToken: String): Boolean
	{
		if (preferences.isCloudStoreLocaleConfigured())
			return true
		if (npssoToken.isBlank())
		{
			Log.w(TAG, "Cannot bootstrap locale: empty npsso token")
			return false
		}

		synchronized(lock)
		{
			if (preferences.isCloudStoreLocaleConfigured())
				return true

			Log.i(TAG, "Bootstrapping cloud locale via Kamaji session (first time only)")
			return runBootstrap(preferences, npssoToken)
		}
	}

	private fun runBootstrap(preferences: Preferences, npssoToken: String): Boolean
	{
		return try
		{
			val duid = DuidUtil.generateDuid()
			val oauthCode = fetchOAuthCode(npssoToken, duid) ?: run {
				Log.w(TAG, "Locale bootstrap failed: OAuth")
				return false
			}
			if (!createKamajiSessionAndSaveLocale(preferences, oauthCode, duid))
			{
				Log.w(TAG, "Locale bootstrap failed: Kamaji session")
				return false
			}
			Log.i(TAG, "Locale bootstrap OK: ${preferences.getCloudStoreLocale()}")
			true
		}
		catch (e: Exception)
		{
			Log.w(TAG, "Locale bootstrap error", e)
			false
		}
	}

	private fun fetchOAuthCode(npssoToken: String, duid: String): String?
	{
		val uri = android.net.Uri.parse("${PsnApiConstants.ACCOUNT_BASE}/v1/oauth/authorize")
			.buildUpon()
			.appendQueryParameter("smcid", "pc:psnow")
			.appendQueryParameter("applicationId", "psnow")
			.appendQueryParameter("response_type", "code")
			.appendQueryParameter("scope", PsnApiConstants.PS4_SCOPES)
			.appendQueryParameter("client_id", PsnApiConstants.CLIENT_ID)
			.appendQueryParameter("redirect_uri", PsnApiConstants.REDIRECT_URI)
			.appendQueryParameter("service_entity", "urn:service-entity:psn")
			.appendQueryParameter("prompt", "none")
			.appendQueryParameter("renderMode", "mobilePortrait")
			.appendQueryParameter("hidePageElements", "forgotPasswordLink")
			.appendQueryParameter("displayFooter", "none")
			.appendQueryParameter("disableLinks", "qriocityLink")
			.appendQueryParameter("mid", "PSNOW")
			.appendQueryParameter("duid", duid)
			.appendQueryParameter("layout_type", "popup")
			.appendQueryParameter("service_logo", "ps")
			.appendQueryParameter("tp_psn", "true")
			.appendQueryParameter("noEVBlock", "true")
			.build()

		val response = HttpClient.get(uri.toString(), mapOf("Cookie" to "npsso=$npssoToken"), followRedirects = false)
		if (response.statusCode != 302)
			return null

		val location = HttpClient.extractLocation(response.headers) ?: return null
		val match = Regex("[?&]code=([^&]+)").find(location) ?: return null
		return match.groupValues.getOrNull(1)?.takeIf { it.isNotEmpty() }
	}

	private fun createKamajiSessionAndSaveLocale(
		preferences: Preferences,
		oauthCode: String,
		duid: String
	): Boolean
	{
		val url = "${PsnApiConstants.KAMAJI_BASE}/user/session"
		val body = "code=$oauthCode&client_id=${PsnApiConstants.CLIENT_ID}&duid=$duid"
		val headers = mapOf(
			"Content-Type" to "text/plain;charset=UTF-8",
			"X-Alt-Referer" to PsnApiConstants.REDIRECT_URI,
			"Origin" to PsnApiConstants.ORIGIN,
			"Referer" to PsnApiConstants.REFERER,
			"Accept" to "*/*"
		)

		val response = HttpClient.post(url, body, headers)
		if (response.statusCode != 200)
			return false

		val json = JSONObject(response.body)
		if (json.optJSONObject("header")?.optString("status_code") != "0x0000")
			return false

		val data = json.optJSONObject("data")
		preferences.setCloudStoreLocaleFromSession(
			data?.optString("language"),
			data?.optString("country")
		)
		return preferences.isCloudStoreLocaleConfigured()
	}
}
