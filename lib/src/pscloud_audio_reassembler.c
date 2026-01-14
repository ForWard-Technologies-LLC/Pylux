// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#include "pscloud_audio_reassembler.h"
#include <chiaki/seqnum.h>
#include <chiaki/time.h>

#include <string.h>
#include <stdlib.h>
#include <assert.h>

#define UNIT_SLOTS_MAX 512
// Timeout for stale generation: if a generation is incomplete after this time, flush it
// Audio is more time-sensitive than video, so we use a shorter timeout than Takion's 200ms
// 150ms balances responsiveness with jitter tolerance:
// - Typical audio frames arrive every ~20ms, 3 units = ~60ms
// - Leaves ~90ms headroom for network jitter (RFC 3551 recommends 0-200ms buffers)
// - Still responsive enough to catch up quickly after network blips
// - More conservative than 100ms but faster than 200ms
// This is similar to video's approach of flushing on new frame arrival, but adds a timeout
// safety net for when network is completely dead (no new packets arriving)
#define GENERATION_TIMEOUT_US (150 * 1000) // 150ms in microseconds

CHIAKI_EXPORT ChiakiErrorCode chiaki_pscloud_audio_reassembler_init(ChiakiPSCLOUDAudioReassembler *reassembler, ChiakiLog *log)
{
	memset(reassembler, 0, sizeof(ChiakiPSCLOUDAudioReassembler));
	reassembler->log = log;
	reassembler->flushed = true;
	reassembler->generation_start_time_us = 0;
	return CHIAKI_ERR_SUCCESS;
}

CHIAKI_EXPORT void chiaki_pscloud_audio_reassembler_fini(ChiakiPSCLOUDAudioReassembler *reassembler)
{
	free(reassembler->frame_buf);
	free(reassembler->unit_received);
	free(reassembler->unit_is_haptics);
	memset(reassembler, 0, sizeof(ChiakiPSCLOUDAudioReassembler));
}

static ChiakiErrorCode chiaki_pscloud_audio_reassembler_alloc_generation(
	ChiakiPSCLOUDAudioReassembler *reassembler,
	ChiakiTakionAVPacket *packet)
{
	// PSCLOUD format: units_in_frame_fec is literal FEC count
	uint16_t total = packet->units_in_frame_total;
	uint16_t fec = packet->units_in_frame_fec;
	
	if(total == 0)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio: invalid total=0");
		return CHIAKI_ERR_INVALID_DATA;
	}
	
	if(fec > total)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio: invalid totals (fec=%u > total=%u)", (unsigned)fec, (unsigned)total);
		return CHIAKI_ERR_INVALID_DATA;
	}
	
	uint16_t source = total - fec;
	if(source == 0)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio: source_count=0 (total=%u fec=%u)", (unsigned)total, (unsigned)fec);
		return CHIAKI_ERR_INVALID_DATA;
	}
	
	if(packet->data_size == 0)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio: zero data_size for generation allocation");
		return CHIAKI_ERR_INVALID_DATA;
	}
	
	reassembler->flushed = false;
	reassembler->source_units_emitted = false;
	reassembler->generation_id++;
	reassembler->first_frame_index = packet->frame_index;
	reassembler->units_source_expected = source;
	reassembler->units_fec_expected = fec;
	reassembler->units_total_expected = total;
	reassembler->unit_size = packet->data_size; // Assume fixed unit size within a generation
	reassembler->units_source_received = 0;
	reassembler->units_fec_received = 0;
	reassembler->generation_start_time_us = chiaki_time_now_monotonic_us();
	
	// Align stride to 16 bytes for FEC
	reassembler->buf_stride_per_unit = ((reassembler->unit_size + 0xf) / 0x10) * 0x10;
	
	// Allocate unit tracking array
	if(total > UNIT_SLOTS_MAX)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio: too many units (%u > %u)", (unsigned)total, UNIT_SLOTS_MAX);
		return CHIAKI_ERR_INVALID_DATA;
	}
	
	if(total != reassembler->unit_received_size)
	{
		free(reassembler->unit_received);
		free(reassembler->unit_is_haptics);
		reassembler->unit_received = calloc(total, sizeof(bool));
		reassembler->unit_is_haptics = calloc(total, sizeof(bool));
		if(!reassembler->unit_received || !reassembler->unit_is_haptics)
		{
			free(reassembler->unit_received);
			free(reassembler->unit_is_haptics);
			reassembler->unit_received = NULL;
			reassembler->unit_is_haptics = NULL;
			reassembler->unit_received_size = 0;
			return CHIAKI_ERR_MEMORY;
		}
		reassembler->unit_received_size = total;
	}
	else
	{
		memset(reassembler->unit_received, 0, total * sizeof(bool));
		memset(reassembler->unit_is_haptics, 0, total * sizeof(bool));
	}
	
	// Allocate frame buffer
	if(reassembler->buf_stride_per_unit > SIZE_MAX / total)
		return CHIAKI_ERR_OVERFLOW;
	
	size_t frame_buf_size_required = total * reassembler->buf_stride_per_unit;
	if(reassembler->frame_buf_size < frame_buf_size_required)
	{
		free(reassembler->frame_buf);
		reassembler->frame_buf = malloc(frame_buf_size_required);
		if(!reassembler->frame_buf)
		{
			reassembler->frame_buf_size = 0;
			return CHIAKI_ERR_MEMORY;
		}
		reassembler->frame_buf_size = frame_buf_size_required;
	}
	memset(reassembler->frame_buf, 0, frame_buf_size_required);
	
	return CHIAKI_ERR_SUCCESS;
}

