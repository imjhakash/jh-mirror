#include "aw_camera_sink.h"
#import <Foundation/Foundation.h>
#import <CoreMediaIO/CoreMediaIO.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#include <stdio.h>
#include <stdatomic.h>
#include <string.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "util/log.h"

static void queue_changed(CMIOStreamID stream, void *token, void *context) { (void)stream; (void)token; (void)context; }
// Static callback state outlives any late CMIO notification during shutdown. One writer per helper process.
static _Atomic bool accepting_notifications;
static _Atomic uint64_t accepted_frames, last_accepted, last_announced;
static void scheduled_output(UInt64 sequence, UInt64 host_time, void *context) {
    (void)sequence; (void)host_time; (void)context;
    if (!atomic_load(&accepting_notifications)) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    atomic_store(&last_accepted, now); atomic_fetch_add(&accepted_frames, 1);
    uint64_t previous = atomic_load(&last_announced);
    if (now - previous > NSEC_PER_SEC && atomic_compare_exchange_strong(&last_announced, &previous, now)) {
        puts("AW_CAMERA_FRAME"); fflush(stdout);
    }
}

// The caller explicitly selects a known device. Never send camera frames to a default device.

@interface JHCameraWriter : NSObject
@property CMIODeviceID device;
@property CMIOStreamID stream;
@property(nonatomic) CMSimpleQueueRef buffers;
@property(nonatomic) CVPixelBufferPoolRef pool;
@property(nonatomic) CMVideoFormatDescriptionRef format;
@property CIContext *imageContext;
@property int width;
@property int height;
@property BOOL started;
@property uint64_t lastEnqueue;
@property(nonatomic) void *controlMap;
@property(nonatomic) void *previewMap;
@property(nonatomic) CVPixelBufferRef thumbnail;
@property uint64_t lastPreview;
@property uint8_t controls;
- (BOOL)connect;
- (int)pushFrame:(const AVFrame *)frame;
@end

