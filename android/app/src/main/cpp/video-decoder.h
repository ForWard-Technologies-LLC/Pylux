// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_JNI_VIDEO_DECODER_H
#define CHIAKI_JNI_VIDEO_DECODER_H

#include <jni.h>

#include <chiaki/thread.h>
#include <chiaki/log.h>

typedef struct AMediaCodec AMediaCodec;
typedef struct ANativeWindow ANativeWindow;

typedef struct android_chiaki_video_decoder_t
{
	ChiakiLog *log;
	ChiakiMutex codec_mutex;
	// Broadcast (with codec_mutex held) when a kill_decoder finishes; teardown entry
	// points wait on it while shutdown_output is set instead of skipping — see kill_decoder.
	ChiakiCond teardown_cond;
	AMediaCodec *codec;
	ANativeWindow *window;
	uint64_t timestamp_cur;
	ChiakiThread output_thread;
	bool shutdown_output;
	// Number of threads parked in the teardown_cond wait inside set_surface. fini must not
	// destroy codec_mutex/teardown_cond while either shutdown_output is set (a kill is in
	// flight) or a waiter is still inside the condvar — it waits for both to clear.
	unsigned int teardown_waiters;
	// Set (under codec_mutex) at the top of fini. set_surface callers that wake from the
	// teardown_cond wait check it and bail out instead of acting on a decoder that is being
	// destroyed; fini re-waits for such late waiters after its kill completes.
	bool fini_requested;
	int32_t target_width;
	int32_t target_height;
	ChiakiCodec target_codec;
} AndroidChiakiVideoDecoder;

ChiakiErrorCode android_chiaki_video_decoder_init(AndroidChiakiVideoDecoder *decoder, ChiakiLog *log, int32_t target_width, int32_t target_height, ChiakiCodec codec);
void android_chiaki_video_decoder_fini(AndroidChiakiVideoDecoder *decoder);
void android_chiaki_video_decoder_set_surface(AndroidChiakiVideoDecoder *decoder, JNIEnv *env, jobject surface);
bool android_chiaki_video_decoder_video_sample(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user);

#endif