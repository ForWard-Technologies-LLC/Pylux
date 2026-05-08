// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.common

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.StringRes
import androidx.preference.PreferenceManager
import com.pylux.stream.R
import com.metallic.chiaki.lib.Codec
import com.metallic.chiaki.lib.ConnectVideoProfile
import com.metallic.chiaki.lib.VideoFPSPreset
import com.metallic.chiaki.lib.VideoResolutionPreset
import io.reactivex.Observable
import io.reactivex.subjects.BehaviorSubject
import kotlin.math.max
import kotlin.math.min

class Preferences(context: Context)
{
	private val tokenManager: SecureTokenManager = SecureTokenManager(context)
	
	enum class Resolution(val value: String, @StringRes val title: Int, val preset: VideoResolutionPreset)
	{
		RES_360P("360p", R.string.preferences_resolution_title_360p, VideoResolutionPreset.RES_360P),
		RES_540P("540p", R.string.preferences_resolution_title_540p, VideoResolutionPreset.RES_540P),
		RES_720P("720p", R.string.preferences_resolution_title_720p, VideoResolutionPreset.RES_720P),
		RES_1080P("1080p", R.string.preferences_resolution_title_1080p, VideoResolutionPreset.RES_1080P),
	}

	enum class FPS(val value: String, @StringRes val title: Int, val preset: VideoFPSPreset)
	{
		FPS_30("30", R.string.preferences_fps_title_30, VideoFPSPreset.FPS_30),
		FPS_60("60", R.string.preferences_fps_title_60, VideoFPSPreset.FPS_60)
	}

	enum class Codec(val value: String, @StringRes val title: Int, val codec: com.metallic.chiaki.lib.Codec)
	{
		CODEC_H264("h264", R.string.preferences_codec_title_h264, com.metallic.chiaki.lib.Codec.CODEC_H264),
		CODEC_H265("h265", R.string.preferences_codec_title_h265, com.metallic.chiaki.lib.Codec.CODEC_H265)
	}

	companion object
	{
		val resolutionDefault = Resolution.RES_720P
		val resolutionAll = Resolution.values()
		val fpsDefault = FPS.FPS_60
		val fpsAll = FPS.values()
		val codecDefault = Codec.CODEC_H265
		val codecAll = Codec.values()
	}

	private val sharedPreferences = PreferenceManager.getDefaultSharedPreferences(context)
	private val sharedPreferenceChangeListener = SharedPreferences.OnSharedPreferenceChangeListener { _, key ->
		when(key)
		{
			resolutionKey -> bitrateAutoSubject.onNext(bitrateAuto)
		}
	}.also { sharedPreferences.registerOnSharedPreferenceChangeListener(it) }

	private val resources = context.resources

	val discoveryEnabledKey get() = resources.getString(R.string.preferences_discovery_enabled_key)
	var discoveryEnabled
		get() = sharedPreferences.getBoolean(discoveryEnabledKey, true)
		set(value) { sharedPreferences.edit().putBoolean(discoveryEnabledKey, value).apply() }

	val onScreenControlsEnabledKey get() = resources.getString(R.string.preferences_on_screen_controls_enabled_key)
	var onScreenControlsEnabled
		get() = sharedPreferences.getBoolean(onScreenControlsEnabledKey, true)
		set(value) { sharedPreferences.edit().putBoolean(onScreenControlsEnabledKey, value).apply() }

	val touchpadOnlyEnabledKey get() = resources.getString(R.string.preferences_touchpad_only_enabled_key)
	var touchpadOnlyEnabled
		get() = sharedPreferences.getBoolean(touchpadOnlyEnabledKey, false)
		set(value) { sharedPreferences.edit().putBoolean(touchpadOnlyEnabledKey, value).apply() }

	val rumbleEnabledKey get() = resources.getString(R.string.preferences_rumble_enabled_key)
	var rumbleEnabled
		get() = sharedPreferences.getBoolean(rumbleEnabledKey, true)
		set(value) { sharedPreferences.edit().putBoolean(rumbleEnabledKey, value).apply() }

	val motionEnabledKey get() = resources.getString(R.string.preferences_motion_enabled_key)
	var motionEnabled
		get() = sharedPreferences.getBoolean(motionEnabledKey, true)
		set(value) { sharedPreferences.edit().putBoolean(motionEnabledKey, value).apply() }

