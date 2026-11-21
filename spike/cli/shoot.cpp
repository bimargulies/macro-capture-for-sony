// One-shot capture test: connect, make sure still images are transferred to this Mac,
// fire the shutter once (S2 down/up, no autofocus), wait for OnCompleteDownload, restore
// the camera's original settings, and disconnect cleanly.
//
// usage: shoot <outdir> [timeout_seconds=60] [mode: s2 | s1s2 | s1andrelease]
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

#include "CameraRemote_SDK.h"
#include "CrDeviceProperty.h"
#include "IDeviceCallback.h"
#include "CrDebugString.h"

namespace {
std::mutex g_mu;
std::promise<void>* g_promise = nullptr;
std::atomic<bool> g_connected{false};
std::vector<std::string> g_downloads;
std::atomic<bool> g_captured{false};
std::chrono::steady_clock::time_point g_t0;

double ms() { return std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - g_t0).count(); }
void setPromise(std::promise<void>* p) { std::lock_guard<std::mutex> l(g_mu); g_promise = p; }
void fulfil() { std::lock_guard<std::mutex> l(g_mu); if (g_promise) { g_promise->set_value(); g_promise = nullptr; } }

class Callback : public SCRSDK::IDeviceCallback {
public:
    void OnConnected(SCRSDK::DeviceConnectionVersioin) override { g_connected = true; fulfil(); }
    void OnDisconnected(CrInt32u) override { g_connected = false; fulfil(); }
    void OnError(CrInt32u e) override { printf("[%8.1f] OnError %s\n", ms(), CrErrorString(e).c_str()); fulfil(); }
    void OnWarning(CrInt32u w) override {
        printf("[%8.1f] OnWarning 0x%x %s\n", ms(), w, CrErrorString(w).c_str());
        if (w == SCRSDK::CrNotify_Captured_Event) g_captured = true;
    }
    void OnWarningExt(CrInt32u w, CrInt32 a, CrInt32 b, CrInt32 c) override { printf("[%8.1f] OnWarningExt 0x%x %d %d %d\n", ms(), w, a, b, c); }
    void OnCompleteDownload(CrChar* filename, CrInt32u type) override {
        printf("[%8.1f] OnCompleteDownload %s (type %u)\n", ms(), filename, type);
        std::lock_guard<std::mutex> l(g_mu); g_downloads.push_back(filename);
    }
    void OnPropertyChangedCodes(CrInt32u num, CrInt32u* codes) override {
        printf("[%8.1f] OnPropertyChangedCodes:", ms());
        for (CrInt32u i = 0; i < num && i < 12; i++) printf(" 0x%x", codes[i]);
        printf("%s\n", num > 12 ? " ..." : "");
    }
    void OnNotifyContentsTransfer(CrInt32u n, SCRSDK::CrContentHandle, CrChar*) override { printf("[%8.1f] OnNotifyContentsTransfer %u\n", ms(), n); }
};

