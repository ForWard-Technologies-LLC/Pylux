// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// ObjC bridge to Chiaki session API for iOS

#import "ChiakiSessionBridge.h"
#import "PyluxChiakiLog.h"
#import <dispatch/dispatch.h>
#include <chiaki/config.h>
#include <chiaki/session.h>
#include <chiaki/ios_bridge_helpers.h>
#include <chiaki/log.h>
#include <chiaki/common.h>
#include <chiaki/controller.h>
#if CHIAKI_LIB_ENABLE_OPUS
#include <chiaki/opusdecoder.h>
#import "ChiakiAudioOutputIOS.h"
#endif
#include <stdlib.h>
#include <string.h>
#include <os/log.h>

static os_log_t s_log;

typedef struct {
    ChiakiSession *session;  // Separately allocated via chiaki_session_get_sizeof()
    ChiakiLog *log;
    char *host_copy;
    /// chiaki_session_init stores these pointers on ChiakiSession for cloud BIG; must live until bridge_free.
    char *cloud_launch_spec_copy;
    char *cloud_handshake_key_copy;
    ChiakiSessionBridgeEventCallback event_cb;
    void *event_user;
    bool (*video_sample_cb)(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user);
    void *video_sample_cb_user;
#if CHIAKI_LIB_ENABLE_OPUS
    ChiakiOpusDecoder opus_decoder;
    void *audio_output;
    bool use_opus_audio; // Remote Play, PS Now, PS Cloud — same Opus → PCM sink (lib handles PS Cloud reassembly)
#endif
} iOSChiakiSession;

static void log_cb(ChiakiLogLevel level, const char *msg, void *user)
{
    (void)user;
    // Use DEFAULT (not INFO) so messages are persisted and visible via idevicesyslog.
    // INFO messages are dropped by the OS unless a logging profile is installed.
    os_log_type_t type = OS_LOG_TYPE_DEFAULT;
    if (level == CHIAKI_LOG_ERROR)
        type = OS_LOG_TYPE_ERROR;
    os_log_with_type(s_log, type, "%{public}s", msg ? msg : "");
}

static void event_cb_chiaki(ChiakiEvent *event, void *user)
{
    iOSChiakiSession *s = (iOSChiakiSession *)user;
    if (!s->event_cb)
        return;
    ChiakiSessionBridgeEvent bridge_event = { 0 };
    bridge_event.type = (ChiakiSessionBridgeEventType)event->type;
    switch (event->type) {
        case CHIAKI_EVENT_QUIT:
            bridge_event.quit_reason = (int)event->quit.reason;
            bridge_event.quit_reason_str = event->quit.reason_str;
            break;
        case CHIAKI_EVENT_LOGIN_PIN_REQUEST:
            bridge_event.login_pin_incorrect = event->login_pin_request.pin_incorrect;
            break;
        case CHIAKI_EVENT_RUMBLE:
            bridge_event.rumble_left = event->rumble.left;
            bridge_event.rumble_right = event->rumble.right;
            break;
        case CHIAKI_EVENT_REGIST:
            bridge_event.regist_target = (int)event->host.target;
            memcpy(bridge_event.regist_server_mac, event->host.server_mac, 6);
            memcpy(bridge_event.regist_server_nickname, event->host.server_nickname, sizeof(bridge_event.regist_server_nickname));
            memcpy(bridge_event.regist_rp_regist_key, event->host.rp_regist_key, 16);
            bridge_event.regist_rp_key_type = event->host.rp_key_type;
            memcpy(bridge_event.regist_rp_key, event->host.rp_key, 16);
            break;
        default:
            break;
    }
    s->event_cb(&bridge_event, s->event_user);
}

static bool video_sample_cb_stub(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user)
{
    (void)buf;
    (void)buf_size;
    (void)frames_lost;
    (void)frame_recovered;
    iOSChiakiSession *s = (iOSChiakiSession *)user;
    if (s->video_sample_cb)
        return s->video_sample_cb(buf, buf_size, frames_lost, frame_recovered, s->video_sample_cb_user);
    return true; // consume to avoid keyframe request
}

static int codec_from_int(int c)
{
    switch (c) {
        case 1: return CHIAKI_CODEC_H265;
        case 2: return CHIAKI_CODEC_H265_HDR;
        default: return CHIAKI_CODEC_H264;
    }
}

int chiaki_session_bridge_init(void)
{
    static dispatch_once_t once;
    static int init_err = 0;
    dispatch_once(&once, ^{
        s_log = os_log_create("com.pylux.stream", "ChiakiSessionBridge");
        init_err = (int)chiaki_lib_init();
    });
    return init_err;
}

