// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.session

import android.graphics.SurfaceTexture
import android.util.Log
import android.view.*
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.metallic.chiaki.common.LogManager
import com.metallic.chiaki.lib.*

sealed class StreamState
object StreamStateIdle: StreamState()
object StreamStateConnecting: StreamState()
object StreamStateConnected: StreamState()
data class StreamStateCreateError(val error: CreateError): StreamState()
data class StreamStateQuit(val reason: QuitReason, val reasonString: String?): StreamState()
data class StreamStateLoginPinRequest(val pinIncorrect: Boolean): StreamState()

class StreamSession(val connectInfo: ConnectInfo, val logManager: LogManager, val logVerbose: Boolean, val input: StreamInput)
{
	var session: Session? = null
		private set

	private val _state = MutableLiveData<StreamState>(StreamStateIdle)
	val state: LiveData<StreamState> get() = _state
	private val _rumbleState = MutableLiveData<RumbleEvent>(RumbleEvent(0U, 0U))
	val rumbleState: LiveData<RumbleEvent> get() = _rumbleState

	private var surfaceTexture: SurfaceTexture? = null
	private var surface: Surface? = null

	/** Holepunch session for PSN connections (kept alive for session lifetime) */
	private var holepunchSession: HolepunchSession? = null

	/** When true, surfaceDestroyed will not call setSurface(null) on the native session.
	 *  Set to true during PiP transitions where the surface is briefly destroyed and
	 *  recreated, and setSurface(null) blocks on the native decoder. */
	var skipNativeSurfaceCleanup = false

	init
	{
		input.controllerStateChangedCallback = {
			session?.setControllerState(it)
		}
	}

	fun shutdown()
	{
		Log.i("StreamSession", "shutdown: session=${session != null}")
		// If a native Session was created with a holepunch pointer, the Session owns it
		// and will free it in chiaki_session_fini(). Don't double-free.
		if(session != null)
		{
			val sessionToDispose = session
			session?.stop()
			// Move blocking dispose() call to background thread to prevent ANR
			// (dispose can block for 10+ seconds on network timeouts during holepunch cleanup)
			Thread {
				sessionToDispose?.dispose()
				Log.i("StreamSession", "Session disposed on background thread")
			}.start()
			session = null
			holepunchSession = null // consumed by native Session
		}
		else
		{
			val hpSessionToFini = holepunchSession
			// Move blocking fini() call to background thread to prevent ANR
			Thread {
				hpSessionToFini?.fini()
				Log.i("StreamSession", "Holepunch session finalized on background thread")
			}.start()
			holepunchSession = null
		}
		_state.value = StreamStateIdle
		//surfaceTexture?.release()
	}

	fun pause()
	{
		Log.i("StreamSession", "pause")
		shutdown()
	}

	fun resume()
	{
		Log.i("StreamSession", "resume: session=${session != null}")
		if(session != null)
			return
		_state.value = StreamStateConnecting

		val duid = connectInfo.duid
		val hasPsnToken = !connectInfo.psnToken.isNullOrEmpty()
		Log.i("StreamSession", "resume: duid=${duid?.take(16) ?: "null"}, hasPsnToken=$hasPsnToken, host=${connectInfo.host}, ps5=${connectInfo.ps5}")
		if(!duid.isNullOrEmpty() && hasPsnToken)
		{
			// PSN connection: perform holepunch before creating session
			Log.i("StreamSession", "Using PSN holepunch connection path")
			resumePsnConnection(duid)
		}
		else
		{
			// Local or cloud connection: create session directly
			Log.i("StreamSession", "Using local/cloud connection path")
			resumeLocalConnection()
		}
	}

	/**
	 * Resume with a PSN holepunch connection.
	 * Mimics StreamSession::ConnectPsnConnection() from the Qt app.
	 * Runs holepunch steps on background thread, then creates Session with holepunch ptr.
	 */
	private fun resumePsnConnection(duid: String)
	{
		Thread {
			try
			{
				Log.i("StreamSession", "Starting PSN holepunch connection (duid=$duid)")

				// Step 1: Initialize holepunch session
				val hpSession = HolepunchSession(connectInfo.psnToken!!)
				holepunchSession = hpSession

				// Step 2: Discover UPnP
				val upnpErr = hpSession.upnpDiscover()
				if(!upnpErr.isSuccess)
					Log.w("StreamSession", "UPnP discover failed (non-fatal): $upnpErr")

				// Step 3: Create session on PSN server
				val createErr = hpSession.create()
				if(!createErr.isSuccess)
				{
					Log.e("StreamSession", "Holepunch session create failed: $createErr")
					hpSession.fini()
					holepunchSession = null
					_state.postValue(StreamStateCreateError(CreateError(createErr)))
					return@Thread
				}
				Log.i("StreamSession", "Holepunch session created")

				// Step 4: Create offer for control connection
				val offerErr = hpSession.createOffer()
				if(!offerErr.isSuccess)
				{
					Log.e("StreamSession", "Holepunch create offer failed: $offerErr")
					hpSession.fini()
					holepunchSession = null
					_state.postValue(StreamStateCreateError(CreateError(offerErr)))
					return@Thread
				}
				Log.i("StreamSession", "Holepunch offer created for CTRL")

				// Step 5: Start session for specific console
				val duidBytes = hexStringToBytes(duid)
				val consoleType = if(connectInfo.ps5) HolepunchConsoleType.PS5 else HolepunchConsoleType.PS4
				val startErr = hpSession.start(duidBytes, consoleType)
				if(!startErr.isSuccess)
				{
					Log.e("StreamSession", "Holepunch session start failed: $startErr")
					hpSession.fini()
					holepunchSession = null
					_state.postValue(StreamStateCreateError(CreateError(startErr)))
					return@Thread
				}
				Log.i("StreamSession", "Holepunch session started")

				// Step 6: Punch hole for control connection
				val punchErr = hpSession.punchHole(HolepunchPortType.CTRL)
				if(!punchErr.isSuccess)
				{
					Log.e("StreamSession", "Holepunch punch hole (CTRL) failed: $punchErr")
					hpSession.fini()
					holepunchSession = null
					_state.postValue(StreamStateCreateError(CreateError(punchErr)))
					return@Thread
				}
				Log.i("StreamSession", "Holepunch CTRL hole punched!")

				// Step 7: Create Session with holepunch session pointer
				// The native session_init() will use this for the streaming connection
				// (data hole punching happens inside the native session thread)
				val psnConnectInfo = connectInfo.copy(holepunchSessionPtr = hpSession.getPtr())
				val session = Session(psnConnectInfo, logManager.createNewFile().file.absolutePath, logVerbose)
				session.eventCallback = this::eventCallback
				session.start()
				val surface = surface
				if(surface != null)
					session.setSurface(surface)
				this.session = session
			}
			catch(e: CreateError)
			{
				holepunchSession?.fini()
				holepunchSession = null
				_state.postValue(StreamStateCreateError(e))
			}
			catch(e: Exception)
			{
				Log.e("StreamSession", "PSN connection failed", e)
				holepunchSession?.fini()
				holepunchSession = null
				_state.postValue(StreamStateCreateError(CreateError(ErrorCode(-1))))
			}
		}.start()
	}

