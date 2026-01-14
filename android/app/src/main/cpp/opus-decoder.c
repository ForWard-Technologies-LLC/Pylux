// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "opus-decoder.h"

static void android_chiaki_opus_decoder_settings(uint32_t channels, uint32_t rate, void *user);
static void android_chiaki_opus_decoder_frame(int16_t *buf, size_t samples_count, void *user);

ChiakiErrorCode android_chiaki_opus_decoder_init(AndroidChiakiOpusDecoder *decoder, ChiakiLog *log)
{
	chiaki_opus_decoder_init(&decoder->opus_decoder, log);
	decoder->channels = 0; // Will be set in settings callback
	decoder->cb_user = NULL;
	decoder->settings_cb = NULL;
	decoder->frame_cb = NULL;
	
	// Set up callbacks from ChiakiOpusDecoder to our wrapper
	decoder->opus_decoder.cb_user = decoder;
	decoder->opus_decoder.settings_cb = android_chiaki_opus_decoder_settings;
	decoder->opus_decoder.frame_cb = android_chiaki_opus_decoder_frame;
	
	return CHIAKI_ERR_SUCCESS;
}

void android_chiaki_opus_decoder_fini(AndroidChiakiOpusDecoder *decoder)
{
	chiaki_opus_decoder_fini(&decoder->opus_decoder);
}

void android_chiaki_opus_decoder_get_sink(AndroidChiakiOpusDecoder *decoder, ChiakiAudioSink *sink)
{
	chiaki_opus_decoder_get_sink(&decoder->opus_decoder, sink);
}

static void android_chiaki_opus_decoder_settings(uint32_t channels, uint32_t rate, void *user)
{
	AndroidChiakiOpusDecoder *decoder = user;
	decoder->channels = channels; // Store for sample count calculation
	CHIAKI_LOGI(decoder->opus_decoder.log, "Native Opus Decoder initialized: %u channels, %u Hz", channels, rate);
	if(decoder->settings_cb)
		decoder->settings_cb(channels, rate, decoder->cb_user);
}

static void android_chiaki_opus_decoder_frame(int16_t *buf, size_t samples_count, void *user)
{
	AndroidChiakiOpusDecoder *decoder = user;
	if(decoder->frame_cb)
	{
		// opus_decode returns samples per channel, but audio output expects total samples
		// For stereo (2 channels), multiply by 2
		size_t total_samples = samples_count * decoder->channels;
		decoder->frame_cb(buf, total_samples, decoder->cb_user);
	}
}

