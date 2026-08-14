// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "video-decoder.h"

#include <jni.h>

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <android/native_window_jni.h>

#include <string.h>

#define INPUT_BUFFER_TIMEOUT_MS 10

static void *android_chiaki_video_decoder_output_thread_func(void *user);

ChiakiErrorCode android_chiaki_video_decoder_init(AndroidChiakiVideoDecoder *decoder, ChiakiLog *log, int32_t target_width, int32_t target_height, ChiakiCodec codec)
{
	decoder->log = log;
	decoder->codec = NULL;
	decoder->timestamp_cur = 0;
	decoder->target_width = target_width;
	decoder->target_height = target_height;
	decoder->target_codec = codec;
	decoder->shutdown_output = false;
	ChiakiErrorCode err = chiaki_mutex_init(&decoder->codec_mutex, false);
	if(err != CHIAKI_ERR_SUCCESS)
		return err;
	err = chiaki_cond_init(&decoder->teardown_cond);
	if(err != CHIAKI_ERR_SUCCESS)
		chiaki_mutex_fini(&decoder->codec_mutex);
	return err;
}

// Shuts the codec down and reaps the output thread. Caller must hold codec_mutex; returns
// with codec_mutex held again (it is dropped around the join so the output thread can finish).
//
// This used to take codec_mutex itself, which self-deadlocked when called from
// set_surface() (which already holds it — codec_mutex is non-recursive); that hang on the
// UI thread is the "chiaki_mutex_lock / Input dispatching timed out" ANR in Play vitals.
// It also only joined the output thread on the EOS path: on the fallback path it deleted
// the codec (and reset shutdown_output) while the output thread was still blocked inside
// AMediaCodec_dequeueOutputBuffer on that same codec — a use-after-free in MediaCodec's
// state machine, consistent with the libc.so abort cluster
// (MediaCodec.cpp CHECK(mActivityNotify == NULL) failed). The join now happens on every
// path, strictly before AMediaCodec_delete.
static void kill_decoder(AndroidChiakiVideoDecoder *decoder)
{
	decoder->shutdown_output = true;
	ssize_t codec_buf_index = AMediaCodec_dequeueInputBuffer(decoder->codec, 1000);
	if(codec_buf_index >= 0)
	{
		CHIAKI_LOGI(decoder->log, "Video Decoder sending EOS buffer");
		AMediaCodec_queueInputBuffer(decoder->codec, (size_t)codec_buf_index, 0, 0, decoder->timestamp_cur++, AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
	}
	else
		CHIAKI_LOGE(decoder->log, "Failed to get input buffer for shutting down Video Decoder!");
	// Stopping the codec forces the output thread's blocking dequeue to return an error, at
	// which point it observes shutdown_output and exits; when the EOS buffer above was
	// queued it instead drains and exits on the EOS flag.
	AMediaCodec_stop(decoder->codec);
	chiaki_mutex_unlock(&decoder->codec_mutex);
	chiaki_thread_join(&decoder->output_thread, NULL);
	chiaki_mutex_lock(&decoder->codec_mutex);
	AMediaCodec_delete(decoder->codec);
	decoder->codec = NULL;
	if(decoder->window)
	{
		// The old code never released the window here; the next set_surface overwrote the
		// pointer, leaking one ANativeWindow ref per surface teardown cycle.
		ANativeWindow_release(decoder->window);
		decoder->window = NULL;
	}
	decoder->shutdown_output = false;
	// Wake anyone parked in the teardown_cond wait loops (fini / set_surface) so they can
	// re-examine state now that this teardown is fully finished.
	chiaki_cond_broadcast(&decoder->teardown_cond);
}

void android_chiaki_video_decoder_fini(AndroidChiakiVideoDecoder *decoder)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	// shutdown_output doubles as a "kill in progress" marker: kill_decoder drops the mutex
	// around its join. Waiting (rather than skipping) matters specifically here — skipping
	// would let this function destroy codec_mutex while the in-flight kill_decoder is about
	// to relock it, and then the caller frees the whole decoder under it.
	while(decoder->shutdown_output)
		chiaki_cond_wait(&decoder->teardown_cond, &decoder->codec_mutex);
	if(decoder->codec)
		kill_decoder(decoder);
	chiaki_mutex_unlock(&decoder->codec_mutex);
	chiaki_cond_fini(&decoder->teardown_cond);
	chiaki_mutex_fini(&decoder->codec_mutex);
}