static ChiakiErrorCode chiaki_pscloud_audio_reassembler_fec(
	ChiakiPSCLOUDAudioReassembler *reassembler)
{
	CHIAKI_LOGV(reassembler->log, "PSCLOUD audio FEC: received %u+%u / %u+%u units, attempting recovery",
		reassembler->units_source_received, reassembler->units_fec_received,
		reassembler->units_source_expected, reassembler->units_fec_expected);
	
	uint16_t received_total = reassembler->units_source_received + reassembler->units_fec_received;
	uint16_t expected_total = reassembler->units_source_expected + reassembler->units_fec_expected;
	
	if(received_total < reassembler->units_source_expected)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio FEC: not enough units for recovery (%u < %u)", 
			(unsigned)received_total, (unsigned)reassembler->units_source_expected);
		return CHIAKI_ERR_FEC_FAILED;
	}
	
	size_t erasures_count = expected_total - received_total;
	if(erasures_count == 0)
		return CHIAKI_ERR_SUCCESS; // Nothing to recover
	
	unsigned int *erasures = calloc(erasures_count, sizeof(unsigned int));
	if(!erasures)
		return CHIAKI_ERR_MEMORY;
	
	size_t erasure_index = 0;
	for(uint16_t i = 0; i < expected_total; i++)
	{
		if(!reassembler->unit_received[i])
		{
			if(erasure_index >= erasures_count)
			{
				assert(false);
				free(erasures);
				return CHIAKI_ERR_UNKNOWN;
			}
			erasures[erasure_index++] = (unsigned int)i;
		}
	}
	assert(erasure_index == erasures_count);
	
	ChiakiErrorCode err = chiaki_fec_decode(
		reassembler->frame_buf,
		reassembler->unit_size,
		reassembler->buf_stride_per_unit,
		reassembler->units_source_expected,
		reassembler->units_fec_expected,
		erasures,
		erasures_count);
	
	if(err != CHIAKI_ERR_SUCCESS)
	{
		CHIAKI_LOGW(reassembler->log, "PSCLOUD audio FEC: decode failed");
		err = CHIAKI_ERR_FEC_FAILED;
	}
	else
	{
		CHIAKI_LOGV(reassembler->log, "PSCLOUD audio FEC: recovery successful");
		// Mark recovered units as received
		for(size_t i = 0; i < erasures_count; i++)
		{
			uint16_t idx = (uint16_t)erasures[i];
				if(idx < reassembler->units_source_expected)
				{
					reassembler->unit_received[idx] = true;
					// Note: We don't know is_haptics for recovered units, assume false (audio)
					// In practice, FEC recovery is rare and haptics/audio are usually separate
					reassembler->unit_is_haptics[idx] = false;
					reassembler->units_source_received++;
				}
		}
	}
	
	free(erasures);
	return err;
}

