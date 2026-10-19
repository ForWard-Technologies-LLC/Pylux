// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

package com.metallic.chiaki.stream.gpu

import android.opengl.EGL14
import android.opengl.EGLConfig
import android.opengl.EGLContext
import android.opengl.EGLDisplay
import android.opengl.EGLExt
import android.opengl.EGLSurface
import android.util.Log

/**
 * Bindings for the Adreno Frame Motion Engine (GL_QCOM_frame_extrapolation) and the block motion
 * estimator (GL_QCOM_motion_estimation). All native functions require a current GL context.
 */
object AdrenoExt
{
	private const val TAG = "AdrenoExt"

	init
	{
		System.loadLibrary("chiaki-jni")
	}

	@JvmStatic external fun nativeProbeFrameExtrapolation(): Boolean
	@JvmStatic external fun nativeExtrapolateTex2D(src1: Int, src2: Int, output: Int, scale: Float)
	@JvmStatic external fun nativeProbeMotionEstimation(): Boolean
	/** Writes per-block motion from [ref] to [target] (R8 textures) into [output] (RGBA16F, block resolution). */
	@JvmStatic external fun nativeEstimateMotion(ref: Int, target: Int, output: Int)

	@Volatile private var cachedSupport: Boolean? = null
	@Volatile private var cachedMotionSupport: Boolean? = null

	/**
	 * Probes on the calling thread's current context if there is one, otherwise on a
	 * throwaway 1x1 pbuffer context. Safe to call from any thread without a GL context
	 * (e.g. the settings screen). Result is cached per process.
	 */
	fun isFrameExtrapolationSupported(): Boolean
	{
		cachedSupport?.let { return it }
		val result = try { probeOnPbuffer { nativeProbeFrameExtrapolation() } } catch(e: Exception) { Log.w(TAG, "probe failed", e); false }
		cachedSupport = result
		return result
	}

	/** Same contract as [isFrameExtrapolationSupported], for GL_QCOM_motion_estimation (interpolation mode). */
	fun isMotionEstimationSupported(): Boolean
	{
		cachedMotionSupport?.let { return it }
		val result = try { probeOnPbuffer { nativeProbeMotionEstimation() } } catch(e: Exception) { Log.w(TAG, "probe failed", e); false }
		cachedMotionSupport = result
		return result
	}

	private fun eglErrorHex(): String = "0x${Integer.toHexString(EGL14.eglGetError())}"

	private fun probeOnPbuffer(probe: () -> Boolean): Boolean
	{
		if(EGL14.eglGetCurrentContext() != EGL14.EGL_NO_CONTEXT)
			return probe()

		val display: EGLDisplay = EGL14.eglGetDisplay(EGL14.EGL_DEFAULT_DISPLAY)
		if(display == EGL14.EGL_NO_DISPLAY)
		{
			Log.w(TAG, "eglGetDisplay failed: ${eglErrorHex()}")
			return false
		}
		val version = IntArray(2)
		if(!EGL14.eglInitialize(display, version, 0, version, 1))
		{
			Log.w(TAG, "eglInitialize failed: ${eglErrorHex()}")
			return false
		}
		try
		{
			val configAttribs = intArrayOf(
				EGL14.EGL_RENDERABLE_TYPE, EGLExt.EGL_OPENGL_ES3_BIT_KHR,
				EGL14.EGL_SURFACE_TYPE, EGL14.EGL_PBUFFER_BIT,
				EGL14.EGL_RED_SIZE, 8, EGL14.EGL_GREEN_SIZE, 8, EGL14.EGL_BLUE_SIZE, 8,
				EGL14.EGL_NONE)
			val configs = arrayOfNulls<EGLConfig>(1)
			val numConfigs = IntArray(1)
			if(!EGL14.eglChooseConfig(display, configAttribs, 0, configs, 0, 1, numConfigs, 0) || numConfigs[0] == 0)
			{
				Log.w(TAG, "eglChooseConfig failed: ${eglErrorHex()}")
				return false
			}
			val config = configs[0]
			if(config == null)
			{
				Log.w(TAG, "eglChooseConfig returned no config: ${eglErrorHex()}")
				return false
			}
			val context: EGLContext = EGL14.eglCreateContext(display, config, EGL14.EGL_NO_CONTEXT,
				intArrayOf(EGL14.EGL_CONTEXT_CLIENT_VERSION, 3, EGL14.EGL_NONE), 0)
			if(context == EGL14.EGL_NO_CONTEXT)
			{
				Log.w(TAG, "eglCreateContext failed: ${eglErrorHex()}")
				return false
			}
			val surface: EGLSurface = EGL14.eglCreatePbufferSurface(display, config,
				intArrayOf(EGL14.EGL_WIDTH, 1, EGL14.EGL_HEIGHT, 1, EGL14.EGL_NONE), 0)
			try
			{
				if(surface == EGL14.EGL_NO_SURFACE)
				{
					Log.w(TAG, "eglCreatePbufferSurface failed: ${eglErrorHex()}")
					return false
				}
				if(!EGL14.eglMakeCurrent(display, surface, surface, context))
				{
					Log.w(TAG, "eglMakeCurrent failed: ${eglErrorHex()}")
					return false
				}
				return probe()
			}
			finally
			{
				EGL14.eglMakeCurrent(display, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_SURFACE, EGL14.EGL_NO_CONTEXT)
				if(surface != EGL14.EGL_NO_SURFACE) EGL14.eglDestroySurface(display, surface)
				EGL14.eglDestroyContext(display, context)
			}
		}
		finally
		{
			EGL14.eglTerminate(display)
		}
	}
}
