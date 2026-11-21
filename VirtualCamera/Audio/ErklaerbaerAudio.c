// The microphone "Erklärbär": an Audio Server plug-in (HAL driver) with two devices that share one
// ring buffer. Erklärbär plays its mix (microphone, sound of the Mac) into the hidden device
// "Erklärbär Zuspielung"; meeting programs record it from the input device "Erklärbär".
//
// Installed to /Library/Audio/Plug-Ins/HAL/ErklaerbaerAudio.driver by the app (needs the
// administrator password once). Written from Apple's AudioServerPlugIn.h; 48 kHz, stereo, Float32.

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <string.h>

// MARK: - Objects and format

enum {
    kObjectPlugIn = kAudioObjectPlugInObject,
    kObjectMic = 2,          // visible input device "Erklärbär"
    kObjectMicStream = 3,
    kObjectFeed = 4,         // hidden output device the app plays into
    kObjectFeedStream = 5,
};

#define kSampleRate 48000.0
#define kChannels 2
#define kBytesPerFrame (kChannels * sizeof(Float32))
#define kRingFrames 16384           // also the zero time stamp period (~0.34 s)
#define kMicUID "ErklaerbaerMikrofon"
#define kFeedUID "ErklaerbaerZuspielung"
#define kManufacturer "Lernsachen.blog"

static AudioServerPlugInHostRef gHost = NULL;
static UInt32 gRefCount = 0;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;

// Clock, shared by both devices so that written and read sample times line up (under gLock).
static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gTimeStampCount = 0;
static UInt32 gRunning[6] = {0};     // IO clients per device object id

// Ring buffer (under gLock). gWriteEnd: sample time after the last written frame.
static Float32 gRing[kRingFrames * kChannels];
static Float64 gWriteEnd = 0;

static AudioStreamBasicDescription Format(void) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static Boolean IsDevice(AudioObjectID id) { return id == kObjectMic || id == kObjectFeed; }
static Boolean IsStream(AudioObjectID id) { return id == kObjectMicStream || id == kObjectFeedStream; }
static AudioObjectID StreamOf(AudioObjectID device) { return device == kObjectMic ? kObjectMicStream : kObjectFeedStream; }
static AudioObjectID DeviceOf(AudioObjectID stream) { return stream == kObjectMicStream ? kObjectMic : kObjectFeed; }
/// The scope in which a device has its stream.
static AudioObjectPropertyScope ScopeOf(AudioObjectID device) {
    return device == kObjectMic ? kAudioObjectPropertyScopeInput : kAudioObjectPropertyScopeOutput;
}

// MARK: - IUnknown

static HRESULT QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG AddRef(void* inDriver);
static ULONG Release(void* inDriver);
static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL, QueryInterface, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddDeviceClient, RemoveDeviceClient,
    PerformDeviceConfigurationChange, AbortDeviceConfigurationChange, HasProperty, IsPropertySettable, GetPropertyDataSize,
    GetPropertyData, SetPropertyData, StartIO, StopIO, GetZeroTimeStamp, WillDoIOOperation, BeginIOOperation, DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

/// The CFPlugIn factory named in Info.plist.
__attribute__((visibility("default"))) void* ErklaerbaerAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
__attribute__((visibility("default"))) void* ErklaerbaerAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) { return gDriverRef; }
    return NULL;
}

static HRESULT QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) { return kAudioHardwareBadObjectError; }
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        os_unfair_lock_lock(&gLock);
        ++gRefCount;
        os_unfair_lock_unlock(&gLock);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void* inDriver) {
    if (inDriver != gDriverRef) { return 0; }
    os_unfair_lock_lock(&gLock);
    ULONG count = ++gRefCount;
    os_unfair_lock_unlock(&gLock);
    return count;
}

static ULONG Release(void* inDriver) {
    if (inDriver != gDriverRef) { return 0; }
    os_unfair_lock_lock(&gLock);
    if (gRefCount > 0) { --gRefCount; }
    ULONG count = gRefCount;
    os_unfair_lock_unlock(&gLock);
    return count;
}