enum { JHPreviewWidth = 640, JHPreviewHeight = 360, JHPreviewBytes = 64 + 640 * 360 * 4 };
static void *map_private_file(const char *path, size_t bytes, BOOL writing) {
    int fd = open(path, (writing ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return NULL;
    struct stat info;
    BOOL valid = !fstat(fd, &info) && S_ISREG(info.st_mode) && info.st_uid == getuid()
        && !(info.st_mode & 077) && info.st_size == (off_t)bytes;
    void *map = valid ? mmap(NULL, bytes, PROT_READ | (writing ? PROT_WRITE : 0), MAP_SHARED, fd, 0) : MAP_FAILED;
    close(fd); return map == MAP_FAILED ? NULL : map;
}

@implementation JHCameraWriter
- (BOOL)connect {
    const char *control = getenv("JH_CAMERA_CONTROL_PATH"), *preview = getenv("JH_CAMERA_PREVIEW_PATH");
    if (control) {
        _controlMap = map_private_file(control, 8, NO);
        if (!_controlMap || memcmp(_controlMap, "JHC1", 4)) { LOGE("Private camera controls unavailable"); return NO; }
    }
    if (preview) {
        _previewMap = map_private_file(preview, JHPreviewBytes, YES);
        if (!_previewMap) { LOGE("Private camera preview unavailable"); return NO; }
        memcpy(_previewMap, "AWP1", 4);
    }
    const char *requested = getenv("JH_CAMERA_DEVICE_UID");
    NSString *uidString = requested ? [NSString stringWithUTF8String:requested] : nil;
    if (!uidString || ![[NSUUID alloc] initWithUUIDString:uidString]) return NO;
    CMIOObjectPropertyAddress address = {kCMIOHardwarePropertyDevices, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
    UInt32 size = 0;
    if (CMIOObjectGetPropertyDataSize(kCMIOObjectSystemObject, &address, 0, NULL, &size) || !size || size > 4096) return NO;
    CMIODeviceID devices[1024];
    if (CMIOObjectGetPropertyData(kCMIOObjectSystemObject, &address, 0, NULL, size, &size, devices)) return NO;
    for (unsigned i = 0; i < size / sizeof(CMIODeviceID); i++) {
        CFStringRef uid = NULL; UInt32 bytes = sizeof(uid);
        CMIOObjectPropertyAddress property = {kCMIODevicePropertyDeviceUID, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        if (!CMIOObjectGetPropertyData(devices[i], &property, 0, NULL, bytes, &bytes, &uid) && uid) {
            BOOL match = [(__bridge NSString *)uid caseInsensitiveCompare:uidString] == NSOrderedSame;
            CFRelease(uid);
            if (match) { _device = devices[i]; break; }
        }
    }
    if (!_device) { LOGE("Virtual camera device was not found"); return NO; }
    address.mSelector = kCMIODevicePropertyStreams; address.mScope = kCMIOObjectPropertyScopeGlobal;
    size = 0;
    CMIOStreamID streams[32];
    if (CMIOObjectGetPropertyDataSize(_device, &address, 0, NULL, &size) || !size || size > sizeof(streams)) return NO;
    if (CMIOObjectGetPropertyData(_device, &address, 0, NULL, size, &size, streams)) return NO;
    address.mSelector = kCMIOStreamPropertyDirection;
    for (unsigned i = 0; i < size / sizeof(CMIOStreamID); i++) {
        UInt32 direction = 1, bytes = sizeof(direction);
        if (!CMIOObjectGetPropertyData(streams[i], &address, 0, NULL, bytes, &bytes, &direction) && !direction) {
            if (_stream) return NO; // An ambiguous output is not safe to guess.
            _stream = streams[i];
        }
    }
    if (!_stream) { LOGE("Virtual camera has no unambiguous producer stream"); return NO; }
    address.mSelector = kCMIOStreamPropertyFormatDescription;
    CMFormatDescriptionRef advertised = NULL; UInt32 bytes = sizeof(advertised);
    OSStatus formatStatus = CMIOObjectGetPropertyData(_stream, &address, 0, NULL, bytes, &bytes, &advertised);
    if (formatStatus || !advertised) { LOGE("Virtual camera format query failed: %d", (int)formatStatus); return NO; }
    CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(advertised);
    BOOL supported = CMFormatDescriptionGetMediaSubType(advertised) == kCVPixelFormatType_32BGRA;
    CFRelease(advertised);
    if (!supported || dimensions.width <= 0 || dimensions.height <= 0 || dimensions.width > 1920 || dimensions.height > 1080) { LOGE("Unsupported virtual camera format: %dx%d", dimensions.width, dimensions.height); return NO; }
    _width = dimensions.width; _height = dimensions.height;
    OSStatus queueStatus = CMIOStreamCopyBufferQueue(_stream, queue_changed, NULL, &_buffers);
    if (queueStatus || !_buffers) { LOGE("Virtual camera queue failed: %d", (int)queueStatus); return NO; }
    address.mSelector = kCMIOStreamPropertyScheduledOutputNotificationProc;
    CMIOStreamScheduledOutputNotificationProcAndRefCon notification = {scheduled_output, NULL};
    OSStatus notificationStatus = CMIOObjectSetPropertyData(_stream, &address, 0, NULL, sizeof(notification), &notification);
    if (notificationStatus) { LOGE("Virtual camera acknowledgements unavailable: %d", (int)notificationStatus); return NO; }
    NSDictionary *attributes = @{(id)kCVPixelBufferWidthKey:@(_width), (id)kCVPixelBufferHeightKey:@(_height),
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA), (id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    if (CVPixelBufferPoolCreate(NULL, NULL, (__bridge CFDictionaryRef)attributes, &_pool)) return NO;
    _imageContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@NO, kCIContextCacheIntermediates:@NO}];
    atomic_store(&accepted_frames, 0); atomic_store(&last_announced, 0);
    atomic_store(&last_accepted, clock_gettime_nsec_np(CLOCK_UPTIME_RAW)); atomic_store(&accepting_notifications, true);
    OSStatus startStatus = CMIODeviceStartStream(_device, _stream);
    _started = startStatus == noErr;
    if (!_started) LOGE("Virtual camera start failed: %d", (int)startStatus);
    _lastEnqueue = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    return _started;
}
- (void)dealloc {
    atomic_store(&accepting_notifications, false);
    if (_started) CMIODeviceStopStream(_device, _stream);
    if (_stream) {
        CMIOObjectPropertyAddress address = {kCMIOStreamPropertyScheduledOutputNotificationProc, kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        CMIOStreamScheduledOutputNotificationProcAndRefCon notification = {NULL, NULL};
        CMIOObjectSetPropertyData(_stream, &address, 0, NULL, sizeof(notification), &notification);
    }
    if (_buffers) {
        const void *sample;
        while ((sample = CMSimpleQueueDequeue(_buffers))) CFRelease(sample);
        CFRelease(_buffers);
    }
    if (_pool) CVPixelBufferPoolRelease(_pool);
    if (_format) CFRelease(_format);
    if (_controlMap) munmap(_controlMap, 8);
    if (_previewMap) munmap(_previewMap, JHPreviewBytes);
    if (_thumbnail) CVPixelBufferRelease(_thumbnail);
}

- (void)publishPreview:(CVPixelBufferRef)image controls:(uint8_t)controls {
    if (!_previewMap || !(controls & 8)) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (now - _lastPreview < 80000000) return;
    _lastPreview = now;
    if (!_thumbnail) {
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        if (CVPixelBufferCreate(NULL, JHPreviewWidth, JHPreviewHeight, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)attributes, &_thumbnail)) return;
    }
    CIImage *scaled = [[CIImage imageWithCVPixelBuffer:image] imageByApplyingTransform:
        CGAffineTransformMakeScale((double)JHPreviewWidth / _width, (double)JHPreviewHeight / _height)];
    [_imageContext render:scaled toCVPixelBuffer:_thumbnail];
    CVPixelBufferLockBaseAddress(_thumbnail, kCVPixelBufferLock_ReadOnly);
    _Atomic uint64_t *sequence = (_Atomic uint64_t *)((uint8_t *)_previewMap + 8);
    atomic_fetch_add_explicit(sequence, 1, memory_order_acq_rel);
    uint32_t dimensions[] = {JHPreviewWidth, JHPreviewHeight, JHPreviewWidth * 4};
    memcpy((uint8_t *)_previewMap + 16, dimensions, sizeof(dimensions));
    const uint8_t *pixels = CVPixelBufferGetBaseAddress(_thumbnail);
    size_t stride = CVPixelBufferGetBytesPerRow(_thumbnail);
    for (unsigned y = 0; y < JHPreviewHeight; y++) {
        memcpy((uint8_t *)_previewMap + 64 + y * JHPreviewWidth * 4, pixels + y * stride, JHPreviewWidth * 4);
    }
    atomic_fetch_add_explicit(sequence, 1, memory_order_release);
    CVPixelBufferUnlockBaseAddress(_thumbnail, kCVPixelBufferLock_ReadOnly);
}
- (CVPixelBufferRef)copyImageForFrame:(const AVFrame *)frame CF_RETURNS_RETAINED {
    if (!frame) return NULL;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX && frame->data[3]) {
        return CVPixelBufferRetain((CVPixelBufferRef)frame->data[3]);
    }
    BOOL nv12 = frame->format == AV_PIX_FMT_NV12;
    BOOL planar = frame->format == AV_PIX_FMT_YUV420P || frame->format == AV_PIX_FMT_YUVJ420P;
    if ((!nv12 && !planar) || frame->width <= 0 || frame->height <= 0 || frame->width > 8192 || frame->height > 8192
            || frame->width % 2 || frame->height % 2 || !frame->data[0] || !frame->data[1]
            || llabs(frame->linesize[0]) < frame->width || llabs(frame->linesize[1]) < frame->width / (nv12 ? 1 : 2)
            || (planar && (!frame->data[2] || llabs(frame->linesize[2]) < frame->width / 2))) return NULL;
    OSType format = frame->color_range == AVCOL_RANGE_JPEG || frame->format == AV_PIX_FMT_YUVJ420P
        ? kCVPixelFormatType_420YpCbCr8BiPlanarFullRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    CVPixelBufferRef image = NULL;
    if (CVPixelBufferCreate(NULL, frame->width, frame->height, format, NULL, &image)) return NULL;
    CVPixelBufferLockBaseAddress(image, 0);
    uint8_t *yplane = CVPixelBufferGetBaseAddressOfPlane(image, 0);
    size_t ys = CVPixelBufferGetBytesPerRowOfPlane(image, 0);
    for (int y = 0; y < frame->height; y++) memcpy(yplane + y * ys, frame->data[0] + y * frame->linesize[0], frame->width);
    uint8_t *uv = CVPixelBufferGetBaseAddressOfPlane(image, 1);
    size_t us = CVPixelBufferGetBytesPerRowOfPlane(image, 1);
    for (int y = 0; y < frame->height / 2; y++) {
        if (nv12) memcpy(uv + y * us, frame->data[1] + y * frame->linesize[1], frame->width);
        else for (int x = 0; x < frame->width / 2; x++) {
            uv[y * us + 2 * x] = frame->data[1][y * frame->linesize[1] + x];
            uv[y * us + 2 * x + 1] = frame->data[2][y * frame->linesize[2] + x];
        }
    }
    CVPixelBufferUnlockBaseAddress(image, 0);
    CVBufferSetAttachment(image, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    return image;
}
- (int)pushFrame:(const AVFrame *)frame {
    if (!_buffers || !_pool || !_imageContext) return -1;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    // Drop a congested frame; fail if the device stops consuming for three seconds.
    if (CMSimpleQueueGetCount(_buffers) >= MIN(2, CMSimpleQueueGetCapacity(_buffers))) {
        return now - _lastEnqueue > 3 * NSEC_PER_SEC ? -1 : 0;
    }
    CVPixelBufferRef source = [self copyImageForFrame:frame];
    if (!source) return -1;
    CVPixelBufferRef output = NULL;
    NSDictionary *limits = @{(id)kCVPixelBufferPoolAllocationThresholdKey:@6};
    CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(NULL, _pool, (__bridge CFDictionaryRef)limits, &output);
    if (result) { CVPixelBufferRelease(source); return result == kCVReturnWouldExceedAllocationThreshold ? 0 : -1; }
    CIImage *image = [CIImage imageWithCVPixelBuffer:source];
    uint8_t controls = _controlMap ? atomic_load_explicit((_Atomic uint8_t *)((uint8_t *)_controlMap + 4), memory_order_acquire) : _controls;
    const int orientations[] = {1, 6, 3, 8}; // clockwise 0, 90, 180, 270 degrees
    image = [image imageByApplyingOrientation:orientations[controls & 3]];
    if (controls & 4) image = [image imageByApplyingOrientation:2];
    image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-image.extent.origin.x, -image.extent.origin.y)];
    double scale = MIN((double)_width / image.extent.size.width, (double)_height / image.extent.size.height);
    CGAffineTransform transform = CGAffineTransformMake(scale, 0, 0, scale,
        (_width - image.extent.size.width * scale) / 2, (_height - image.extent.size.height * scale) / 2);
    CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]]
        imageByCroppingToRect:CGRectMake(0, 0, _width, _height)];
    [_imageContext render:[[image imageByApplyingTransform:transform] imageByCompositingOverImage:black] toCVPixelBuffer:output];
    [self publishPreview:output controls:controls];
    CVPixelBufferRelease(source);
    if (!_format && CMVideoFormatDescriptionCreateForImageBuffer(NULL, output, &_format)) { CVPixelBufferRelease(output); return -1; }
    CMSampleTimingInfo timing = {CMTimeMake(1, 30), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    CMSampleBufferRef sample = NULL;
    OSStatus status = CMSampleBufferCreateReadyWithImageBuffer(NULL, output, _format, &timing, &sample);
    CVPixelBufferRelease(output);
    if (status) return -1;
    if (CMSimpleQueueEnqueue(_buffers, sample)) { CFRelease(sample); return -1; }
    _lastEnqueue = now;
    // Ownership of the sample transfers through the CMIO sink buffer queue.
    return 1;
}
@end

