// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "audio-decoder.h"

#include <jni.h>

#include <media/NdkMediaCodec.h>
#include <media/NdkMediaFormat.h>

#include <string.h>

#define INPUT_BUFFER_TIMEOUT_MS 10

static void *android_chiaki_audio_decoder_output_thread_func(void *user);
static void android_chiaki_audio_decoder_header(ChiakiAudioHeader *header, void *user);
static void android_chiaki_audio_decoder_frame(uint8_t *buf, size_t buf_size, void *user);

ChiakiErrorCode android_chiaki_audio_decoder_init(AndroidChiakiAudioDecoder *decoder, ChiakiLog *log)
{
	decoder->log = log;
	memset(&decoder->audio_header, 0, sizeof(decoder->audio_header));
	decoder->codec = NULL;
	decoder->timestamp_cur = 0;

	decoder->cb_user = NULL;
	decoder->settings_cb = NULL;
	decoder->frame_cb = NULL;

	return CHIAKI_ERR_SUCCESS;
}

void android_chiaki_audio_decoder_fini(AndroidChiakiAudioDecoder *decoder)
{
	if(decoder->codec)
	{
		// Stop codec to unblock output thread (makes dequeueOutputBuffer return immediately)
		AMediaCodec_stop(decoder->codec);
		chiaki_thread_join(&decoder->output_thread, NULL);
		AMediaCodec_delete(decoder->codec);
		decoder->codec = NULL;
	}
}

void android_chiaki_audio_decoder_get_sink(AndroidChiakiAudioDecoder *decoder, ChiakiAudioSink *sink)
{
	sink->user = decoder;
	sink->header_cb = android_chiaki_audio_decoder_header;
	sink->frame_cb = android_chiaki_audio_decoder_frame;
}

static void *android_chiaki_audio_decoder_output_thread_func(void *user)
{
	AndroidChiakiAudioDecoder *decoder = user;

	while(1)
	{
		AMediaCodecBufferInfo info;
		ssize_t codec_buf_index = AMediaCodec_dequeueOutputBuffer(decoder->codec, &info, 1000);
		
		if(codec_buf_index == AMEDIACODEC_INFO_TRY_AGAIN_LATER)
			continue;
		else if(codec_buf_index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED)
			continue;
		else if(codec_buf_index == AMEDIACODEC_INFO_OUTPUT_BUFFERS_CHANGED)
			continue;
		else if(codec_buf_index < 0)
		{
			CHIAKI_LOGE(decoder->log, "Audio Decoder Output Thread got error code %d", (int)codec_buf_index);
			break;
		}

		size_t codec_buf_size;
		uint8_t *codec_buf = AMediaCodec_getOutputBuffer(decoder->codec, (size_t)codec_buf_index, &codec_buf_size);
		size_t samples_count = info.size / sizeof(int16_t);
		if(decoder->frame_cb)
			decoder->frame_cb((int16_t *)codec_buf, samples_count, decoder->cb_user);

		AMediaCodec_releaseOutputBuffer(decoder->codec, (size_t)codec_buf_index, false);
		
		if(info.flags & AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM)
		{
			CHIAKI_LOGI(decoder->log, "AMediaCodec for Audio Decoder reported EOS");
			break;
		}
	}

	return NULL;
}

