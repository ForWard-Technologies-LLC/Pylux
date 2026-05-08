// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// VideoToolbox-based H.264/HEVC decoder for Chiaki stream

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PyluxVideoCodec) {
    PyluxVideoCodecH264 = 0,
    PyluxVideoCodecH265 = 1,
};

/**
 * Callback when a decoded frame is ready. Called on decoder thread.
 */
typedef void (^PyluxVideoDecoderFrameCallback)(CVPixelBufferRef pixelBuffer, CMTime presentationTime);

/**
 * VideoToolbox decoder for Chiaki H.264/HEVC stream.
 * Accepts Annex B NAL data, decodes via VTDecompressionSession, outputs CVPixelBuffers.
 */
@interface PyluxVideoDecoder : NSObject

@property (nonatomic, assign) int32_t width;
@property (nonatomic, assign) int32_t height;
@property (nonatomic, assign) PyluxVideoCodec codec;
@property (nonatomic, copy, nullable) PyluxVideoDecoderFrameCallback frameCallback;

- (instancetype)initWithWidth:(int32_t)width height:(int32_t)height codec:(PyluxVideoCodec)codec;

/**
 * Feed Annex B format data (NAL units with 0x00000001 start codes).
 * Can be header (SPS/PPS) or frame. Header is detected and used to create format description.
 * @return YES if consumed successfully, NO to request keyframe
 */
- (BOOL)feedSample:(const uint8_t *)buf size:(size_t)bufSize framesLost:(int32_t)framesLost frameRecovered:(BOOL)frameRecovered;

/**
 * Attach display layer for direct output. If nil, frames go to frameCallback only.
 */
- (void)setDisplayLayer:(AVSampleBufferDisplayLayer * _Nullable)layer;

/**
 * Reset decoder (e.g. after stream format change). Clears format description.
 */
- (void)reset;

@end

NS_ASSUME_NONNULL_END

/**
 * C-callable trampoline for chiaki_session_bridge_set_video_sample_cb.
 * Pass decoder as user: chiaki_session_bridge_set_video_sample_cb(ref, PyluxVideoDecoderVideoSampleCallback, (__bridge void*)decoder)
 */
bool PyluxVideoDecoderVideoSampleCallback(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user);