ChiakiSessionRef chiaki_session_bridge_create(const ChiakiSessionBridgeConnectInfo *connect_info,
                                               ChiakiSessionBridgeEventCallback event_cb,
                                               void *event_user,
                                               int *err_code)
{
    if (err_code)
        *err_code = 0;
    if (!connect_info || !connect_info->host)
        return NULL;
    int err = chiaki_session_bridge_init();
    if (err != 0) {
        if (err_code) *err_code = err;
        return NULL;
    }
    iOSChiakiSession *s = (iOSChiakiSession *)calloc(1, sizeof(iOSChiakiSession));
    if (!s) {
        if (err_code) *err_code = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    s->host_copy = strdup(connect_info->host);
    if (!s->host_copy) {
        free(s);
        if (err_code) *err_code = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    // Allocate using the library's own sizeof to avoid struct layout mismatch
    s->session = (ChiakiSession *)calloc(1, chiaki_session_get_sizeof());
    if (!s->session) {
        free(s->host_copy);
        free(s);
        if (err_code) *err_code = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    s->log = (ChiakiLog *)malloc(sizeof(ChiakiLog));
    if (!s->log) {
        free(s->session);
        free(s->host_copy);
        free(s);
        if (err_code) *err_code = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    pylux_chiaki_log_init(s->log, log_cb, NULL);

    ChiakiConnectInfo ci = { 0 };
    ci.ps5 = connect_info->ps5;
    ci.host = s->host_copy;
    memcpy(ci.regist_key, connect_info->regist_key, sizeof(ci.regist_key));
    memcpy(ci.morning, connect_info->morning, sizeof(ci.morning));
    ci.video_profile.width = connect_info->video_width;
    ci.video_profile.height = connect_info->video_height;
    ci.video_profile.max_fps = connect_info->video_max_fps;
    ci.video_profile.bitrate = connect_info->video_bitrate;
    ci.video_profile.codec = (ChiakiCodec)codec_from_int(connect_info->video_codec);
    ci.video_profile_auto_downgrade = true;
    ci.audio_video_disabled = CHIAKI_NONE_DISABLED;
    ci.holepunch_session = (ChiakiHolepunchSession)connect_info->holepunch_session;
    ci.auto_regist = connect_info->auto_regist;
    memcpy(ci.psn_account_id, connect_info->psn_account_id, sizeof(ci.psn_account_id));

    // Cloud streaming fields (matching Android chiaki-jni.c).
    // Session keeps pointers to launch_spec / handshake_key — do NOT free until after chiaki_session_fini.
    ci.service_type = (ChiakiServiceType)connect_info->service_type;
    s->cloud_launch_spec_copy = connect_info->cloud_launch_spec ? strdup(connect_info->cloud_launch_spec) : NULL;
    s->cloud_handshake_key_copy = connect_info->cloud_handshake_key ? strdup(connect_info->cloud_handshake_key) : NULL;
    if ((connect_info->cloud_launch_spec && !s->cloud_launch_spec_copy)
        || (connect_info->cloud_handshake_key && !s->cloud_handshake_key_copy)) {
        free(s->cloud_launch_spec_copy);
        free(s->cloud_handshake_key_copy);
        free(s->log);
        free(s->session);
        free(s->host_copy);
        free(s);
        if (err_code) *err_code = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    char *cloud_session_id_copy = connect_info->cloud_session_id ? strdup(connect_info->cloud_session_id) : NULL;
    if (connect_info->cloud_session_id && !cloud_session_id_copy) {
        free(s->cloud_launch_spec_copy);
        free(s->cloud_handshake_key_copy);
        s->cloud_launch_spec_copy = NULL;
        s->cloud_handshake_key_copy = NULL;
        free(s->log);
        free(s->session);
        free(s->host_copy);
        free(s);
        if (err_code) *err_code = CHIAKI_ERR_MEMORY;
        return NULL;
    }
    ci.cloud_launch_spec = s->cloud_launch_spec_copy;
    ci.cloud_handshake_key = s->cloud_handshake_key_copy;
    ci.cloud_session_id = cloud_session_id_copy;
    ci.cloud_port = connect_info->cloud_port;
    ci.cloud_psn_wrapper_type = connect_info->cloud_psn_wrapper_type;
    ci.cloud_mtu_in = connect_info->cloud_mtu_in;
    ci.cloud_mtu_out = connect_info->cloud_mtu_out;
    ci.cloud_rtt_us = connect_info->cloud_rtt_us;

    ChiakiErrorCode ec = chiaki_session_init(s->session, &ci, s->log);

    if (cloud_session_id_copy)
        free(cloud_session_id_copy);

    if (ec != CHIAKI_ERR_SUCCESS) {
        free(s->cloud_launch_spec_copy);
        free(s->cloud_handshake_key_copy);
        s->cloud_launch_spec_copy = NULL;
        s->cloud_handshake_key_copy = NULL;
        free(s->log);
        free(s->session);
        free(s->host_copy);
        free(s);
        if (err_code) *err_code = (int)ec;
        return NULL;
    }
    s->event_cb = event_cb;
    s->event_user = event_user;
    chiaki_session_set_event_cb_ex(s->session, event_cb_chiaki, s);
    chiaki_session_set_video_sample_cb_ex(s->session, video_sample_cb_stub, s);

#if CHIAKI_LIB_ENABLE_OPUS
    /* ChiakiOpusDecoder + ios_chiaki_audio_output: header_cb configures Opus; frame_cb receives raw packets (codec 5).
     * PS Cloud vs other modes differ inside lib/audioreceiver.c only; the session audio_sink contract is the same. */
    s->use_opus_audio = false;
    s->audio_output = ios_chiaki_audio_output_create();
    if (!s->audio_output) {
        os_log_with_type(s_log, OS_LOG_TYPE_ERROR, "Audio: failed to alloc output (service_type=%d)", connect_info->service_type);
    } else {
        chiaki_opus_decoder_init(&s->opus_decoder, s->log);
        s->opus_decoder.cb_user = s->audio_output;
        s->opus_decoder.settings_cb = ios_chiaki_audio_output_settings;
        s->opus_decoder.frame_cb = ios_chiaki_opus_frame_bridge;
        ChiakiAudioSink audio_sink;
        chiaki_opus_decoder_get_sink(&s->opus_decoder, &audio_sink);
        chiaki_session_set_audio_sink_ex(s->session, &audio_sink);
        s->use_opus_audio = true;
        os_log(s_log, "Audio: ChiakiOpusDecoder + queue (service_type=%d)", connect_info->service_type);
    }
#endif

    return (ChiakiSessionRef)s;
}

void chiaki_session_bridge_free(ChiakiSessionRef ref)
{
    if (!ref) return;
    iOSChiakiSession *s = (iOSChiakiSession *)ref;
    if (s->session) {
        chiaki_session_fini(s->session);
        free(s->session);
    }
    free(s->cloud_launch_spec_copy);
    free(s->cloud_handshake_key_copy);
#if CHIAKI_LIB_ENABLE_OPUS
    if (s->use_opus_audio && s->audio_output) {
        chiaki_opus_decoder_fini(&s->opus_decoder);
        ios_chiaki_audio_output_free(s->audio_output);
    }
#endif
    free(s->log);
    free(s->host_copy);
    free(s);
}

int chiaki_session_bridge_start(ChiakiSessionRef ref)
{
    if (!ref)
        return CHIAKI_ERR_UNINITIALIZED;
    iOSChiakiSession *s = (iOSChiakiSession *)ref;
    return (int)chiaki_session_start(s->session);
}

int chiaki_session_bridge_stop(ChiakiSessionRef ref)
{
    if (!ref) return CHIAKI_ERR_UNINITIALIZED;
    return (int)chiaki_session_stop(((iOSChiakiSession *)ref)->session);
}

int chiaki_session_bridge_join(ChiakiSessionRef ref)
{
    if (!ref) return CHIAKI_ERR_UNINITIALIZED;
    return (int)chiaki_session_join(((iOSChiakiSession *)ref)->session);
}

int chiaki_session_bridge_set_controller_state(ChiakiSessionRef ref, const void *state)
{
    if (!ref || !state) return CHIAKI_ERR_INVALID_DATA;
    return (int)chiaki_session_set_controller_state(((iOSChiakiSession *)ref)->session, (ChiakiControllerState *)state);
}

int chiaki_session_bridge_set_login_pin(ChiakiSessionRef ref, const uint8_t *pin, size_t pin_size)
{
    if (!ref) return CHIAKI_ERR_UNINITIALIZED;
    return (int)chiaki_session_set_login_pin(((iOSChiakiSession *)ref)->session, pin, pin_size);
}

void chiaki_session_bridge_set_video_sample_cb(ChiakiSessionRef ref,
                                               bool (*cb)(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user),
                                               void *user)
{
    if (!ref) return;
    iOSChiakiSession *s = (iOSChiakiSession *)ref;
    s->video_sample_cb = cb;
    s->video_sample_cb_user = user;
}

const char *chiaki_session_bridge_error_string(int code)
{
    return chiaki_error_string((ChiakiErrorCode)code);
}

const char *chiaki_session_bridge_quit_reason_string(int reason)
{
    return chiaki_quit_reason_string((ChiakiQuitReason)reason);
}

bool chiaki_session_bridge_quit_reason_is_error(int reason)
{
    return chiaki_quit_reason_is_error((ChiakiQuitReason)reason);
}
