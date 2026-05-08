// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// VideoToolbox-based H.264/HEVC decoder

#import "VideoDecoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <os/log.h>

static os_log_t g_vdec_log;

@interface PyluxVideoDecoder ()
@property (nonatomic, assign) VTDecompressionSessionRef session;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDesc;
@property (nonatomic, assign) uint64_t presentationTimeStamp;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
@property (nonatomic, assign) uint64_t framesDecoded;
@property (nonatomic, assign) BOOL loggedFirstFrame;
@end

static void outputCallback(void *decompressionOutputRefCon,
                           void *sourceFrameRefCon,
                           OSStatus status,
                           VTDecodeInfoFlags infoFlags,
                           CVImageBufferRef imageBuffer,
                           CMTime presentationTimeStamp,
                           CMTime presentationDuration) {
    (void)sourceFrameRefCon;
    (void)infoFlags;
    (void)presentationDuration;
    PyluxVideoDecoder *dec = (__bridge PyluxVideoDecoder *)decompressionOutputRefCon;
    if (status != noErr || !imageBuffer) {
#if DEBUG
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "[outputCallback] VT decode status %d", (int)status);
#else
        /* kVTVideoDecoderBadDataErr (-12909): common when upstream drops/corrupts frames (FEC gaps). */
        if (status != -12909)
            os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "[outputCallback] VT decode status %d", (int)status);
#endif
        return;
    }
    dec.framesDecoded++;
    if (!dec.loggedFirstFrame) {
        dec.loggedFirstFrame = YES;
        os_log(g_vdec_log, "[outputCallback] First decoded frame (status=%d)", (int)status);
    } else if (dec.framesDecoded % 300 == 0) {
        os_log(g_vdec_log, "[outputCallback] Decoded frame %llu", (unsigned long long)dec.framesDecoded);
    }
    if (dec.frameCallback) {
        dec.frameCallback(imageBuffer, presentationTimeStamp);
    }
    __strong AVSampleBufferDisplayLayer *layer = dec.displayLayer;
    if (!layer && dec.framesDecoded <= 3) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_DEFAULT, "[outputCallback] No displayLayer attached, frame %llu", (unsigned long long)dec.framesDecoded);
    }
    if (layer) {
        CMVideoFormatDescriptionRef fmtDesc = NULL;
        OSStatus err = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &fmtDesc);
        if (err == noErr && fmtDesc) {
            CMSampleBufferRef sbuf = NULL;
            // Order: duration, presentationTimeStamp, decodeTimeStamp (not PTS first).
            CMTime pts = presentationTimeStamp;
            if (!CMTIME_IS_VALID(pts) || !CMTIME_IS_NUMERIC(pts)) {
                pts = CMTimeMake((int64_t)dec.framesDecoded, 90000);
            }
            CMSampleTimingInfo timing = {
                .duration = kCMTimeInvalid,
                .presentationTimeStamp = pts,
                .decodeTimeStamp = kCMTimeInvalid
            };
            err = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, true, NULL, NULL, fmtDesc, &timing, &sbuf);
            CFRelease(fmtDesc);
            if (err == noErr && sbuf) {
                CMSetAttachment(sbuf, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue, kCMAttachmentMode_ShouldNotPropagate);
                __strong AVSampleBufferDisplayLayer *layerStrong = layer;
                uint64_t frameNum = dec.framesDecoded;
                dispatch_async(dispatch_get_main_queue(), ^{
                    CGRect b = layerStrong.bounds;
                    if (frameNum <= 2) {
                        os_log(g_vdec_log, "[outputCallback] enqueue frame %llu bounds=%.0fx%.0f", (unsigned long long)frameNum, b.size.width, b.size.height);
                    }
                    [layerStrong enqueueSampleBuffer:sbuf];
                    CFRelease(sbuf);
                });
            }
        }
    }
}

@implementation PyluxVideoDecoder

+ (void)initialize {
    if (self == [PyluxVideoDecoder class]) {
        g_vdec_log = os_log_create("com.pylux.stream", "VideoDecoder");
    }
}

