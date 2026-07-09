// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Tests for the unified PS-button chord transform (chiaki_ps_chord_apply):
// OPTIONS+SHARE held >= hold_ms -> one synthesized BUTTON_PS pulse, with the
// two source buttons suppressed for the duration of the hold.

#include <munit.h>

#include <chiaki/feedbacksender.h>
#include <chiaki/controller.h>

#define CHORD_BITS (CHIAKI_CONTROLLER_BUTTON_OPTIONS | CHIAKI_CONTROLLER_BUTTON_SHARE)

static ChiakiPsChord chord_default(void)
{
	ChiakiPsChord chord = { 0 };
	chord.enabled = true;
	chord.hold_ms = 2000;
	return chord;
}

static ChiakiControllerState state_with_buttons(uint32_t buttons)
{
	ChiakiControllerState state;
	chiaki_controller_state_set_idle(&state);
	state.buttons = buttons;
	return state;
}

static MunitResult test_suppression_and_no_fire_below_threshold(const MunitParameter params[], void *user)
{
	ChiakiPsChord chord = chord_default();

	ChiakiControllerState state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1000);
	munit_assert_uint32(state.buttons & CHORD_BITS, ==, 0); // suppressed from the first wake
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, ==, 0);

	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1000 + 1999); // 1ms short of the threshold
	munit_assert_uint32(state.buttons & CHORD_BITS, ==, 0);
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, ==, 0);
	return MUNIT_OK;
}

static MunitResult test_fires_once_with_pulse_then_release(const MunitParameter params[], void *user)
{
	ChiakiPsChord chord = chord_default();

	ChiakiControllerState state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1000); // chord starts

	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 3000); // threshold crossed -> pulse starts
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, !=, 0);
	munit_assert_uint32(state.buttons & CHORD_BITS, ==, 0);

	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 3000 + CHIAKI_PS_CHORD_PULSE_MS - 1); // still inside the pulse
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, !=, 0);

	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 3000 + CHIAKI_PS_CHORD_PULSE_MS); // pulse over -> PS released
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, ==, 0);

	// latched: keep holding well past another hold interval -> no second pulse
	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 10000);
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, ==, 0);
	return MUNIT_OK;
}

static MunitResult test_rearm_after_release(const MunitParameter params[], void *user)
{
	ChiakiPsChord chord = chord_default();

	ChiakiControllerState state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1000);
	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 3000); // fired
	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 4000); // pulse over, still held: latched

	state = state_with_buttons(0); // full release
	chiaki_ps_chord_apply(&chord, &state, 5000);
	munit_assert_uint32(state.buttons, ==, 0);

	// re-hold: fires again after a fresh hold interval
	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 6000);
	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 8000);
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, !=, 0);
	return MUNIT_OK;
}

static MunitResult test_early_release_completes_pulse(const MunitParameter params[], void *user)
{
	ChiakiPsChord chord = chord_default();

	ChiakiControllerState state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1000);
	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 3000); // pulse until 3000 + PULSE_MS

	// chord released mid-pulse: the started press still completes...
	state = state_with_buttons(0);
	chiaki_ps_chord_apply(&chord, &state, 3050);
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, !=, 0);

	// ...and cleanly releases afterwards
	state = state_with_buttons(0);
	chiaki_ps_chord_apply(&chord, &state, 3000 + CHIAKI_PS_CHORD_PULSE_MS + 10);
	munit_assert_uint32(state.buttons, ==, 0);
	return MUNIT_OK;
}

