// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// PCM playback: Chiaki decodes Opus to int16; we buffer and feed AudioQueue (pull callback, ring buffer).

#import "ChiakiAudioOutputIOS.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <dispatch/dispatch.h>
#import <pthread.h>
#import <stdlib.h>
#import <string.h>
#import <os/log.h>

#define RING_BYTES (512 * 1024)
#define NUM_AQ_BUFS 4
#define AQ_BUF_BYTES 4096

static os_log_t g_audio_log;

typedef struct PyluxChiakiAudioOutput {
    AudioQueueRef aq;
    AudioQueueBufferRef bufs[NUM_AQ_BUFS];
    int n_bufs;
    uint32_t channels;
    uint8_t *ring;
    size_t ring_cap;
    size_t read_pos;
    size_t byte_count;
    pthread_mutex_t mtx;
} PyluxChiakiAudioOutput;

static size_t ring_space(PyluxChiakiAudioOutput *a) {
    return a->ring_cap - a->byte_count;
}

static void ring_push(PyluxChiakiAudioOutput *a, const void *data, size_t len) {
    pthread_mutex_lock(&a->mtx);
    if (len > ring_space(a)) {
        os_log_with_type(g_audio_log, OS_LOG_TYPE_DEFAULT, "[ChiakiAudio] ring overflow, dropping %zu bytes", len);
        pthread_mutex_unlock(&a->mtx);
        return;
    }
    size_t w = (a->read_pos + a->byte_count) % a->ring_cap;
    size_t first = len;
    if (w + first > a->ring_cap)
        first = a->ring_cap - w;
    memcpy(a->ring + w, data, first);
    memcpy(a->ring, (const uint8_t *)data + first, len - first);
    a->byte_count += len;
    pthread_mutex_unlock(&a->mtx);
}

static size_t ring_pop(PyluxChiakiAudioOutput *a, void *dst, size_t max) {
    pthread_mutex_lock(&a->mtx);
    size_t n = max < a->byte_count ? max : a->byte_count;
    size_t first = n;
    if (a->read_pos + first > a->ring_cap)
        first = a->ring_cap - a->read_pos;
    memcpy(dst, a->ring + a->read_pos, first);
    memcpy((uint8_t *)dst + first, a->ring, n - first);
    a->read_pos = (a->read_pos + n) % a->ring_cap;
    a->byte_count -= n;
    pthread_mutex_unlock(&a->mtx);
    return n;
}

static void ring_reset(PyluxChiakiAudioOutput *a) {
    pthread_mutex_lock(&a->mtx);
    a->read_pos = 0;
    a->byte_count = 0;
    pthread_mutex_unlock(&a->mtx);
}

/// Chiaki calls settings from a worker thread; AVAudioSession and AudioQueue setup must run on the main thread.
static void run_on_main(void (^block)(void)) {
    if ([NSThread isMainThread]) {
        block();
    } else {
        dispatch_sync(dispatch_get_main_queue(), block);
    }
}

static void audio_teardown(PyluxChiakiAudioOutput *ao) {
    if (!ao->aq)
        return;
    AudioQueueStop(ao->aq, true);
    for (int i = 0; i < ao->n_bufs; i++) {
        if (ao->bufs[i]) {
            AudioQueueFreeBuffer(ao->aq, ao->bufs[i]);
            ao->bufs[i] = NULL;
        }
    }
    ao->n_bufs = 0;
    AudioQueueDispose(ao->aq, true);
    ao->aq = NULL;
    ring_reset(ao);
}

static void aq_output_callback(void *userdata, AudioQueueRef q, AudioQueueBufferRef buf) {
    (void)q;
    PyluxChiakiAudioOutput *ao = userdata;
    UInt32 cap = buf->mAudioDataBytesCapacity;
    size_t n = ring_pop(ao, buf->mAudioData, cap);
    if (n < cap)
        memset((uint8_t *)buf->mAudioData + n, 0, cap - n);
    buf->mAudioDataByteSize = cap;
    AudioQueueEnqueueBuffer(ao->aq, buf, 0, NULL);
}

void *ios_chiaki_audio_output_create(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        g_audio_log = os_log_create("com.pylux.stream", "ChiakiAudio");
    });
    PyluxChiakiAudioOutput *ao = calloc(1, sizeof(*ao));
    if (!ao)
        return NULL;
    ao->ring_cap = RING_BYTES;
    ao->ring = malloc(ao->ring_cap);
    if (!ao->ring) {
        free(ao);
        return NULL;
    }
    pthread_mutex_init(&ao->mtx, NULL);
    return ao;
}

