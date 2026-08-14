// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// Regression tests for the ctrl thread lifecycle guard.
//
// chiaki_ctrl_join() used to decide whether a thread existed by memcmp-ing ctrl->thread
// against a zeroed ChiakiThread. ChiakiThread wraps an opaque pthread_t, so that test is
// unsound: a stale or partially written handle compares non-zero while still being invalid,
// and the guard then forwards it to pthread_join(). pthread_join() does not report an
// invalid handle as an error — bionic aborts the process:
//
//     invalid pthread_t 0x100000000 passed to pthread_join
//
// which showed up as the chiaki_thread_join SIGABRT cluster in Play vitals for 2.11.2, and
// (because the join never completed) let session teardown destroy notif_mutex underneath a
// still-running ctrl thread, producing the paired "pthread_mutex_lock called on a destroyed
// mutex" FORTIFY aborts.
//
// The guard now keys off an explicit ctrl->thread_started flag, so these cases must return
// cleanly instead of calling pthread_join at all. Under the old implementation the poisoned
// case below aborts the whole test binary.

#include <munit.h>

#include <chiaki/ctrl.h>
#include <chiaki/thread.h>

#include <string.h>

// A freshly zeroed ctrl was never started, so joining it is a no-op.
static MunitResult test_join_never_started(const MunitParameter p[], void *data)
{
	(void)p; (void)data;

	ChiakiCtrl ctrl;
	memset(&ctrl, 0, sizeof(ctrl));

	munit_assert_false(ctrl.thread_started);
	munit_assert_int(chiaki_ctrl_join(&ctrl), ==, CHIAKI_ERR_SUCCESS);
	munit_assert_false(ctrl.thread_started);

	return MUNIT_OK;
}

// The production regression: thread holds a non-zero but invalid handle while no thread is
// actually running. The old memcmp guard saw "non-zero, therefore started" and aborted in
// pthread_join. thread_started is the only thing allowed to answer this question.
static MunitResult test_join_poisoned_handle_never_started(const MunitParameter p[], void *data)
{
	(void)p; (void)data;

	ChiakiCtrl ctrl;
	memset(&ctrl, 0, sizeof(ctrl));
	// Any non-zero bit pattern reproduces the fault; 0xAB keeps it non-zero on both 32- and
	// 64-bit pthread_t, unlike the literal 0x100000000 seen in the arm64 crash reports.
	memset(&ctrl.thread, 0xAB, sizeof(ctrl.thread));
	ctrl.thread_started = false;

	munit_assert_int(chiaki_ctrl_join(&ctrl), ==, CHIAKI_ERR_SUCCESS);

	return MUNIT_OK;
}

// Joining twice must stay a no-op: after the first join the handle is spent, and handing a
// spent handle back to pthread_join is the same process-fatal mistake.
static MunitResult test_join_is_idempotent(const MunitParameter p[], void *data)
{
	(void)p; (void)data;

	ChiakiCtrl ctrl;
	memset(&ctrl, 0, sizeof(ctrl));
	memset(&ctrl.thread, 0xAB, sizeof(ctrl.thread));
	ctrl.thread_started = false;

	munit_assert_int(chiaki_ctrl_join(&ctrl), ==, CHIAKI_ERR_SUCCESS);
	munit_assert_int(chiaki_ctrl_join(&ctrl), ==, CHIAKI_ERR_SUCCESS);
	munit_assert_false(ctrl.thread_started);

	return MUNIT_OK;
}

static void *trivial_thread_func(void *arg)
{
	(void)arg;
	return NULL;
}

// Positive path: a genuinely running thread joins cleanly through the new guard, the flag
// drops, and a repeat join is a no-op instead of a second pthread_join on a spent handle.
// (chiaki_ctrl_start() itself isn't used here because it spins the real ctrl thread, which
// immediately tries to open a session connection; the guard only cares about thread +
// thread_started, so the thread is created directly the same way chiaki_ctrl_start does.)
static MunitResult test_join_real_thread(const MunitParameter p[], void *data)
{
	(void)p; (void)data;

	ChiakiCtrl ctrl;
	memset(&ctrl, 0, sizeof(ctrl));

	munit_assert_int(chiaki_thread_create(&ctrl.thread, trivial_thread_func, NULL), ==, CHIAKI_ERR_SUCCESS);
	ctrl.thread_started = true;

	munit_assert_int(chiaki_ctrl_join(&ctrl), ==, CHIAKI_ERR_SUCCESS);
	munit_assert_false(ctrl.thread_started);

	// The handle is spent; a second join must not reach pthread_join.
	munit_assert_int(chiaki_ctrl_join(&ctrl), ==, CHIAKI_ERR_SUCCESS);

	return MUNIT_OK;
}

MunitTest tests_ctrl_lifecycle[] = {
	{
		"/join_real_thread",
		test_join_real_thread,
		NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL
	},
	{
		"/join_never_started",
		test_join_never_started,
		NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL
	},
	{
		"/join_poisoned_handle_never_started",
		test_join_poisoned_handle_never_started,
		NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL
	},
	{
		"/join_is_idempotent",
		test_join_is_idempotent,
		NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL
	},
	{ NULL, NULL, NULL, NULL, MUNIT_TEST_OPTION_NONE, NULL }
};