	/**
	 * Resume with a local/cloud connection (no holepunch).
	 */
	private fun resumeLocalConnection()
	{
		// Create session on background thread to avoid ANR (DNS resolution can block)
		Thread {
			try
			{
				val session = Session(connectInfo, logManager.createNewFile().file.absolutePath, logVerbose)
				session.eventCallback = this::eventCallback
				session.start()
				val surface = surface
				if(surface != null)
					session.setSurface(surface)
				this.session = session
			}
			catch(e: CreateError)
			{
				_state.postValue(StreamStateCreateError(e))
			}
		}.start()
	}

	private fun hexStringToBytes(hex: String): ByteArray
	{
		val len = hex.length / 2
		val result = ByteArray(len)
		for(i in 0 until len)
		{
			result[i] = hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
		}
		return result
	}

	private fun eventCallback(event: Event)
	{
		Log.i("StreamSession", "eventCallback: ${event.javaClass.simpleName}")
		when(event)
		{
			is ConnectedEvent -> {
				Log.i("StreamSession", "EVENT: Connected!")
				_state.postValue(StreamStateConnected)
			}
			is QuitEvent -> {
				Log.i("StreamSession", "EVENT: Quit reason=${event.reason} str=${event.reasonString}")
				_state.postValue(StreamStateQuit(event.reason, event.reasonString))
			}
			is LoginPinRequestEvent -> {
				Log.i("StreamSession", "EVENT: LoginPinRequest pinIncorrect=${event.pinIncorrect}")
				_state.postValue(StreamStateLoginPinRequest(event.pinIncorrect))
			}
			is RumbleEvent -> _rumbleState.postValue(event)
			is AutoRegistEvent -> Log.i("StreamSession", "EVENT: AutoRegist host=${event.host.serverNickname}")
			is HolepunchEvent -> Log.i("StreamSession", "EVENT: Holepunch")
		}
	}

	fun attachToSurfaceView(surfaceView: SurfaceView)
	{
		surfaceView.holder.addCallback(object: SurfaceHolder.Callback {
			override fun surfaceCreated(holder: SurfaceHolder)
			{
				Log.i("StreamSession", "surfaceCreated")
			}

			override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int)
			{
				Log.i("StreamSession", "surfaceChanged: ${width}x${height}, session=${session != null}")
				val surface = holder.surface
				this@StreamSession.surface = surface
				session?.setSurface(surface)
				Log.i("StreamSession", "surfaceChanged: setSurface done")
			}

			override fun surfaceDestroyed(holder: SurfaceHolder)
			{
				Log.i("StreamSession", "surfaceDestroyed: session=${session != null}, skipNativeCleanup=$skipNativeSurfaceCleanup")
				this@StreamSession.surface = null
				if (!skipNativeSurfaceCleanup)
				{
					// Normal cleanup - session is being shut down or activity is finishing
					session?.setSurface(null)
					Log.i("StreamSession", "surfaceDestroyed: setSurface(null) done")
				}
				// When skipNativeSurfaceCleanup is true (PiP transition), don't call
				// setSurface(null) - it blocks the native decoder. The new surface
				// will be provided via surfaceChanged shortly after.
			}
		})
	}

	fun attachToTextureView(textureView: TextureView)
	{
		textureView.surfaceTextureListener = object: TextureView.SurfaceTextureListener {
			override fun onSurfaceTextureAvailable(surface: SurfaceTexture, width: Int, height: Int)
			{
				if(surfaceTexture != null)
					return
				surfaceTexture = surface
				this@StreamSession.surface = Surface(surfaceTexture)
				session?.setSurface(Surface(surface))
			}

			override fun onSurfaceTextureDestroyed(surface: SurfaceTexture): Boolean
			{
				// return false if we want to keep the surface texture
				return surfaceTexture == null
			}

			override fun onSurfaceTextureSizeChanged(surface: SurfaceTexture, width: Int, height: Int) { }
			override fun onSurfaceTextureUpdated(surface: SurfaceTexture) {}
		}

		val surfaceTexture = surfaceTexture
		if(surfaceTexture != null)
			textureView.setSurfaceTexture(surfaceTexture)
	}

	fun setLoginPin(pin: String)
	{
		session?.setLoginPin(pin)
	}
}