- (instancetype)initWithWidth:(int32_t)width height:(int32_t)height codec:(PyluxVideoCodec)codec {
    self = [super init];
    if (self) {
        _width = width;
        _height = height;
        _codec = codec;
        _presentationTimeStamp = 0;
        _framesDecoded = 0;
        _loggedFirstFrame = NO;
        os_log(g_vdec_log, "[init] VideoDecoder %dx%d codec=%{public}@", width, height, codec == PyluxVideoCodecH265 ? @"HEVC" : @"H264");
    }
    return self;
}

- (void)dealloc {
    [self reset];
}

static BOOL findNextNAL(const uint8_t *data, size_t size, size_t *startOut, size_t *lenOut) {
    size_t i = 0;
    while (i + 4 <= size) {
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 1) {
            size_t nalStart = (data[i+3] == 0) ? i + 4 : i + 3;
            size_t j = nalStart;
            while (j + 3 <= size) {
                if (data[j] == 0 && data[j+1] == 0 && (data[j+2] == 1 || (data[j+2] == 0 && j+4 <= size && data[j+3] == 1)))
                    break;
                j++;
            }
            *startOut = nalStart;
            *lenOut = (j + 3 <= size) ? (j - nalStart) : (size - nalStart);
            return YES;
        }
        if (data[i] == 0 && data[i+1] == 0 && data[i+2] == 0 && i+4 <= size && data[i+3] == 1) {
            size_t nalStart = i + 4;
            size_t j = nalStart;
            while (j + 4 <= size) {
                if (data[j] == 0 && data[j+1] == 0 && data[j+2] == 0 && data[j+3] == 1)
                    break;
                j++;
            }
            *startOut = nalStart;
            *lenOut = (j + 4 <= size) ? (j - nalStart) : (size - nalStart);
            return YES;
        }
        i++;
    }
    return NO;
}

static uint8_t h264NALType(const uint8_t *nal, size_t len) {
    if (len < 1) return 0;
    return nal[0] & 0x1f;
}

static uint8_t h265NALType(const uint8_t *nal, size_t len) {
    if (len < 2) return 0;
    return (nal[0] >> 1) & 0x3f;
}

- (BOOL)updateFormatFromAnnexB:(const uint8_t *)buf size:(size_t)bufSize {
    const uint8_t *params[3] = { NULL, NULL, NULL }; // H265: VPS/SPS/PPS, H264: SPS/PPS
    size_t paramSizes[3] = { 0, 0, 0 };
    size_t paramCount = 0;
    BOOL isH265 = (self.codec == PyluxVideoCodecH265);
    size_t off = 0;
    size_t start, len;
    while (findNextNAL(buf + off, bufSize - off, &start, &len)) {
        const uint8_t *nal = buf + off + start;
        uint8_t type = isH265 ? h265NALType(nal, len) : h264NALType(nal, len);
        if (isH265) {
            if (type == 32) { params[0] = nal; paramSizes[0] = len; } // VPS
            else if (type == 33) { params[1] = nal; paramSizes[1] = len; } // SPS
            else if (type == 34) { params[2] = nal; paramSizes[2] = len; } // PPS
            if (params[1] && params[2]) {
                // Prefer VPS+SPS+PPS when available, but still accept SPS+PPS only.
                paramCount = params[0] ? 3 : 2;
                break;
            }
        } else {
            if (type == 7) { params[0] = nal; paramSizes[0] = len; } // SPS
            else if (type == 8 && params[0]) { params[1] = nal; paramSizes[1] = len; paramCount = 2; break; } // PPS
        }
        off += start + len;
    }
    if (paramCount < 2 && !isH265) {
        if (params[0]) { paramCount = 1; params[1] = NULL; paramSizes[1] = 0; }
    }
    if (paramCount < 1) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "[updateFormatFromAnnexB] No param sets found");
        return NO;
    }
    CMVideoFormatDescriptionRef newFmt = NULL;
    if (isH265) {
        if (paramCount < 2) return NO;
        const uint8_t *paramSetPointers[3] = { 0 };
        size_t paramSetSizes[3] = { 0 };
        if (paramCount == 3) {
            // VPS + SPS + PPS
            paramSetPointers[0] = params[0];
            paramSetPointers[1] = params[1];
            paramSetPointers[2] = params[2];
            paramSetSizes[0] = paramSizes[0];
            paramSetSizes[1] = paramSizes[1];
            paramSetSizes[2] = paramSizes[2];
        } else {
            // SPS + PPS fallback
            paramSetPointers[0] = params[1];
            paramSetPointers[1] = params[2];
            paramSetSizes[0] = paramSizes[1];
            paramSetSizes[1] = paramSizes[2];
        }
        OSStatus err = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, paramCount, paramSetPointers, paramSetSizes, 4, NULL, &newFmt);
        if (err != noErr) return NO;
    } else {
        OSStatus err = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, paramCount, params, paramSizes, 4, &newFmt);
        if (err != noErr) return NO;
    }
    if (self.formatDesc) CFRelease(self.formatDesc);
    self.formatDesc = newFmt;
    os_log(g_vdec_log, "[updateFormatFromAnnexB] Format created paramCount=%zu %{public}s", (size_t)paramCount, isH265 ? "HEVC" : "H264");
    [self createSession];
    return YES;
}