bool getProp(int64_t dev, CrInt32u code, SCRSDK::CrDeviceProperty& out) {
    CrInt32 n = 0; SCRSDK::CrDeviceProperty* list = nullptr;
    auto err = SCRSDK::GetSelectDeviceProperties(dev, 1, &code, &list, &n);
    bool ok = !err && list && n >= 1;
    if (ok) out = list[0];
    if (list) SCRSDK::ReleaseDeviceProperties(dev, list);
    return ok;
}
bool setProp(int64_t dev, CrInt32u code, uint64_t value) {
    SCRSDK::CrDeviceProperty p;
    if (!getProp(dev, code, p)) return false;
    p.SetCurrentValue(value);
    auto err = SCRSDK::SetDeviceProperty(dev, &p);
    if (err) printf("SetDeviceProperty 0x%x failed: %s\n", code, CrErrorString(err).c_str());
    return !err;
}
} // namespace

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: shoot <outdir> [timeout_s]\n"); return 2; }
    const std::string outdir = argv[1];
    const int timeoutS = argc > 2 ? atoi(argv[2]) : 60;
    const std::string mode = argc > 3 ? argv[3] : "s2";
    g_t0 = std::chrono::steady_clock::now();
    int rc = 1;
    Callback cb; int64_t dev = 0; SCRSDK::ICrEnumCameraObjectInfo* en = nullptr;
    bool restoreDest = false; uint64_t origDest = 0;

    if (!SCRSDK::Init()) { fprintf(stderr, "Init failed\n"); return 1; }
    auto err = SCRSDK::EnumCameraObjects(&en, 3);
    if (err || !en || en->GetCount() < 1) { fprintf(stderr, "no camera: %s\n", CrErrorString(err).c_str()); goto done; }
    {
        auto* info = const_cast<SCRSDK::ICrCameraObjectInfo*>(en->GetCameraObjectInfo(0));
        printf("camera: %s\n", (const char*)info->GetModel());
        std::promise<void> p; auto f = p.get_future(); setPromise(&p);
        err = SCRSDK::Connect(info, &cb, &dev, SCRSDK::CrSdkControlMode_Remote, SCRSDK::CrReconnecting_OFF);
        if (err) { fprintf(stderr, "Connect: %s\n", CrErrorString(err).c_str()); setPromise(nullptr); goto done; }
        if (f.wait_for(std::chrono::seconds(10)) != std::future_status::ready || !g_connected) { fprintf(stderr, "connect failed/timeout\n"); setPromise(nullptr); goto done; }
    }
    usleep(1500 * 1000);

    {
        SCRSDK::CrDeviceProperty p;
        if (getProp(dev, SCRSDK::CrDeviceProperty_StillImageStoreDestination, p)) {
            origDest = p.GetCurrentValue();
            printf("StillImageStoreDestination current = 0x%llx (HostPC=0x%x, Card=0x%x, Both=0x%x)\n", (unsigned long long)origDest,
                   SCRSDK::CrStillImageStoreDestination_HostPC, SCRSDK::CrStillImageStoreDestination_MemoryCard,
                   SCRSDK::CrStillImageStoreDestination_HostPCAndMemoryCard);
            if (origDest == SCRSDK::CrStillImageStoreDestination_MemoryCard) {
                printf("changing destination to HostPCAndMemoryCard for this test (will restore)\n");
                if (setProp(dev, SCRSDK::CrDeviceProperty_StillImageStoreDestination, SCRSDK::CrStillImageStoreDestination_HostPCAndMemoryCard)) restoreDest = true;
                usleep(800 * 1000);
            }
        } else printf("could not read StillImageStoreDestination\n");
        if (getProp(dev, SCRSDK::CrDeviceProperty_RAW_J_PC_Save_Image, p))
            printf("RAW_J_PC_Save_Image current = 0x%llx (RAW+JPEG=0x%x, JPEG only=0x%x, RAW only=0x%x)\n", (unsigned long long)p.GetCurrentValue(),
                   SCRSDK::CrPropertyRAWJPCSaveImage_RAWAndJPEG, SCRSDK::CrPropertyRAWJPCSaveImage_JPEGOnly, SCRSDK::CrPropertyRAWJPCSaveImage_RAWOnly);
        if (getProp(dev, SCRSDK::CrDeviceProperty_FileType, p)) printf("FileType current = 0x%llx\n", (unsigned long long)p.GetCurrentValue());
    }

    err = SCRSDK::SetSaveInfo(dev, const_cast<CrChar*>(outdir.c_str()), const_cast<CrChar*>("TEST"), 1);
    printf("SetSaveInfo(%s): %s\n", outdir.c_str(), err ? CrErrorString(err).c_str() : "ok");
    if (err) goto done;

    printf("[%8.1f] >>> firing shutter, mode %s\n", ms(), mode.c_str());
    if (mode == "s1andrelease") {
        err = SCRSDK::SendCommand(dev, SCRSDK::CrCommandId_S1andRelease, SCRSDK::CrCommandParam_Down);
        usleep(100 * 1000);
        err = err ? err : SCRSDK::SendCommand(dev, SCRSDK::CrCommandId_S1andRelease, SCRSDK::CrCommandParam_Up);
    } else {
        if (mode == "s1s2") {
            printf("[%8.1f] S1 lock\n", ms());
            if (!setProp(dev, SCRSDK::CrDeviceProperty_S1, SCRSDK::CrLockIndicator_Locked)) printf("S1 lock failed\n");
            usleep(1500 * 1000);  // manual focus: no focus confirmation to wait for
        }
        err = SCRSDK::SendCommand(dev, SCRSDK::CrCommandId_Release, SCRSDK::CrCommandParam_Down);
        usleep(100 * 1000);
        err = err ? err : SCRSDK::SendCommand(dev, SCRSDK::CrCommandId_Release, SCRSDK::CrCommandParam_Up);
        if (mode == "s1s2") { usleep(300 * 1000); setProp(dev, SCRSDK::CrDeviceProperty_S1, SCRSDK::CrLockIndicator_Unlocked); }
    }
    printf("[%8.1f] release result: %s\n", ms(), err ? CrErrorString(err).c_str() : "ok");
    if (err) goto done;

    // Wait for the first download, then a few seconds more for a second file (RAW+JPEG).
    {
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(timeoutS);
        while (std::chrono::steady_clock::now() < deadline) {
            { std::lock_guard<std::mutex> l(g_mu); if (!g_downloads.empty()) break; }
            usleep(100 * 1000);
        }
        sleep(4);
        std::lock_guard<std::mutex> l(g_mu);
        printf("downloads: %zu\n", g_downloads.size());
        for (auto& d : g_downloads) printf("  %s\n", d.c_str());
        rc = g_downloads.empty() ? 3 : 0;
    }

done:
    if (restoreDest && g_connected) {
        printf("restoring StillImageStoreDestination = 0x%llx\n", (unsigned long long)origDest);
        setProp(dev, SCRSDK::CrDeviceProperty_StillImageStoreDestination, origDest);
        usleep(800 * 1000);
    }
    if (en) en->Release();
    if (g_connected) {
        std::promise<void> p; auto f = p.get_future(); setPromise(&p);
        SCRSDK::Disconnect(dev);
        f.wait_for(std::chrono::seconds(3));
        setPromise(nullptr);
    }
    if (dev) SCRSDK::ReleaseDevice(dev);
    SCRSDK::Release();
    return rc;
}
