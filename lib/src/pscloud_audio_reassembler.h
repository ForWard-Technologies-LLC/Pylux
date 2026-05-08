// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_PSCLOUD_AUDIO_REASSEMBLER_H
#define CHIAKI_PSCLOUD_AUDIO_REASSEMBLER_H

#include <chiaki/common.h>
#include <chiaki/log.h>
#include <chiaki/takion.h>
#include <chiaki/fec.h>
#include <chiaki/seqnum.h>
#include <chiaki/time.h>

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct chiaki_pscloud_audio_reassembler_t
{
	ChiakiLog *log;
	
	// Current generation being assembled
	// Note: frame_index increments per packet in PSCLOUD, so we use generation_id instead
	uint32_t generation_id; // Increments for each new generation
	ChiakiSeqNum16 first_frame_index; // First frame_index seen in this generation (for logging)
	uint16_t units_source_expected;
	uint16_t units_fec_expected;
	uint16_t units_total_expected;
	size_t unit_size;
	
	// Buffer for units (source + FEC)
	uint8_t *frame_buf;
	size_t frame_buf_size;
	size_t buf_stride_per_unit;
	
	// Track which units we've received and their haptics flag
	bool *unit_received;
	bool *unit_is_haptics; // Track is_haptics per unit
	size_t unit_received_size;
	
	// Counters
	uint16_t units_source_received;
	uint16_t units_fec_received;
	
	bool flushed;
	bool source_units_emitted; // Track if we've already emitted source units for this generation
	
	// Timeout tracking for stale generation detection
	uint64_t generation_start_time_us; // Timestamp when current generation started (0 if flushed)
} ChiakiPSCLOUDAudioReassembler;

/**
 * Initialize the reassembler
 */
CHIAKI_EXPORT ChiakiErrorCode chiaki_pscloud_audio_reassembler_init(ChiakiPSCLOUDAudioReassembler *reassembler, ChiakiLog *log);

/**
 * Cleanup the reassembler
 */
CHIAKI_EXPORT void chiaki_pscloud_audio_reassembler_fini(ChiakiPSCLOUDAudioReassembler *reassembler);

/**
 * Process a PSCLOUD audio AV packet
 * @param reassembler The reassembler instance
 * @param packet The AV packet (must be PSCLOUD format)
 * @param frame_cb Callback to emit completed source units (called with frame_index, is_haptics from packet)
 * @param frame_cb_user User data for frame_cb
 * @return CHIAKI_ERR_SUCCESS on success, other on error
 */
CHIAKI_EXPORT ChiakiErrorCode chiaki_pscloud_audio_reassembler_put_packet(
	ChiakiPSCLOUDAudioReassembler *reassembler,
	ChiakiTakionAVPacket *packet,
	void (*frame_cb)(ChiakiSeqNum16 frame_index, uint8_t *buf, size_t buf_size, bool is_haptics, void *user),
	void *frame_cb_user);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_PSCLOUD_AUDIO_REASSEMBLER_H