- (void)createSession {
    if (self.session) {
        os_log(g_vdec_log, "[createSession] invalidating previous session");
        VTDecompressionSessionInvalidate(self.session);
        CFRelease(self.session);
        self.session = NULL;
    }
    self.presentationTimeStamp = 0;
    if (!self.formatDesc) return;
    os_log(g_vdec_log, "[createSession] VTDecompressionSessionCreate");
    NSDictionary *attrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{}
    };
    VTDecompressionOutputCallbackRecord cb = { outputCallback, (__bridge void *)self };
    OSStatus err = VTDecompressionSessionCreate(kCFAllocatorDefault, self.formatDesc, NULL, (__bridge CFDictionaryRef)attrs, &cb, &_session);
    os_log(g_vdec_log, "[createSession] err=%d session=%p", (int)err, (void *)self.session);
    if (err != noErr) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "[createSession] VTDecompressionSessionCreate FAILED %d", (int)err);
    }
}

- (void)setDisplayLayer:(AVSampleBufferDisplayLayer *)layer {
    _displayLayer = layer;
    if (layer) {
        CGRect b = layer.bounds;
        os_log(g_vdec_log, "[setDisplayLayer] bounds=%.0fx%.0f superlayer=%d", b.size.width, b.size.height, layer.superlayer ? 1 : 0);
    } else {
        os_log(g_vdec_log, "[setDisplayLayer] cleared");
    }
}

- (void)reset {
    if (self.session) {
        VTDecompressionSessionInvalidate(self.session);
        CFRelease(self.session);
        _session = NULL;
    }
    if (self.formatDesc) {
        CFRelease(self.formatDesc);
        _formatDesc = NULL;
    }
}

