// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream.gpu

import android.content.res.AssetManager
import android.graphics.SurfaceTexture
import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.opengl.GLES11Ext
import android.opengl.GLES31
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import android.view.Choreographer
import android.view.Surface
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * User tuning for the GPU path. [extrapolationScale] is the glExtrapolateTex2DQCOM scale factor:
 * how far past the newest real frame the generated frame targets, in frame intervals (0.5 = the
 * midpoint between two 60 fps frames, which is where a 120 Hz vsync falls).
 */
data class GpuTuning(
	val sgsrEdgeSharpness: Float = GlShaders.SGSR1_DEFAULT_EDGE_SHARPNESS,
	val sgsrEdgeThreshold255: Int = GlShaders.SGSR1_DEFAULT_EDGE_THRESHOLD_255,
	val sgsrEdgeDirection: Boolean = true,
	val extrapolationScale: Float = 0.5f,
	val generationMode: GenerationMode = GenerationMode.EXTRAPOLATE)

/**
 * GPU video path: MediaCodec decodes into [inputSurface]; every display vsync this thread
 * presents either the newest decoded frame or a hardware-extrapolated one, upscaled with
 * SGSR1 (or a plain blit) onto the SurfaceView's surface.
 *
 * HDR ([hdr]): the decoder's 10-bit BT.2020 PQ frames are converted explicitly from Y'CbCr
 * (GL_EXT_YUV_target), kept PQ-encoded in RGBA16F ring slots (a format the extrapolation
 * extension accepts), and presented on a 10-bit window surface tagged BT.2020 PQ, which
 * SurfaceFlinger composes as an HDR10 layer like a video player's output.
 *
 * Threading: all GL work happens on the private render thread, whose [HandlerThread] starts
 * in the constructor, so construct this only when the GPU path will actually be used. Public
 * methods are safe to call from any thread other than the render thread; [start] and [release]
 * block until the render thread is done, so they must never be called from the render thread itself.
 */
