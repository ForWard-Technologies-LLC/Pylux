// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// ObjC bridge to Chiaki session API for iOS

#ifndef ChiakiSessionBridge_h
#define ChiakiSessionBridge_h

#import <Foundation/Foundation.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <chiaki/controller.h>

/**
 * Opaque session reference. Create with chiaki_session_bridge_create, free with chiaki_session_bridge_free.
 */
typedef void *ChiakiSessionRef;

/**
 * Event types matching ChiakiEventType (CHIAKI_EVENT_*).
 */
typedef enum {
    ChiakiSessionBridgeEventConnected = 0,
    ChiakiSessionBridgeEventLoginPinRequest = 1,
    ChiakiSessionBridgeEventHolepunch = 2,
    ChiakiSessionBridgeEventRegist = 3,
    ChiakiSessionBridgeEventNicknameReceived = 4,
    ChiakiSessionBridgeEventKeyboardOpen = 5,
    ChiakiSessionBridgeEventKeyboardTextChange = 6,
    ChiakiSessionBridgeEventKeyboardRemoteClose = 7,
    ChiakiSessionBridgeEventRumble = 8,
    ChiakiSessionBridgeEventQuit = 9,
    ChiakiSessionBridgeEventTriggerEffects = 10,
    ChiakiSessionBridgeEventMotionReset = 11,
    ChiakiSessionBridgeEventLedColor = 12,
    ChiakiSessionBridgeEventPlayerIndex = 13,
    ChiakiSessionBridgeEventHapticIntensity = 14,
    ChiakiSessionBridgeEventTriggerIntensity = 15,
} ChiakiSessionBridgeEventType;

/**
 * Flattened event data for bridge callback. Only relevant fields set per event_type.
 */
typedef struct ChiakiSessionBridgeEvent {
    ChiakiSessionBridgeEventType type;
    int quit_reason;           // ChiakiQuitReason when type == Quit
    const char *quit_reason_str;
    bool login_pin_incorrect;  // when type == LoginPinRequest
    uint8_t rumble_left;       // when type == Rumble
    uint8_t rumble_right;
    // Auto-registration data (when type == Regist)
    int regist_target;                   // ChiakiTarget
    uint8_t regist_server_mac[6];
    char regist_server_nickname[0x20];
    uint8_t regist_rp_regist_key[16];    // CHIAKI_SESSION_AUTH_SIZE
    uint32_t regist_rp_key_type;
    uint8_t regist_rp_key[16];
} ChiakiSessionBridgeEvent;

/**
 * Event callback - invoked from chiaki thread. Dispatch to main queue for UI updates.
 */
typedef void (*ChiakiSessionBridgeEventCallback)(const ChiakiSessionBridgeEvent *event, void *user);

/**
 * Connect info for local, PSN holepunch, or cloud streaming connections.
 * Caller must ensure host and cloud string pointers remain valid for session lifetime.
 */
typedef struct ChiakiSessionBridgeConnectInfo {
    const char *host;
    bool ps5;
    uint8_t regist_key[16];
    uint8_t morning[16];
    unsigned int video_width;
    unsigned int video_height;
    unsigned int video_max_fps;
    unsigned int video_bitrate;
    int video_codec; // 0=H264, 1=H265, 2=H265_HDR
    // PSN holepunch fields (optional, 0/NULL for local connections)
    uintptr_t holepunch_session;  // ChiakiHolepunchSession ptr (owned by native session after create)
    bool auto_regist;
    uint8_t psn_account_id[8];   // CHIAKI_PSN_ACCOUNT_ID_SIZE
    // Cloud streaming fields (optional, NULL/0 for non-cloud connections)
    int service_type;             // 0=REMOTE_PLAY, 1=PSNOW, 2=PSCLOUD
    const char *cloud_launch_spec;     // base64-encoded launch specification
    const char *cloud_handshake_key;   // base64-encoded handshake key
    const char *cloud_session_id;      // Gaikai session ID
    uint16_t cloud_port;               // cloud streaming port (0 for non-cloud)
    uint8_t cloud_psn_wrapper_type;    // last octet of private IP
    uint32_t cloud_mtu_in;             // MTU in from ping (0 = use default)
    uint32_t cloud_mtu_out;            // MTU out from ping (0 = use default)
    uint64_t cloud_rtt_us;             // RTT in microseconds from ping (0 = use default)
} ChiakiSessionBridgeConnectInfo;


/**
 * Initialize chiaki library (call once at app startup). Safe to call multiple times.
 * Returns 0 on success, non-zero ChiakiErrorCode on failure.
 */
int chiaki_session_bridge_init(void);

/**
 * Create a session. connect_info is copied; host string must remain valid.
 * event_cb and event_user are stored for event delivery.
 * Returns NULL on failure (check err_code if provided).
 */
ChiakiSessionRef chiaki_session_bridge_create(const ChiakiSessionBridgeConnectInfo *connect_info,
                                               ChiakiSessionBridgeEventCallback event_cb,
                                               void *event_user,
                                               int *err_code);

/**
 * Free session. Stops if running. Safe to call with NULL.
 */
void chiaki_session_bridge_free(ChiakiSessionRef ref);

/**
 * Start session (spawns background thread). Call before join.
 * Returns ChiakiErrorCode (0 = success).
 */
int chiaki_session_bridge_start(ChiakiSessionRef ref);

/**
 * Stop session. Idempotent.
 * Returns ChiakiErrorCode (0 = success).
 */
int chiaki_session_bridge_stop(ChiakiSessionRef ref);

/**
 * Join session thread (blocks until session ends).
 * Returns ChiakiErrorCode (0 = success).
 */
int chiaki_session_bridge_join(ChiakiSessionRef ref);

/**
 * Set controller state. state layout must match ChiakiControllerState.
 */
int chiaki_session_bridge_set_controller_state(ChiakiSessionRef ref, const void *state);

/**
 * Set login PIN (e.g. when LoginPinRequest event received).
 * pin: bytes, pin_size: length (typically 8).
 */
int chiaki_session_bridge_set_login_pin(ChiakiSessionRef ref, const uint8_t *pin, size_t pin_size);

/**
 * Set video sample callback. If NULL, video frames are dropped (Phase 1 stub).
 * Callback: return true if sample was consumed, false to request keyframe.
 */
void chiaki_session_bridge_set_video_sample_cb(ChiakiSessionRef ref,
                                               bool (*cb)(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user),
                                               void *user);

/**
 * Helpers for error/quit strings.
 */
const char *chiaki_session_bridge_error_string(int code);
const char *chiaki_session_bridge_quit_reason_string(int reason);
bool chiaki_session_bridge_quit_reason_is_error(int reason);

#endif /* ChiakiSessionBridge_h */
