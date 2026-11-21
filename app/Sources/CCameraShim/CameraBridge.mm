#import "CameraBridge.h"

#include <algorithm>
#include <atomic>
#include <cstdarg>
#include <cstring>
#include <ctime>
#include <chrono>
#include <future>
#include <iterator>
#include <memory>
#include <mutex>
#include <shared_mutex>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>

#include "CameraRemote_SDK.h"
#include "CrDeviceProperty.h"
#include "CrError.h"
#include "IDeviceCallback.h"

static NSString *const kErrDomain = @"CameraBridge";

static NSError *MakeError(NSString *msg, int code = -1) {
    return [NSError errorWithDomain:kErrDomain code:code userInfo:@{NSLocalizedDescriptionKey: msg}];
}

static uint64_t NowNanos() { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

static uint64_t g_t0 = 0;
// Sony's SDK crashes if Init() is called again after Release() in the same process,
// so Init() runs once per process and Release() only at final shutdown.
static bool g_sdkReady = false;
static void WallLog(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void WallLog(const char *fmt, ...) {
    time_t t = time(nullptr); struct tm tmv; localtime_r(&t, &tmv);
    char ts[16]; strftime(ts, sizeof ts, "%H:%M:%S", &tmv);
    char body[256]; va_list ap; va_start(ap, fmt); vsnprintf(body, sizeof body, fmt, ap); va_end(ap);
    fprintf(stderr, "[%s] %s\n", ts, body);
}
#define TLOG(msg) fprintf(stderr, "[+%7.1f ms] %s\n", (NowNanos() - g_t0) / 1e6, msg)

static uint64_t Fnv1a(const unsigned char *p, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}

// Forward: SDK callbacks are routed to the Objective-C object.
@interface CameraBridge ()
- (void)sdkConnected;
- (void)sdkDisconnected:(unsigned)error;
- (void)sdkError:(unsigned)error;
- (void)sdkWarning:(unsigned)warning;
- (void)sdkDownloaded:(NSString *)path;
@end

namespace {
// The SDK hands out objects that must be released through their own Release(); own them with unique_ptr.
struct InfoRelease { void operator()(SCRSDK::ICrCameraObjectInfo *p) const { if (p) p->Release(); } };
struct EnumRelease { void operator()(SCRSDK::ICrEnumCameraObjectInfo *p) const { if (p) p->Release(); } };

class Callback : public SCRSDK::IDeviceCallback {
public:
    __weak CameraBridge *owner = nil;
    // These run on SDK threads, which have no autorelease pool of their own.
    void OnConnected(SCRSDK::DeviceConnectionVersioin) override { @autoreleasepool { WallLog("SDK OnConnected"); [owner sdkConnected]; } }
    void OnDisconnected(CrInt32u e) override { @autoreleasepool { WallLog("SDK OnDisconnected error=0x%x", e); [owner sdkDisconnected:e]; } }
    void OnError(CrInt32u e) override { @autoreleasepool { WallLog("SDK OnError 0x%x", e); [owner sdkError:e]; } }
    void OnCompleteDownload(CrChar *filename, CrInt32u) override {
        @autoreleasepool {
            // stringWithUTF8String: returns nil for a null or non-UTF-8 name; never pass that on.
            NSString *path = filename ? [NSString stringWithUTF8String:reinterpret_cast<const char *>(filename)] : nil;
            WallLog("SDK OnCompleteDownload %s", path ? path.UTF8String : "(unreadable file name)");
            if (path) [owner sdkDownloaded:path];
        }
    }
    void OnWarning(CrInt32u w) override {
        @autoreleasepool {
            WallLog("SDK OnWarning 0x%x%s", w, w == SCRSDK::CrWarning_Connect_Reconnecting ? " (Reconnecting)" : w == SCRSDK::CrWarning_Connect_Reconnected ? " (Reconnected)" : "");
            [owner sdkWarning:w];
        }
    }
    void OnWarningExt(CrInt32u w, CrInt32 a, CrInt32 b, CrInt32 c) override { WallLog("SDK OnWarningExt 0x%x %d %d %d", w, a, b, c); }
};
} // namespace

@implementation CameraBridge {
    Callback _cb;   // the SDK keeps a raw pointer to this; it outlives ReleaseDevice (see teardown)
    int64_t _dev;
    std::unique_ptr<SCRSDK::ICrEnumCameraObjectInfo, EnumRelease> _enum;
    std::unique_ptr<SCRSDK::ICrCameraObjectInfo, InfoRelease> _usbInfo;
    std::atomic<bool> _connected;
    std::atomic<bool> _stop;
    std::thread _poller;
    // Every call into the SDK holds _devLock shared; Connect, Disconnect and ReleaseDevice hold it
    // exclusive, so a device can never be released while another thread is using it.
    std::shared_mutex _devLock;
    std::mutex _mu;                              // guards _promise, _model, _transferNote
    std::shared_ptr<std::promise<void>> _promise;
    std::string _savePath, _savePrefix;          // the SDK may keep pointers to these; owned here
    int _lastLiveState;
    bool _loggedFirstFrame;
    NSString *_model;
    NSString *_transferNote;
}

- (instancetype)init {
    if ((self = [super init])) {
        _cb.owner = self;
        _dev = 0; _lastLiveState = -1; _loggedFirstFrame = false;
        _connected = false; _stop = false;
    }
    return self;
}

- (void)dealloc { [self disconnect]; }

- (NSString *)modelName { std::lock_guard<std::mutex> l(_mu); return _model; }
- (NSString *)transferNote { std::lock_guard<std::mutex> l(_mu); return _transferNote; }
- (BOOL)isConnected { return _connected; }

#pragma mark SDK callbacks

- (void)resolvePromise:(BOOL)ok {
    std::lock_guard<std::mutex> l(_mu);
    if (!_promise) return;
    if (ok) _promise->set_value();
    else _promise->set_exception(std::make_exception_ptr(std::runtime_error("sdk error")));
    _promise.reset();
}

- (void)sdkConnected {
    _connected = true;
    [self resolvePromise:YES];
    [self.delegate cameraBridge:self didChangeState:CameraBridgeStateConnected message:@"Connected"];
}

- (void)sdkDownloaded:(NSString *)path {
    [self.delegate cameraBridge:self didDownloadFile:path];
}

- (void)sdkWarning:(unsigned)warning {
    if (warning == SCRSDK::CrNotify_Captured_Event) {
        [self.delegate cameraBridgeDidCapture:self];
        return;
    }
    if (warning == SCRSDK::CrWarning_Connect_Reconnecting)
        [self.delegate cameraBridge:self didChangeState:CameraBridgeStateReconnecting message:@"Camera not responding; reconnecting…"];
    else if (warning == SCRSDK::CrWarning_Connect_Reconnected)
        [self.delegate cameraBridge:self didChangeState:CameraBridgeStateConnected message:@"Connected"];
}

- (void)sdkDisconnected:(unsigned)error {
    bool was = _connected.exchange(false);
    [self resolvePromise:YES];
    if (was && !_stop) [self.delegate cameraBridge:self didChangeState:CameraBridgeStateDisconnected message:@"Camera disconnected"];
}

- (void)sdkError:(unsigned)error {
    [self resolvePromise:NO];
    if (!_stop) [self.delegate cameraBridge:self didChangeState:CameraBridgeStateDisconnected message:[NSString stringWithFormat:@"SDK error 0x%x", error]];
}

#pragma mark Connect / disconnect

/// Arms a one-shot signal that the next OnConnected/OnDisconnected/OnError will fulfil.
- (std::future<void>)armSignal {
    auto p = std::make_shared<std::promise<void>>();
    std::future<void> f = p->get_future();
    std::lock_guard<std::mutex> l(_mu);
    _promise = std::move(p);
    return f;
}

- (void)disarmSignal {
    std::lock_guard<std::mutex> l(_mu);
    _promise.reset();
}

- (BOOL)connectWithError:(NSError **)outError {
    g_t0 = NowNanos();
    if (_dev) { if (outError) *outError = MakeError(@"already connected"); return NO; }
    if (!g_sdkReady) {
        if (!SCRSDK::Init()) { if (outError) *outError = MakeError(@"SDK Init failed"); return NO; }
        g_sdkReady = true;
    }
    TLOG("Init done");

    SCRSDK::CrError err = 0;
    SCRSDK::ICrCameraObjectInfo *info = nullptr;   // not owned: points into _enum or _usbInfo
    const char *serial = getenv("CAM_SERIAL");  // experiment: skip slow enumeration (USB only)
    if (serial && *serial) {
        std::string serialCopy(serial);             // the SDK wants a mutable buffer
        SCRSDK::ICrCameraObjectInfo *raw = nullptr;
        err = SCRSDK::CreateCameraObjectInfoUSBConnection(&raw, SCRSDK::CrCameraDeviceModel_ILCE_7RM5,
                                                          reinterpret_cast<CrInt8u *>(serialCopy.data()));
        _usbInfo.reset(raw);
        TLOG("CreateCameraObjectInfoUSBConnection returned");
        if (err || !_usbInfo) {
            if (outError) *outError = MakeError([NSString stringWithFormat:@"USB camera object failed (0x%x)", err]);
            [self teardown];
            return NO;
        }
        info = _usbInfo.get();
        std::lock_guard<std::mutex> l(_mu);
        _model = @"ILCE-7RM5";
    } else {
        SCRSDK::ICrEnumCameraObjectInfo *raw = nullptr;
        err = SCRSDK::EnumCameraObjects(&raw, 3);
        _enum.reset(raw);
        TLOG("EnumCameraObjects returned");
        if (err || !_enum || _enum->GetCount() < 1) {
            if (outError) *outError = MakeError([NSString stringWithFormat:@"No camera found (0x%x). Is it on, in PC Remote mode, and not held by another app?", err]);
            [self teardown];
            return NO;
        }
        // Connect() takes a non-const pointer; the object is still owned by _enum.
        info = const_cast<SCRSDK::ICrCameraObjectInfo *>(_enum->GetCameraObjectInfo(0));
        NSString *model = [NSString stringWithUTF8String:reinterpret_cast<const char *>(info->GetModel())];
        { std::lock_guard<std::mutex> l(_mu); _model = model; }
        fprintf(stderr, "camera id (usable as CAM_SERIAL): %.*s\n", (int)info->GetIdSize(), reinterpret_cast<const char *>(info->GetId()));
    }

    std::future<void> f = [self armSignal];

    TLOG("calling Connect");
    {
        std::unique_lock<std::shared_mutex> lock(_devLock);
        err = SCRSDK::Connect(info, &_cb, &_dev, SCRSDK::CrSdkControlMode_Remote, SCRSDK::CrReconnecting_ON);
    }
    if (err) {
        [self disarmSignal];
        if (outError) *outError = MakeError([NSString stringWithFormat:@"Connect failed (0x%x)", err]);
        [self teardown];
        return NO;
    }
    if (f.wait_for(std::chrono::seconds(10)) != std::future_status::ready) {
        [self disarmSignal];
        if (outError) *outError = MakeError(@"Connection timed out. Quit other apps that use the camera (e.g. Adobe Bridge) and retry.");
        // The connection may still complete after we give up; close it so the camera is not left holding a session.
        [self closeSession];
        [self teardown];
        return NO;
    }
    TLOG("OnConnected received");
    try { f.get(); } catch (...) {
        if (outError) *outError = MakeError(@"Camera refused the connection (is another app or session holding it?)");
        [self closeSession];
        [self teardown];
        return NO;
    }

    std::this_thread::sleep_for(std::chrono::seconds(1)); // the SDK sample waits 1s after connect

    [self ensurePCTransfer];
    TLOG("settle done, starting poller");
    _stop = false;
    _lastLiveState = -1;
    _loggedFirstFrame = false;
    __weak CameraBridge *weakSelf = self;
    _poller = std::thread([weakSelf] { [weakSelf pollLoop]; });
    return YES;
}

- (void)pollLoop {
    SCRSDK::CrImageInfo ii;
    SCRSDK::CrError infoErr;
    { std::shared_lock<std::shared_mutex> lock(_devLock); infoErr = _dev ? SCRSDK::GetLiveViewImageInfo(_dev, &ii) : SCRSDK::CrError_Generic_Unknown; }
    if (infoErr) {
        [self.delegate cameraBridge:self didChangeState:CameraBridgeStateDisconnected message:@"GetLiveViewImageInfo failed"];
        return;
    }
    std::vector<CrInt8u> buf(ii.GetBufferSize());
    uint64_t lastHash = 0;
    while (!_stop) {
        SCRSDK::CrImageDataBlock blk;
        blk.SetData(buf.data());
        blk.SetSize((CrInt32u)buf.size());
        SCRSDK::CrError e;
        {
            std::shared_lock<std::shared_mutex> lock(_devLock);
            if (!_dev) break;
            e = SCRSDK::GetLiveViewImage(_dev, &blk);
        }
        uint64_t t = NowNanos();
        int state = (e || blk.GetImageSize() == 0) ? (int)e + 1 : 0;  // 0 ok, else error code + 1
        if (state != _lastLiveState) { WallLog("live view %s (err=0x%x)", state == 0 ? "OK" : "FAILING", (unsigned)e); _lastLiveState = state; }
        if (!e && blk.GetImageSize() > 0) {
            uint64_t h = Fnv1a((const unsigned char *)blk.GetImageData(), blk.GetImageSize());
            if (!_loggedFirstFrame) { _loggedFirstFrame = true; TLOG("first live-view frame fetched"); }
            if (h != lastHash) {  // the SDK returns its cached frame until a new one arrives
                lastHash = h;
                @autoreleasepool {
                    NSData *d = [NSData dataWithBytes:blk.GetImageData() length:blk.GetImageSize()];
                    [self.delegate cameraBridge:self didReceiveFrame:d arrivalNanos:t];
                }
            }
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(3));
    }
}

#pragma mark Shooting

// getProperty/setProperty do not lock: callers hold _devLock (shared).
- (BOOL)getProperty:(CrInt32u)code into:(SCRSDK::CrDeviceProperty &)out {
    CrInt32u c = code;
    CrInt32 n = 0;
    SCRSDK::CrDeviceProperty *list = nullptr;
    SCRSDK::CrError err = SCRSDK::GetSelectDeviceProperties(_dev, 1, &c, &list, &n);
    BOOL ok = !err && list && n >= 1;
    if (ok) out = list[0];
    if (list) SCRSDK::ReleaseDeviceProperties(_dev, list);
    return ok;
}

- (SCRSDK::CrError)setProperty:(CrInt32u)code value:(uint64_t)value {
    SCRSDK::CrDeviceProperty p;
    if (![self getProperty:code into:p]) return SCRSDK::CrError_Generic_Unknown;
    p.SetCurrentValue(value);
    return SCRSDK::SetDeviceProperty(_dev, &p);
}

/// Photos only reach the Mac if the camera's save destination includes the host PC.
- (void)ensurePCTransfer {
    { std::lock_guard<std::mutex> l(_mu); _transferNote = nil; }
    std::shared_lock<std::shared_mutex> lock(_devLock);
    SCRSDK::CrDeviceProperty p;
    if (![self getProperty:SCRSDK::CrDeviceProperty_StillImageStoreDestination into:p]) return;
    uint64_t cur = p.GetCurrentValue();
    WallLog("StillImageStoreDestination = 0x%llx", (unsigned long long)cur);
    if (cur == SCRSDK::CrStillImageStoreDestination_MemoryCard) {
        SCRSDK::CrError e = [self setProperty:SCRSDK::CrDeviceProperty_StillImageStoreDestination
                                        value:SCRSDK::CrStillImageStoreDestination_HostPCAndMemoryCard];
        NSString *note = e ? [NSString stringWithFormat:@"Camera saves to the card only and could not be switched (0x%x); photos will not reach this Mac.", e]
                          : @"Camera was saving to the card only; switched it to Mac and card.";
        { std::lock_guard<std::mutex> l(_mu); _transferNote = note; }
        WallLog("%s", note.UTF8String);
    }
}

- (BOOL)setSaveFolder:(NSString *)path error:(NSError **)outError {
    const char *utf8 = path.UTF8String;
    if (!utf8) { if (outError) *outError = MakeError(@"The save folder path is not valid text."); return NO; }
    std::unique_lock<std::shared_mutex> lock(_devLock);   // exclusive: it rewrites buffers the SDK may read
    if (!_dev) { if (outError) *outError = MakeError(@"not connected"); return NO; }
    _savePath = utf8;                  // mutable copies owned by the bridge
    _savePrefix = "SHOT";
    SCRSDK::CrError e = SCRSDK::SetSaveInfo(_dev, reinterpret_cast<CrChar *>(_savePath.data()),
                                            reinterpret_cast<CrChar *>(_savePrefix.data()), -1);
    if (e) { if (outError) *outError = MakeError([NSString stringWithFormat:@"SetSaveInfo failed (0x%x)", e]); return NO; }
    return YES;
}

- (BOOL)setHalfPress:(BOOL)pressed error:(NSError **)outError {
    std::shared_lock<std::shared_mutex> lock(_devLock);
    if (!_dev || !_connected) { if (outError) *outError = MakeError(@"Camera not connected"); return NO; }
    SCRSDK::CrError e = [self setProperty:SCRSDK::CrDeviceProperty_S1
                                    value:pressed ? SCRSDK::CrLockIndicator_Locked : SCRSDK::CrLockIndicator_Unlocked];
    if (e) { if (outError) *outError = MakeError([NSString stringWithFormat:@"Half-press failed (0x%x)", e]); return NO; }
    return YES;
}

- (NSArray<NSNumber *> *)magnifierRatios {
    NSMutableArray<NSNumber *> *out = [NSMutableArray array];
    std::shared_lock<std::shared_mutex> lock(_devLock);
    if (!_dev || !_connected) return out;
    SCRSDK::CrDeviceProperty p;
    if (![self getProperty:SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting into:p]) return out;
    size_t width = 8;
    switch (p.GetValueType() & 0x00FF) {
        case 0x01: case 0x11: width = 1; break;
        case 0x02: case 0x12: width = 2; break;
        case 0x03: case 0x13: width = 4; break;
        default: width = 8; break;
    }
    const CrInt8u *data = p.GetSetValues();   // owned by p, valid while p lives
    CrInt32u bytes = p.GetSetValueSize();
    for (size_t i = 0; data && i + width <= bytes; i += width) {
        uint64_t v = 0;
        memcpy(&v, data + i, width);
        uint32_t ratio = (uint32_t)(v >> 32);
        if (ratio > 10 && ![out containsObject:@(ratio)]) [out addObject:@(ratio)];
    }
    [out sortUsingSelector:@selector(compare:)];
    return out;
}

const unsigned CameraBridgePropFNumber = SCRSDK::CrDeviceProperty_FNumber;
const unsigned CameraBridgePropShutterSpeed = SCRSDK::CrDeviceProperty_ShutterSpeed;
const unsigned CameraBridgePropISO = SCRSDK::CrDeviceProperty_IsoSensitivity;
const unsigned CameraBridgePropExposureBias = SCRSDK::CrDeviceProperty_ExposureBiasCompensation;
const unsigned CameraBridgePropMeteredManual = SCRSDK::CrDeviceProperty_MeteredManualLevel;
const unsigned CameraBridgePropExposureProgram = SCRSDK::CrDeviceProperty_ExposureProgramMode;

- (NSDictionary<NSNumber *, NSNumber *> *)readExposure {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    std::shared_lock<std::shared_mutex> lock(_devLock);
    if (!_dev || !_connected) return out;
    CrInt32u codes[] = { CameraBridgePropFNumber, CameraBridgePropShutterSpeed, CameraBridgePropISO,
                         CameraBridgePropExposureBias, CameraBridgePropMeteredManual, CameraBridgePropExposureProgram };
    CrInt32 n = 0;
    SCRSDK::CrDeviceProperty *list = nullptr;
    SCRSDK::CrError err = SCRSDK::GetSelectDeviceProperties(_dev, static_cast<CrInt32>(std::size(codes)), codes, &list, &n);
    if (!err && list) {
        for (CrInt32 i = 0; i < n; i++) out[@(list[i].GetCode())] = @(list[i].GetCurrentValue());
    }
    if (list) SCRSDK::ReleaseDeviceProperties(_dev, list);
    return out;
}

- (int)currentMagnifierRatio {
    std::shared_lock<std::shared_mutex> lock(_devLock);
    if (!_dev || !_connected) return -1;
    SCRSDK::CrDeviceProperty p;
    if (![self getProperty:SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting into:p]) return -1;
    uint32_t r = (uint32_t)(p.GetCurrentValue() >> 32);
    return r <= 10 ? 0 : (int)r;
}

- (BOOL)setMagnifierRatio:(uint32_t)ratio x:(int)x y:(int)y error:(NSError **)outError {
    std::shared_lock<std::shared_mutex> lock(_devLock);
    if (!_dev || !_connected) { if (outError) *outError = MakeError(@"Camera not connected"); return NO; }
    x = std::max(0, std::min(639, x));
    y = std::max(0, std::min(479, y));
    uint64_t v = ((uint64_t)ratio << 32) | ((uint64_t)x << 16) | (uint64_t)y;
    SCRSDK::CrError e = [self setProperty:SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting value:v];
    if (e) { if (outError) *outError = MakeError([NSString stringWithFormat:@"Magnifier command failed (0x%x)", e]); return NO; }
    return YES;
}

- (BOOL)fullPressWithError:(NSError **)outError {
    std::shared_lock<std::shared_mutex> lock(_devLock);
    if (!_dev || !_connected) { if (outError) *outError = MakeError(@"Camera not connected"); return NO; }
    SCRSDK::CrError e = SCRSDK::SendCommand(_dev, SCRSDK::CrCommandId_Release, SCRSDK::CrCommandParam_Down);
    std::this_thread::sleep_for(std::chrono::milliseconds(100));
    SCRSDK::CrError e2 = SCRSDK::SendCommand(_dev, SCRSDK::CrCommandId_Release, SCRSDK::CrCommandParam_Up);
    if (e || e2) { if (outError) *outError = MakeError([NSString stringWithFormat:@"Shutter command failed (0x%x)", e ? e : e2]); return NO; }
    return YES;
}

/// Asks the camera to end the session and waits briefly for it to confirm.
- (void)closeSession {
    if (!_dev) return;
    std::future<void> f = [self armSignal];
    {
        std::unique_lock<std::shared_mutex> lock(_devLock);
        SCRSDK::Disconnect(_dev);
    }
    f.wait_for(std::chrono::seconds(3));
    [self disarmSignal];
}

/// Releases everything the SDK gave us. The callback object `_cb` is a member, so it is still alive for
/// any late callback until the object itself is destroyed, which happens after this.
- (void)teardown {
    std::unique_lock<std::shared_mutex> lock(_devLock);
    _enum.reset();
    _usbInfo.reset();
    if (_dev) { SCRSDK::ReleaseDevice(_dev); _dev = 0; }
}

- (void)releaseSDK {
    if (g_sdkReady) { SCRSDK::Release(); g_sdkReady = false; }
}

- (void)disconnect {
    _stop = true;
    if (_poller.joinable()) _poller.join();
    if (_connected) [self closeSession];
    [self teardown];
}

@end