static MunitResult test_staggered_release_after_fire_is_consumed(const MunitParameter params[], void *user)
{
	// Regression: after the chord fires, the user is still holding both buttons
	// and releases them a few frames apart. The button released LAST must not
	// land as a real press (SHARE would otherwise open the PS5 capture gallery
	// on top of the home overlay the chord just opened).
	ChiakiPsChord chord = chord_default();

	ChiakiControllerState state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1000);   // chord starts
	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 3000);   // threshold crossed -> fired + pulse
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, !=, 0);

	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 3000 + CHIAKI_PS_CHORD_PULSE_MS); // pulse over, both still down
	munit_assert_uint32(state.buttons, ==, 0);

	// OPTIONS released first, SHARE still held -> SHARE must stay consumed
	state = state_with_buttons(CHIAKI_CONTROLLER_BUTTON_SHARE);
	chiaki_ps_chord_apply(&chord, &state, 3500);
	munit_assert_uint32(state.buttons, ==, 0);
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, ==, 0);

	// keeps hanging on to SHARE much longer -> still consumed, no second pulse
	state = state_with_buttons(CHIAKI_CONTROLLER_BUTTON_SHARE);
	chiaki_ps_chord_apply(&chord, &state, 6000);
	munit_assert_uint32(state.buttons, ==, 0);

	// full release re-arms; a later lone SHARE tap passes through normally
	state = state_with_buttons(0);
	chiaki_ps_chord_apply(&chord, &state, 6100);
	state = state_with_buttons(CHIAKI_CONTROLLER_BUTTON_SHARE);
	chiaki_ps_chord_apply(&chord, &state, 6200);
	munit_assert_uint32(state.buttons, ==, CHIAKI_CONTROLLER_BUTTON_SHARE);
	return MUNIT_OK;
}

static MunitResult test_staggered_release_before_fire_is_consumed(const MunitParameter params[], void *user)
{
	// Regression: the user engages the chord (both down) but lets go BEFORE the
	// 2s threshold, releasing the two buttons a few frames apart. The button
	// released last must not leak -- aborting the hold shouldn't fire OPTIONS or
	// open the SHARE capture menu.
	ChiakiPsChord chord = chord_default();

	ChiakiControllerState state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1000);   // engaged (both down), not fired
	munit_assert_uint32(state.buttons, ==, 0);
	state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1500);   // still under threshold
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_PS, ==, 0); // never fired

	// OPTIONS released first, SHARE lingers -> SHARE consumed, not leaked
	state = state_with_buttons(CHIAKI_CONTROLLER_BUTTON_SHARE);
	chiaki_ps_chord_apply(&chord, &state, 1600);
	munit_assert_uint32(state.buttons, ==, 0);

	// full release re-arms; a later lone SHARE tap passes through normally
	state = state_with_buttons(0);
	chiaki_ps_chord_apply(&chord, &state, 1700);
	state = state_with_buttons(CHIAKI_CONTROLLER_BUTTON_SHARE);
	chiaki_ps_chord_apply(&chord, &state, 1800);
	munit_assert_uint32(state.buttons, ==, CHIAKI_CONTROLLER_BUTTON_SHARE);
	return MUNIT_OK;
}

static MunitResult test_disabled_passthrough_and_other_buttons(const MunitParameter params[], void *user)
{
	ChiakiPsChord chord = chord_default();
	chord.enabled = false;

	ChiakiControllerState state = state_with_buttons(CHORD_BITS);
	chiaki_ps_chord_apply(&chord, &state, 1000);
	chiaki_ps_chord_apply(&chord, &state, 5000);
	munit_assert_uint32(state.buttons, ==, CHORD_BITS); // untouched when disabled

	// enabled: unrelated buttons pass through while the chord is suppressed
	chord = chord_default();
	state = state_with_buttons(CHORD_BITS | CHIAKI_CONTROLLER_BUTTON_CROSS);
	chiaki_ps_chord_apply(&chord, &state, 1000);
	munit_assert_uint32(state.buttons & CHIAKI_CONTROLLER_BUTTON_CROSS, !=, 0);
	munit_assert_uint32(state.buttons & CHORD_BITS, ==, 0);

	// single-button presses are never suppressed
	chord = chord_default();
	state = state_with_buttons(CHIAKI_CONTROLLER_BUTTON_SHARE);
	chiaki_ps_chord_apply(&chord, &state, 1000);
	munit_assert_uint32(state.buttons, ==, CHIAKI_CONTROLLER_BUTTON_SHARE);
	return MUNIT_OK;
}

MunitTest tests_ps_chord[] = {
	{ "/suppression_and_threshold", test_suppression_and_no_fire_below_threshold, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/fires_once_with_pulse", test_fires_once_with_pulse_then_release, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/rearm_after_release", test_rearm_after_release, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/early_release_completes_pulse", test_early_release_completes_pulse, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/staggered_release_after_fire", test_staggered_release_after_fire_is_consumed, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/staggered_release_before_fire", test_staggered_release_before_fire_is_consumed, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ "/disabled_passthrough", test_disabled_passthrough_and_other_buttons, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL },
	{ NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL }
};