static void android_chiaki_audio_decoder_header(ChiakiAudioHeader *header, void *user)
{
	AndroidChiakiAudioDecoder *decoder = user;
	memcpy(&decoder->audio_header, header, sizeof(decoder->audio_header));

	if(decoder->codec)
	{
		CHIAKI_LOGI(decoder->log, "Audio decoder already initialized, shutting down the old one");
		chiaki_thread_join(&decoder->output_thread, NULL);
		AMediaCodec_delete(decoder->codec);
		decoder->codec = NULL;
	}

	const char *mime = "audio/opus";
	decoder->codec = AMediaCodec_createDecoderByType(mime);
	if(!decoder->codec)
	{
		CHIAKI_LOGE(decoder->log, "Failed to create AMediaCodec for mime type %s", mime);
		goto beach;
	}

	AMediaFormat *format = AMediaFormat_new();
	AMediaFormat_setString(format, AMEDIAFORMAT_KEY_MIME, mime);
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_CHANNEL_COUNT, header->channels);
	AMediaFormat_setInt32(format, AMEDIAFORMAT_KEY_SAMPLE_RATE, header->rate);

	AMediaCodec_configure(decoder->codec, format, NULL, NULL, 0);
	AMediaCodec_start(decoder->codec);

	AMediaFormat_delete(format);

	ChiakiErrorCode err = chiaki_thread_create(&decoder->output_thread, android_chiaki_audio_decoder_output_thread_func, decoder);
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGE(decoder->log, "Failed to create output thread for AMediaCodec");
		AMediaCodec_delete(decoder->codec);
		decoder->codec = NULL;
	}

	uint8_t opus_id_head[0x13];
	memcpy(opus_id_head, "OpusHead", 8);
	opus_id_head[0x8] = 1; // version
	opus_id_head[0x9] = header->channels;
	uint16_t pre_skip = 3840;
	opus_id_head[0xa] = (uint8_t)(pre_skip & 0xff);
	opus_id_head[0xb] = (uint8_t)(pre_skip >> 8);
	opus_id_head[0xc] = (uint8_t)(header->rate & 0xff);
	opus_id_head[0xd] = (uint8_t)((header->rate >> 0x8) & 0xff);
	opus_id_head[0xe] = (uint8_t)((header->rate >> 0x10) & 0xff);
	opus_id_head[0xf] = (uint8_t)(header->rate >> 0x18);
	uint16_t output_gain = 0;
	opus_id_head[0x10] = (uint8_t)(output_gain & 0xff);
	opus_id_head[0x11] = (uint8_t)(output_gain >> 8);
	opus_id_head[0x12] = 0; // channel map
	android_chiaki_audio_decoder_frame(opus_id_head, sizeof(opus_id_head), decoder);

	uint64_t pre_skip_ns = 0;
	uint8_t csd1[8] = { (uint8_t)(pre_skip_ns & 0xff), (uint8_t)((pre_skip_ns >> 0x8) & 0xff), (uint8_t)((pre_skip_ns >> 0x10) & 0xff), (uint8_t)((pre_skip_ns >> 0x18) & 0xff),
						(uint8_t)((pre_skip_ns >> 0x20) & 0xff), (uint8_t)((pre_skip_ns >> 0x28) & 0xff), (uint8_t)((pre_skip_ns >> 0x30) & 0xff), (uint8_t)(pre_skip_ns >> 0x38)};
	android_chiaki_audio_decoder_frame(csd1, sizeof(csd1), decoder);

	uint64_t pre_roll_ns = 0;
	uint8_t csd2[8] = { (uint8_t)(pre_roll_ns & 0xff), (uint8_t)((pre_roll_ns >> 0x8) & 0xff), (uint8_t)((pre_roll_ns >> 0x10) & 0xff), (uint8_t)((pre_roll_ns >> 0x18) & 0xff),
						(uint8_t)((pre_roll_ns >> 0x20) & 0xff), (uint8_t)((pre_roll_ns >> 0x28) & 0xff), (uint8_t)((pre_roll_ns >> 0x30) & 0xff), (uint8_t)(pre_roll_ns >> 0x38)};
	android_chiaki_audio_decoder_frame(csd2, sizeof(csd2), decoder);

	if(decoder->settings_cb)
		decoder->settings_cb(header->channels, header->rate, decoder->cb_user);

beach:
	return;
}

static void android_chiaki_audio_decoder_frame(uint8_t *buf, size_t buf_size, void *user)
{
	AndroidChiakiAudioDecoder *decoder = user;
	if(!decoder->codec)
	{
		CHIAKI_LOGE(decoder->log, "Received audio frame, but codec is not initialized");
		return;
	}

	ssize_t buf_index = AMediaCodec_dequeueInputBuffer(decoder->codec, INPUT_BUFFER_TIMEOUT_MS * 1000);
	if(buf_index < 0)
	{
		if(buf_index == AMEDIACODEC_INFO_TRY_AGAIN_LATER)
			CHIAKI_LOGV(decoder->log, "Audio Decoder dequeueInputBuffer failed: no buffer available currently");
		else
			CHIAKI_LOGE(decoder->log, "Audio Decoder dequeueInputBuffer failed: %d", (int)buf_index);
		return;
	}

	size_t codec_buf_size;
	uint8_t *codec_buf = AMediaCodec_getInputBuffer(decoder->codec, (size_t)buf_index, &codec_buf_size);
	if(!codec_buf)
	{
		CHIAKI_LOGE(decoder->log, "AMediaCodec_getInputBuffer failed");
		return;
	}

	if(codec_buf_size < buf_size)
	{
		CHIAKI_LOGE(decoder->log, "Audio Decoder AMediaCodec buffer is too small");
		return;
	}

	memcpy(codec_buf, buf, buf_size);

	media_status_t r = AMediaCodec_queueInputBuffer(decoder->codec, (size_t)buf_index, 0, buf_size, decoder->timestamp_cur, 0);
	if(r != AMEDIA_OK)
	{
		CHIAKI_LOGE(decoder->log, "AMediaCodec_queueInputBuffer failed: %d", (int)r);
		return;
	}

	decoder->timestamp_cur += buf_size; // just use something as timestamp
}
