// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "video-decoder.h"

#include <jni.h>

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>
#include <android/native_window_jni.h>

#include <string.h>
#include <stdio.h>
#include <time.h>

/**
 * Presentation timestamp for input buffers: CLOCK_MONOTONIC in microseconds, the same clock as
 * System.nanoTime() and Choreographer on the Java side. MediaCodec carries it to the output
 * buffer (SurfaceTexture.getTimestamp() returns it in nanoseconds), so a consumer can measure
 * decoder-input-to-present latency. Monotonic, hence always non-decreasing as MediaCodec requires.
 */
static int64_t monotonic_us(void)
{
	struct timespec ts;
	clock_gettime(CLOCK_MONOTONIC, &ts);
	return (int64_t)ts.tv_sec * 1000000 + ts.tv_nsec / 1000;
}

#define INPUT_BUFFER_TIMEOUT_MS 10

static void *android_chiaki_video_decoder_output_thread_func(void *user);

ChiakiErrorCode android_chiaki_video_decoder_init(AndroidChiakiVideoDecoder *decoder, ChiakiLog *log, int32_t target_width, int32_t target_height, ChiakiCodec codec)
{
	decoder->log = log;
	decoder->codec = NULL;
	decoder->target_width = target_width;
	decoder->target_height = target_height;
	decoder->target_codec = codec;
	decoder->shutdown_output = false;
	return chiaki_mutex_init(&decoder->codec_mutex, false);
}

// Must be called WITHOUT codec_mutex held: it takes the (non-recursive) mutex itself.
static void kill_decoder(AndroidChiakiVideoDecoder *decoder)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	if(!decoder->codec)
	{
		chiaki_mutex_unlock(&decoder->codec_mutex);
		return;
	}
	decoder->shutdown_output = true;
	ssize_t codec_buf_index = AMediaCodec_dequeueInputBuffer(decoder->codec, 1000);
	if(codec_buf_index >= 0)
	{
		CHIAKI_LOGI(decoder->log, "Video Decoder sending EOS buffer");
		AMediaCodec_queueInputBuffer(decoder->codec, (size_t)codec_buf_index, 0, 0, monotonic_us(), AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM);
		AMediaCodec_stop(decoder->codec);
		chiaki_mutex_unlock(&decoder->codec_mutex);
	}
	else
	{
		CHIAKI_LOGE(decoder->log, "Failed to get input buffer for shutting down Video Decoder!");
		AMediaCodec_stop(decoder->codec);
		chiaki_mutex_unlock(&decoder->codec_mutex);
	}
	// Always join: AMediaCodec_stop() makes a pending dequeueOutputBuffer(-1) return an
	// error, the output thread then sees shutdown_output under the mutex and exits. Deleting
	// the codec (or resetting shutdown_output) while that thread still runs would let it
	// dequeue from a NULL codec.
	chiaki_thread_join(&decoder->output_thread, NULL);
	// The session thread may still be feeding video_sample(); clear the codec under the
	// mutex so it cannot observe a deleted AMediaCodec.
	chiaki_mutex_lock(&decoder->codec_mutex);
	AMediaCodec_delete(decoder->codec);
	decoder->codec = NULL;
	decoder->shutdown_output = false;
	chiaki_mutex_unlock(&decoder->codec_mutex);
}

size_t android_chiaki_video_decoder_hdr_static_info(AndroidChiakiVideoDecoder *decoder, uint8_t *out, size_t out_size)
{
	chiaki_mutex_lock(&decoder->codec_mutex);
	size_t n = decoder->hdr_static_info_size;
	if(n > out_size)
		n = out_size;
	if(n)
		memcpy(out, decoder->hdr_static_info, n);
	chiaki_mutex_unlock(&decoder->codec_mutex);
	return n;
}

void android_chiaki_video_decoder_fini(AndroidChiakiVideoDecoder *decoder)
{
	if(decoder->codec)
		kill_decoder(decoder);
	chiaki_mutex_fini(&decoder->codec_mutex);
}