void android_chiaki_video_decoder_set_surface(AndroidChiakiVideoDecoder *decoder, JNIEnv *env, jobject surface)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	// If a teardown is in flight (kill_decoder drops the mutex around its join), wait for it
	// to finish before acting on codec state — entering it twice would double-join the
	// output thread, and swapping the surface mid-teardown would operate on a dying codec.
	while(decoder->shutdown_output)
		chiaki_cond_wait(&decoder->teardown_cond, &decoder->codec_mutex);

	if(!surface)
	{
		if(decoder->codec)
		{
			kill_decoder(decoder);
			CHIAKI_LOGI(decoder->log, "Decoder shut down after surface was removed");
		}
		// goto, not return: this used to return while still holding codec_mutex, so even
		// when the kill_decoder deadlock didn't bite, every later decode call blocked forever.
		goto beach;
	}

	if(decoder->codec)
	{
#if __ANDROID_API__ >= 23
		CHIAKI_LOGI(decoder->log, "Video decoder already initialized, swapping surface");
		ANativeWindow *new_window = surface ? ANativeWindow_fromSurface(env, surface) : NULL;
		AMediaCodec_setOutputSurface(decoder->codec, new_window);
		ANativeWindow_release(decoder->window);
		decoder->window = new_window;
#else
		CHIAKI_LOGE(decoder->log, "Video Decoder already initialized");
#endif
		goto beach;
	}

	decoder->window = ANativeWindow_fromSurface(env, surface);

	const char *mime = chiaki_codec_is_h265(decoder->target_codec) ? "video/hevc" : "video/avc";
	CHIAKI_LOGI(decoder->log, "Initializing decoder with mime %s", mime);

	decoder->codec = AMediaCodec_createDecoderByType(mime);
	if(!decoder->codec)
	{
		CHIAKI_LOGE(decoder->log, "Failed to create AMediaCodec for mime type %s", mime);
		goto error_surface;
	}

	AMediaFormat *format = AMediaFormat_new();
	AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_WIDTH, decoder->target_width);
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_HEIGHT, decoder->target_height);

	media_status_t r = AMediaCodec_configure(decoder->codec, format, decoder->window, NULL, 0);
	if(r != AMEDIA_OK)
	{
		CHIAKI_LOGE(decoder->log, "AMediaCodec_configure() failed: %d", (int)r);
		AMediaFormat_delete(format);
		goto error_codec;
	}

	r = AMediaCodec_start(decoder->codec);
	AMediaFormat_delete(format);
	if(r != AMEDIA_OK)
	{
		CHIAKI_LOGE(decoder->log, "AMediaCodec_start() failed: %d", (int)r);
		goto error_codec;
	}

	ChiakiErrorCode err = chiaki_thread_create(&decoder->output_thread, android_chiaki_video_decoder_output_thread_func, decoder);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(decoder->log, "Failed to create output thread for AMediaCodec");
		goto error_codec;
	}

	goto beach;

error_codec:
	AMediaCodec_delete(decoder->codec);
	decoder->codec = NULL;

error_surface:
	ANativeWindow_release(decoder->window);
	decoder->window = NULL;

beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
}

