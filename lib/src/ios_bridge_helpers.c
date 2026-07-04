// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// iOS bridge helpers - see ios_bridge_helpers.h for rationale.

#include <chiaki/ios_bridge_helpers.h>
#include <chiaki/streamconnection.h> // F5 thread-safe video metric accessors

CHIAKI_EXPORT size_t chiaki_session_get_sizeof(void)
{
	return sizeof(ChiakiSession);
}

CHIAKI_EXPORT void chiaki_session_set_event_cb_ex(ChiakiSession *session, ChiakiEventCallback cb, void *user)
{
	chiaki_session_set_event_cb(session, cb, user);
}

CHIAKI_EXPORT void chiaki_session_set_video_sample_cb_ex(ChiakiSession *session, ChiakiVideoSampleCallback cb, void *user)
{
	chiaki_session_set_video_sample_cb(session, cb, user);
}

CHIAKI_EXPORT void chiaki_session_set_audio_sink_ex(ChiakiSession *session, ChiakiAudioSink *sink)
{
	chiaki_session_set_audio_sink(session, sink);
}

CHIAKI_EXPORT void chiaki_session_set_haptics_sink_ex(ChiakiSession *session, ChiakiAudioSink *sink)
{
	chiaki_session_set_haptics_sink(session, sink);
}

CHIAKI_EXPORT void chiaki_session_ctrl_set_display_sink_ex(ChiakiSession *session, ChiakiCtrlDisplaySink *sink)
{
	chiaki_session_ctrl_set_display_sink(session, sink);
}

CHIAKI_EXPORT void chiaki_session_set_log_ex(ChiakiSession *session, ChiakiLog *log)
{
	session->log = log;
}

CHIAKI_EXPORT void chiaki_session_set_host_addrinfo_selected_ex(ChiakiSession *session, struct addrinfo *ai)
{
	session->connect_info.host_addrinfo_selected = ai;
}

CHIAKI_EXPORT void chiaki_session_set_enable_dualsense_ex(ChiakiSession *session, bool val)
{
	session->connect_info.enable_dualsense = val;
}

CHIAKI_EXPORT void chiaki_session_set_target_ex(ChiakiSession *session, ChiakiTarget target)
{
	session->target = target;
}

CHIAKI_EXPORT void chiaki_session_set_cloud_port_ex(ChiakiSession *session, uint16_t port)
{
	session->cloud_port = port;
}

CHIAKI_EXPORT void chiaki_session_set_cloud_psn_wrapper_type_ex(ChiakiSession *session, uint8_t type)
{
	session->cloud_psn_wrapper_type = type;
}

CHIAKI_EXPORT void chiaki_session_set_service_type_ex(ChiakiSession *session, ChiakiServiceType st)
{
	session->service_type = st;
}

CHIAKI_EXPORT void chiaki_session_get_stream_metrics_ex(ChiakiSession *session,
		double *bitrate_mbps, double *packet_loss, uint64_t *dropped_frames,
		double *fps, double *rtt_ms, int *width, int *height)
{
	double v_bitrate = 0.0, v_loss = 0.0, v_fps = 0.0, v_rtt = 0.0;
	uint64_t v_drops = 0;
	int v_w = 0, v_h = 0;
	if(session)
	{
		ChiakiStreamConnection *sc = &session->stream_connection;
		v_bitrate = sc->measured_bitrate;
		v_loss = sc->congestion_control.packet_loss;
		v_fps = sc->measured_fps;
		v_rtt = sc->measured_rtt_ms;
		// Thread-safe reads (state_mutex-guarded): the takion thread can free video_receiver
		// during teardown while this metrics poll runs on another thread (F5).
		v_drops = chiaki_stream_connection_video_frames_lost(sc);
		unsigned int rw = 0, rh = 0;
		if(chiaki_stream_connection_video_resolution(sc, &rw, &rh))
		{
			v_w = (int)rw;
			v_h = (int)rh;
		}
		// Fall back to the requested profile before the first adaptive profile is selected.
		if(v_w == 0 || v_h == 0)
		{
			v_w = (int)session->connect_info.video_profile.width;
			v_h = (int)session->connect_info.video_profile.height;
		}
	}
	if(bitrate_mbps) *bitrate_mbps = v_bitrate;
	if(packet_loss) *packet_loss = v_loss;
	if(dropped_frames) *dropped_frames = v_drops;
	if(fps) *fps = v_fps;
	if(rtt_ms) *rtt_ms = v_rtt;
	if(width) *width = v_w;
	if(height) *height = v_h;
}
