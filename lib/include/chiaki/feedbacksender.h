// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL

#ifndef CHIAKI_FEEDBACKSENDER_H
#define CHIAKI_FEEDBACKSENDER_H

#include "controller.h"
#include "takion.h"
#include "thread.h"
#include "common.h"

#ifdef __cplusplus
extern "C" {
#endif

/**
 * State for the unified "PS button via chord" feature: holding OPTIONS + SHARE
 * together for hold_ms synthesizes a short BUTTON_PS pulse (and suppresses the
 * two source buttons while the chord is held, so the console doesn't act on
 * them). Implemented once here so every client (Qt, Android, iOS) gets an
 * identical PS-button path — including iOS, where the physical PS/Home button
 * is reserved by the OS and never delivered to apps.
 */
typedef struct chiaki_ps_chord_t
{
	bool enabled;
	uint32_t hold_ms;         // chord hold time before the PS pulse fires
	uint64_t chord_start_ms;  // 0 = chord not currently held
	uint64_t pulse_until_ms;  // synthesized PS press active until this time
	bool fired;               // latched: fire at most once per hold
	bool releasing;           // in the staggered-release tail (one button still down)
} ChiakiPsChord;

typedef struct chiaki_feedback_sender_t
{
	ChiakiLog *log;
	ChiakiTakion *takion;
	ChiakiThread thread;

	ChiakiSeqNum16 state_seq_num;

	ChiakiSeqNum16 history_seq_num;
	ChiakiFeedbackHistoryBuffer history_buf;

	bool should_stop;
	ChiakiControllerState controller_state_prev;
	// Last state as pushed by the platform, BEFORE the chord transform. Kept
	// separately because the transform suppresses/synthesizes buttons over time
	// (re-evaluated on every wake, incl. timeout ticks) while a steady hold
	// produces no new platform pushes.
	ChiakiControllerState controller_state_raw;
	ChiakiControllerState controller_state;
	bool controller_state_changed;
	ChiakiPsChord ps_chord;
	// Invoked (outside state_mutex) on the rising edge of a chord fire, so the
	// owner can emit a client event. NULL = no notification. Set by streamconnection.
	void (*ps_chord_fired_cb)(void *user);
	void *ps_chord_fired_user;
	ChiakiMutex state_mutex;
	ChiakiCond state_cond;
} ChiakiFeedbackSender;

CHIAKI_EXPORT ChiakiErrorCode chiaki_feedback_sender_init(ChiakiFeedbackSender *feedback_sender, ChiakiTakion *takion);
CHIAKI_EXPORT void chiaki_feedback_sender_fini(ChiakiFeedbackSender *feedback_sender);
CHIAKI_EXPORT ChiakiErrorCode chiaki_feedback_sender_set_controller_state(ChiakiFeedbackSender *feedback_sender, ChiakiControllerState *state);
CHIAKI_EXPORT void chiaki_feedback_sender_set_ps_chord(ChiakiFeedbackSender *feedback_sender, bool enabled, uint32_t hold_ms);

/**
 * Set the callback invoked (with state_mutex released) on the rising edge of a chord
 * fire. Takes state_mutex so the store is published under the same lock the feedback
 * thread reads it with. Pass NULL to disable.
 */
CHIAKI_EXPORT void chiaki_feedback_sender_set_ps_chord_fired_cb(ChiakiFeedbackSender *feedback_sender, void (*cb)(void *user), void *user);

/**
 * Apply the PS-chord transform to @a state (pure function of state+chord+now;
 * exposed for unit tests). Mutates @a chord tracking fields and @a state's
 * buttons: suppresses OPTIONS+SHARE while both are held, synthesizes BUTTON_PS
 * for CHIAKI_PS_CHORD_PULSE_MS once the hold threshold is crossed.
 */
#define CHIAKI_PS_CHORD_PULSE_MS 150
CHIAKI_EXPORT void chiaki_ps_chord_apply(ChiakiPsChord *chord, ChiakiControllerState *state, uint64_t now_ms);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_FEEDBACKSENDER_H
