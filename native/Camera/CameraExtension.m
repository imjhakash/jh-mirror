#import <Foundation/Foundation.h>
#import <CoreMediaIO/CMIOExtension.h>
#import <CoreVideo/CoreVideo.h>
#import <Security/Security.h>

// Fixed device/stream identities keep calling-app selections stable across app updates.
static NSString *const JHDeviceID = @"D9F956F1-3EC7-47A2-9F61-6D6E7CD66B25";
static NSString *const JHSourceID = @"1B50445C-5EB3-4A2D-A2EE-423C26CD6D87";
static NSString *const JHSinkID = @"20C15A6D-4FD3-4612-B6E1-AF420BBF9071";
static const int JHWidth = 1280, JHHeight = 720;
static const uint64_t JHStaleNanoseconds = 500000000;

@class JHCameraDevice;
@interface JHCameraStream : NSObject <CMIOExtensionStreamSource>
@property CMIOExtensionStream *stream;
@property CMIOExtensionStreamFormat *format;
@property(weak) JHCameraDevice *owner;
@property BOOL sink;
- (instancetype)initWithOwner:(JHCameraDevice *)owner sink:(BOOL)sink;
@end

@interface JHCameraDevice : NSObject <CMIOExtensionDeviceSource>
@property CMIOExtensionDevice *device;
@property JHCameraStream *output;
@property JHCameraStream *input;
@property dispatch_queue_t queue;
@property dispatch_source_t timer;
@property CMIOExtensionClient *writer;
@property BOOL writerStarted;
@property BOOL consuming;
@property NSUInteger readers;
@property uint64_t writerGeneration;
@property uint64_t lastArrival;
@property(nonatomic) CVPixelBufferRef latest;
@property(nonatomic) CVPixelBufferRef blank;
@property(nonatomic) CMVideoFormatDescriptionRef formatDescription;
- (instancetype)initWithQueue:(dispatch_queue_t)queue;
- (BOOL)authorizeWriter:(CMIOExtensionClient *)client;
- (void)updateTimer;
- (void)disconnect:(CMIOExtensionClient *)client;
@end

@implementation JHCameraStream
- (instancetype)initWithOwner:(JHCameraDevice *)owner sink:(BOOL)sink {
    if ((self = [super init])) {
        _owner = owner; _sink = sink;
        _format = [CMIOExtensionStreamFormat streamFormatWithFormatDescription:owner.formatDescription
            maxFrameDuration:CMTimeMake(1, 30) minFrameDuration:CMTimeMake(1, 30) validFrameDurations:nil];
        _stream = [[CMIOExtensionStream alloc] initWithLocalizedName:sink ? @"JH Mirror Frame Input" : @"JH Mirror Camera"
            streamID:[[NSUUID alloc] initWithUUIDString:sink ? JHSinkID : JHSourceID]
            direction:sink ? CMIOExtensionStreamDirectionSink : CMIOExtensionStreamDirectionSource
            clockType:CMIOExtensionStreamClockTypeHostTime source:self];
    }
    return self;
}
- (NSArray *)formats { return @[_format]; }
- (NSSet *)availableProperties {
    NSMutableSet *keys = [NSMutableSet setWithObjects:CMIOExtensionPropertyStreamActiveFormatIndex,
        CMIOExtensionPropertyStreamFrameDuration, nil];
    if (_sink) [keys addObjectsFromArray:@[CMIOExtensionPropertyStreamSinkBufferQueueSize,
        CMIOExtensionPropertyStreamSinkBuffersRequiredForStartup, CMIOExtensionPropertyStreamSinkBufferUnderrunCount,
        CMIOExtensionPropertyStreamSinkEndOfData]];
    return keys;
}
- (CMIOExtensionStreamProperties *)streamPropertiesForProperties:(NSSet *)properties error:(NSError **)error {
    (void)properties; (void)error;
    CMIOExtensionStreamProperties *value = [[CMIOExtensionStreamProperties alloc] initWithDictionary:@{}];
    value.activeFormatIndex = @0;
    value.frameDuration = CFBridgingRelease(CMTimeCopyAsDictionary(CMTimeMake(1, 30), kCFAllocatorDefault));
    if (_sink) {
        value.sinkBufferQueueSize = @2; value.sinkBuffersRequiredForStartup = @1;
        value.sinkBufferUnderrunCount = @0; value.sinkEndOfData = @NO;
    }
    return value;
}
- (BOOL)setStreamProperties:(CMIOExtensionStreamProperties *)properties error:(NSError **)error {
    if (properties.activeFormatIndex && properties.activeFormatIndex.unsignedIntegerValue != 0) return NO;
    if (properties.frameDuration) {
        CMTime duration = CMTimeMakeFromDictionary((__bridge CFDictionaryRef)properties.frameDuration);
        if (CMTimeCompare(duration, CMTimeMake(1, 30))) {
            if (error) *error = [NSError errorWithDomain:NSOSStatusErrorDomain code:kAudioHardwareUnsupportedOperationError userInfo:nil];
            return NO;
        }
    }
    return YES;
}
- (BOOL)authorizedToStartStreamForClient:(CMIOExtensionClient *)client { return !_sink || [_owner authorizeWriter:client]; }
- (BOOL)startStreamAndReturnError:(NSError **)error {
    (void)error;
    if (_sink) _owner.writerStarted = YES; else _owner.readers += 1;
    [_owner updateTimer]; return YES;
}
- (BOOL)stopStreamAndReturnError:(NSError **)error {
    (void)error;
    if (_sink) {
        _owner.writerStarted = NO; _owner.writer = nil; _owner.writerGeneration += 1;
        if (_owner.latest) { CVPixelBufferRelease(_owner.latest); _owner.latest = nil; }
    } else if (_owner.readers) _owner.readers -= 1;
    [_owner updateTimer]; return YES;
}
@end

