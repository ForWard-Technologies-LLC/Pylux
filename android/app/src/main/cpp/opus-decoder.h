// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_ANDROID_OPUS_DECODER_H
#define CHIAKI_ANDROID_OPUS_DECODER_H

#include <chiaki/opusdecoder.h>
#include <chiaki/audioreceiver.h>

#ifdef __cplusplus
extern "C" {
#endif

/**
 * Wrapper around ChiakiOpusDecoder for Android
 * Used for PSCloud audio (unitized Opus format)
 */
typedef struct android_chiaki_opus_decoder_t
{
	ChiakiOpusDecoder opus_decoder;
	uint32_t channels; // Store channel count for sample calculation
	void *cb_user;
	void (*settings_cb)(uint32_t channels, uint32_t rate, void *user);
	void (*frame_cb)(int16_t *buf, size_t samples_count, void *user);
} AndroidChiakiOpusDecoder;

ChiakiErrorCode android_chiaki_opus_decoder_init(AndroidChiakiOpusDecoder *decoder, ChiakiLog *log);
void android_chiaki_opus_decoder_fini(AndroidChiakiOpusDecoder *decoder);
void android_chiaki_opus_decoder_get_sink(AndroidChiakiOpusDecoder *decoder, ChiakiAudioSink *sink);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_ANDROID_OPUS_DECODER_H