// MARK: - Basic operations

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) { return kAudioHardwareBadObjectError; }
    gHost = inHost;
    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    return 0;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* c, AudioObjectID* out) {
    (void)d; (void)desc; (void)c; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)c;
    return d == gDriverRef && IsDevice(id) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef d, AudioObjectID id, const AudioServerPlugInClientInfo* c) {
    (void)c;
    return d == gDriverRef && IsDevice(id) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)a; (void)i;
    return d == gDriverRef && IsDevice(id) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)a; (void)i;
    return d == gDriverRef && IsDevice(id) ? 0 : kAudioHardwareBadObjectError;
}

// MARK: - Properties

static Boolean HasProperty(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a) {
    UInt32 size = 0;
    return GetPropertyDataSize(d, id, pid, a, 0, NULL, &size) == 0;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a, Boolean* outIsSettable) {
    if (d != gDriverRef || outIsSettable == NULL) { return kAudioHardwareBadObjectError; }
    if (!HasProperty(d, id, pid, a)) { return kAudioHardwareUnknownPropertyError; }
    switch (a->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyIsActive:
            *outIsSettable = true;
            break;
        default:
            *outIsSettable = false;
    }
    return 0;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                    UInt32 qualifierSize, const void* qualifier, UInt32* outDataSize) {
    (void)pid; (void)qualifierSize; (void)qualifier;
    if (d != gDriverRef || a == NULL || outDataSize == NULL) { return kAudioHardwareBadObjectError; }
    UInt32 size = 0;
    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
            size = sizeof(AudioClassID);
            break;
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyName:
            size = sizeof(CFStringRef);
            break;
        default:
            break;
    }
    if (size == 0 && id == kObjectPlugIn) {
        switch (a->mSelector) {
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: size = 2 * sizeof(AudioObjectID); break;
            case kAudioPlugInPropertyTranslateUIDToDevice: size = sizeof(AudioObjectID); break;
            case kAudioPlugInPropertyResourceBundle: size = sizeof(CFStringRef); break;
            default: return kAudioHardwareUnknownPropertyError;
        }
    } else if (size == 0 && IsDevice(id)) {
        Boolean ownScope = a->mScope == kAudioObjectPropertyScopeGlobal || a->mScope == ScopeOf(id);
        switch (a->mSelector) {
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID: size = sizeof(CFStringRef); break;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod: size = sizeof(UInt32); break;
            case kAudioDevicePropertyRelatedDevices: size = sizeof(AudioObjectID); break;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams: size = ownScope ? sizeof(AudioObjectID) : 0; break;
            case kAudioObjectPropertyControlList: size = 0; break;
            case kAudioDevicePropertyNominalSampleRate: size = sizeof(Float64); break;
            case kAudioDevicePropertyAvailableNominalSampleRates: size = sizeof(AudioValueRange); break;
            case kAudioDevicePropertyPreferredChannelsForStereo: size = 2 * sizeof(UInt32); break;
            default: return kAudioHardwareUnknownPropertyError;
        }
    } else if (size == 0 && IsStream(id)) {
        switch (a->mSelector) {
            case kAudioObjectPropertyOwnedObjects: size = 0; break;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency: size = sizeof(UInt32); break;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat: size = sizeof(AudioStreamBasicDescription); break;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: size = sizeof(AudioStreamRangedDescription); break;
            default: return kAudioHardwareUnknownPropertyError;
        }
    } else if (size == 0) {
        return kAudioHardwareBadObjectError;
    }
    *outDataSize = size;
    return 0;
}

#define NEED(type) do { if (inDataSize < sizeof(type)) { return kAudioHardwareBadPropertySizeError; } } while (0)

