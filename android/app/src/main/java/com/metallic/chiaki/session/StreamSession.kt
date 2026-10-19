// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.session

import android.content.res.AssetManager
import android.graphics.SurfaceTexture
import android.util.Log
import android.view.*
import androidx.lifecycle.LiveData
import androidx.lifecycle.MutableLiveData
import com.metallic.chiaki.common.LogManager
import com.metallic.chiaki.lib.*
import com.metallic.chiaki.stream.gpu.GpuTuning
import com.metallic.chiaki.stream.gpu.GpuVideoRenderer

sealed class StreamState
object StreamStateIdle: StreamState()
object StreamStateConnecting: StreamState()
object StreamStateConnected: StreamState()
data class StreamStateCreateError(val error: CreateError): StreamState()
data class StreamStateQuit(val reason: QuitReason, val reasonString: String?): StreamState()
data class StreamStateLoginPinRequest(val pinIncorrect: Boolean): StreamState()

/** Which GPU features the session should use; null means the direct MediaCodec→SurfaceView path. */
data class GpuPipelineConfig(val upscaling: Boolean, val frameGeneration: Boolean, val tuning: GpuTuning = GpuTuning())
{
	val enabled get() = upscaling || frameGeneration
}

class StreamSession(val connectInfo: ConnectInfo, val logManager: LogManager, val logVerbose: Boolean, val input: StreamInput,
	private val assets: AssetManager, private val gpuConfig: GpuPipelineConfig?)
{
	@Volatile var session: Session? = null
		private set

	private val _state = MutableLiveData<StreamState>(StreamStateIdle)
	val state: LiveData<StreamState> get() = _state
	private val _rumbleState = MutableLiveData<RumbleEvent>(RumbleEvent(0U, 0U))
	val rumbleState: LiveData<RumbleEvent> get() = _rumbleState
	// Bumped each time the OPTIONS+SHARE chord fires, so the activity surfaces the in-stream menu.
	private val _menuRequest = MutableLiveData(0)
	val menuRequest: LiveData<Int> get() = _menuRequest

	/**
	 * Guards everything that ties the native decoder to a window: [surface], [surfaceWidth],
	 * [surfaceHeight], [gpuRenderer] and the publication of [session]. Taken by the
	 * SurfaceHolder callbacks and [shutdown] on the main thread and by the connect threads
	 * when they attach video output, so a surface change cannot be lost while a connect
	 * thread is between reading the surface and handing it to the decoder.
	 */
	private val videoOutputLock = Any()
	private var surfaceTexture: SurfaceTexture? = null
	private var surface: Surface? = null
	private var surfaceWidth = 0
	private var surfaceHeight = 0
	@Volatile private var gpuRenderer: GpuVideoRenderer? = null
	/** Non-null while the GPU path is active for the current session. */
	val gpuStats get() = gpuRenderer?.stats()
	/** True while the GPU path is attached, i.e. the live toggles below have an effect. */
	val gpuPathActive get() = gpuRenderer != null

	fun setGpuUpscaling(enabled: Boolean)
	{
		gpuRenderer?.setUpscaling(enabled)
	}

	fun setGpuFrameGeneration(enabled: Boolean)
	{
		gpuRenderer?.setFrameGeneration(enabled)
	}

	/**
	 * Incremented by every [shutdown]. A connect thread captures it before creating its
	 * Session and only publishes the Session if it is unchanged; otherwise the Session was
	 * shut down while still connecting and is torn down instead of leaking.
	 */
	@Volatile private var generation = 0

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
		generation++
		synchronized(videoOutputLock)
		{
			val sessionToDispose = session
			Log.i("StreamSession", "shutdown: session=${sessionToDispose != null}, gpu=${gpuRenderer != null}")
			// If a native Session was created with a holepunch pointer, the Session owns it
			// and will free it in chiaki_session_fini(). Don't double-free.
			if(sessionToDispose != null)
			{
				// Ordering matters here:
				//  1. stop() only signals the session thread; the MediaCodec keeps running.
				//  2. setSurface(null) kills the MediaCodec (native kill_decoder) and joins
				//     its output thread, so nothing writes to the video surface any more.
				//     Without it the codec would live on until dispose() finishes on the
				//     background thread, seconds later.
				//  3. Only then may the renderer go: release() abandons the SurfaceTexture
				//     the codec was rendering into.
				//  4. dispose() in the background (it can block on holepunch cleanup).
				sessionToDispose.stop()
				sessionToDispose.setSurface(null)
				gpuRenderer?.release()
				gpuRenderer = null
				// Move blocking dispose() call to background thread to prevent ANR
				// (dispose can block for 10+ seconds on network timeouts during holepunch cleanup)
				Thread {
					sessionToDispose.dispose()
					Log.i("StreamSession", "Session disposed on background thread")
				}.start()
				session = null
				holepunchSession = null // consumed by native Session
			}
			else
			{
				// No renderer can exist here: it is published together with the session
				// under this lock, and a connect thread that loses the generation race
				// releases its own renderer (see publishVideoOutput).
				val hpSessionToFini = holepunchSession
				// Move blocking fini() call to background thread to prevent ANR
				Thread {
					hpSessionToFini?.fini()
					Log.i("StreamSession", "Holepunch session finalized on background thread")
				}.start()
				holepunchSession = null
			}
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
			var started: Session? = null
			val gen = generation
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
				started = session
				session.eventCallback = this::eventCallback
				session.setPsChord(true) // always on: safe, no user toggle
				session.start()
				if(publishVideoOutput(session, gen))
					started = null
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
				// A created native Session owns the holepunch session and frees it in
				// chiaki_session_fini(); only fini() it ourselves if no Session exists.
				if(started != null)
					discardUnpublished(started)
				else
				{
					val hpSessionToFini = holepunchSession
					Thread {
						hpSessionToFini?.fini()
						Log.i("StreamSession", "Holepunch session finalized after failed PSN connection")
					}.start()
				}
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
			var started: Session? = null
			try
			{
				val gen = generation
				val session = Session(connectInfo, logManager.createNewFile().file.absolutePath, logVerbose)
				started = session
				session.eventCallback = this::eventCallback
				session.setPsChord(true) // always on: safe, no user toggle
				session.start()
				if(publishVideoOutput(session, gen))
					started = null
			}
			catch(e: CreateError)
			{
				_state.postValue(StreamStateCreateError(e))
			}
			catch(e: Exception)
			{
				Log.e("StreamSession", "Local connection failed", e)
				discardUnpublished(started)
				_state.postValue(StreamStateCreateError(CreateError(ErrorCode(-1))))
			}
		}.start()
	}

	/**
	 * Attaches video output to a freshly started [session] and publishes it as [this.session],
	 * unless [shutdown] ran since [gen] was captured, in which case the session is torn down
	 * here and false is returned.
	 *
	 * The decoder is pointed at either the GPU renderer's input surface or the SurfaceView
	 * directly; if the renderer cannot start, the direct path is used. Starting the renderer
	 * takes tens to hundreds of milliseconds and happens outside [videoOutputLock]; the
	 * generation check, the surface hand-off and the publication are one critical section,
	 * so a renderer only becomes visible together with a session that is wanted.
	 */
	private fun publishVideoOutput(session: Session, gen: Int): Boolean
	{
		val cfg = gpuConfig
		var renderer: GpuVideoRenderer? = null
		if(cfg != null && cfg.enabled)
		{
			val vp = connectInfo.videoProfile
			// Native forces H264 on PS4, so HDR can only be in effect on a PS5 session.
			val hdr = connectInfo.ps5 && vp.codec == Codec.CODEC_H265_HDR
			val candidate = GpuVideoRenderer(assets, vp.width, vp.height, vp.maxFPS, cfg.upscaling, cfg.frameGeneration, hdr, cfg.tuning,
				hdrMetadataProvider = { session.getVideoHdrStaticInfo() })
			if(candidate.start())
				renderer = candidate
			else
				Log.w("StreamSession", "video output: GPU path unavailable, using direct path")
		}
		synchronized(videoOutputLock)
		{
			if(gen == generation)
			{
				if(renderer != null)
				{
					gpuRenderer = renderer
					renderer.setOutputSurface(surface, surfaceWidth, surfaceHeight)
					session.setSurface(renderer.inputSurface)
					Log.i("StreamSession", "video output: GPU path (upscale=${cfg?.upscaling}, framegen=${cfg?.frameGeneration})")
				}
				else
				{
					val s = surface
					if(s != null)
						session.setSurface(s)
				}
				this.session = session
				return true
			}
		}
		// shutdown() ran while this thread was connecting. The decoder never got a surface,
		// so no MediaCodec exists and the renderer can be released straight away.
		Log.i("StreamSession", "session connected after shutdown, discarding it")
		renderer?.release()
		discardUnpublished(session)
		return false
	}

	/** Stops and disposes a started Session that was never published as [session]. */
	private fun discardUnpublished(session: Session?)
	{
		if(session == null)
			return
		session.stop()
		Thread {
			session.dispose()
			Log.i("StreamSession", "Unpublished session disposed on background thread")
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
			is PsChordEvent -> {
				Log.i("StreamSession", "EVENT: PsChord -> requesting in-stream menu")
				_menuRequest.postValue((_menuRequest.value ?: 0) + 1)
			}
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
				Log.i("StreamSession", "surfaceChanged: ${width}x${height}, session=${session != null}, gpu=${gpuRenderer != null}")
				synchronized(videoOutputLock)
				{
					val surface = holder.surface
					this@StreamSession.surface = surface
					surfaceWidth = width
					surfaceHeight = height
					val renderer = gpuRenderer
					if(renderer != null)
						renderer.setOutputSurface(surface, width, height)
					else
						session?.setSurface(surface)
				}
				Log.i("StreamSession", "surfaceChanged: done")
			}

			override fun surfaceDestroyed(holder: SurfaceHolder)
			{
				Log.i("StreamSession", "surfaceDestroyed: session=${session != null}, gpu=${gpuRenderer != null}, skipNativeCleanup=$skipNativeSurfaceCleanup")
				synchronized(videoOutputLock)
				{
					this@StreamSession.surface = null
					val renderer = gpuRenderer
					if(renderer != null)
					{
						// GPU path: the decoder keeps writing to the SurfaceTexture; only the EGL
						// window goes away. This call blocks until the render thread has stopped
						// drawing to the surface, as the SurfaceHolder contract requires.
						renderer.setOutputSurface(null, 0, 0)
					}
					else if(!skipNativeSurfaceCleanup)
					{
						// Direct path, normal cleanup - session is being shut down or activity is finishing
						session?.setSurface(null)
						Log.i("StreamSession", "surfaceDestroyed: setSurface(null) done")
					}
					// Direct path with skipNativeSurfaceCleanup (PiP transition): don't call
					// setSurface(null) - it blocks the native decoder. The new surface
					// will be provided via surfaceChanged shortly after.
				}
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

	/** Latest live stream metrics (bitrate/loss/fps/rtt/resolution) for the stats overlay. */
	fun metrics(): StreamMetrics? = session?.getMetrics()
}
