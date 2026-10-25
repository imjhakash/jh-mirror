// Synthetic images only. Never opens a physical camera, phone, adb, or audio input.
#include "../../scrcpy-5.0.1/app/src/aw_camera_sink.m"
#import <AppKit/AppKit.h>
#include <assert.h>
#include <pthread.h>
#include <SDL3/SDL.h>

static AVFrame *image(void) {
    AVFrame *frame = av_frame_alloc(); assert(frame);
    frame->format = AV_PIX_FMT_YUV420P; frame->width = 8; frame->height = 8;
    assert(av_frame_get_buffer(frame, 0) == 0);
    for (int y=0;y<8;y++) memset(frame->data[0]+y*frame->linesize[0],235,8);
    for (int y=0;y<4;y++) {
        memset(frame->data[1]+y*frame->linesize[1],128,4);
        memset(frame->data[2]+y*frame->linesize[2],128,4);
    }
    return frame;
}
static void check_pixels(CVPixelBufferRef pixel) {
    assert(pixel && CVPixelBufferGetWidth(pixel)==1280 && CVPixelBufferGetHeight(pixel)==720);
    CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    size_t stride=CVPixelBufferGetBytesPerRow(pixel);
    uint8_t *data=CVPixelBufferGetBaseAddress(pixel), *center=data+360*stride+640*4, *edge=data+360*stride+10*4;
    assert(center[0]>220 && center[1]>220 && center[2]>220 && center[3]==255);
    assert(edge[0]<5 && edge[1]<5 && edge[2]<5 && edge[3]==255);
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
}
static int color_at(CVPixelBufferRef pixel, unsigned x, unsigned y) {
    CVPixelBufferLockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly);
    const uint8_t *p=(const uint8_t *)CVPixelBufferGetBaseAddress(pixel)+y*CVPixelBufferGetBytesPerRow(pixel)+x*4;
    int color = p[2]>200 && p[1]<40 && p[0]<40 ? 0 : p[1]>200 && p[2]<40 && p[0]<40 ? 1
        : p[0]>200 && p[1]<40 && p[2]<40 ? 2 : p[0]>200 && p[1]>200 && p[2]>200 ? 3 : -1;
    CVPixelBufferUnlockBaseAddress(pixel,kCVPixelBufferLock_ReadOnly); return color;
}
static void check_rotation(JHCameraWriter *writer) {
    CVPixelBufferRef image=NULL; assert(CVPixelBufferCreate(NULL,8,4,kCVPixelFormatType_32BGRA,NULL,&image)==0);
    CVPixelBufferLockBaseAddress(image,0);
    const uint8_t colors[4][4]={{0,0,255,255},{0,255,0,255},{255,0,0,255},{255,255,255,255}};
    for (unsigned y=0;y<4;y++) for (unsigned x=0;x<8;x++) {
        memcpy((uint8_t *)CVPixelBufferGetBaseAddress(image)+y*CVPixelBufferGetBytesPerRow(image)+x*4,colors[(y/2)*2+x/4],4);
    }
    CVPixelBufferUnlockBaseAddress(image,0);
    AVFrame frame={0}; frame.format=AV_PIX_FMT_VIDEOTOOLBOX; frame.data[3]=(uint8_t *)image;
    const int expected[5][4]={{0,1,2,3},{2,0,3,1},{3,2,1,0},{1,3,0,2},{1,0,3,2}};
    for (unsigned setting=0;setting<5;setting++) {
        writer.controls=setting;
        assert([writer pushFrame:&frame]==1);
        CMSampleBufferRef sample=(CMSampleBufferRef)CMSimpleQueueDequeue(writer.buffers);
        CVPixelBufferRef out=CMSampleBufferGetImageBuffer(sample);
        unsigned xs[2]={480,800},ys[2]={270,450};
        if (setting==1 || setting==3) { xs[0]=550;xs[1]=730;ys[0]=180;ys[1]=540; }
        for (unsigned y=0;y<2;y++) for(unsigned x=0;x<2;x++) assert(color_at(out,xs[x],ys[y])==expected[setting][y*2+x]);
        CFRelease(sample);
    }
    writer.previewMap=mmap(NULL,JHPreviewBytes,PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0); assert(writer.previewMap!=MAP_FAILED);
    memcpy(writer.previewMap,"AWP1",4); writer.controls=8;
    assert([writer pushFrame:&frame]==1);
    CMSampleBufferRef sample=(CMSampleBufferRef)CMSimpleQueueDequeue(writer.buffers);CFRelease(sample);
    assert(*(uint64_t *)((uint8_t *)writer.previewMap+8)>0 && !(*(uint64_t *)((uint8_t *)writer.previewMap+8)&1));
    assert(*(uint32_t *)((uint8_t *)writer.previewMap+16)==640 && *(uint32_t *)((uint8_t *)writer.previewMap+20)==360);
    CVPixelBufferRelease(image);
    puts("PASS: clockwise quarter-turns and mirroring match expected pixels; bounded output preview publishes complete frames.");
}
static void unit_tests(void) {
    JHCameraWriter *writer=[JHCameraWriter new]; writer.width=1280; writer.height=720;
    CMSimpleQueueRef queue=NULL; assert(CMSimpleQueueCreate(NULL,2,&queue)==noErr); writer.buffers=queue;
    CVPixelBufferPoolRef pool=NULL;
    NSDictionary *attributes=@{(id)kCVPixelBufferWidthKey:@1280,(id)kCVPixelBufferHeightKey:@720,
        (id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),(id)kCVPixelBufferIOSurfacePropertiesKey:@{}};
    assert(CVPixelBufferPoolCreate(NULL,NULL,(__bridge CFDictionaryRef)attributes,&pool)==kCVReturnSuccess); writer.pool=pool;
    writer.imageContext=[CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer:@YES}];
    writer.lastEnqueue=clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    AVFrame *frame=image();
    assert([writer pushFrame:frame]==1); assert([writer pushFrame:frame]==1);
    assert([writer pushFrame:frame]==0 && CMSimpleQueueGetCount(queue)==2);
    writer.lastEnqueue-=4*NSEC_PER_SEC; assert([writer pushFrame:frame]==-1);
    CMSampleBufferRef sample=(CMSampleBufferRef)CMSimpleQueueDequeue(queue);
    check_pixels(CMSampleBufferGetImageBuffer(sample)); CFRelease(sample);
    sample=(CMSampleBufferRef)CMSimpleQueueDequeue(queue); CFRelease(sample);
    // Software NV12 and VideoToolbox pixel buffers share the same output path.
    CVPixelBufferRef nv12=[writer copyImageForFrame:frame]; assert(nv12);
    AVFrame hardware={0}; hardware.format=AV_PIX_FMT_VIDEOTOOLBOX; hardware.data[3]=(uint8_t *)nv12;
    assert([writer pushFrame:&hardware]==1); sample=(CMSampleBufferRef)CMSimpleQueueDequeue(queue);
    check_pixels(CMSampleBufferGetImageBuffer(sample)); CFRelease(sample); CVPixelBufferRelease(nv12);
    for (int y=0;y<8;y++) memset(frame->data[0]+y*frame->linesize[0],81,8);
    for (int y=0;y<4;y++) {
        memset(frame->data[1]+y*frame->linesize[1],90,4);
        memset(frame->data[2]+y*frame->linesize[2],240,4);
    }
    assert([writer pushFrame:frame]==1); sample=(CMSampleBufferRef)CMSimpleQueueDequeue(queue);
    CVPixelBufferRef red=CMSampleBufferGetImageBuffer(sample); CVPixelBufferLockBaseAddress(red,kCVPixelBufferLock_ReadOnly);
    uint8_t *center=(uint8_t *)CVPixelBufferGetBaseAddress(red)+360*CVPixelBufferGetBytesPerRow(red)+640*4;
    assert(center[2]>200 && center[0]<100 && center[1]<100);
    CVPixelBufferUnlockBaseAddress(red,kCVPixelBufferLock_ReadOnly); CFRelease(sample);
    frame->width=7; assert([writer pushFrame:frame]==-1); frame->width=8;
    uint8_t *saved=frame->data[1]; frame->data[1]=NULL; assert([writer pushFrame:frame]==-1); frame->data[1]=saved;
    av_frame_free(&frame);
    check_rotation(writer);
    puts("PASS: YUV/VideoToolbox conversion, letterboxing, bounded queue, stalled device rejection, malformed frame rejection.");
}
static void virtual_device_test(BOOL pumpRunloop) {
    assert(![NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.obsproject.obs-studio"].count);
    setenv("JH_CAMERA_DEVICE_UID","7626645E-4425-469E-9D8B-97E0FA59AC75",1);
    CMIOObjectPropertyAddress check={kCMIOHardwarePropertyDevices,kCMIOObjectPropertyScopeGlobal,kCMIOObjectPropertyElementMain};
    CMIODeviceID devices[1024]; UInt32 deviceBytes=sizeof(devices);
    assert(CMIOObjectGetPropertyData(kCMIOObjectSystemObject,&check,0,NULL,deviceBytes,&deviceBytes,devices)==noErr);
    BOOL idle=NO;
    for (unsigned i=0;i<deviceBytes/sizeof(CMIODeviceID);i++) {
        CFStringRef uid=NULL; UInt32 bytes=sizeof(uid); check.mSelector=kCMIODevicePropertyDeviceUID;
        if (!CMIOObjectGetPropertyData(devices[i],&check,0,NULL,bytes,&bytes,&uid) && uid) {
            BOOL match=[(__bridge NSString *)uid isEqualToString:@"7626645E-4425-469E-9D8B-97E0FA59AC75"]; CFRelease(uid);
            if (match) {
                UInt32 running=1; bytes=sizeof(running); check.mSelector=kCMIODevicePropertyDeviceIsRunningSomewhere;
                idle=!CMIOObjectGetPropertyData(devices[i],&check,0,NULL,bytes,&bytes,&running) && !running;
                break;
            }
        }
    }
    if (!idle) { puts("SKIP: virtual camera is busy, unavailable, or cannot be confirmed idle."); exit(77); }
    JHCameraWriter *writer=[JHCameraWriter new];
    // Opens only this confirmed-idle virtual device, never physical capture.
    assert([writer connect]);
    printf("Virtual camera connected: %dx%d, queue capacity %d; OBS app is closed.\n",writer.width,writer.height,CMSimpleQueueGetCapacity(writer.buffers));
    AVFrame *frame=image();
    for (unsigned i=0;i<90 && atomic_load(&accepted_frames)<5;i++) {
        assert([writer pushFrame:frame]>=0);
        if (pumpRunloop) CFRunLoopRunInMode(kCFRunLoopDefaultMode,.001,false);
        usleep(33333);
    }
    av_frame_free(&frame);
    printf("Acknowledged %llu generated frames.\n",(unsigned long long)atomic_load(&accepted_frames));
    assert(atomic_load(&accepted_frames)>=5);
    puts("PASS: synthetic frames acknowledged by the real signed camera extension with OBS closed; no phone or physical camera used.");
}
static _Atomic bool workerDone;
static void *virtual_worker(void *context) {
    (void)context;
    @autoreleasepool { virtual_device_test(NO); }
    atomic_store(&workerDone,true); return NULL;
}
int main(int argc,char **argv) {
    @autoreleasepool {
        if (argc==2 && !strcmp(argv[1],"--worker-device")) {
            assert(SDL_Init(SDL_INIT_EVENTS));
            pthread_t worker; assert(pthread_create(&worker,NULL,virtual_worker,NULL)==0);
            while (!atomic_load(&workerDone)) { SDL_Event event; SDL_WaitEventTimeout(&event,33); }
            pthread_join(worker,NULL); SDL_Quit();
            puts("PASS: actual decoder-thread / SDL-event-loop transport without a camera window.");
        } else if (argc==2 && !strcmp(argv[1],"--virtual-device")) virtual_device_test(YES);
        else unit_tests();
    }
    return 0;
}