	val buttonHapticEnabledKey get() = resources.getString(R.string.preferences_button_haptic_enabled_key)
	var buttonHapticEnabled
		get() = sharedPreferences.getBoolean(buttonHapticEnabledKey, true)
		set(value) { sharedPreferences.edit().putBoolean(buttonHapticEnabledKey, value).apply() }

	val logVerboseKey get() = resources.getString(R.string.preferences_log_verbose_key)
	var logVerbose
		get() = sharedPreferences.getBoolean(logVerboseKey, false)
		set(value) { sharedPreferences.edit().putBoolean(logVerboseKey, value).apply() }

	val pipEnabledKey get() = resources.getString(R.string.preferences_pip_enabled_key)
	var pipEnabled
		get() = sharedPreferences.getBoolean(pipEnabledKey, true)
		set(value) { sharedPreferences.edit().putBoolean(pipEnabledKey, value).apply() }

	val swapCrossMoonKey get() = resources.getString(R.string.preferences_swap_cross_moon_key)
	var swapCrossMoon
		get() = sharedPreferences.getBoolean(swapCrossMoonKey, false)
		set(value) { sharedPreferences.edit().putBoolean(swapCrossMoonKey, value).apply() }

	val resolutionKey get() = resources.getString(R.string.preferences_resolution_key)
	var resolution
		get() = sharedPreferences.getString(resolutionKey, resolutionDefault.value)?.let { value ->
			Resolution.values().firstOrNull { it.value == value }
		} ?: resolutionDefault
		set(value) { sharedPreferences.edit().putString(resolutionKey, value.value).apply() }

	val fpsKey get() = resources.getString(R.string.preferences_fps_key)
	var fps
		get() = sharedPreferences.getString(fpsKey, fpsDefault.value)?.let { value ->
			FPS.values().firstOrNull { it.value == value }
		}  ?: fpsDefault
		set(value) { sharedPreferences.edit().putString(fpsKey, value.value).apply() }

	fun validateBitrate(bitrate: Int) = max(2000, min(50000, bitrate))
	val bitrateKey get() = resources.getString(R.string.preferences_bitrate_key)
	var bitrate
		get() = sharedPreferences.getInt(bitrateKey, 0).let { if(it == 0) null else validateBitrate(it) }
		set(value) { sharedPreferences.edit().putInt(bitrateKey, if(value != null) validateBitrate(value) else 0).apply() }
	val bitrateAuto get() = videoProfileDefaultBitrate.bitrate
	private val bitrateAutoSubject by lazy { BehaviorSubject.createDefault(bitrateAuto) }
	val bitrateAutoObservable: Observable<Int> get() = bitrateAutoSubject

	val codecKey get() = resources.getString(R.string.preferences_codec_key)
	var codec
		get() = sharedPreferences.getString(codecKey, codecDefault.value)?.let { value ->
			Codec.values().firstOrNull { it.value == value }
		}  ?: codecDefault
		set(value) { sharedPreferences.edit().putString(codecKey, value.value).apply() }

	private val videoProfileDefaultBitrate get() = ConnectVideoProfile.preset(resolution.preset, fps.preset, codec.codec)
	val videoProfile get() = videoProfileDefaultBitrate.let {
		val bitrate = bitrate
		if(bitrate == null)
			it
		else
			it.copy(bitrate = bitrate)
	}

	// Cloud Play settings
	/**
	 * Get NPSSO token from secure storage
	 */
	fun getNpssoToken(): String
	{
		return tokenManager.getNpssoToken()
	}

	/**
	 * Save NPSSO token to secure storage
	 */
	fun setNpssoToken(token: String)
	{
		tokenManager.saveNpssoToken(token)
	}
	
	/**
	 * Check if NPSSO token exists
	 */
	fun hasNpssoToken(): Boolean
	{
		return tokenManager.hasNpssoToken()
	}
	
	/**
	 * Clear NPSSO token (logout)
	 */
	fun clearNpssoToken()
	{
		tokenManager.clearNpssoToken()
	}

	// ==========================================================================
	// PSN Remote Play token storage (for holepunch-based console connections)
	// These are separate from the NPSSO token used for cloud play
	// ==========================================================================
	private val PSN_AUTH_TOKEN_KEY = "psn_rp_auth_token"
	private val PSN_REFRESH_TOKEN_KEY = "psn_rp_refresh_token"
	private val PSN_AUTH_TOKEN_EXPIRY_KEY = "psn_rp_auth_token_expiry"
	private val PSN_ACCOUNT_ID_KEY = "psn_rp_account_id"
	private val PSN_DUID_KEY = "psn_rp_duid"