CHIAKI_EXPORT ChiakiErrorCode chiaki_pscloud_audio_reassembler_put_packet(
	ChiakiPSCLOUDAudioReassembler *reassembler,
	ChiakiTakionAVPacket *packet,
	void (*frame_cb)(ChiakiSeqNum16 frame_index, uint8_t *buf, size_t buf_size, bool is_haptics, void *user),
	void *frame_cb_user)
{
	// For PSCLOUD, frame_index increments per packet, not per generation.
	// We group generations by unit_index=0 (which marks the start of a new generation).
	// A new generation starts when:
	// 1. We're flushed (no active generation), OR
	// 2. We receive unit_index=0 (always starts a new generation), OR
	// 3. We've received all units (generation complete), OR
	// 4. Current generation has timed out (stale, flush to catch up)
	
	// Check for stale generation timeout (catch up after network blips)
	bool is_stale = false;
	if(!reassembler->flushed && reassembler->generation_start_time_us > 0)
	{
		uint64_t now = chiaki_time_now_monotonic_us();
		uint64_t age_us = now - reassembler->generation_start_time_us;
		if(age_us > GENERATION_TIMEOUT_US)
		{
			// Generation is stale - flush it to catch up
			is_stale = true;
			CHIAKI_LOGW(reassembler->log, "PSCLOUD audio: generation id=%u timed out after %llu ms, flushing to catch up",
				(unsigned)reassembler->generation_id, (unsigned long long)(age_us / 1000));
		}
	}
	
	bool is_new_generation = reassembler->flushed || is_stale;
	if(!is_new_generation)
	{
		// unit_index=0 always starts a new generation
		if(packet->unit_index == 0)
		{
			is_new_generation = true;
		}
		// If we've received ALL units (source + FEC), the generation is complete
		// Only then should the next packet start a new generation
		else if((reassembler->units_source_received + reassembler->units_fec_received) >= reassembler->units_total_expected)
		{
			is_new_generation = true;
		}
		// If unit_index is out of bounds for current generation, it's a new one
		else if(packet->unit_index >= reassembler->units_total_expected)
		{
			is_new_generation = true;
		}
		// If totals don't match, it's a new generation (different format)
		else
		{
			uint16_t expected_total = reassembler->units_total_expected;
			uint16_t expected_fec = reassembler->units_fec_expected;
			uint16_t packet_total = packet->units_in_frame_total;
			uint16_t packet_fec = packet->units_in_frame_fec;
			if(packet_total != expected_total || packet_fec != expected_fec)
			{
				is_new_generation = true;
			}
		}
	}
	
	if(is_new_generation)
	{
		// Flush previous generation if any
		if(!reassembler->flushed)
		{
			// Detect stale generation (incomplete generation being dropped)
			bool was_stale = (reassembler->units_source_received < reassembler->units_source_expected) &&
				((reassembler->units_source_received + reassembler->units_fec_received) < reassembler->units_source_expected);
			
			if(was_stale)
			{
				CHIAKI_LOGW(reassembler->log, "PSCLOUD audio: dropping stale generation id=%u (received %u+%u/%u+%u)",
					(unsigned)reassembler->generation_id,
					(unsigned)reassembler->units_source_received, (unsigned)reassembler->units_fec_received,
					(unsigned)reassembler->units_source_expected, (unsigned)reassembler->units_fec_expected);
			}
			
			// Try FEC recovery if we have enough units
			if(reassembler->units_source_received < reassembler->units_source_expected)
			{
				uint16_t received_total = reassembler->units_source_received + reassembler->units_fec_received;
				if(received_total >= reassembler->units_source_expected)
				{
					chiaki_pscloud_audio_reassembler_fec(reassembler);
				}
			}
			
		// Emit all received source units (if not already emitted)
		if(!reassembler->source_units_emitted)
		{
			for(uint16_t i = 0; i < reassembler->units_source_expected; i++)
			{
				if(reassembler->unit_received[i])
				{
					uint8_t *unit_buf = reassembler->frame_buf + i * reassembler->buf_stride_per_unit;
					ChiakiSeqNum16 frame_index = (ChiakiSeqNum16)(reassembler->first_frame_index + i);
					if(frame_cb)
						frame_cb(frame_index, unit_buf, reassembler->unit_size, reassembler->unit_is_haptics[i], frame_cb_user);
				}
			}
		}
		}
		// Mark previous generation as flushed
		reassembler->flushed = true;
		reassembler->generation_start_time_us = 0; // Clear timestamp
		
		// Start new generation
		ChiakiErrorCode err = chiaki_pscloud_audio_reassembler_alloc_generation(reassembler, packet);
		if(err != CHIAKI_ERR_SUCCESS)
			return err;
		
		// Log generation start for debugging (verbose to reduce noise)
		// For first generation, log detailed format info (observed from actual packets)
		if(reassembler->generation_id == 1)
		{
			CHIAKI_LOGI(reassembler->log, "PSCLOUD audio format (observed from packets): unitized Opus, %u source + %u FEC units per generation, unit_size=%zu bytes",
				(unsigned)reassembler->units_source_expected, (unsigned)reassembler->units_fec_expected,
				reassembler->unit_size);
		}
		CHIAKI_LOGV(reassembler->log, "PSCLOUD audio: new generation id=%u frame_index=%u unit_index=%u total=%u fec=%u",
			(unsigned)reassembler->generation_id, (unsigned)packet->frame_index, (unsigned)packet->unit_index,
			(unsigned)reassembler->units_total_expected, (unsigned)reassembler->units_fec_expected);
	}
	
	// Validate unit_index
	if(packet->unit_index >= reassembler->units_total_expected)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio: unit_index %u >= total %u",
			(unsigned)packet->unit_index, (unsigned)reassembler->units_total_expected);
		return CHIAKI_ERR_INVALID_DATA;
	}
	
	// Check if already received
	if(reassembler->unit_received[packet->unit_index])
	{
		CHIAKI_LOGW(reassembler->log, "PSCLOUD audio: duplicate unit_index %u in gen=%u (frame_index=%u, received %u+%u/%u+%u)",
			(unsigned)packet->unit_index, (unsigned)reassembler->generation_id, (unsigned)packet->frame_index,
			(unsigned)reassembler->units_source_received, (unsigned)reassembler->units_fec_received,
			(unsigned)reassembler->units_source_expected, (unsigned)reassembler->units_fec_expected);
		return CHIAKI_ERR_INVALID_DATA;
	}
	
	// Validate data pointer and size
	if(!packet->data)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio: NULL data pointer for unit_index %u", (unsigned)packet->unit_index);
		return CHIAKI_ERR_INVALID_DATA;
	}
	if(packet->data_size == 0)
	{
		CHIAKI_LOGE(reassembler->log, "PSCLOUD audio: zero data_size for unit_index %u", (unsigned)packet->unit_index);
		return CHIAKI_ERR_INVALID_DATA;
	}
	
	// Validate data size matches expected unit size (allow slight variation for last unit)
	if(packet->data_size != reassembler->unit_size)
	{
		// Allow size mismatch if packet is smaller (last unit might be smaller)
		if(packet->data_size > reassembler->unit_size)
		{
			CHIAKI_LOGW(reassembler->log, "PSCLOUD audio: unit size too large %zu > %zu, truncating",
				packet->data_size, reassembler->unit_size);
		}
		size_t copy_size = (packet->data_size < reassembler->unit_size) ? packet->data_size : reassembler->unit_size;
		memcpy(reassembler->frame_buf + packet->unit_index * reassembler->buf_stride_per_unit,
			packet->data, copy_size);
		// Zero-pad if needed
		if(copy_size < reassembler->unit_size)
			memset(reassembler->frame_buf + packet->unit_index * reassembler->buf_stride_per_unit + copy_size,
				0, reassembler->unit_size - copy_size);
	}
	else
	{
		memcpy(reassembler->frame_buf + packet->unit_index * reassembler->buf_stride_per_unit,
			packet->data, reassembler->unit_size);
	}
	
	reassembler->unit_received[packet->unit_index] = true;
	reassembler->unit_is_haptics[packet->unit_index] = packet->is_haptics;
	
	if(packet->unit_index < reassembler->units_source_expected)
		reassembler->units_source_received++;
	else
		reassembler->units_fec_received++;
	
	// Check if we can emit source units immediately (all received)
	if(reassembler->units_source_received == reassembler->units_source_expected && !reassembler->source_units_emitted)
	{
		// Emit units individually for ChiakiOpusDecoder
		for(uint16_t i = 0; i < reassembler->units_source_expected; i++)
		{
			uint8_t *unit_buf = reassembler->frame_buf + i * reassembler->buf_stride_per_unit;
			ChiakiSeqNum16 frame_index = (ChiakiSeqNum16)(reassembler->first_frame_index + i);
			if(frame_cb)
				frame_cb(frame_index, unit_buf, reassembler->unit_size, reassembler->unit_is_haptics[i], frame_cb_user);
		}
		reassembler->source_units_emitted = true;
	}
	
	return CHIAKI_ERR_SUCCESS;
}