void android_chiaki_video_decoder_set_surface(AndroidChiakiVideoDecoder *decoder, JNIEnv *env, jobject surface)
{
	chiaki_mutex_lock(&decoder->codec_mutex);

	if(!surface)
	{
		// kill_decoder() locks codec_mutex itself and the mutex is not recursive, so it
		// must not be held here (and must not be leaked when there is no codec).
		bool had_codec = decoder->codec != NULL;
		chiaki_mutex_unlock(&decoder->codec_mutex);
		if(had_codec)
		{
			kill_decoder(decoder);
			CHIAKI_LOGI(decoder->log, "Decoder shut down after surface was removed");
		}
		return;
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
	// Remote Play has no B-frames, so ask the decoder to output every frame as soon as it is
	// decoded instead of holding frames for reordering. "low-latency" is MediaFormat.KEY_LOW_LATENCY
	// (Android 11+); the vendor key is honoured by older Qualcomm decoders. Unknown keys are ignored.
	AMediaFormat_setInt32(format, "low-latency", 1);
	AMediaFormat_setInt32(format, "vendor.qti-ext-dec-low-latency.enable", 1);
	// MediaFormat.KEY_PRIORITY 0 = realtime.
	AMediaFormat_setInt32(format, "priority", 0);

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

	if(!decoder->codec)
	{
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
		size_t codec_sample_size = buf_size;
		if(codec_sample_size > codec_buf_size)
		{
			//CHIAKI_LOGD(decoder->log, "Sample is bigger than buffer, splitting");
			codec_sample_size = codec_buf_size;
		}
		memcpy(codec_buf, buf, codec_sample_size);
		media_status_t status = AMediaCodec_queueInputBuffer(decoder->codec, (size_t)codec_buf_index, 0, codec_sample_size, monotonic_us(), 0);
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
		ssize_t status = AMediaCodec_dequeueOutputBuffer(decoder->codec, &info, -1);
		if(status >= 0)
		{
			AMediaCodec_releaseOutputBuffer(decoder->codec, (size_t)status, info.size != 0);
			if(info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)
			{
				CHIAKI_LOGI(decoder->log, "AMediaCodec reported EOS");
				break;
			}
		}
		else if(status == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED)
		{
			// Diagnostic for HDR: shows what the decoder parsed from the stream's VUI.
			// MediaFormat constants: color-standard 1=BT.709 6=BT.2020; color-transfer 3=SDR video
			// 6=ST 2084 (PQ) 7=HLG; color-range 1=full 2=limited.
			AMediaFormat *format = AMediaCodec_getOutputFormat(decoder->codec);
			if(format)
			{
				int32_t standard = -1, transfer = -1, range = -1;
				AMediaFormat_getInt32(format, "color-standard", &standard);
				AMediaFormat_getInt32(format, "color-transfer", &transfer);
				AMediaFormat_getInt32(format, "color-range", &range);
				CHIAKI_LOGI(decoder->log, "Video decoder output format: color-standard=%d color-transfer=%d color-range=%d",
						(int)standard, (int)transfer, (int)range);
				// Mastering display / content light level metadata from the HEVC SEI, as Android's
				// HDRStaticInfo Type 1 struct. The GPU path attaches it to its EGL surface.
				void *info = NULL;
				size_t info_size = 0;
				if(AMediaFormat_getBuffer(format, "hdr-static-info", &info, &info_size) && info && info_size > 0)
				{
					chiaki_mutex_lock(&decoder->codec_mutex);
					decoder->hdr_static_info_size = info_size < sizeof(decoder->hdr_static_info) ? info_size : sizeof(decoder->hdr_static_info);
					memcpy(decoder->hdr_static_info, info, decoder->hdr_static_info_size);
					chiaki_mutex_unlock(&decoder->codec_mutex);
					char hex[3 * 32 + 1] = { 0 };
					for(size_t i = 0; i < decoder->hdr_static_info_size; i++)
						snprintf(hex + 3 * i, 4, "%02x ", decoder->hdr_static_info[i]);
					CHIAKI_LOGI(decoder->log, "Video decoder HDR static info: %u bytes: %s", (unsigned)info_size, hex);
				}
				AMediaFormat_delete(format);
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