void ios_chiaki_audio_output_free(void *ptr) {
    if (!ptr)
        return;
    PyluxChiakiAudioOutput *ao = ptr;
    run_on_main(^{
        audio_teardown(ao);
    });
    pthread_mutex_destroy(&ao->mtx);
    free(ao->ring);
    free(ao);
}

void ios_chiaki_audio_output_settings(uint32_t channels, uint32_t rate, void *ptr) {
    PyluxChiakiAudioOutput *ao = ptr;
    if (!ao || channels < 1 || channels > 8 || rate < 8000)
        return;

    ao->channels = channels;

    run_on_main(^{
        audio_teardown(ao);

        NSError *nserr = nil;
        AVAudioSession *session = [AVAudioSession sharedInstance];
        // Reset session before reconfiguring; avoids paramErr -50 when category/options change mid-stream.
        [session setActive:NO error:nil];

        // Plain Playback only: AllowBluetoothA2DP + Playback yields AVAudioSessionErrorCodeBadParam (-50) when a
        // mediaplaybackd sibling session exists (e.g. Safari in-app browser after Add to Library). DefaultToSpeaker
        // is invalid with Playback (PlayAndRecord only). See pylux.log SessionCore.mm:517 / AudioAnalytics Session_Error.
        if (![session setCategory:AVAudioSessionCategoryPlayback error:&nserr]) {
            os_log_with_type(g_audio_log, OS_LOG_TYPE_ERROR, "[ChiakiAudio] setCategory failed: %{public}@", nserr.localizedDescription);
        }
        [session setMode:AVAudioSessionModeMoviePlayback error:&nserr];
        [session setPreferredSampleRate:(double)rate error:&nserr];
        [session setPreferredIOBufferDuration:0.02 error:&nserr];
        if (![session setActive:YES error:&nserr])
            os_log_with_type(g_audio_log, OS_LOG_TYPE_ERROR, "[ChiakiAudio] setActive failed: %{public}@", nserr.localizedDescription);

        AudioStreamBasicDescription fmt;
        memset(&fmt, 0, sizeof(fmt));
        fmt.mSampleRate = rate;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked;
        fmt.mBitsPerChannel = 16;
        fmt.mChannelsPerFrame = channels;
        fmt.mBytesPerFrame = (fmt.mBitsPerChannel / 8) * channels;
        fmt.mFramesPerPacket = 1;
        fmt.mBytesPerPacket = fmt.mBytesPerFrame;

        OSStatus st = AudioQueueNewOutput(&fmt, aq_output_callback, ao, NULL, NULL, 0, &ao->aq);
        if (st != noErr) {
            os_log_with_type(g_audio_log, OS_LOG_TYPE_ERROR, "[ChiakiAudio] AudioQueueNewOutput failed: %d", (int)st);
            ao->aq = NULL;
            return;
        }

        ao->n_bufs = 0;
        for (int i = 0; i < NUM_AQ_BUFS; i++) {
            AudioQueueBufferRef b = NULL;
            st = AudioQueueAllocateBuffer(ao->aq, AQ_BUF_BYTES, &b);
            if (st != noErr || !b)
                break;
            memset(b->mAudioData, 0, AQ_BUF_BYTES);
            b->mAudioDataByteSize = AQ_BUF_BYTES;
            AudioQueueEnqueueBuffer(ao->aq, b, 0, NULL);
            ao->bufs[ao->n_bufs++] = b;
        }

        st = AudioQueueStart(ao->aq, NULL);
        if (st != noErr)
            os_log_with_type(g_audio_log, OS_LOG_TYPE_ERROR, "[ChiakiAudio] AudioQueueStart failed: %d", (int)st);
        else
            os_log(g_audio_log, "[ChiakiAudio] stream started ch=%u rate=%u", channels, rate);
    });
}

void ios_chiaki_audio_output_frame(int16_t *buf, size_t total_interleaved_samples, void *ptr) {
    PyluxChiakiAudioOutput *ao = ptr;
    if (!ao || !buf || total_interleaved_samples == 0)
        return;
    ring_push(ao, buf, total_interleaved_samples * sizeof(int16_t));
}

void ios_chiaki_opus_frame_bridge(int16_t *buf, size_t samples_per_channel, void *user) {
    PyluxChiakiAudioOutput *ao = user;
    if (!ao || !ao->channels || !buf || samples_per_channel == 0)
        return;
    ios_chiaki_audio_output_frame(buf, samples_per_channel * ao->channels, user);
}
