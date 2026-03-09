// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// iOS bridge helpers - compiled as part of libchiaki to guarantee correct struct layout.
// The iOS ObjC bridge is compiled separately and may see different struct sizes for
// ChiakiSession due to platform-specific type differences. These wrappers ensure all
// struct field access happens in code compiled alongside the library itself.

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

#ifdef __cplusplus
}
#endif

#endif // CHIAKI_IOS_BRIDGE_HELPERS_H
