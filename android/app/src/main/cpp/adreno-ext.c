// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// JNI shim for the Qualcomm Adreno Frame Motion Engine, exposed to OpenGL ES as
// GL_QCOM_frame_extrapolation (Khronos OpenGL ES extension #333) and for the block motion
// estimator GL_QCOM_motion_estimation (#326). All functions must be called on a thread with
// an ES 3.x context current.

#include <jni.h>
#include <stdatomic.h>
#include <string.h>
#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <android/log.h>

#define LOG_TAG "AdrenoExt"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)

#define ADRENO_JNI(name) Java_com_metallic_chiaki_stream_gpu_AdrenoExt_##name

typedef void (GL_APIENTRYP PFNGLEXTRAPOLATETEX2DQCOMPROC)(GLuint src1, GLuint src2, GLuint output, GLfloat scaleFactor);
typedef void (GL_APIENTRYP PFNGLTEXESTIMATEMOTIONQCOMPROC)(GLuint ref, GLuint target, GLuint output);

// The renderer must run the probe on its own context before calling nativeExtrapolateTex2D;
// the settings-screen probe only informs the UI.
static _Atomic(PFNGLEXTRAPOLATETEX2DQCOMPROC) s_extrapolate = NULL;
static _Atomic(PFNGLTEXESTIMATEMOTIONQCOMPROC) s_estimate_motion = NULL;

static const char *renderer_name(void)
{
	const char *name = (const char *)glGetString(GL_RENDERER);
	return name ? name : "?";
}

static int gl_has_extension(const char *name)
{
	GLint count = 0;
	glGetIntegerv(GL_NUM_EXTENSIONS, &count);
	for(GLint i = 0; i < count; i++)
	{
		const char *ext = (const char *)glGetStringi(GL_EXTENSIONS, (GLuint)i);
		if(ext && strcmp(ext, name) == 0)
			return 1;
	}
	return 0;
}

JNIEXPORT jboolean JNICALL ADRENO_JNI(nativeProbeFrameExtrapolation)(JNIEnv *env, jclass cls)
{
	(void)env; (void)cls;
	if(eglGetCurrentContext() == EGL_NO_CONTEXT)
	{
		LOGW("probe called without a current EGL context");
		return JNI_FALSE;
	}
	if(!gl_has_extension("GL_QCOM_frame_extrapolation"))
	{
		atomic_store_explicit(&s_extrapolate, NULL, memory_order_release);
		LOGI("GL_QCOM_frame_extrapolation not advertised by driver (renderer: %s)", renderer_name());
		return JNI_FALSE;
	}
	PFNGLEXTRAPOLATETEX2DQCOMPROC fn = (PFNGLEXTRAPOLATETEX2DQCOMPROC)eglGetProcAddress("glExtrapolateTex2DQCOM");
	atomic_store_explicit(&s_extrapolate, fn, memory_order_release);
	LOGI("GL_QCOM_frame_extrapolation supported=%d (renderer: %s)", fn != NULL, renderer_name());
	return fn != NULL ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL ADRENO_JNI(nativeExtrapolateTex2D)(JNIEnv *env, jclass cls, jint src1, jint src2, jint output, jfloat scale)
{
	(void)env; (void)cls;
	PFNGLEXTRAPOLATETEX2DQCOMPROC fn = atomic_load_explicit(&s_extrapolate, memory_order_acquire);
	if(!fn)
		return;
	fn((GLuint)src1, (GLuint)src2, (GLuint)output, scale);
}

JNIEXPORT jboolean JNICALL ADRENO_JNI(nativeProbeMotionEstimation)(JNIEnv *env, jclass cls)
{
	(void)env; (void)cls;
	if(eglGetCurrentContext() == EGL_NO_CONTEXT)
	{
		LOGW("motion estimation probe called without a current EGL context");
		return JNI_FALSE;
	}
	if(!gl_has_extension("GL_QCOM_motion_estimation"))
	{
		atomic_store_explicit(&s_estimate_motion, NULL, memory_order_release);
		LOGI("GL_QCOM_motion_estimation not advertised by driver (renderer: %s)", renderer_name());
		return JNI_FALSE;
	}
	PFNGLTEXESTIMATEMOTIONQCOMPROC fn = (PFNGLTEXESTIMATEMOTIONQCOMPROC)eglGetProcAddress("glTexEstimateMotionQCOM");
	atomic_store_explicit(&s_estimate_motion, fn, memory_order_release);
	LOGI("GL_QCOM_motion_estimation supported=%d (renderer: %s)", fn != NULL, renderer_name());
	return fn != NULL ? JNI_TRUE : JNI_FALSE;
}

// ref and target: GL_R8 textures of identical size, multiples of the search block; output: RGBA16F of
// size (w / block_x, h / block_y) receiving per-block motion from ref to target in pixels (R = x, G = y).
JNIEXPORT void JNICALL ADRENO_JNI(nativeEstimateMotion)(JNIEnv *env, jclass cls, jint ref, jint target, jint output)
{
	(void)env; (void)cls;
	PFNGLTEXESTIMATEMOTIONQCOMPROC fn = atomic_load_explicit(&s_estimate_motion, memory_order_acquire);
	if(!fn)
		return;
	fn((GLuint)ref, (GLuint)target, (GLuint)output);
}
