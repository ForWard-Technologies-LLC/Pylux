// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// PCM output for Chiaki (PS Cloud Opus → speakers via AudioQueue).

#ifndef ChiakiAudioOutputIOS_h
#define ChiakiAudioOutputIOS_h

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

void *ios_chiaki_audio_output_create(void);
void ios_chiaki_audio_output_free(void *ptr);
void ios_chiaki_audio_output_settings(uint32_t channels, uint32_t rate, void *ptr);
void ios_chiaki_audio_output_frame(int16_t *buf, size_t total_interleaved_samples, void *ptr);

/// ChiakiOpusDecoderFrameCallback: samples_per_channel from lib; forwards as interleaved sample count.
void ios_chiaki_opus_frame_bridge(int16_t *buf, size_t samples_per_channel, void *user);

#ifdef __cplusplus
}
#endif

#endif
