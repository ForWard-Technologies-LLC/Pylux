// SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
// VideoToolbox-based H.264/HEVC decoder

#import "VideoDecoder.h"
#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <os/log.h>

static os_log_t g_vdec_log;

@interface PyluxVideoDecoder ()
@property (nonatomic, assign) VTDecompressionSessionRef session;
@property (nonatomic, assign) CMVideoFormatDescriptionRef formatDesc;
@property (nonatomic, assign) uint64_t presentationTimeStamp;
@property (nonatomic, strong) AVSampleBufferDisplayLayer *displayLayer;
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
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "VT decode status %d", (int)status);
        return;
    }
    if (dec.frameCallback) {
        dec.frameCallback(imageBuffer, presentationTimeStamp);
    }
    if (dec.displayLayer) {
        CMVideoFormatDescriptionRef fmtDesc = NULL;
        OSStatus err = CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, &fmtDesc);
        if (err == noErr && fmtDesc) {
            CMSampleBufferRef sbuf = NULL;
            CMSampleTimingInfo timing = { presentationTimeStamp, kCMTimeInvalid, kCMTimeInvalid };
            err = CMSampleBufferCreateForImageBuffer(kCFAllocatorDefault, imageBuffer, true, NULL, NULL, fmtDesc, &timing, &sbuf);
            CFRelease(fmtDesc);
            if (err == noErr && sbuf) {
                [dec.displayLayer enqueueSampleBuffer:sbuf];
                CFRelease(sbuf);
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
    const uint8_t *params[2] = { NULL, NULL };
    size_t paramSizes[2] = { 0, 0 };
    size_t paramCount = 0;
    BOOL isH265 = (self.codec == PyluxVideoCodecH265);
    size_t off = 0;
    size_t start, len;
    while (findNextNAL(buf + off, bufSize - off, &start, &len)) {
        const uint8_t *nal = buf + off + start;
        uint8_t type = isH265 ? h265NALType(nal, len) : h264NALType(nal, len);
        if (isH265) {
            if (type == 33) { params[0] = nal; paramSizes[0] = len; paramCount = 1; }
            else if (type == 34 && paramCount >= 1) { params[1] = nal; paramSizes[1] = len; paramCount = 2; break; }
        } else {
            if (type == 7) { params[0] = nal; paramSizes[0] = len; }
            else if (type == 8 && params[0]) { params[1] = nal; paramSizes[1] = len; paramCount = 2; break; }
        }
        off += start + len;
    }
    if (paramCount < 2 && !isH265) {
        if (params[0]) { paramCount = 1; params[1] = NULL; paramSizes[1] = 0; }
    }
    if (paramCount < 1) return NO;
    CMVideoFormatDescriptionRef newFmt = NULL;
    if (isH265) {
        if (paramCount < 2) return NO;
        const uint8_t *paramSetPointers[2] = { params[0], params[1] };
        size_t paramSetSizes[2] = { paramSizes[0], paramSizes[1] };
        OSStatus err = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault, 2, paramSetPointers, paramSetSizes, 4, NULL, &newFmt);
        if (err != noErr) return NO;
    } else {
        OSStatus err = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, paramCount, params, paramSizes, 4, &newFmt);
        if (err != noErr) return NO;
    }
    if (self.formatDesc) CFRelease(self.formatDesc);
    self.formatDesc = newFmt;
    [self createSession];
    return YES;
}

- (void)createSession {
    if (self.session) {
        VTDecompressionSessionInvalidate(self.session);
        CFRelease(self.session);
        self.session = NULL;
    }
    if (!self.formatDesc) return;
    NSDictionary *attrs = @{ (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
    VTDecompressionOutputCallbackRecord cb = { outputCallback, (__bridge void *)self };
    OSStatus err = VTDecompressionSessionCreate(kCFAllocatorDefault, self.formatDesc, NULL, (__bridge CFDictionaryRef)attrs, &cb, &_session);
    if (err != noErr) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "VTDecompressionSessionCreate failed %d", (int)err);
    }
}

- (void)setDisplayLayer:(AVSampleBufferDisplayLayer *)layer {
    _displayLayer = layer;
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
    (void)framesLost;
    (void)frameRecovered;
    if (!buf || bufSize == 0) return YES;
    BOOL isH265 = (self.codec == PyluxVideoCodecH265);
    size_t off = 0;
    size_t start, len;
    BOOL hasSlice = NO;
    while (findNextNAL(buf + off, bufSize - off, &start, &len)) {
        const uint8_t *nal = buf + off + start;
        uint8_t type = isH265 ? h265NALType(nal, len) : h264NALType(nal, len);
        if (isH265) {
            if (type == 33 || type == 34) {
                if ([self updateFormatFromAnnexB:buf size:bufSize]) {}
            } else if (type == 19 || type == 1) hasSlice = YES;
        } else {
            if (type == 7 || type == 8) {
                if ([self updateFormatFromAnnexB:buf size:bufSize]) {}
            } else if (type == 5 || type == 1) hasSlice = YES;
        }
        off += start + len;
    }
    if (!hasSlice && bufSize < 1024) return YES;
    if (!self.formatDesc && ![self updateFormatFromAnnexB:buf size:bufSize]) return NO;
    if (!self.session) return NO;
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
    void *avccCopy = malloc(avcc.length);
    if (!avccCopy) return YES;
    memcpy(avccCopy, avcc.bytes, avcc.length);
    CMBlockBufferRef blockBuf = NULL;
    OSStatus err = CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, avccCopy, avcc.length, kCFAllocatorDefault, NULL, 0, avcc.length, kCMBlockBufferAssureMemoryNowFlag, &blockBuf);
    if (err != noErr || !blockBuf) {
        free(avccCopy);
        return NO;
    }
    CMSampleBufferRef sampleBuf = NULL;
    CMSampleTimingInfo timing = { CMTimeMake(self.presentationTimeStamp, 90000), kCMTimeInvalid, kCMTimeInvalid };
    err = CMSampleBufferCreate(kCFAllocatorDefault, blockBuf, TRUE, NULL, NULL, self.formatDesc, 1, 1, &timing, 0, NULL, &sampleBuf);
    CFRelease(blockBuf);
    if (err != noErr || !sampleBuf) return NO;
    self.presentationTimeStamp++;
    VTDecodeFrameFlags flags = kVTDecodeFrame_EnableAsynchronousDecompression;
    err = VTDecompressionSessionDecodeFrame(self.session, sampleBuf, flags, sampleBuf, NULL);
    CFRelease(sampleBuf);
    if (err != noErr) {
        os_log_with_type(g_vdec_log, OS_LOG_TYPE_ERROR, "VTDecompressionSessionDecodeFrame %d", (int)err);
        return err == kVTInvalidSessionErr ? NO : YES;
    }
    return YES;
}

@end

bool PyluxVideoDecoderVideoSampleCallback(uint8_t *buf, size_t buf_size, int32_t frames_lost, bool frame_recovered, void *user) {
    if (!user) return true;
    PyluxVideoDecoder *dec = (__bridge PyluxVideoDecoder *)user;
    return [dec feedSample:buf size:buf_size framesLost:frames_lost frameRecovered:frame_recovered];
}
