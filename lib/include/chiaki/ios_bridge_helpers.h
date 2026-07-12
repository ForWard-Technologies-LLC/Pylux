// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
//
// iOS bridge helpers — compiled as part of libchiaki (CMake) to guarantee correct
// struct layout when accessed from Xcode-compiled ObjC/Swift code.
//
// ╔══════════════════════════════════════════════════════════════════════════╗
// ║  ABI MISMATCH WARNING                                                  ║
// ║                                                                        ║
// ║  libchiaki is built as a static library by CMake (arm64-iphoneos,      ║
// ║  Release). The iOS app is built separately by Xcode (Debug or Release).║
// ║  Large structs like ChiakiSession embed many sub-structs whose sizes   ║
// ║  can differ between the two compilation units (different compiler       ║
// ║  flags, padding, conditional fields). This causes offsetof() to        ║
// ║  diverge — writing session->field in Xcode hits the wrong byte.        ║
// ║                                                                        ║
// ║  RULES:                                                                ║
// ║  1. NEVER access ChiakiSession fields directly from Xcode-compiled     ║
// ║     code (.m / .mm / .swift bridge). Use the _ex() helpers below or    ║
// ║     add new ones here.                                                 ║
// ║  2. Always allocate ChiakiSession with chiaki_session_get_sizeof(),    ║
// ║     never sizeof(ChiakiSession).                                       ║
// ║  3. If you add a new field to ChiakiSession that iOS needs, add a      ║
// ║     corresponding _ex() setter/getter here.                            ║
// ║  4. Smaller structs (ChiakiSenkusha, ChiakiEvent, ChiakiConnectInfo,   ║
// ║     ChiakiDiscoveryHost, etc.) are lower risk but could diverge too.   ║
// ║     If you hit unexplained data corruption, check struct layout first. ║
// ║  5. Rule 1 includes the `static inline` setters in the chiaki headers  ║
// ║     (chiaki_session_set_haptics_sink & co.) — they are field access    ║
// ║     compiled on the caller's side. Violating this made the haptics     ║
// ║     sink NULL and killed Remote Play rumble on iOS (2026-07-08).       ║
// ║     ios/build.sh now FAILS the build on such calls                     ║
// ║     (check_forbidden_inline_setters).                                  ║
// ╚══════════════════════════════════════════════════════════════════════════╝

#ifndef CHIAKI_IOS_BRIDGE_HELPERS_H
#define CHIAKI_IOS_BRIDGE_HELPERS_H

#include <chiaki/common.h>
#include <chiaki/session.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

CHIAKI_EXPORT size_t chiaki_session_get_sizeof(void);

CHIAKI_EXPORT void chiaki_session_set_event_cb_ex(ChiakiSession *session, ChiakiEventCallback cb, void *user);
CHIAKI_EXPORT void chiaki_session_set_video_sample_cb_ex(ChiakiSession *session, ChiakiVideoSampleCallback cb, void *user);
CHIAKI_EXPORT void chiaki_session_set_audio_sink_ex(ChiakiSession *session, ChiakiAudioSink *sink);
CHIAKI_EXPORT void chiaki_session_set_haptics_sink_ex(ChiakiSession *session, ChiakiAudioSink *sink);
CHIAKI_EXPORT void chiaki_session_ctrl_set_display_sink_ex(ChiakiSession *session, ChiakiCtrlDisplaySink *sink);

CHIAKI_EXPORT void chiaki_session_set_log_ex(ChiakiSession *session, ChiakiLog *log);
CHIAKI_EXPORT void chiaki_session_set_host_addrinfo_selected_ex(ChiakiSession *session, struct addrinfo *ai);
CHIAKI_EXPORT void chiaki_session_set_enable_dualsense_ex(ChiakiSession *session, bool val);
CHIAKI_EXPORT void chiaki_session_set_target_ex(ChiakiSession *session, ChiakiTarget target);
CHIAKI_EXPORT void chiaki_session_set_cloud_port_ex(ChiakiSession *session, uint16_t port);
CHIAKI_EXPORT void chiaki_session_set_cloud_psn_wrapper_type_ex(ChiakiSession *session, uint8_t type);
CHIAKI_EXPORT void chiaki_session_set_service_type_ex(ChiakiSession *session, ChiakiServiceType st);

// Live stream metrics for the on-screen stats overlay. All values are owned/computed
// by libchiaki (shared with Qt/Android) so Swift just renders them. Out-params are
// primitives (ABI-safe across the CMake/Xcode boundary); pass NULL for any you don't
// need. Cheap best-effort read with no locking (same as the other clients' polling).
CHIAKI_EXPORT void chiaki_session_get_stream_metrics_ex(ChiakiSession *session,
		double *bitrate_mbps, double *packet_loss, uint64_t *dropped_frames,
		double *fps, double *rtt_ms, int *width, int *height);

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_IOS_BRIDGE_HELPERS_H
