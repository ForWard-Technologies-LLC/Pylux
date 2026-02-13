// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.regist

import android.content.Context
import android.util.Log
import com.metallic.chiaki.common.*
import com.metallic.chiaki.lib.*
import io.reactivex.android.schedulers.AndroidSchedulers
import io.reactivex.disposables.CompositeDisposable
import io.reactivex.rxkotlin.addTo
import io.reactivex.schedulers.Schedulers

/**
 * Performs PSN auto-registration via holepunch.
 * Runs on a background thread, reports progress via [onStatus] and result via [onSuccess]/[onError].
 * All callbacks are invoked on the main thread.
 *
 * Mimics the Qt app's autoRegister() flow.
 */
class PsnAutoRegistration(
	private val context: Context,
	private val duid: String,
	private val hostName: String,
	private val isPS5: Boolean,
	private val onStatus: (String) -> Unit,
	private val onSuccess: (String) -> Unit,  // nickname
	private val onError: (String) -> Unit
)
{
	companion object
	{
		private const val TAG = "PsnAutoRegistration"
		private const val CHIAKI_SESSION_AUTH_SIZE = 0x10
		private const val CHIAKI_KEY_SIZE = 0x10
	}

	private val disposable = CompositeDisposable()
	private var session: Session? = null
	private var holepunchSession: HolepunchSession? = null
	@Volatile private var cancelled = false

	fun start()
	{
		Thread {
			try
			{
				val prefs = Preferences(context)
				if(!prefs.hasPsnRemotePlayTokens)
				{
					postError("No PSN tokens. Please log in first.")
					return@Thread
				}

				Log.i(TAG, "Starting PSN registration for $hostName (duid=$duid)")

				val tokenManager = PsnTokenManager(prefs)
				val token = tokenManager.getValidToken()
				if(token == null)
				{
					postError("Failed to get valid PSN token")
					return@Thread
				}
				if(cancelled) return@Thread

				// Step 1: Initialize holepunch session
				postStatus("Initializing...")
				val hpSession = HolepunchSession(token)
				holepunchSession = hpSession

				// Step 2: UPnP (non-fatal)
				postStatus("Discovering network...")
				val upnpErr = hpSession.upnpDiscover()
				if(!upnpErr.isSuccess)
					Log.w(TAG, "UPnP discover failed (non-fatal): $upnpErr")
				if(cancelled) { cleanup(); return@Thread }

				// Step 3: Create session
				postStatus("Connecting to PSN...")
				val createErr = hpSession.create()
				if(!createErr.isSuccess)
				{
					cleanup()
					postError("Failed to create PSN session")
					return@Thread
				}
				if(cancelled) { cleanup(); return@Thread }

				// Step 4: Create offer
				postStatus("Setting up connection...")
				val offerErr = hpSession.createOffer()
				if(!offerErr.isSuccess)
				{
					cleanup()
					postError("Failed to create control offer")
					return@Thread
				}
				if(cancelled) { cleanup(); return@Thread }

				// Step 5: Start for console
				postStatus("Contacting $hostName...")
				val duidBytes = hexStringToBytes(duid)
				val consoleType = if(isPS5) HolepunchConsoleType.PS5 else HolepunchConsoleType.PS4
				val startErr = hpSession.start(duidBytes, consoleType)
				if(!startErr.isSuccess)
				{
					cleanup()
					postError("Console not responding")
					return@Thread
				}
				if(cancelled) { cleanup(); return@Thread }

				// Step 6: Punch hole
				postStatus("Establishing connection...")
				val punchErr = hpSession.punchHole(HolepunchPortType.CTRL)
				if(!punchErr.isSuccess)
				{
					cleanup()
					postError("Failed to establish connection")
					return@Thread
				}
				if(cancelled) { cleanup(); return@Thread }

				// Step 7: Create native session with auto_regist
				postStatus("Registering $hostName...")
				val connectInfo = ConnectInfo(
					ps5 = isPS5,
					host = "",
					registKey = ByteArray(CHIAKI_SESSION_AUTH_SIZE),
					morning = ByteArray(CHIAKI_KEY_SIZE),
					videoProfile = prefs.videoProfile,
					duid = duid,
					psnToken = token,
					psnAccountId = prefs.psnAccountId,
					holepunchSessionPtr = hpSession.getPtr(),
					autoRegist = true
				)

				val nativeSession = Session(connectInfo, LogManager(context).createNewFile().file.absolutePath, prefs.logVerbose)
				session = nativeSession
				nativeSession.eventCallback = { event ->
					Log.i(TAG, "Session event: ${event.javaClass.simpleName}")
					when(event)
					{
						is AutoRegistEvent ->
						{
							Log.i(TAG, "Registration succeeded for ${event.host.serverNickname}")
							val registeredHost = RegisteredHost(event.host)
							val db = getDatabase(context)
							db.registeredHostDao().deleteByMac(registeredHost.serverMac)
								.andThen(db.registeredHostDao().insert(registeredHost))
								.subscribeOn(Schedulers.io())
								.observeOn(AndroidSchedulers.mainThread())
								.subscribe({
									Log.i(TAG, "Registered host saved to database")
									postSuccess(event.host.serverNickname)
								}, { error ->
									Log.e(TAG, "Failed to save registered host", error)
									postError("Registration succeeded but failed to save")
								})
								.addTo(disposable)
						}
						is QuitEvent ->
						{
							if(event.reason.isError)
								postError("Registration failed: ${event.reasonString ?: "unknown error"}")
						}
						else -> {}
					}
				}
				nativeSession.start()
			}
			catch(e: CreateError)
			{
				Log.e(TAG, "Failed to create session", e)
				cleanup()
				postError("Failed to create session")
			}
			catch(e: Exception)
			{
				Log.e(TAG, "Registration failed", e)
				cleanup()
				postError("Registration failed: ${e.message}")
			}
		}.start()
	}

	fun cancel()
	{
		cancelled = true
		holepunchSession?.cancel(true)
		dispose()
	}

	fun dispose()
	{
		if(session != null)
		{
			session?.stop()
			session?.dispose()
			session = null
			holepunchSession = null
		}
		else
		{
			holepunchSession?.fini()
			holepunchSession = null
		}
		disposable.dispose()
	}

	private fun cleanup()
	{
		if(session == null)
		{
			holepunchSession?.fini()
			holepunchSession = null
		}
	}

	private fun postStatus(msg: String)
	{
		android.os.Handler(android.os.Looper.getMainLooper()).post { onStatus(msg) }
	}

	private fun postSuccess(nickname: String)
	{
		android.os.Handler(android.os.Looper.getMainLooper()).post { onSuccess(nickname) }
	}

	private fun postError(msg: String)
	{
		android.os.Handler(android.os.Looper.getMainLooper()).post { onError(msg) }
	}

	private fun hexStringToBytes(hex: String): ByteArray
	{
		val len = hex.length / 2
		val result = ByteArray(len)
		for(i in 0 until len)
			result[i] = hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
		return result
	}
}