bool android_chiaki_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
	bool r = true;
	AndroidChiakiVideoDecoder *decoder = user;
	// Ignore frames_lost and frame_recovered parameters for now - Android decoder handles frame loss internally
	(void)frames_lost;
	(void)frame_recovered;

	chiaki_mutex_lock(&decoder->codec_mutex);

	// shutdown_output: a teardown is in flight (kill_decoder has stopped the codec and
	// dropped the mutex around its join) — the codec pointer is non-NULL but stopped, so
	// dequeueing would just fail three times per frame. Skip quietly; the lib treats a
	// false return as a dropped frame.
	if(!decoder->codec || decoder->shutdown_output)
	{
		if(!decoder->codec)
			CHIAKI_LOGE(decoder->log, "Received video data, but decoder is not initialized!");
		goto beach;
	}

	while(buf_size > 0)
	{
		ssize_t codec_buf_index = -1;
		for(int attempt = 0; attempt < 3; attempt++)
		{
			codec_buf_index = AMediaCodec_dequeueInputBuffer(decoder->codec, INPUT_BUFFER_TIMEOUT_MS * 1000);
			if(codec_buf_index >= 0)
				break;
		}
		if(codec_buf_index < 0)
		{
			CHIAKI_LOGE(decoder->log, "Failed to get input buffer");
			r = false;
			break;
		}

		size_t codec_buf_size;
		uint8_t *codec_buf = AMediaCodec_getInputBuffer(decoder->codec, (size_t)codec_buf_index, &codec_buf_size);
		if(!codec_buf)
		{
			// Defensive: the codec can only be stopped under codec_mutex (which we hold), but
			// a NULL here must never reach the memcpy below.
			CHIAKI_LOGE(decoder->log, "AMediaCodec_getInputBuffer returned NULL");
			r = false;
			break;
		}
		size_t codec_sample_size = buf_size;
		if(codec_sample_size > codec_buf_size)
		{
			//CHIAKI_LOGD(decoder->log, "Sample is bigger than buffer, splitting");
			codec_sample_size = codec_buf_size;
		}
		memcpy(codec_buf, buf, codec_sample_size);
		media_status_t status = AMediaCodec_queueInputBuffer(decoder->codec, (size_t)codec_buf_index, 0, codec_sample_size, decoder->timestamp_cur++, 0); // timestamp just raised by 1 for maximum realtime
		if(status != AMEDIA_OK)
		{
			CHIAKI_LOGE(decoder->log, "AMediaCodec_queueInputBuffer() failed: %d", (int)status);
		}
		buf += codec_sample_size;
		buf_size -= codec_sample_size;
	}

beach:
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return r;
}

static void *android_chiaki_video_decoder_output_thread_func(void *user)
{
	AndroidChiakiVideoDecoder *decoder = user;

	while(1)
	{
		AMediaCodecBufferInfo info;
		// Finite timeout, NOT -1: teardown's join relies on this dequeue returning after
		// AMediaCodec_stop. Stock AOSP cancels a pending infinite dequeue on stop, but the
		// crash reports this file addresses come from vendor-modified TV-box MediaCodec
		// stacks — with an infinite wait, a vendor stop() that fails to cancel would turn
		// the teardown join into a permanent main-thread block (the same ANR class this
		// change fixes). With 100ms, the error branch below re-checks shutdown_output and
		// exits within one period on every device, regardless of vendor stop() behavior.
		ssize_t status = AMediaCodec_dequeueOutputBuffer(decoder->codec, &info, 100000);
		if(status >= 0)
		{
			AMediaCodec_releaseOutputBuffer(decoder->codec, (size_t)status, info.size != 0);
			if(info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)
			{
				CHIAKI_LOGI(decoder->log, "AMediaCodec reported EOS");
				break;
			}
		}
		else
		{
			chiaki_mutex_lock(&decoder->codec_mutex);
			bool shutdown = decoder->shutdown_output;
			chiaki_mutex_unlock(&decoder->codec_mutex);
			if(shutdown)
			{
				CHIAKI_LOGI(decoder->log, "Video Decoder Output Thread detected shutdown after reported error");
				break;
			}
		}
	}

	CHIAKI_LOGI(decoder->log, "Video Decoder Output Thread exiting");

	return NULL;
}