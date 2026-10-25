// JH Mirror's user-space Core Audio loopback device. No kernel code or external audio app.
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreAudio/AudioHardware.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <stdatomic.h>
#include <pthread.h>
#include <math.h>
#include <stddef.h>
#include <string.h>

enum { JHPlugin = kAudioObjectPlugInObject, JHDevice = 2, JHInput = 3, JHOutput = 4,
       JHRate = 48000, JHChannels = 2, JHFrames = 512, JHRing = 32768, JHPeriod = 16384 };
static CFStringRef const JHUID = CFSTR("com.johirulhoqakash.jhmirror.microphone");
static _Atomic UInt64 frame_tags[JHRing];
static _Atomic UInt64 frame_values[JHRing];
static _Atomic UInt32 references = 1, running = 0;
static _Atomic bool input_active = true, output_active = true;
static _Atomic UInt64 anchor, clock_seed = 1;
static double ticks_per_frame;
static pthread_mutex_t state_mutex = PTHREAD_MUTEX_INITIALIZER;
static AudioServerPlugInHostRef host;
static AudioServerPlugInDriverInterface driver_interface;
static AudioServerPlugInDriverInterface *driver_pointer = &driver_interface;
static AudioServerPlugInDriverRef driver = &driver_pointer;
_Static_assert(ATOMIC_LLONG_LOCK_FREE == 2, "The audio ring requires lock-free 64-bit atomics");