	var psnAuthToken: String
		get() = sharedPreferences.getString(PSN_AUTH_TOKEN_KEY, "") ?: ""
		set(value) { sharedPreferences.edit().putString(PSN_AUTH_TOKEN_KEY, value).apply() }

	var psnRefreshToken: String
		get() = sharedPreferences.getString(PSN_REFRESH_TOKEN_KEY, "") ?: ""
		set(value) { sharedPreferences.edit().putString(PSN_REFRESH_TOKEN_KEY, value).apply() }

	var psnAuthTokenExpiry: Long
		get() = sharedPreferences.getLong(PSN_AUTH_TOKEN_EXPIRY_KEY, 0L)
		set(value) { sharedPreferences.edit().putLong(PSN_AUTH_TOKEN_EXPIRY_KEY, value).apply() }

	/** Base64-encoded 8-byte PSN account ID */
	var psnAccountId: String
		get() = sharedPreferences.getString(PSN_ACCOUNT_ID_KEY, "") ?: ""
		set(value) { sharedPreferences.edit().putString(PSN_ACCOUNT_ID_KEY, value).apply() }

	/** Client device DUID for PSN holepunch auth (generated once, reused) */
	var psnDuid: String
		get() = sharedPreferences.getString(PSN_DUID_KEY, "") ?: ""
		set(value) { sharedPreferences.edit().putString(PSN_DUID_KEY, value).apply() }

	val hasPsnRemotePlayTokens: Boolean
		get() = psnAuthToken.isNotEmpty() && psnRefreshToken.isNotEmpty()

	val isPsnTokenExpired: Boolean
		get()
		{
			val expiry = psnAuthTokenExpiry
			if(expiry == 0L) return true
			// Give 60 seconds buffer
			return System.currentTimeMillis() + 60_000 >= expiry
		}

	fun clearPsnRemotePlayTokens()
	{
		sharedPreferences.edit()
			.remove(PSN_AUTH_TOKEN_KEY)
			.remove(PSN_REFRESH_TOKEN_KEY)
			.remove(PSN_AUTH_TOKEN_EXPIRY_KEY)
			.remove(PSN_ACCOUNT_ID_KEY)
			.apply()
	}

	// Cloud language settings - UNIFIED for both PSNow and PSCloud (matching Qt GetCloudLanguagePSCloud)
	// Qt uses ONE setting for both PSNow and PSCloud
	fun getCloudLanguage(): String
	{
		return sharedPreferences.getString("cloud_language_pscloud", "en-US") ?: "en-US"
	}

	fun setCloudLanguage(value: String)
	{
		sharedPreferences.edit().putString("cloud_language_pscloud", value).apply()
	}
	
	// Cloud resolution settings (matching Qt GetCloudResolutionPSNOW/SetCloudResolutionPSNOW)
	val cloudResolutionPsnowKey get() = resources.getString(R.string.preferences_cloud_resolution_psnow_key)
	fun getCloudResolutionPsnow(): Int
	{
		return sharedPreferences.getString(cloudResolutionPsnowKey, "720")?.toIntOrNull() ?: 720
	}
	
	fun setCloudResolutionPsnow(value: Int)
	{
		sharedPreferences.edit().putString(cloudResolutionPsnowKey, value.toString()).apply()
	}
	
	// Cloud resolution settings for PSCloud (matching Qt GetCloudResolutionPSCloud/SetCloudResolutionPSCloud)
	val cloudResolutionPscloudKey get() = resources.getString(R.string.preferences_cloud_resolution_pscloud_key)
	fun getCloudResolutionPscloud(): Int
	{
		return sharedPreferences.getString(cloudResolutionPscloudKey, "720")?.toIntOrNull() ?: 720
	}
	
	fun setCloudResolutionPscloud(value: Int)
	{
		sharedPreferences.edit().putString(cloudResolutionPscloudKey, value.toString()).apply()
	}

	// Cloud datacenter settings (matching Qt GetCloudDatacenterPSNOW/SetCloudDatacenterPSNOW)
	val cloudDatacenterPsnowKey get() = resources.getString(R.string.preferences_cloud_datacenter_psnow_key)
	fun getCloudDatacenterPsnow(): String
	{
		return sharedPreferences.getString(cloudDatacenterPsnowKey, "Auto") ?: "Auto"
	}