static OSStatus GetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qualifierSize, const void* qualifier, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)pid;
    if (d != gDriverRef || a == NULL || outDataSize == NULL || outData == NULL) { return kAudioHardwareBadObjectError; }
    UInt32 expected = 0;
    OSStatus known = GetPropertyDataSize(d, id, pid, a, qualifierSize, qualifier, &expected);
    if (known != 0) { return known; }
    if (inDataSize < expected) { return kAudioHardwareBadPropertySizeError; }
    *outDataSize = expected;

    switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
            *(AudioClassID*)outData = kAudioObjectClassID;
            return 0;
        case kAudioObjectPropertyClass:
            *(AudioClassID*)outData = id == kObjectPlugIn ? kAudioPlugInClassID : (IsDevice(id) ? kAudioDeviceClassID : kAudioStreamClassID);
            return 0;
        case kAudioObjectPropertyOwner:
            *(AudioObjectID*)outData = id == kObjectPlugIn ? kAudioObjectUnknown : (IsDevice(id) ? kObjectPlugIn : DeviceOf(id));
            return 0;
        case kAudioObjectPropertyManufacturer:
            *(CFStringRef*)outData = CFSTR(kManufacturer);
            return 0;
        case kAudioObjectPropertyName:
            if (id == kObjectPlugIn) { *(CFStringRef*)outData = CFSTR("Erklärbär"); }
            else if (id == kObjectMic || id == kObjectMicStream) { *(CFStringRef*)outData = CFSTR("Erklärbär"); }
            else { *(CFStringRef*)outData = CFSTR("Erklärbär Zuspielung"); }
            return 0;
        default:
            break;
    }

    if (id == kObjectPlugIn) {
        switch (a->mSelector) {
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList: {
                AudioObjectID* list = (AudioObjectID*)outData;
                list[0] = kObjectMic;
                list[1] = kObjectFeed;
                return 0;
            }
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                AudioObjectID found = kAudioObjectUnknown;
                if (qualifierSize == sizeof(CFStringRef) && qualifier != NULL) {
                    CFStringRef uid = *(const CFStringRef*)qualifier;
                    if (uid != NULL && CFStringCompare(uid, CFSTR(kMicUID), 0) == kCFCompareEqualTo) { found = kObjectMic; }
                    if (uid != NULL && CFStringCompare(uid, CFSTR(kFeedUID), 0) == kCFCompareEqualTo) { found = kObjectFeed; }
                }
                *(AudioObjectID*)outData = found;
                return 0;
            }
            case kAudioPlugInPropertyResourceBundle:
                *(CFStringRef*)outData = CFSTR("");
                return 0;
        }
    } else if (IsDevice(id)) {
        Boolean mic = id == kObjectMic;
        switch (a->mSelector) {
            case kAudioDevicePropertyDeviceUID:
                *(CFStringRef*)outData = mic ? CFSTR(kMicUID) : CFSTR(kFeedUID);
                return 0;
            case kAudioDevicePropertyModelUID:
                *(CFStringRef*)outData = mic ? CFSTR("ErklaerbaerMikrofonModell") : CFSTR("ErklaerbaerZuspielungModell");
                return 0;
            case kAudioDevicePropertyTransportType: *(UInt32*)outData = kAudioDeviceTransportTypeVirtual; return 0;
            case kAudioDevicePropertyClockDomain: *(UInt32*)outData = 0; return 0;
            case kAudioDevicePropertyDeviceIsAlive: *(UInt32*)outData = 1; return 0;
            case kAudioDevicePropertyDeviceIsRunning:
                os_unfair_lock_lock(&gLock);
                *(UInt32*)outData = gRunning[id] > 0 ? 1 : 0;
                os_unfair_lock_unlock(&gLock);
                return 0;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
                // The microphone may be chosen as the Mac's input; the hidden feed never as its output.
                *(UInt32*)outData = mic && a->mScope != kAudioObjectPropertyScopeOutput ? 1 : 0;
                return 0;
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: *(UInt32*)outData = 0; return 0;
            case kAudioDevicePropertyLatency: *(UInt32*)outData = 0; return 0;
            case kAudioDevicePropertySafetyOffset: *(UInt32*)outData = 0; return 0;
            case kAudioDevicePropertyIsHidden: *(UInt32*)outData = mic ? 0 : 1; return 0;
            case kAudioDevicePropertyZeroTimeStampPeriod: *(UInt32*)outData = kRingFrames; return 0;
            case kAudioDevicePropertyRelatedDevices: *(AudioObjectID*)outData = id; return 0;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyStreams:
                if (expected > 0) { *(AudioObjectID*)outData = StreamOf(id); }
                return 0;
            case kAudioObjectPropertyControlList: return 0;
            case kAudioDevicePropertyNominalSampleRate: *(Float64*)outData = kSampleRate; return 0;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange* range = (AudioValueRange*)outData;
                range->mMinimum = kSampleRate;
                range->mMaximum = kSampleRate;
                return 0;
            }
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32* channels = (UInt32*)outData;
                channels[0] = 1;
                channels[1] = 2;
                return 0;
            }
        }
    } else if (IsStream(id)) {
        Boolean input = id == kObjectMicStream;
        switch (a->mSelector) {
            case kAudioObjectPropertyOwnedObjects: return 0;
            case kAudioStreamPropertyIsActive: *(UInt32*)outData = 1; return 0;
            case kAudioStreamPropertyDirection: *(UInt32*)outData = input ? 1 : 0; return 0;
            case kAudioStreamPropertyTerminalType:
                *(UInt32*)outData = input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker;
                return 0;
            case kAudioStreamPropertyStartingChannel: *(UInt32*)outData = 1; return 0;
            case kAudioStreamPropertyLatency: *(UInt32*)outData = 0; return 0;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *(AudioStreamBasicDescription*)outData = Format();
                return 0;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription* ranged = (AudioStreamRangedDescription*)outData;
                ranged->mFormat = Format();
                ranged->mSampleRateRange.mMinimum = kSampleRate;
                ranged->mSampleRateRange.mMaximum = kSampleRate;
                return 0;
            }
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef d, AudioObjectID id, pid_t pid, const AudioObjectPropertyAddress* a,
                                UInt32 qualifierSize, const void* qualifier, UInt32 inDataSize, const void* inData) {
    (void)pid; (void)qualifierSize; (void)qualifier;
    if (d != gDriverRef || a == NULL || inData == NULL) { return kAudioHardwareBadObjectError; }
    switch (a->mSelector) {
        case kAudioDevicePropertyNominalSampleRate:
            if (!IsDevice(id)) { return kAudioHardwareUnknownPropertyError; }
            NEED(Float64);
            return *(const Float64*)inData == kSampleRate ? 0 : kAudioDeviceUnsupportedFormatError;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            if (!IsStream(id)) { return kAudioHardwareUnknownPropertyError; }
            NEED(AudioStreamBasicDescription);
            const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
            AudioStreamBasicDescription own = Format();
            return f->mSampleRate == own.mSampleRate && f->mFormatID == own.mFormatID && f->mChannelsPerFrame == own.mChannelsPerFrame
                && f->mBitsPerChannel == own.mBitsPerChannel ? 0 : kAudioDeviceUnsupportedFormatError;
        }
        case kAudioStreamPropertyIsActive:
            return IsStream(id) ? 0 : kAudioHardwareUnknownPropertyError;
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

// MARK: - IO

static OSStatus StartIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || !IsDevice(id)) { return kAudioHardwareBadObjectError; }
    os_unfair_lock_lock(&gLock);
    if (gRunning[kObjectMic] + gRunning[kObjectFeed] == 0) {
        // Nothing ran: the clock starts again at sample time 0, so the old ring content is worthless.
        gAnchorHostTime = mach_absolute_time();
        gTimeStampCount = 0;
        gWriteEnd = 0;
        memset(gRing, 0, sizeof(gRing));
    }
    gRunning[id] += 1;
    os_unfair_lock_unlock(&gLock);
    return 0;
}