class GpuVideoRenderer(
	private val assets: AssetManager,
	private val streamWidth: Int,
	private val streamHeight: Int,
	streamFps: Int,
	private val upscalingRequested: Boolean,
	private val frameGenerationRequested: Boolean,
	private val hdr: Boolean = false,
	private val tuning: GpuTuning = GpuTuning(),
	/**
	 * Supplies the decoder's parsed HDR static metadata once available (null before). Polled once per
	 * stats window on the render thread until it returns a usable value, which is then attached to the
	 * window surface so the compositor tone maps like it does for the decoder's own buffers.
	 */
	private val hdrMetadataProvider: (() -> ByteArray?)? = null
)
{
	companion object
	{
		private const val TAG = "GpuVideoRenderer"
		private const val STATS_WINDOW_NS = 1_000_000_000L
		private const val SURFACE_TEARDOWN_TIMEOUT_MS = 500L
		// EGL_KHR_gl_colorspace and EGL_EXT_gl_colorspace_bt2020_pq; android.opengl exposes neither constant.
		private const val EGL_GL_COLORSPACE_KHR = 0x309D
		private const val EGL_GL_COLORSPACE_BT2020_PQ_EXT = 0x3340
		// EGL_EXT_surface_SMPTE2086_metadata / EGL_EXT_surface_CTA861_3_metadata
		private const val EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT = 0x3341
		private const val EGL_SMPTE2086_DISPLAY_PRIMARY_RY_EXT = 0x3342
		private const val EGL_SMPTE2086_DISPLAY_PRIMARY_GX_EXT = 0x3343
		private const val EGL_SMPTE2086_DISPLAY_PRIMARY_GY_EXT = 0x3344
		private const val EGL_SMPTE2086_DISPLAY_PRIMARY_BX_EXT = 0x3345
		private const val EGL_SMPTE2086_DISPLAY_PRIMARY_BY_EXT = 0x3346
		private const val EGL_SMPTE2086_WHITE_POINT_X_EXT = 0x3347
		private const val EGL_SMPTE2086_WHITE_POINT_Y_EXT = 0x3348
		private const val EGL_SMPTE2086_MAX_LUMINANCE_EXT = 0x3349
		private const val EGL_SMPTE2086_MIN_LUMINANCE_EXT = 0x334A
		private const val EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT = 0x3360
		private const val EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT = 0x3361
		private const val EGL_METADATA_SCALING_EXT = 50000
		// GL_QCOM_motion_estimation
		private const val GL_MOTION_ESTIMATION_SEARCH_BLOCK_X_QCOM = 0x8C90
		private const val GL_MOTION_ESTIMATION_SEARCH_BLOCK_Y_QCOM = 0x8C91
		private const val MAX_CONFIGS = 16
	}

	/**
	 * [outputWidth]/[outputHeight] are the window surface size, 0 while no surface is attached.
	 * [latencyMs] is the mean time from the decoder receiving a frame's data (native input
	 * timestamp) to the vsync at which the GPU path renders it, over the last stats window;
	 * 0 until the first real frame. Scanout adds one more vsync on top.
	 */
	data class Stats(val presentedFps: Double, val generatedFps: Double, val frameGenerationActive: Boolean, val upscalingActive: Boolean,
		val outputWidth: Int, val outputHeight: Int, val latencyMs: Double, val interpolating: Boolean)

	private val thread = HandlerThread("GpuVideoRenderer").also { it.start() }
	private val handler = Handler(thread.looper)
	private val pacer = FramePacer(1_000_000_000L / streamFps.coerceAtLeast(1), frameGenerationRequested)
	// A single flag suffices: the SurfaceTexture producer is non-blocking, queueBuffer replaces the
	// last un-acquired buffer, and updateTexImage always latches the newest frame, so MediaCodec
	// never stalls on us and no FIFO latency can build up between decoder and vsync.
	private val frameAvailable = AtomicBoolean(false)
	@Volatile private var released = false
	/** Set when decoding has ended (updateTexImage failed); no further GL work happens afterwards. */
	@Volatile private var stopped = false
	private var started = false

	// EGL
	private var eglDisplay: EGLDisplay = EGL14.EGL_NO_DISPLAY
	private var eglConfig: EGLConfig? = null
	private var eglContext: EGLContext = EGL14.EGL_NO_CONTEXT
	private var pbufferSurface: EGLSurface = EGL14.EGL_NO_SURFACE
	private var windowSurface: EGLSurface = EGL14.EGL_NO_SURFACE
	@Volatile private var windowWidth = 0
	@Volatile private var windowHeight = 0

	// GL objects
	private var oesTexture = 0
	private val ring = IntArray(2)
	private val ringFbo = IntArray(2)
	private var newestSlot = 0 // index into ring of the most recent real frame
	private var generatedTexture = 0
	// Interpolation mode (GL_QCOM_motion_estimation): luma copies of the ring, block motion fields both
	// ways, and an FBO so the warp shader can write the generated texture.
	private var generatedFbo = 0
	private val lumaTex = IntArray(2)
	private val lumaFbo = IntArray(2)
	private var mvTexAB = 0
	private var mvTexBA = 0
	private var lumaProgram = 0
	private var warpProgram = 0
	private var lumaWidth = 0
	private var lumaHeight = 0
	@Volatile private var interpolationActive = false
	/** Decoder timestamp of the frame consumed by PRESENT_INTERPOLATED and shown at the next vsync. */
	private var heldTimestampNs = 0L
	private var oesCopyProgram = 0
	private var oesTransformLoc = -1
	private var presentProgram = 0 // SGSR1 or blit
	private var blitProgram = 0
	private var sgsrProgram = 0 // built on first use
	private var sgsrFailed = false
	private var extrapolationSupported = false
	private var interpolationTried = false
	@Volatile private var presentIsSgsr = false
	@Volatile private var frameGenerationActive = false
	private val transform = FloatArray(16)
	/** Render thread only. Set once the provider returned usable metadata; re-applied to every new window surface. */
	private var hdrMetadata: HdrStaticInfo? = null
	private var hdrMetadataSupported = false

	private var surfaceTexture: SurfaceTexture? = null
	lateinit var inputSurface: Surface
		private set

	// Stats (1 s window, Choreographer frame time base)
	private var windowStartNs = Long.MIN_VALUE
	private var presentedInWindow = 0
	private var generatedInWindow = 0
	@Volatile private var presentedFps = 0.0
	@Volatile private var generatedFps = 0.0
	private var latencySumNs = 0L
	private var latencyCount = 0
	@Volatile private var latencyMs = 0.0
	private val loggedGlErrors = HashSet<String>()

	private val vsyncCallback = object: Choreographer.FrameCallback
	{
		override fun doFrame(frameTimeNanos: Long)
		{
			if(released) return
			Choreographer.getInstance().postFrameCallback(this)
			onVsync(frameTimeNanos)
		}
	}

	/** Initializes EGL/GL on the render thread. Returns false (after logging and cleaning up) if the GPU path is unusable. */
	fun start(): Boolean
	{
		check(Looper.myLooper() != thread.looper) { "start() must not be called from the render thread" }
		check(!released) { "start() after release()" }
		check(!started) { "start() called twice" }
		started = true
		var ok = false
		val latch = CountDownLatch(1)
		handler.post {
			try
			{
				initGl()
				Choreographer.getInstance().postFrameCallback(vsyncCallback)
				ok = true
			}
			catch(e: Throwable)
			{
				// Throwable: an UnsatisfiedLinkError or OOM must not leave the caller waiting forever.
				Log.e(TAG, "GPU path init failed: ${e.message}", e)
			}
			finally
			{
				latch.countDown()
			}
		}
		latch.await()
		if(!ok) release()
		return ok
	}

	/**
	 * New SurfaceView surface (or null when it is gone). Only the EGL window surface changes; decoding continues.
	 *
	 * The null case blocks (bounded) until the render thread has destroyed the window surface, because the
	 * SurfaceHolder contract requires that drawing has stopped before surfaceDestroyed returns. The
	 * non-null case stays asynchronous. The render thread never waits on the caller, so this cannot deadlock.
	 */
	fun setOutputSurface(surface: Surface?, width: Int, height: Int)
	{
		val gone = if(surface == null) CountDownLatch(1) else null
		val posted = handler.post {
			try
			{
				if(!released)
					applyOutputSurface(surface, width, height)
			}
			finally
			{
				gone?.countDown()
			}
		}
		if(gone != null && posted && !gone.await(SURFACE_TEARDOWN_TIMEOUT_MS, TimeUnit.MILLISECONDS))
			Log.w(TAG, "render thread did not release the window surface within ${SURFACE_TEARDOWN_TIMEOUT_MS} ms")
	}

	/** Switches SGSR upscaling on or off for the frames that follow. Asynchronous; safe from any thread. */
	fun setUpscaling(enabled: Boolean)
	{
		handler.post { if(!released) applyUpscaling(enabled) }
	}

	/** Switches frame generation on or off for the frames that follow. Asynchronous; safe from any thread. */
	fun setFrameGeneration(enabled: Boolean)
	{
		handler.post { if(!released) applyFrameGeneration(enabled) }
	}

	fun stats(): Stats = Stats(presentedFps, generatedFps, frameGenerationActive, presentIsSgsr, windowWidth, windowHeight, latencyMs, interpolationActive)

	/**
	 * Stops presenting and frees all EGL/GL resources, blocking until the render thread is done.
	 * Must be called from a thread other than the render thread (it would deadlock on itself).
	 * The caller must stop the native decoder first (native setSurface(null) / session stop):
	 * releasing the SurfaceTexture abandons its BufferQueue, and a decoder still queueing into
	 * [inputSurface] would fail.
	 */
	fun release()
	{
		check(Looper.myLooper() != thread.looper) { "release() must not be called from the render thread" }
		if(released) return
		released = true
		val latch = CountDownLatch(1)
		handler.post {
			try
			{
				Choreographer.getInstance().removeFrameCallback(vsyncCallback)
				releaseGl()
			}
			finally
			{
				latch.countDown()
			}
		}
		if(!latch.await(2, TimeUnit.SECONDS))
			Log.e(TAG, "release(): render thread did not finish GL teardown within 2 s")
		thread.quitSafely()
	}

	// ---- render thread below ----

	private fun applyOutputSurface(surface: Surface?, width: Int, height: Int)
	{
		destroyWindowSurface()
		if(surface == null || !surface.isValid) return
		val surfaceAttribs = if(hdr) intArrayOf(EGL_GL_COLORSPACE_KHR, EGL_GL_COLORSPACE_BT2020_PQ_EXT, EGL14.EGL_NONE)
			else intArrayOf(EGL14.EGL_NONE)
		windowSurface = EGL14.eglCreateWindowSurface(eglDisplay, eglConfig, surface, surfaceAttribs, 0)
		if(windowSurface == EGL14.EGL_NO_SURFACE)
		{
			Log.e(TAG, "eglCreateWindowSurface failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
			return
		}
		if(!EGL14.eglMakeCurrent(eglDisplay, windowSurface, windowSurface, eglContext))
		{
			Log.e(TAG, "eglMakeCurrent(window) failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
			destroyWindowSurface()
			return
		}
		EGL14.eglSwapInterval(eglDisplay, 1)
		val w = IntArray(1)
		val h = IntArray(1)
		EGL14.eglQuerySurface(eglDisplay, windowSurface, EGL14.EGL_WIDTH, w, 0)
		EGL14.eglQuerySurface(eglDisplay, windowSurface, EGL14.EGL_HEIGHT, h, 0)
		windowWidth = if(w[0] > 0) w[0] else width
		windowHeight = if(h[0] > 0) h[0] else height
		hdrMetadata?.let { applyHdrMetadata(it) }
		Log.i(TAG, "output surface ${windowWidth}x${windowHeight} (stream ${streamWidth}x${streamHeight}, upscale=$presentIsSgsr, framegen=$frameGenerationActive, hdr=$hdr)")
	}


	private fun initGl()
	{
		eglDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
		check(eglDisplay != EGL14.EGL_NO_DISPLAY) { "eglGetDisplay failed" }
		val version = IntArray(2)
		check(EGL14.eglInitialize(eglDisplay, version, 0, version, 1)) { "eglInitialize failed" }
		if(hdr)
		{
			val eglExtensions = EGL14.eglQueryString(eglDisplay, EGL14.EGL_EXTENSIONS) ?: ""
			check(eglExtensions.contains("EGL_EXT_gl_colorspace_bt2020_pq")) { "HDR needs EGL_EXT_gl_colorspace_bt2020_pq" }
			hdrMetadataSupported = eglExtensions.contains("EGL_EXT_surface_SMPTE2086_metadata")
				&& eglExtensions.contains("EGL_EXT_surface_CTA861_3_metadata")
			if(!hdrMetadataSupported) Log.w(TAG, "HDR static metadata extensions missing; compositor will use defaults")
		}
		// SDR: RGBA8. HDR: RGB10_A2, which Android maps to a RGBA_1010102 window buffer.
		eglConfig = chooseConfig(colorBits = if(hdr) 10 else 8, alphaBits = if(hdr) 2 else 8)
		eglContext = EGL14.eglCreateContext(eglDisplay, eglConfig, EGL14.EGL_NO_CONTEXT,
			intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
		check(eglContext != EGL14.EGL_NO_CONTEXT) { "eglCreateContext failed" }
		pbufferSurface = EGL14.eglCreatePbufferSurface(eglDisplay, eglConfig,
			intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
		check(pbufferSurface != EGL14.EGL_NO_SURFACE) { "eglCreatePbufferSurface failed" }
		check(EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)) { "eglMakeCurrent failed" }
		Log.i(TAG, "GL ${GLES31.glGetString(GLES31.GL_VERSION)} on ${GLES31.glGetString(GLES31.GL_RENDERER)}, hdr=$hdr")
		if(hdr)
		{
			val glExtensions = GLES31.glGetString(GLES31.GL_EXTENSIONS) ?: ""
			check(glExtensions.split(' ').contains("GL_EXT_YUV_target")) { "HDR needs GL_EXT_YUV_target" }
		}

		// Programs: the copy shader and the blit are mandatory; SGSR is built when first enabled and a
		// compile failure only means bilinear. Uniforms that never change are set once per program;
		// only the OES transform is per frame.
		oesCopyProgram = GlShaders.buildOesCopyProgram(hdr)
		GLES31.glUseProgram(oesCopyProgram)
		GLES31.glUniform1i(GLES31.glGetUniformLocation(oesCopyProgram, "uTex"), 0)
		oesTransformLoc = GLES31.glGetUniformLocation(oesCopyProgram, "uTransform")
		blitProgram = GlShaders.buildBlitProgram()
		setPresentUniforms(blitProgram, sgsr = false)
		presentProgram = blitProgram
		GLES31.glUseProgram(0)
		applyUpscaling(upscalingRequested)

		// Textures: external input, 2-slot ring, generated output (stream size, identical format: RGBA8,
		// or RGBA16F for PQ-encoded HDR; both are accepted by glExtrapolateTex2DQCOM).
		val ringFormat = if(hdr) GLES31.GL_RGBA16F else GLES31.GL_RGBA8
		val ids = IntArray(4)
		GLES31.glGenTextures(4, ids, 0)
		oesTexture = ids[0]
		ring[0] = ids[1]
		ring[1] = ids[2]
		generatedTexture = ids[3]
		GLES31.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture)
		setSamplerParams(GLES11Ext.GL_TEXTURE_EXTERNAL_OES)
		for(tex in intArrayOf(ring[0], ring[1], generatedTexture))
		{
			GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, tex)
			GLES31.glTexStorage2D(GLES31.GL_TEXTURE_2D, 1, ringFormat, streamWidth, streamHeight)
			setSamplerParams(GLES31.GL_TEXTURE_2D)
		}
		GLES31.glGenFramebuffers(2, ringFbo, 0)
		for(i in 0..1)
		{
			GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, ringFbo[i])
			GLES31.glFramebufferTexture2D(GLES31.GL_FRAMEBUFFER, GLES31.GL_COLOR_ATTACHMENT0, GLES31.GL_TEXTURE_2D, ring[i], 0)
			val status = GLES31.glCheckFramebufferStatus(GLES31.GL_FRAMEBUFFER)
			check(status == GLES31.GL_FRAMEBUFFER_COMPLETE) { "ring FBO $i incomplete: 0x${Integer.toHexString(status)}" }
		}
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)
		checkGlError("init")

		// Probed unconditionally so the in-stream toggle can switch generation on later.
		extrapolationSupported = AdrenoExt.nativeProbeFrameExtrapolation()
		applyFrameGeneration(frameGenerationRequested)

		val st = SurfaceTexture(oesTexture)
		st.setDefaultBufferSize(streamWidth, streamHeight)
		st.setOnFrameAvailableListener({ frameAvailable.set(true) }, handler)
		surfaceTexture = st
		inputSurface = Surface(st)
	}

	private fun setPresentUniforms(program: Int, sgsr: Boolean)
	{
		GLES31.glUseProgram(program)
		GLES31.glUniform1i(GLES31.glGetUniformLocation(program, "ps0"), 0)
		if(sgsr)
		{
			var loc = GLES31.glGetUniformLocation(program, "ViewportInfo")
			if(loc < 0) loc = GLES31.glGetUniformLocation(program, "ViewportInfo[0]")
			GLES31.glUniform4f(loc, 1f / streamWidth, 1f / streamHeight, streamWidth.toFloat(), streamHeight.toFloat())
		}
		GLES31.glUseProgram(0)
	}

	/** Render thread. Selects SGSR (building it on first use) or the blit for subsequent presents. */
	private fun applyUpscaling(enabled: Boolean)
	{
		if(enabled && sgsrProgram == 0 && !sgsrFailed)
		{
			try
			{
				sgsrProgram = GlShaders.buildSgsr1Program(assets, tuning.sgsrEdgeSharpness, tuning.sgsrEdgeThreshold255, tuning.sgsrEdgeDirection)
				setPresentUniforms(sgsrProgram, sgsr = true)
			}
			catch(e: ShaderCompileException)
			{
				sgsrFailed = true
				Log.w(TAG, "SGSR1 unavailable, using bilinear blit: ${e.message}")
			}
		}
		presentIsSgsr = enabled && sgsrProgram != 0
		presentProgram = if(presentIsSgsr) sgsrProgram else blitProgram
		Log.i(TAG, "upscaling ${if(presentIsSgsr) "SGSR1" else "bilinear"} (requested=$enabled)")
	}

	/**
	 * Render thread. Enables generation if the hardware allows: interpolation when selected and the
	 * motion estimator is available (set up on first use), otherwise extrapolation when supported.
	 */
	private fun applyFrameGeneration(enabled: Boolean)
	{
		if(enabled && tuning.generationMode == GenerationMode.INTERPOLATE && !interpolationActive && !interpolationTried)
		{
			interpolationTried = true
			interpolationActive = AdrenoExt.nativeProbeMotionEstimation() && setupInterpolation()
			if(!interpolationActive)
				Log.w(TAG, "interpolation unavailable, falling back to extrapolation (supported=$extrapolationSupported)")
		}
		frameGenerationActive = enabled && (interpolationActive || extrapolationSupported)
		pacer.frameGenerationEnabled = frameGenerationActive
		pacer.generationMode = if(interpolationActive) GenerationMode.INTERPOLATE else GenerationMode.EXTRAPOLATE
		Log.i(TAG, "frame generation active=$frameGenerationActive (extrapolation supported=$extrapolationSupported, interpolation=$interpolationActive) requested=$enabled, tuning=$tuning")
	}

	/**
	 * Allocates everything interpolation needs. The estimator wants R8 inputs whose size is a multiple
	 * of its search block, so the luma textures are rounded up and the motion fields are block-sized.
	 * Returns false (after logging) if the block size query fails; GL objects created so far are
	 * released with everything else in [releaseGl].
	 */
	private fun setupInterpolation(): Boolean
	{
		val block = IntArray(2)
		GLES31.glGetIntegerv(GL_MOTION_ESTIMATION_SEARCH_BLOCK_X_QCOM, block, 0)
		GLES31.glGetIntegerv(GL_MOTION_ESTIMATION_SEARCH_BLOCK_Y_QCOM, block, 1)
		if(block[0] <= 0 || block[1] <= 0)
		{
			Log.w(TAG, "motion estimation block size query failed: ${block[0]}x${block[1]}")
			return false
		}
		lumaWidth = (streamWidth + block[0] - 1) / block[0] * block[0]
		lumaHeight = (streamHeight + block[1] - 1) / block[1] * block[1]
		val fieldWidth = lumaWidth / block[0]
		val fieldHeight = lumaHeight / block[1]
		val scaleX = streamWidth.toFloat() / lumaWidth
		val scaleY = streamHeight.toFloat() / lumaHeight

		lumaProgram = GlShaders.buildLumaProgram()
		warpProgram = GlShaders.buildWarpProgram()
		GLES31.glUseProgram(lumaProgram)
		GLES31.glUniform1i(GLES31.glGetUniformLocation(lumaProgram, "ps0"), 0)
		GLES31.glUniform2f(GLES31.glGetUniformLocation(lumaProgram, "uScale"), scaleX, scaleY)
		GLES31.glUseProgram(warpProgram)
		GLES31.glUniform1i(GLES31.glGetUniformLocation(warpProgram, "uTexA"), 0)
		GLES31.glUniform1i(GLES31.glGetUniformLocation(warpProgram, "uTexB"), 1)
		GLES31.glUniform1i(GLES31.glGetUniformLocation(warpProgram, "uMvAB"), 2)
		GLES31.glUniform1i(GLES31.glGetUniformLocation(warpProgram, "uMvBA"), 3)
		GLES31.glUniform2f(GLES31.glGetUniformLocation(warpProgram, "uTexel"), 1f / streamWidth, 1f / streamHeight)
		GLES31.glUniform2f(GLES31.glGetUniformLocation(warpProgram, "uMvUvScale"), scaleX, scaleY)
		GLES31.glUseProgram(0)

		val ids = IntArray(4)
		GLES31.glGenTextures(4, ids, 0)
		lumaTex[0] = ids[0]
		lumaTex[1] = ids[1]
		mvTexAB = ids[2]
		mvTexBA = ids[3]
		for(tex in lumaTex)
		{
			GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, tex)
			GLES31.glTexStorage2D(GLES31.GL_TEXTURE_2D, 1, GLES31.GL_R8, lumaWidth, lumaHeight)
			setSamplerParams(GLES31.GL_TEXTURE_2D)
		}
		for(tex in intArrayOf(mvTexAB, mvTexBA))
		{
			GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, tex)
			GLES31.glTexStorage2D(GLES31.GL_TEXTURE_2D, 1, GLES31.GL_RGBA16F, fieldWidth, fieldHeight)
			setSamplerParams(GLES31.GL_TEXTURE_2D)
		}
		val fbos = IntArray(3)
		GLES31.glGenFramebuffers(3, fbos, 0)
		lumaFbo[0] = fbos[0]
		lumaFbo[1] = fbos[1]
		generatedFbo = fbos[2]
		for((fbo, tex) in listOf(lumaFbo[0] to lumaTex[0], lumaFbo[1] to lumaTex[1], generatedFbo to generatedTexture))
		{
			GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, fbo)
			GLES31.glFramebufferTexture2D(GLES31.GL_FRAMEBUFFER, GLES31.GL_COLOR_ATTACHMENT0, GLES31.GL_TEXTURE_2D, tex, 0)
			val status = GLES31.glCheckFramebufferStatus(GLES31.GL_FRAMEBUFFER)
			check(status == GLES31.GL_FRAMEBUFFER_COMPLETE) { "interpolation FBO incomplete: 0x${Integer.toHexString(status)}" }
		}
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)
		checkGlError("interpolation init")
		// When enabled mid-stream the ring already holds frames whose luma was never rendered.
		renderLuma(0)
		renderLuma(1)
		Log.i(TAG, "interpolation: search block ${block[0]}x${block[1]}, luma ${lumaWidth}x${lumaHeight}, motion field ${fieldWidth}x${fieldHeight}")
		return true
	}

	/**
	 * Picks an ES3 window+pbuffer config with exactly [colorBits] per colour channel. eglChooseConfig
	 * sorts deeper colour buffers first, so an exact match is enforced here rather than taking its first result.
	 */
	private fun chooseConfig(colorBits: Int, alphaBits: Int): EGLConfig
	{
		val attribs = intArrayOf(
			EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
			EGL14.EGL_SURFACE_TYPE, EGL14.EGL_WINDOW_BIT or EGL14.EGL_PBUFFER_BIT,
			EGL14.EGL_RED_SIZE, colorBits, EGL14.EGL_GREEN_SIZE, colorBits, EGL14.EGL_BLUE_SIZE, colorBits, EGL14.EGL_ALPHA_SIZE, alphaBits,
			EGL14.EGL_NONE)
		val configs = arrayOfNulls<EGLConfig>(MAX_CONFIGS)
		val num = IntArray(1)
		check(EGL14.eglChooseConfig(eglDisplay, attribs, 0, configs, 0, MAX_CONFIGS, num, 0) && num[0] > 0) { "no ES3 EGL config with $colorBits-bit colour" }
		val value = IntArray(1)
		for(i in 0 until num[0])
		{
			val config = configs[i] ?: continue
			EGL14.eglGetConfigAttrib(eglDisplay, config, EGL14.EGL_RED_SIZE, value, 0)
			if(value[0] != colorBits) continue
			EGL14.eglGetConfigAttrib(eglDisplay, config, EGL14.EGL_ALPHA_SIZE, value, 0)
			if(value[0] == alphaBits) return config
		}
		throw IllegalStateException("no EGL config with exactly R${colorBits}G${colorBits}B${colorBits}A$alphaBits")
	}

	private fun setSamplerParams(target: Int)
	{
		GLES31.glTexParameteri(target, GLES31.GL_TEXTURE_MIN_FILTER, GLES31.GL_LINEAR)
		GLES31.glTexParameteri(target, GLES31.GL_TEXTURE_MAG_FILTER, GLES31.GL_LINEAR)
		GLES31.glTexParameteri(target, GLES31.GL_TEXTURE_WRAP_S, GLES31.GL_CLAMP_TO_EDGE)
		GLES31.glTexParameteri(target, GLES31.GL_TEXTURE_WRAP_T, GLES31.GL_CLAMP_TO_EDGE)
	}

	private fun onVsync(frameTimeNanos: Long)
	{
		if(stopped) return
		val st = surfaceTexture ?: return
		// Peek only: the pacer may hold an early real frame for one vsync (PRESENT_GENERATED while a
		// frame is pending), so the flag is cleared only when the frame is actually consumed.
		val newFrame = frameAvailable.get()
		when(pacer.decide(frameTimeNanos, newFrame))
		{
			PaceDecision.PRESENT_REAL ->
			{
				if(!latchNewFrame(st)) return
				recordLatency(frameTimeNanos, st.timestamp)
				present(ring[newestSlot])
			}
			PaceDecision.PRESENT_GENERATED ->
			{
				// Without a window surface the extrapolation would be wasted GPU work; the pacer's
				// bookkeeping is the same either way.
				if(windowSurface != EGL14.EGL_NO_SURFACE)
				{
					AdrenoExt.nativeExtrapolateTex2D(ring[1 - newestSlot], ring[newestSlot], generatedTexture, tuning.extrapolationScale)
					checkGlError("extrapolate")
					if(present(generatedTexture))
						generatedInWindow++
				}
			}
			PaceDecision.PRESENT_INTERPOLATED ->
			{
				if(!latchNewFrame(st)) return
				heldTimestampNs = st.timestamp
				if(windowSurface != EGL14.EGL_NO_SURFACE)
				{
					interpolate()
					if(present(generatedTexture))
						generatedInWindow++
				}
			}
			PaceDecision.PRESENT_HELD_REAL ->
			{
				recordLatency(frameTimeNanos, heldTimestampNs)
				present(ring[newestSlot])
			}
			PaceDecision.SKIP -> {}
		}
		updateStats(frameTimeNanos)
	}

	/**
	 * Consumes the pending decoder frame into the next ring slot (plus its luma when interpolating).
	 * Returns false when the decoder side is gone, which ends the GPU path for this session.
	 */
	private fun latchNewFrame(st: SurfaceTexture): Boolean
	{
		frameAvailable.set(false)
		try
		{
			st.updateTexImage()
		}
		catch(e: RuntimeException)
		{
			// The pacer has already recorded this frame, so reset it rather than let a later vsync
			// generate from a stale pair.
			Log.w(TAG, "updateTexImage failed, stopping GPU path: ${e.message}")
			pacer.reset()
			presentedFps = 0.0
			generatedFps = 0.0
			latencyMs = 0.0
			stopped = true
			return false
		}
		st.getTransformMatrix(transform)
		newestSlot = 1 - newestSlot
		copyOesToSlot(newestSlot)
		if(interpolationActive) renderLuma(newestSlot)
		return true
	}

	private fun renderLuma(slot: Int)
	{
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, lumaFbo[slot])
		GLES31.glViewport(0, 0, lumaWidth, lumaHeight)
		GLES31.glUseProgram(lumaProgram)
		GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
		GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, ring[slot])
		GLES31.glDrawArrays(GLES31.GL_TRIANGLES, 0, 3)
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)
		checkGlError("luma")
	}

	/** Estimates motion both ways between the two ring slots and warps their midpoint into [generatedTexture]. */
	private fun interpolate()
	{
		val older = 1 - newestSlot
		AdrenoExt.nativeEstimateMotion(lumaTex[older], lumaTex[newestSlot], mvTexAB)
		AdrenoExt.nativeEstimateMotion(lumaTex[newestSlot], lumaTex[older], mvTexBA)
		checkGlError("motion estimation")
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, generatedFbo)
		GLES31.glViewport(0, 0, streamWidth, streamHeight)
		GLES31.glUseProgram(warpProgram)
		for((unit, tex) in listOf(ring[older], ring[newestSlot], mvTexAB, mvTexBA).withIndex())
		{
			GLES31.glActiveTexture(GLES31.GL_TEXTURE0 + unit)
			GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, tex)
		}
		GLES31.glDrawArrays(GLES31.GL_TRIANGLES, 0, 3)
		GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)
		checkGlError("warp")
	}

	private fun copyOesToSlot(slot: Int)
	{
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, ringFbo[slot])
		GLES31.glViewport(0, 0, streamWidth, streamHeight)
		GLES31.glUseProgram(oesCopyProgram)
		GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
		GLES31.glBindTexture(GLES11Ext.GL_TEXTURE_EXTERNAL_OES, oesTexture)
		GLES31.glUniformMatrix4fv(oesTransformLoc, 1, false, transform, 0)
		GLES31.glDrawArrays(GLES31.GL_TRIANGLES, 0, 3)
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)
		checkGlError("copy")
	}

	/**
	 * Draws [sourceTexture] to the window surface and swaps. Returns false when there is no window
	 * surface or the swap failed. A failed swap means the surface is gone (or about to be); it is
	 * destroyed so this logs once instead of at vsync rate, and the next [setOutputSurface] recreates it.
	 */
	private fun present(sourceTexture: Int): Boolean
	{
		if(windowSurface == EGL14.EGL_NO_SURFACE) return false
		GLES31.glBindFramebuffer(GLES31.GL_FRAMEBUFFER, 0)
		GLES31.glViewport(0, 0, windowWidth, windowHeight)
		GLES31.glUseProgram(presentProgram)
		GLES31.glActiveTexture(GLES31.GL_TEXTURE0)
		GLES31.glBindTexture(GLES31.GL_TEXTURE_2D, sourceTexture)
		GLES31.glDrawArrays(GLES31.GL_TRIANGLES, 0, 3)
		checkGlError("present")
		if(!EGL14.eglSwapBuffers(eglDisplay, windowSurface))
		{
			Log.w(TAG, "eglSwapBuffers failed: 0x${Integer.toHexString(EGL14.eglGetError())}, dropping window surface")
			destroyWindowSurface()
			return false
		}
		presentedInWindow++
		return true
	}

	/** Polls the decoder for HDR metadata until it has some, then attaches it to the window surface. */
	private fun pollHdrMetadata()
	{
		if(!hdr || !hdrMetadataSupported || hdrMetadata != null) return
		val provider = hdrMetadataProvider ?: return
		val info = HdrStaticInfo.parse(provider()) ?: return
		if(info.isEmpty) return
		hdrMetadata = info
		Log.i(TAG, "HDR static metadata: mastering ${info.maxLuminance}/${info.minLuminance} nits, MaxCLL ${info.maxContentLightLevel}, MaxFALL ${info.maxFrameAverageLightLevel}")
		if(windowSurface != EGL14.EGL_NO_SURFACE) applyHdrMetadata(info)
	}

	private fun applyHdrMetadata(info: HdrStaticInfo)
	{
		fun scaled(v: Float) = (v * EGL_METADATA_SCALING_EXT).toLong().coerceIn(0L, Int.MAX_VALUE.toLong()).toInt()
		val attribs = listOf(
			EGL_SMPTE2086_DISPLAY_PRIMARY_RX_EXT to info.redX, EGL_SMPTE2086_DISPLAY_PRIMARY_RY_EXT to info.redY,
			EGL_SMPTE2086_DISPLAY_PRIMARY_GX_EXT to info.greenX, EGL_SMPTE2086_DISPLAY_PRIMARY_GY_EXT to info.greenY,
			EGL_SMPTE2086_DISPLAY_PRIMARY_BX_EXT to info.blueX, EGL_SMPTE2086_DISPLAY_PRIMARY_BY_EXT to info.blueY,
			EGL_SMPTE2086_WHITE_POINT_X_EXT to info.whiteX, EGL_SMPTE2086_WHITE_POINT_Y_EXT to info.whiteY,
			EGL_SMPTE2086_MAX_LUMINANCE_EXT to info.maxLuminance, EGL_SMPTE2086_MIN_LUMINANCE_EXT to info.minLuminance,
			EGL_CTA861_3_MAX_CONTENT_LIGHT_LEVEL_EXT to info.maxContentLightLevel,
			EGL_CTA861_3_MAX_FRAME_AVERAGE_LEVEL_EXT to info.maxFrameAverageLightLevel)
		for((attrib, value) in attribs)
		{
			if(!EGL14.eglSurfaceAttrib(eglDisplay, windowSurface, attrib, scaled(value)))
			{
				Log.w(TAG, "eglSurfaceAttrib(0x${Integer.toHexString(attrib)}) failed: 0x${Integer.toHexString(EGL14.eglGetError())}")
				return
			}
		}
		Log.i(TAG, "HDR static metadata attached to the window surface")
	}

	/** [decoderTimestampNs] is the native input timestamp (CLOCK_MONOTONIC) MediaCodec carried through; 0 if unknown. */
	private fun recordLatency(vsyncNs: Long, decoderTimestampNs: Long)
	{
		if(decoderTimestampNs <= 0L) return
		val age = vsyncNs - decoderTimestampNs
		// Ignore nonsense (clock mismatch or a decoder that rewrites timestamps) rather than skew the mean.
		if(age < 0L || age > 1_000_000_000L) return
		latencySumNs += age
		latencyCount++
	}

	private fun updateStats(nowNs: Long)
	{
		if(windowStartNs == Long.MIN_VALUE)
		{
			windowStartNs = nowNs
			return
		}
		val elapsed = nowNs - windowStartNs
		if(elapsed >= STATS_WINDOW_NS)
		{
			pollHdrMetadata()
			presentedFps = presentedInWindow * 1e9 / elapsed
			generatedFps = generatedInWindow * 1e9 / elapsed
			latencyMs = if(latencyCount > 0) latencySumNs / latencyCount / 1e6 else 0.0
			presentedInWindow = 0
			generatedInWindow = 0
			latencySumNs = 0L
			latencyCount = 0
			windowStartNs = nowNs
		}
	}

	private fun checkGlError(where: String)
	{
		val err = GLES31.glGetError()
		if(err != GLES31.GL_NO_ERROR && loggedGlErrors.add("$where:$err"))
			Log.w(TAG, "GL error 0x${Integer.toHexString(err)} in $where (logged once per site)")
	}

	private fun destroyWindowSurface()
	{
		if(windowSurface != EGL14.EGL_NO_SURFACE)
		{
			EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext)
			EGL14.eglDestroySurface(eglDisplay, windowSurface)
			windowSurface = EGL14.EGL_NO_SURFACE
		}
	}

	/** Tolerates partially initialised state so that a failed [initGl] still cleans up whatever it created. */
	private fun releaseGl()
	{
		surfaceTexture?.release()
		surfaceTexture = null
		if(this::inputSurface.isInitialized) inputSurface.release()
		if(eglDisplay == EGL14.EGL_NO_DISPLAY) return
		destroyWindowSurface()
		if(eglContext != EGL14.EGL_NO_CONTEXT && pbufferSurface != EGL14.EGL_NO_SURFACE
			&& EGL14.eglMakeCurrent(eglDisplay, pbufferSurface, pbufferSurface, eglContext))
		{
			// Names of 0 are silently ignored by glDelete*, so unset objects need no guard.
			GLES31.glDeleteProgram(oesCopyProgram)
			GLES31.glDeleteProgram(blitProgram)
			GLES31.glDeleteProgram(sgsrProgram)
			GLES31.glDeleteProgram(lumaProgram)
			GLES31.glDeleteProgram(warpProgram)
			GLES31.glDeleteFramebuffers(2, ringFbo, 0)
			GLES31.glDeleteFramebuffers(3, intArrayOf(lumaFbo[0], lumaFbo[1], generatedFbo), 0)
			GLES31.glDeleteTextures(8, intArrayOf(oesTexture, ring[0], ring[1], generatedTexture, lumaTex[0], lumaTex[1], mvTexAB, mvTexBA), 0)
		}
		EGL14.eglMakeCurrent(eglDisplay, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
		if(pbufferSurface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(eglDisplay, pbufferSurface)
		if(eglContext != EGL14.EGL_NO_CONTEXT) EGL14.eglDestroyContext(eglDisplay, eglContext)
		EGL14.eglTerminate(eglDisplay)
		pbufferSurface = EGL14.EGL_NO_SURFACE
		eglContext = EGL14.EGL_NO_CONTEXT
		eglConfig = null
		eglDisplay = EGL14.EGL_NO_DISPLAY
		Log.i(TAG, "released")
	}
}