static bool valid_object(AudioObjectID object) { return object >= JHPlugin && object <= JHOutput; }
static bool stream_object(AudioObjectID object) { return object == JHInput || object == JHOutput; }
static AudioStreamBasicDescription stream_format(void) {
    return (AudioStreamBasicDescription){.mSampleRate = JHRate, .mFormatID = kAudioFormatLinearPCM,
        .mFormatFlags = kAudioFormatFlagsNativeFloatPacked, .mBytesPerPacket = 8, .mFramesPerPacket = 1,
        .mBytesPerFrame = 8, .mChannelsPerFrame = 2, .mBitsPerChannel = 32};
}
static OSStatus copy_data(UInt32 capacity, UInt32 *size, void *output, const void *value, UInt32 bytes) {
    if (!size) return kAudioHardwareIllegalOperationError;
    *size = bytes;
    if (!output) return noErr; // Also used for GetPropertyDataSize, without allocating or retaining.
    if (capacity < bytes) return kAudioHardwareBadPropertySizeError;
    if (bytes) memcpy(output, value, bytes);
    return noErr;
}
static OSStatus copy_string(UInt32 capacity, UInt32 *size, void *output, CFStringRef value) {
    if (output && capacity >= sizeof(value) && value) CFRetain(value);
    return copy_data(capacity, size, output, &value, sizeof(value));
}
static OSStatus property(AudioObjectID object, const AudioObjectPropertyAddress *address,
        UInt32 qualifier_size, const void *qualifier, UInt32 capacity, UInt32 *size, void *output) {
    if (!valid_object(object) || !address) return kAudioHardwareBadObjectError;
    AudioObjectPropertySelector selector = address->mSelector;
    UInt32 integer = 0;
    AudioObjectID objects[2] = {0}; UInt32 count = 0;
    switch (selector) {
        case kAudioObjectPropertyBaseClass:
            integer = stream_object(object) ? kAudioObjectClassID : kAudioObjectClassID; break;
        case kAudioObjectPropertyClass:
            integer = object == JHPlugin ? kAudioPlugInClassID : object == JHDevice ? kAudioDeviceClassID : kAudioStreamClassID; break;
        case kAudioObjectPropertyOwner:
            integer = object == JHPlugin ? kAudioObjectUnknown : object == JHDevice ? JHPlugin : JHDevice; break;
        case kAudioObjectPropertyName:
            return copy_string(capacity, size, output, object == JHInput ? CFSTR("Phone Microphone")
                : object == JHOutput ? CFSTR("JH Mirror Feed") : CFSTR("JH Mirror Microphone"));
        case kAudioObjectPropertyManufacturer:
            return copy_string(capacity, size, output, CFSTR("Johirul Hoq Akash · JH Mirror"));
        case kAudioObjectPropertyOwnedObjects:
            if (object == JHPlugin) objects[count++] = JHDevice;
            if (object == JHDevice) {
                if (address->mScope != kAudioObjectPropertyScopeOutput) objects[count++] = JHInput;
                if (address->mScope != kAudioObjectPropertyScopeInput) objects[count++] = JHOutput;
            }
            return copy_data(capacity, size, output, objects, count * sizeof(AudioObjectID));
        case kAudioObjectPropertyCustomPropertyInfoList:
            return copy_data(capacity, size, output, NULL, 0);
        default:
            if (object == JHPlugin) {
                switch (selector) {
                    case kAudioPlugInPropertyBundleID: return copy_string(capacity, size, output, CFSTR("com.johirulhoqakash.jhmirror.audio"));
                    case kAudioPlugInPropertyResourceBundle: return copy_string(capacity, size, output, CFSTR(""));
                    case kAudioPlugInPropertyDeviceList: integer = JHDevice; break;
                    case kAudioPlugInPropertyTranslateUIDToDevice:
                        if (qualifier_size != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
                        { CFStringRef uid = *(const CFStringRef *)qualifier;
                          integer = uid && CFGetTypeID(uid) == CFStringGetTypeID() && CFEqual(uid, JHUID) ? JHDevice : kAudioObjectUnknown; }
                        break;
                    default: return kAudioHardwareUnknownPropertyError;
                }
            } else if (object == JHDevice) {
                switch (selector) {
                    case kAudioDevicePropertyDeviceUID: return copy_string(capacity, size, output, JHUID);
                    case kAudioDevicePropertyModelUID: return copy_string(capacity, size, output, CFSTR("com.johirulhoqakash.jhmirror.audio.v1"));
                    case kAudioDevicePropertyTransportType: integer = kAudioDeviceTransportTypeVirtual; break;
                    case kAudioDevicePropertyClockDomain: integer = 0; break;
                    case kAudioDevicePropertyDeviceIsAlive: integer = 1; break;
                    case kAudioDevicePropertyDeviceIsRunning:
                    case kAudioDevicePropertyDeviceIsRunningSomewhere: integer = atomic_load(&running) != 0; break;
                    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                        integer = address->mScope == kAudioObjectPropertyScopeInput; break;
                    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: integer = 0; break;
                    case kAudioDevicePropertyRelatedDevices: integer = JHDevice; break;
                    case kAudioDevicePropertyLatency:
                    case kAudioDevicePropertySafetyOffset: integer = 0; break;
                    case kAudioDevicePropertyZeroTimeStampPeriod: integer = JHPeriod; break;
                    case kAudioDevicePropertyClockAlgorithm: integer = kAudioDeviceClockAlgorithmRaw; break;
                    case kAudioDevicePropertyClockIsStable: integer = 1; break;
                    case kAudioDevicePropertyIsHidden: integer = 0; break;
                    case kAudioObjectPropertyControlList: return copy_data(capacity, size, output, NULL, 0);
                    case kAudioDevicePropertyStreams:
                        if (address->mScope != kAudioObjectPropertyScopeOutput) objects[count++] = JHInput;
                        if (address->mScope != kAudioObjectPropertyScopeInput) objects[count++] = JHOutput;
                        return copy_data(capacity, size, output, objects, count * sizeof(AudioObjectID));
                    case kAudioDevicePropertyStreamConfiguration: {
                        AudioBufferList layout = {.mNumberBuffers = 1, .mBuffers = {{.mNumberChannels = 2, .mDataByteSize = 0, .mData = NULL}}};
                        return copy_data(capacity, size, output, &layout, sizeof(layout));
                    }
                    case kAudioDevicePropertyNominalSampleRate: {
                        Float64 rate = JHRate; return copy_data(capacity, size, output, &rate, sizeof(rate));
                    }
                    case kAudioDevicePropertyAvailableNominalSampleRates: {
                        AudioValueRange rates = {JHRate, JHRate}; return copy_data(capacity, size, output, &rates, sizeof(rates));
                    }
                    case kAudioDevicePropertyBufferFrameSize: integer = JHFrames; break;
                    case kAudioDevicePropertyBufferFrameSizeRange: {
                        AudioValueRange frames = {JHFrames, JHFrames}; return copy_data(capacity, size, output, &frames, sizeof(frames));
                    }
                    case kAudioDevicePropertyPreferredChannelsForStereo: {
                        UInt32 channels[] = {1, 2}; return copy_data(capacity, size, output, channels, sizeof(channels));
                    }
                    case kAudioDevicePropertyPreferredChannelLayout: {
                        AudioChannelLayout layout = {.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo, .mNumberChannelDescriptions = 0};
                        return copy_data(capacity, size, output, &layout, offsetof(AudioChannelLayout, mChannelDescriptions));
                    }
                    default: return kAudioHardwareUnknownPropertyError;
                }
            } else {
                switch (selector) {
                    case kAudioStreamPropertyIsActive: integer = atomic_load(object == JHInput ? &input_active : &output_active); break;
                    case kAudioStreamPropertyDirection: integer = object == JHInput; break;
                    case kAudioStreamPropertyTerminalType: integer = object == JHInput ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeLine; break;
                    case kAudioStreamPropertyStartingChannel: integer = 1; break;
                    case kAudioStreamPropertyLatency: integer = 0; break;
                    case kAudioStreamPropertyVirtualFormat:
                    case kAudioStreamPropertyPhysicalFormat: {
                        AudioStreamBasicDescription format = stream_format(); return copy_data(capacity, size, output, &format, sizeof(format));
                    }
                    case kAudioStreamPropertyAvailableVirtualFormats:
                    case kAudioStreamPropertyAvailablePhysicalFormats: {
                        AudioStreamRangedDescription format = {.mFormat = stream_format(), .mSampleRateRange = {JHRate, JHRate}};
                        return copy_data(capacity, size, output, &format, sizeof(format));
                    }
                    default: return kAudioHardwareUnknownPropertyError;
                }
            }
    }
    return copy_data(capacity, size, output, &integer, sizeof(integer));
}

static ULONG retain_driver(void *pointer) { return pointer == driver ? atomic_fetch_add(&references, 1) + 1 : 0; }
static ULONG release_driver(void *pointer) {
    if (pointer != driver) return 0;
    UInt32 old = atomic_load(&references);
    while (old > 1 && !atomic_compare_exchange_weak(&references, &old, old - 1)) { }
    return old > 1 ? old - 1 : 1; // A singleton stays alive for the host's lifetime.
}
static HRESULT query_interface(void *pointer, REFIID uuid, LPVOID *result) {
    if (pointer != driver || !result) return E_NOINTERFACE;
    *result = NULL;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, uuid);
    bool accepted = CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(requested);
    if (!accepted) return E_NOINTERFACE;
    retain_driver(pointer); *result = driver; return S_OK;
}
static OSStatus initialize(AudioServerPlugInDriverRef pointer, AudioServerPlugInHostRef interface) {
    if (pointer != driver) return kAudioHardwareBadObjectError;
    host = interface;
    mach_timebase_info_data_t timebase; mach_timebase_info(&timebase);
    ticks_per_frame = 1e9 * timebase.denom / timebase.numer / JHRate;
    atomic_store(&anchor, mach_absolute_time()); return noErr;
}
static OSStatus create_device(AudioServerPlugInDriverRef pointer, CFDictionaryRef description,
        const AudioServerPlugInClientInfo *client, AudioObjectID *object) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus destroy_device(AudioServerPlugInDriverRef pointer, AudioObjectID object) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus device_client(AudioServerPlugInDriverRef pointer, AudioObjectID object, const AudioServerPlugInClientInfo *client) {
    return pointer == driver && object == JHDevice ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus configuration(AudioServerPlugInDriverRef pointer, AudioObjectID object, UInt64 action, void *info) {
    return pointer == driver && object == JHDevice ? noErr : kAudioHardwareBadObjectError;
}
static Boolean has_property(AudioServerPlugInDriverRef pointer, AudioObjectID object, pid_t pid, const AudioObjectPropertyAddress *address) {
    UInt32 size;
    if (pointer == driver && object == JHPlugin && address && address->mSelector == kAudioPlugInPropertyTranslateUIDToDevice) return true;
    return pointer == driver && property(object, address, 0, NULL, 0, &size, NULL) == noErr;
}
static OSStatus settable(AudioServerPlugInDriverRef pointer, AudioObjectID object, pid_t pid,
        const AudioObjectPropertyAddress *address, Boolean *result) {
    if (!result) return kAudioHardwareIllegalOperationError;
    if (!has_property(pointer, object, pid, address)) return kAudioHardwareUnknownPropertyError;
    *result = (stream_object(object) && (address->mSelector == kAudioStreamPropertyIsActive
        || address->mSelector == kAudioStreamPropertyVirtualFormat || address->mSelector == kAudioStreamPropertyPhysicalFormat))
        || (object == JHDevice && (address->mSelector == kAudioDevicePropertyNominalSampleRate || address->mSelector == kAudioDevicePropertyBufferFrameSize));
    return noErr;
}
static OSStatus property_size(AudioServerPlugInDriverRef pointer, AudioObjectID object, pid_t pid,
        const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 *size) {
    if (pointer != driver) return kAudioHardwareBadObjectError;
    return property(object, address, qualifier_size, qualifier, 0, size, NULL);
}
static OSStatus get_property(AudioServerPlugInDriverRef pointer, AudioObjectID object, pid_t pid,
        const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 capacity, UInt32 *size, void *data) {
    if (pointer != driver) return kAudioHardwareBadObjectError;
    return property(object, address, qualifier_size, qualifier, capacity, size, data);
}
static OSStatus set_property(AudioServerPlugInDriverRef pointer, AudioObjectID object, pid_t pid,
        const AudioObjectPropertyAddress *address, UInt32 qualifier_size, const void *qualifier, UInt32 size, const void *data) {
    Boolean allowed = false;
    OSStatus status = settable(pointer, object, pid, address, &allowed);
    if (status || !allowed || !data) return status ? status : kAudioHardwareIllegalOperationError;
    if (address->mSelector == kAudioStreamPropertyIsActive) {
        if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        atomic_store(object == JHInput ? &input_active : &output_active, *(const UInt32 *)data != 0);
        if (host) host->PropertiesChanged(host, object, 1, address);
        return noErr;
    }
    if (address->mSelector == kAudioDevicePropertyNominalSampleRate) {
        if (size != sizeof(Float64)) return kAudioHardwareBadPropertySizeError;
        return *(const Float64 *)data == JHRate ? noErr : kAudioDeviceUnsupportedFormatError;
    }
    if (address->mSelector == kAudioDevicePropertyBufferFrameSize) {
        if (size != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
        return *(const UInt32 *)data == JHFrames ? noErr : kAudioHardwareUnsupportedOperationError;
    }
    if (size != sizeof(AudioStreamBasicDescription)) return kAudioHardwareBadPropertySizeError;
    const AudioStreamBasicDescription *format = data; AudioStreamBasicDescription supported = stream_format();
    return format->mSampleRate == supported.mSampleRate && format->mFormatID == supported.mFormatID
        && format->mFormatFlags == supported.mFormatFlags && format->mBytesPerPacket == supported.mBytesPerPacket
        && format->mFramesPerPacket == 1 && format->mBytesPerFrame == 8 && format->mChannelsPerFrame == 2 && format->mBitsPerChannel == 32
        ? noErr : kAudioDeviceUnsupportedFormatError;
}
static OSStatus start_io(AudioServerPlugInDriverRef pointer, AudioObjectID object, UInt32 client) {
    if (pointer != driver || object != JHDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&state_mutex);
    if (!atomic_load(&running)) {
        for (unsigned i = 0; i < JHRing; i++) atomic_store(&frame_tags[i], 0);
        atomic_store(&anchor, mach_absolute_time()); atomic_fetch_add(&clock_seed, 1);
    }
    atomic_fetch_add(&running, 1);
    pthread_mutex_unlock(&state_mutex); return noErr;
}
static OSStatus stop_io(AudioServerPlugInDriverRef pointer, AudioObjectID object, UInt32 client) {
    if (pointer != driver || object != JHDevice) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&state_mutex);
    UInt32 current = atomic_load(&running);
    if (current) atomic_fetch_sub(&running, 1);
    pthread_mutex_unlock(&state_mutex);
    return current ? noErr : kAudioHardwareIllegalOperationError;
}
static OSStatus zero_timestamp(AudioServerPlugInDriverRef pointer, AudioObjectID object, UInt32 client,
        Float64 *sample, UInt64 *host_time, UInt64 *seed) {
    if (pointer != driver || object != JHDevice) return kAudioHardwareBadObjectError;
    if (!sample || !host_time || !seed || ticks_per_frame <= 0) return kAudioHardwareIllegalOperationError;
    UInt64 start = atomic_load(&anchor), now = mach_absolute_time();
    double periods = floor((now > start ? now - start : 0) / (ticks_per_frame * JHPeriod));
    *sample = periods * JHPeriod; *host_time = start + (UInt64)(*sample * ticks_per_frame); *seed = atomic_load(&clock_seed);
    return noErr;
}
static OSStatus will_io(AudioServerPlugInDriverRef pointer, AudioObjectID object, UInt32 client, UInt32 operation,
        Boolean *will_do, Boolean *in_place) {
    if (pointer != driver || object != JHDevice) return kAudioHardwareBadObjectError;
    if (!will_do || !in_place) return kAudioHardwareIllegalOperationError;
    *will_do = operation == kAudioServerPlugInIOOperationReadInput || operation == kAudioServerPlugInIOOperationWriteMix;
    *in_place = true; return noErr;
}
static OSStatus io_boundary(AudioServerPlugInDriverRef pointer, AudioObjectID object, UInt32 client,
        UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle) {
    return pointer == driver && object == JHDevice ? noErr : kAudioHardwareBadObjectError;
}
static OSStatus do_io(AudioServerPlugInDriverRef pointer, AudioObjectID object, AudioObjectID stream, UInt32 client,
        UInt32 operation, UInt32 frames, const AudioServerPlugInIOCycleInfo *cycle, void *main_buffer, void *secondary) {
    if (pointer != driver || object != JHDevice || !stream_object(stream)) return kAudioHardwareBadObjectError;
    if (!cycle || !main_buffer || frames > JHRing) return kAudioHardwareIllegalOperationError;
    bool reading = operation == kAudioServerPlugInIOOperationReadInput && stream == JHInput;
    bool writing = operation == kAudioServerPlugInIOOperationWriteMix && stream == JHOutput;
    if (!reading && !writing) return kAudioHardwareUnsupportedOperationError;
    Float64 sample_time = reading ? cycle->mInputTime.mSampleTime : cycle->mOutputTime.mSampleTime;
    bool valid = isfinite(sample_time) && sample_time >= 0 && sample_time < 0x1p52;
    if (!valid || !atomic_load(reading ? &input_active : &output_active) || !atomic_load(&running)) {
        if (reading) memset(main_buffer, 0, frames * 8);
        return noErr;
    }
    UInt64 first = (UInt64)sample_time;
    float *samples = main_buffer;
    // Real-time path: no allocation, file IO, locks, logging or unbounded work.
    for (UInt32 i = 0; i < frames; i++) {
        UInt64 position = first + i, tag = position + 1, slot = position % JHRing;
        if (writing) {
            float pair[2];
            for (unsigned channel = 0; channel < 2; channel++) {
                float value = samples[2 * i + channel]; pair[channel] = isfinite(value) ? fmaxf(-1, fminf(1, value)) : 0;
            }
            UInt64 packed; memcpy(&packed, pair, sizeof(packed));
            atomic_store_explicit(&frame_tags[slot], 0, memory_order_release);
            atomic_store_explicit(&frame_values[slot], packed, memory_order_release);
            atomic_store_explicit(&frame_tags[slot], tag, memory_order_release);
        } else {
            UInt64 before = atomic_load_explicit(&frame_tags[slot], memory_order_acquire);
            UInt64 packed = atomic_load_explicit(&frame_values[slot], memory_order_acquire);
            UInt64 after = atomic_load_explicit(&frame_tags[slot], memory_order_acquire);
            if (before == tag && after == tag) memcpy(samples + 2 * i, &packed, sizeof(packed));
            else samples[2 * i] = samples[2 * i + 1] = 0; // Underrun / expired ring slots are always silence.
        }
    }
    return noErr;
}

static AudioServerPlugInDriverInterface driver_interface = {
    ._reserved = NULL, .QueryInterface = query_interface, .AddRef = retain_driver, .Release = release_driver,
    .Initialize = initialize, .CreateDevice = create_device, .DestroyDevice = destroy_device,
    .AddDeviceClient = device_client, .RemoveDeviceClient = device_client,
    .PerformDeviceConfigurationChange = configuration, .AbortDeviceConfigurationChange = configuration,
    .HasProperty = has_property, .IsPropertySettable = settable, .GetPropertyDataSize = property_size,
    .GetPropertyData = get_property, .SetPropertyData = set_property,
    .StartIO = start_io, .StopIO = stop_io, .GetZeroTimeStamp = zero_timestamp,
    .WillDoIOOperation = will_io, .BeginIOOperation = io_boundary, .DoIOOperation = do_io, .EndIOOperation = io_boundary
};
__attribute__((visibility("default")))
void *JHMirrorAudioFactory(CFAllocatorRef allocator, CFUUIDRef type) {
    return type && CFEqual(type, kAudioServerPlugInTypeUUID) ? driver : NULL;
}