@implementation JHCameraDevice
- (instancetype)initWithQueue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        _queue = queue;
        CVPixelBufferRef blank = nil;
        NSDictionary *attributes = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
        if (CVPixelBufferCreate(kCFAllocatorDefault, JHWidth, JHHeight, kCVPixelFormatType_32BGRA,
                (__bridge CFDictionaryRef)attributes, &blank) != kCVReturnSuccess) return nil;
        _blank = blank;
        CVPixelBufferLockBaseAddress(blank, 0);
        size_t stride = CVPixelBufferGetBytesPerRow(blank);
        for (int y = 0; y < JHHeight; y++) {
            uint8_t *row = (uint8_t *)CVPixelBufferGetBaseAddress(blank) + y * stride;
            memset(row, 0, stride);
            for (int x = 0; x < JHWidth; x++) row[4 * x + 3] = 255;
        }
        CVPixelBufferUnlockBaseAddress(blank, 0);
        if (CMVideoFormatDescriptionCreateForImageBuffer(kCFAllocatorDefault, blank, &_formatDescription) != noErr) return nil;
        _device = [[CMIOExtensionDevice alloc] initWithLocalizedName:@"JH Mirror Camera"
            deviceID:[[NSUUID alloc] initWithUUIDString:JHDeviceID] legacyDeviceID:nil source:self];
        _output = [[JHCameraStream alloc] initWithOwner:self sink:NO];
        _input = [[JHCameraStream alloc] initWithOwner:self sink:YES];
        NSError *error = nil;
        if (![_device addStream:_output.stream error:&error] || ![_device addStream:_input.stream error:&error]) return nil;
    }
    return self;
}
- (void)dealloc {
    if (_timer) dispatch_source_cancel(_timer);
    if (_latest) CVPixelBufferRelease(_latest);
    if (_blank) CVPixelBufferRelease(_blank);
    if (_formatDescription) CFRelease(_formatDescription);
}
- (NSSet *)availableProperties { return [NSSet setWithObjects:CMIOExtensionPropertyDeviceTransportType, CMIOExtensionPropertyDeviceModel, nil]; }
- (CMIOExtensionDeviceProperties *)devicePropertiesForProperties:(NSSet *)properties error:(NSError **)error {
    (void)properties; (void)error;
    CMIOExtensionDeviceProperties *value = [[CMIOExtensionDeviceProperties alloc] initWithDictionary:@{}];
    value.transportType = @(kAudioDeviceTransportTypeVirtual); value.model = @"JH Mirror Native Camera"; return value;
}
- (BOOL)setDeviceProperties:(CMIOExtensionDeviceProperties *)properties error:(NSError **)error { (void)properties; (void)error; return YES; }
- (BOOL)authorizeWriter:(CMIOExtensionClient *)client {
    if (_writer && ![_writer.clientID isEqual:client.clientID]) return NO;
    // Capture clients may read normally. Only our signed helper may supply camera frames.
    NSString *team = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"JHMirrorTeamID"];
    if (!team || team.length != 10 || ![client.signingID isEqualToString:@"com.johirulhoqakash.jhmirror.screen"]) return NO;
    NSDictionary *attributes = @{(__bridge NSString *)kSecGuestAttributePid:@(client.pid)};
    SecCodeRef code = nil; SecRequirementRef requirement = nil;
    NSString *rule = [NSString stringWithFormat:@"anchor apple generic and identifier \"com.johirulhoqakash.jhmirror.screen\" and certificate leaf[subject.OU] = \"%@\"", team];
    BOOL trusted = SecCodeCopyGuestWithAttributes(nil, (__bridge CFDictionaryRef)attributes, kSecCSDefaultFlags, &code) == errSecSuccess
        && SecRequirementCreateWithString((__bridge CFStringRef)rule, kSecCSDefaultFlags, &requirement) == errSecSuccess
        && SecCodeCheckValidity(code, kSecCSStrictValidate, requirement) == errSecSuccess;
    if (code) CFRelease(code); if (requirement) CFRelease(requirement);
    if (trusted) _writer = client;
    return trusted;
}
- (void)disconnect:(CMIOExtensionClient *)client {
    if ([_writer.clientID isEqual:client.clientID]) {
        _writer = nil; _writerStarted = NO; _writerGeneration += 1;
        if (_latest) { CVPixelBufferRelease(_latest); _latest = nil; }
        [self updateTimer];
    }
}
- (void)updateTimer {
    if (!_readers && !_writerStarted) {
        if (_timer) { dispatch_source_cancel(_timer); _timer = nil; }
        return;
    }
    if (_timer) return;
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 30, NSEC_PER_MSEC);
    __weak JHCameraDevice *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}