static OSStatus StopIO(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client) {
    (void)client;
    if (d != gDriverRef || !IsDevice(id)) { return kAudioHardwareBadObjectError; }
    os_unfair_lock_lock(&gLock);
    if (gRunning[id] > 0) { gRunning[id] -= 1; }
    os_unfair_lock_unlock(&gLock);
    return 0;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)client;
    if (d != gDriverRef || !IsDevice(id)) { return kAudioHardwareBadObjectError; }
    os_unfair_lock_lock(&gLock);
    Float64 ticksPerRing = gHostTicksPerFrame * kRingFrames;
    UInt64 now = mach_absolute_time();
    // One step per pass through the ring, the same for both devices.
    while (gAnchorHostTime + (UInt64)((Float64)(gTimeStampCount + 1) * ticksPerRing) <= now) { ++gTimeStampCount; }
    *outSampleTime = (Float64)(gTimeStampCount * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gTimeStampCount * ticksPerRing);
    *outSeed = 1;
    os_unfair_lock_unlock(&gLock);
    return 0;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 client, UInt32 operation, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)client;
    if (d != gDriverRef || !IsDevice(id)) { return kAudioHardwareBadObjectError; }
    Boolean will = (id == kObjectMic && operation == kAudioServerPlugInIOOperationReadInput)
                || (id == kObjectFeed && operation == kAudioServerPlugInIOOperationWriteMix);
    if (outWillDo) { *outWillDo = will; }
    if (outWillDoInPlace) { *outWillDoInPlace = true; }
    return 0;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 o, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)c; (void)o; (void)n; (void)i;
    return d == gDriverRef && IsDevice(id) ? 0 : kAudioHardwareBadObjectError;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 o, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)c; (void)o; (void)n; (void)i;
    return d == gDriverRef && IsDevice(id) ? 0 : kAudioHardwareBadObjectError;
}