	fun setCloudDatacenterPsnow(value: String)
	{
		sharedPreferences.edit().putString(cloudDatacenterPsnowKey, value).apply()
	}

	// Cloud datacenters JSON (matching Qt GetCloudDatacentersJsonPSNOW/SetCloudDatacentersJsonPSNOW)
	val cloudDatacentersJsonPsnowKey get() = resources.getString(R.string.preferences_cloud_datacenters_json_psnow_key)
	fun getCloudDatacentersJsonPsnow(): String
	{
		return sharedPreferences.getString(cloudDatacentersJsonPsnowKey, "") ?: ""
	}

	fun setCloudDatacentersJsonPsnow(json: String)
	{
		sharedPreferences.edit().putString(cloudDatacentersJsonPsnowKey, json).apply()
	}

	// PSCloud datacenter settings (matching Qt GetCloudDatacenterPSCloud/SetCloudDatacenterPSCloud)
	val cloudDatacenterPscloudKey get() = resources.getString(R.string.preferences_cloud_datacenter_pscloud_key)
	fun getCloudDatacenterPscloud(): String
	{
		return sharedPreferences.getString(cloudDatacenterPscloudKey, "Auto") ?: "Auto"
	}

	fun setCloudDatacenterPscloud(value: String)
	{
		sharedPreferences.edit().putString(cloudDatacenterPscloudKey, value).apply()
	}

	// PSCloud datacenters JSON (matching Qt GetCloudDatacentersJsonPSCloud/SetCloudDatacentersJsonPSCloud)
	val cloudDatacentersJsonPscloudKey get() = resources.getString(R.string.preferences_cloud_datacenters_json_pscloud_key)
	fun getCloudDatacentersJsonPscloud(): String
	{
		return sharedPreferences.getString(cloudDatacentersJsonPscloudKey, "") ?: ""
	}

	fun setCloudDatacentersJsonPscloud(json: String)
	{
		sharedPreferences.edit().putString(cloudDatacentersJsonPscloudKey, json).apply()
	}

	// Cloud Play UI state
	private val LAST_CLOUD_SECTION_KEY = "last_cloud_section"
	private val PSCLOUD_FILTER_OWNED_KEY = "pscloud_filter_owned"
	private val LAST_MAIN_TAB_KEY = "last_main_tab"
	private val CLOUD_SORT_STATE_KEY = "cloud_sort_state"
	private val FAVORITE_GAMES_KEY = "favorite_games"
	private val PSNOW_FILTER_FAVORITES_KEY = "psnow_filter_favorites"
	private val PSCLOUD_FILTER_FAVORITES_KEY = "pscloud_filter_favorites"
	private val LICENSE_AGREED_KEY = "license_agreed"
	private val TOTAL_STREAM_TIME_MS_KEY = "total_stream_time_ms"
	/** Migrated from one-time flag; removed after [lastDonationPromptWallClockMs] is seeded. */
	private val DONATION_STREAM_AUTO_PROMPT_SHOWN_KEY = "donation_stream_auto_prompt_shown"
	private val LAST_DONATION_PROMPT_WALL_MS_KEY = "last_donation_prompt_wall_ms"
	private val DONATION_PAYWALL_SHOW_COUNT_KEY = "donation_paywall_show_count"

	/** Total times the support paywall was opened (1-based after [incrementDonationPaywallShowCount]). */
	val donationPaywallShowCount: Int
		get() = sharedPreferences.getInt(DONATION_PAYWALL_SHOW_COUNT_KEY, 0)

	/** @return New total paywall open count after increment. */
	fun incrementDonationPaywallShowCount(): Int
	{
		val next = donationPaywallShowCount + 1
		sharedPreferences.edit().putInt(DONATION_PAYWALL_SHOW_COUNT_KEY, next).apply()
		return next
	}

	fun getLastCloudSection(): String
	{
		return sharedPreferences.getString(LAST_CLOUD_SECTION_KEY, "psnow") ?: "psnow"
	}

	fun setLastCloudSection(section: String)
	{
		sharedPreferences.edit().putString(LAST_CLOUD_SECTION_KEY, section).apply()
	}

	fun getPsCloudFilterOwned(): Boolean
	{
		return sharedPreferences.getBoolean(PSCLOUD_FILTER_OWNED_KEY, false)
	}

	fun setPsCloudFilterOwned(isOwned: Boolean)
	{
		sharedPreferences.edit().putBoolean(PSCLOUD_FILTER_OWNED_KEY, isOwned).apply()
	}