- (void)tick {
    if (_writerStarted && _writer && !_consuming) {
        _consuming = YES;
        uint64_t generation = _writerGeneration;
        [_input.stream consumeSampleBufferFromClient:_writer completionHandler:^(CMSampleBufferRef sample, uint64_t sequence,
                CMIOExtensionStreamDiscontinuityFlags flags, BOOL more, NSError *error) {
            (void)flags; (void)more;
            if (sample) CFRetain(sample);
            dispatch_async(self.queue, ^{
                self.consuming = NO;
                if (generation == self.writerGeneration && self.writerStarted && !error && sample) {
                    CVPixelBufferRef image = CMSampleBufferGetImageBuffer(sample);
                    if (image && CVPixelBufferGetWidth(image) == JHWidth && CVPixelBufferGetHeight(image) == JHHeight
                            && CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA) {
                        if (self.latest) CVPixelBufferRelease(self.latest);
                        self.latest = CVPixelBufferRetain(image); self.lastArrival = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
                    }
                    [self.input.stream notifyScheduledOutputChanged:[[CMIOExtensionScheduledOutput alloc]
                        initWithSequenceNumber:sequence hostTimeInNanoseconds:clock_gettime_nsec_np(CLOCK_UPTIME_RAW)]];
                }
                if (sample) CFRelease(sample);
            });
        }];
    }
    if (!_readers) return;
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    CVPixelBufferRef image = _latest && now - _lastArrival < JHStaleNanoseconds ? _latest : _blank;
    CMSampleTimingInfo timing = {CMTimeMake(1, 30), CMClockGetTime(CMClockGetHostTimeClock()), kCMTimeInvalid};
    CMSampleBufferRef sample = nil;
    if (CMSampleBufferCreateReadyWithImageBuffer(kCFAllocatorDefault, image, _formatDescription, &timing, &sample) == noErr) {
        [_output.stream sendSampleBuffer:sample discontinuity:CMIOExtensionStreamDiscontinuityFlagNone hostTimeInNanoseconds:now];
        CFRelease(sample);
    }
}
@end

@interface JHCameraProvider : NSObject <CMIOExtensionProviderSource>
@property CMIOExtensionProvider *provider;
@property JHCameraDevice *camera;
@end
@implementation JHCameraProvider
- (instancetype)init {
    if ((self = [super init])) {
        dispatch_queue_t queue = dispatch_queue_create("com.johirulhoqakash.jhmirror.camera", DISPATCH_QUEUE_SERIAL);
        _camera = [[JHCameraDevice alloc] initWithQueue:queue];
        _provider = [[CMIOExtensionProvider alloc] initWithSource:self clientQueue:queue];
        NSError *error = nil;
        if (!_camera || ![_provider addDevice:_camera.device error:&error]) return nil;
    }
    return self;
}
- (BOOL)connectClient:(CMIOExtensionClient *)client error:(NSError **)error { (void)client; (void)error; return YES; }
- (void)disconnectClient:(CMIOExtensionClient *)client { [_camera disconnect:client]; }
- (NSSet *)availableProperties { return [NSSet setWithObject:CMIOExtensionPropertyProviderManufacturer]; }
- (CMIOExtensionProviderProperties *)providerPropertiesForProperties:(NSSet *)properties error:(NSError **)error {
    (void)properties; (void)error;
    CMIOExtensionProviderProperties *value = [[CMIOExtensionProviderProperties alloc] initWithDictionary:@{}];
    value.manufacturer = @"JH Mirror · Johirul Hoq Akash"; return value;
}
- (BOOL)setProviderProperties:(CMIOExtensionProviderProperties *)properties error:(NSError **)error { (void)properties; (void)error; return YES; }
@end

#ifndef JH_CAMERA_UNIT_TEST
int main(void) {
    @autoreleasepool {
        JHCameraProvider *provider = [JHCameraProvider new];
        if (!provider) return 1;
        [CMIOExtensionProvider startServiceWithProvider:provider.provider];
        CFRunLoopRun();
    }
    return 0;
}
#endif