static bool camera_open(struct sc_frame_sink *sink, const AVCodecContext *ctx, const struct sc_stream_session *session) {
    (void)ctx; (void)session;
    struct sc_aw_camera_sink *camera = container_of(sink, struct sc_aw_camera_sink, frame_sink);
    @autoreleasepool {
        JHCameraWriter *writer = [JHCameraWriter new];
        if (![writer connect]) { LOGE("The selected virtual camera is unavailable or writer access was denied"); return false; }
        camera->context = (void *)CFBridgingRetain(writer); return true;
    }
}
static void camera_close(struct sc_frame_sink *sink) {
    struct sc_aw_camera_sink *camera = container_of(sink, struct sc_aw_camera_sink, frame_sink);
    if (camera->context) { CFRelease(camera->context); camera->context = NULL; }
}
static enum sc_sink_result camera_push(struct sc_frame_sink *sink, const AVFrame *frame) {
    struct sc_aw_camera_sink *camera = container_of(sink, struct sc_aw_camera_sink, frame_sink);
    @autoreleasepool {
        JHCameraWriter *writer = (__bridge JHCameraWriter *)camera->context;
        int result = [writer pushFrame:frame];
        if (writer.started && clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - atomic_load(&last_accepted) > 5 * NSEC_PER_SEC) result = -1;
        return result < 0 ? SC_SINK_KO : SC_SINK_OK;
    }
}
bool sc_aw_camera_sink_init(struct sc_aw_camera_sink *camera) {
    memset(camera, 0, sizeof(*camera));
    static const struct sc_frame_sink_ops ops = {.open = camera_open, .close = camera_close, .push = camera_push};
    camera->frame_sink.ops = &ops; return true;
}
void sc_aw_camera_sink_destroy(struct sc_aw_camera_sink *camera) { camera_close(&camera->frame_sink); }