	fun getLastMainTab(): Int
	{
		return sharedPreferences.getInt(LAST_MAIN_TAB_KEY, 0) // Default to Remote Play (0)
	}

	fun setLastMainTab(tabPosition: Int)
	{
		sharedPreferences.edit().putInt(LAST_MAIN_TAB_KEY, tabPosition).apply()
	}
	
	fun getCloudSortState(): Int
	{
		return sharedPreferences.getInt(CLOUD_SORT_STATE_KEY, 0) // Default to Recent (0)
	}
	
	fun setCloudSortState(sortState: Int)
	{
		sharedPreferences.edit().putInt(CLOUD_SORT_STATE_KEY, sortState).apply()
	}
	
	// Favorite games management
	fun getFavoriteGames(): Set<String>
	{
		return sharedPreferences.getStringSet(FAVORITE_GAMES_KEY, emptySet()) ?: emptySet()
	}
	
	fun addFavoriteGame(productId: String)
	{
		val favorites = getFavoriteGames().toMutableSet()
		favorites.add(productId)
		sharedPreferences.edit().putStringSet(FAVORITE_GAMES_KEY, favorites).apply()
	}
	
	fun removeFavoriteGame(productId: String)
	{
		val favorites = getFavoriteGames().toMutableSet()
		favorites.remove(productId)
		sharedPreferences.edit().putStringSet(FAVORITE_GAMES_KEY, favorites).apply()
	}
	
	fun isFavoriteGame(productId: String): Boolean
	{
		return getFavoriteGames().contains(productId)
	}
	
	// Filter states for favorites
	fun getPsnowFilterFavorites(): Boolean
	{
		return sharedPreferences.getBoolean(PSNOW_FILTER_FAVORITES_KEY, false)
	}
	
	fun setPsnowFilterFavorites(isFavorites: Boolean)
	{
		sharedPreferences.edit().putBoolean(PSNOW_FILTER_FAVORITES_KEY, isFavorites).apply()
	}
	
	fun getPsCloudFilterFavorites(): Boolean
	{
		return sharedPreferences.getBoolean(PSCLOUD_FILTER_FAVORITES_KEY, false)
	}
	
	fun setPsCloudFilterFavorites(isFavorites: Boolean)
	{
		sharedPreferences.edit().putBoolean(PSCLOUD_FILTER_FAVORITES_KEY, isFavorites).apply()
	}
	
	// License agreement
	fun hasAgreedToLicense(): Boolean
	{
		return sharedPreferences.getBoolean(LICENSE_AGREED_KEY, false)
	}
	
	fun setLicenseAgreed(agreed: Boolean)
	{
		sharedPreferences.edit().putBoolean(LICENSE_AGREED_KEY, agreed).apply()
	}

	/** Cumulative time spent in connected remote play sessions (client-side estimate). */
	val totalStreamTimeMs: Long
		get() = sharedPreferences.getLong(TOTAL_STREAM_TIME_MS_KEY, 0L)

	fun addTotalStreamTimeMs(deltaMs: Long)
	{
		if (deltaMs <= 0L) return
		val sum = totalStreamTimeMs + deltaMs
		sharedPreferences.edit().putLong(TOTAL_STREAM_TIME_MS_KEY, sum).apply()
	}

	/**
	 * Wall clock: last time the in-stream auto donation prompt ran (dialog or “already supporting” toast).
	 * Used to enforce at most one such prompt per hour; 0 means none yet.
	 */
	var lastDonationPromptWallClockMs: Long
		get()
		{
			var wall = sharedPreferences.getLong(LAST_DONATION_PROMPT_WALL_MS_KEY, 0L)
			if (wall == 0L && sharedPreferences.getBoolean(DONATION_STREAM_AUTO_PROMPT_SHOWN_KEY, false))
			{
				wall = System.currentTimeMillis()
				sharedPreferences.edit()
					.putLong(LAST_DONATION_PROMPT_WALL_MS_KEY, wall)
					.remove(DONATION_STREAM_AUTO_PROMPT_SHOWN_KEY)
					.apply()
				return wall
			}
			return wall
		}
		set(value)
		{
			sharedPreferences.edit()
				.putLong(LAST_DONATION_PROMPT_WALL_MS_KEY, value)
				.remove(DONATION_STREAM_AUTO_PROMPT_SHOWN_KEY)
				.apply()
		}
}