- (BOOL)feedSample:(const uint8_t *)buf size:(size_t)bufSize framesLost:(int32_t)framesLost frameRecovered:(BOOL)frameRecovered {
    static uint64_t s_callbackCount = 0;
    s_callbackCount++;
    if (s_callbackCount <= 3 || (s_callbackCount % 300 == 0)) {
        os_log(g_vdec_log, "[feedSample] #%llu size=%zu lost=%d recovered=%{public}s", (unsigned long long)s_callbackCount, bufSize, (int)framesLost, frameRecovered ? "Y" : "N");
    }
    if (!buf || bufSize == 0) return YES;
    BOOL isH265 = (self.codec == PyluxVideoCodecH265);
    size_t off = 0;
    size_t start, len;
    BOOL hasSlice = NO;
    BOOL needsFormatUpdate = NO;  // Track if we have param NALs; update format once per buffer
    while (findNextNAL(buf + off, bufSize - off, &start, &len)) {
        const uint8_t *nal = buf + off + start;
        uint8_t type = isH265 ? h265NALType(nal, len) : h264NALType(nal, len);
        if (isH265) {
            if (type == 32 || type == 33 || type == 34) {
                needsFormatUpdate = YES;
            } else if (type <= 31) {
                hasSlice = YES;
            }
        } else {
            if (type == 7 || type == 8) {
                needsFormatUpdate = YES;
            } else if (type == 5 || type == 1) hasSlice = YES;
        }
        off += start + len;
    }
    if (needsFormatUpdate && [self updateFormatFromAnnexB:buf size:bufSize]) {
        os_log(g_vdec_log, "[feedSample] format updated from param NALs");
    }
    // Header-only buffers (SPS/PPS or VPS/SPS/PPS): always acknowledge without decoding.
    if (!hasSlice) {
        if (s_callbackCount <= 5) os_log(g_vdec_log, "[feedSample] header-only size=%zu, ack", bufSize);
        return YES;
    }
    if (!self.formatDesc && ![self updateFormatFromAnnexB:buf size:bufSize]) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR,
                         "[feedSample] No format description (codec=%{public}s, buf=%zu, lost=%d, recovered=%{public}s)",
                         isH265 ? "H265" : "H264",
                         bufSize,
                         (int)framesLost,
                         frameRecovered ? "true" : "false");
        return NO;
    }
    if (!self.session) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "[feedSample] Decoder session not available");
        return NO;
    }
    NSMutableData *avcc = [NSMutableData dataWithCapacity:bufSize + 256];
    off = 0;
    while (findNextNAL(buf + off, bufSize - off, &start, &len)) {
        const uint8_t *nal = buf + off + start;
        uint32_t lenBe = CFSwapInt32HostToBig((uint32_t)len);
        [avcc appendBytes:&lenBe length:4];
        [avcc appendBytes:nal length:len];
        off += start + len;
    }
    if (avcc.length < 5) return YES;
    void *avccCopy = CFAllocatorAllocate(kCFAllocatorDefault, avcc.length, 0);
    if (!avccCopy) return YES;
    memcpy(avccCopy, avcc.bytes, avcc.length);
    CMBlockBufferRef blockBuf = NULL;
    OSStatus err = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, avccCopy, avcc.length, kCFAllocatorDefault, NULL, 0, avcc.length, kCMBlockBufferAssureMemoryNowFlag, &blockBuf);
    if (err != noErr || !blockBuf) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "[feedSample] CMBlockBufferCreateWithMemoryBlock failed: %d", (int)err);
        CFAllocatorDeallocate(kCFAllocatorDefault, avccCopy);
        return NO;
    }
    CMSampleBufferRef sampleBuf = NULL;
    CMSampleTimingInfo timing = {
        .duration = kCMTimeInvalid,
        .presentationTimeStamp = CMTimeMake(self.presentationTimeStamp, 90000),
        .decodeTimeStamp = kCMTimeInvalid
    };
    err = CMSampleBufferCreate(kCFAllocatorDefault, blockBuf, TRUE, NULL, NULL, self.formatDesc, 1, 1, &timing, 0, NULL, &sampleBuf);
    CFRelease(blockBuf);
    if (err != noErr || !sampleBuf) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "[feedSample] CMSampleBufferCreate failed: %d", (int)err);
        return NO;
    }
    self.presentationTimeStamp++;
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    err = VTDecompressionSessionDecodeFrame(self.session, sampleBuf, flags, sampleBuf, NULL);
    CFRelease(sampleBuf);
    if (err != noErr) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "[feedSample] VTDecompressionSessionDecodeFrame err=%d buf=%zu lost=%d", (int)err, bufSize, (int)framesLost);
        return NO;
    }
    if (s_callbackCount <= 5 || (self.presentationTimeStamp > 0 && self.presentationTimeStamp % 300 == 1)) {
        os_log(g_vdec_log, "[feedSample] queued frame pts=%llu", (unsigned long long)self.presentationTimeStamp);
    }
    return YES;
}

@end

bool PyluxVideoDecoderVideoSampleCallback(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user) {
    if (!user) return true;
    PyluxVideoDecoder *dec = (__bridge PyluxVideoDecoder *)user;
    return [dec feedSample:buf size:buf_size framesLost:frames_lost frameRecovered:frame_recovered];
}