/// Frames are kept by their sample time; a frame is valid when it was written and not yet overwritten.
static OSStatus DoIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, AudioObjectID stream, UInt32 client, UInt32 operation,
                              UInt32 frames, const AudioServerPlugInIOCycleInfo* cycle, void* main, void* secondary) {
    (void)client; (void)secondary;
    if (d != gDriverRef || !IsDevice(id) || !IsStream(stream) || cycle == NULL) { return kAudioHardwareBadObjectError; }
    if (main == NULL || frames == 0) { return 0; }
    Float32* buffer = (Float32*)main;

    if (id == kObjectFeed && operation == kAudioServerPlugInIOOperationWriteMix) {
        Float64 start = cycle->mOutputTime.mSampleTime;
        os_unfair_lock_lock(&gLock);
        // A gap since the last write (the app paused): clear it, otherwise old sound would come back.
        if (start > gWriteEnd) {
            Float64 gap = start - gWriteEnd;
            UInt64 clear = gap > kRingFrames ? kRingFrames : (UInt64)gap;
            UInt64 from = gap > kRingFrames ? (UInt64)start : (UInt64)gWriteEnd;
            for (UInt64 f = 0; f < clear; ++f) {
                UInt64 slot = (from + f) % kRingFrames;
                for (UInt32 ch = 0; ch < kChannels; ++ch) { gRing[slot * kChannels + ch] = 0; }
            }
        }
        for (UInt32 f = 0; f < frames; ++f) {
            UInt64 slot = ((UInt64)start + f) % kRingFrames;
            for (UInt32 ch = 0; ch < kChannels; ++ch) { gRing[slot * kChannels + ch] = buffer[f * kChannels + ch]; }
        }
        if (start + frames > gWriteEnd) { gWriteEnd = start + frames; }
        os_unfair_lock_unlock(&gLock);
    } else if (id == kObjectMic && operation == kAudioServerPlugInIOOperationReadInput) {
        Float64 start = cycle->mInputTime.mSampleTime;
        os_unfair_lock_lock(&gLock);
        for (UInt32 f = 0; f < frames; ++f) {
            Float64 time = start + f;
            Boolean valid = time >= 0 && time < gWriteEnd && gWriteEnd - time < kRingFrames;
            UInt64 slot = valid ? ((UInt64)time % kRingFrames) : 0;
            for (UInt32 ch = 0; ch < kChannels; ++ch) { buffer[f * kChannels + ch] = valid ? gRing[slot * kChannels + ch] : 0; }
        }
        os_unfair_lock_unlock(&gLock);
    }
    return 0;
}
