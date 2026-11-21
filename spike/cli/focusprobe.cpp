// Research tool for focus peaking: what can the SDK tell us about focus, and can the camera's focus
// magnifier be driven remotely so live view shows magnified detail? Everything changed is restored.
//
// usage: focusprobe <outdir>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
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
void setPromise(std::promise<void>* p) { std::lock_guard<std::mutex> l(g_mu); g_promise = p; }
void fulfil() { std::lock_guard<std::mutex> l(g_mu); if (g_promise) { g_promise->set_value(); g_promise = nullptr; } }

class Callback : public SCRSDK::IDeviceCallback {
public:
    void OnConnected(SCRSDK::DeviceConnectionVersioin) override { g_connected = true; fulfil(); }
    void OnDisconnected(CrInt32u) override { g_connected = false; fulfil(); }
    void OnError(CrInt32u e) override { printf("OnError %s\n", CrErrorString(e).c_str()); fulfil(); }
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
    if (err) printf("  SetDeviceProperty 0x%x failed: %s\n", code, CrErrorString(err).c_str());
    return !err;
}
std::vector<uint64_t> readList(const CrInt8u* data, CrInt32u bytes, SCRSDK::CrDataType type) {
    size_t sz = 8;
    switch (type & 0x00FF) { // low byte: element width in the SDK's type codes
        case 0x01: case 0x11: sz = 1; break;
        case 0x02: case 0x12: sz = 2; break;
        case 0x03: case 0x13: sz = 4; break;
        default: sz = 8; break;
    }
    std::vector<uint64_t> out;
    for (size_t i = 0; i + sz <= bytes; i += sz) { uint64_t v = 0; memcpy(&v, data + i, sz); out.push_back(v); }
    return out;
}
void describe(int64_t dev, const char* name, CrInt32u code) {
    SCRSDK::CrDeviceProperty p;
    if (!getProp(dev, code, p)) { printf("%-34s (could not read)\n", name); return; }
    printf("%-34s current=0x%llx  type=0x%x  enableFlag=%d  variable=%d  getEnable=%d setEnable=%d\n", name,
           (unsigned long long)p.GetCurrentValue(), (unsigned)p.GetValueType(), (int)p.GetPropertyEnableFlag(),
           (int)p.GetPropertyVariableFlag(), p.IsGetEnableCurrentValue(), p.IsSetEnableCurrentValue());
    auto vals = readList(p.GetValues(), p.GetValueSize(), p.GetValueType());
    printf("    possible (%zu):", vals.size()); for (size_t i = 0; i < vals.size() && i < 24; i++) printf(" 0x%llx", (unsigned long long)vals[i]); printf("\n");
    auto sets = readList(p.GetSetValues(), p.GetSetValueSize(), p.GetValueType());
    printf("    settable (%zu):", sets.size()); for (size_t i = 0; i < sets.size() && i < 24; i++) printf(" 0x%llx", (unsigned long long)sets[i]); printf("\n");
}
int grabFrames(int64_t dev, const std::string& prefix, int want) {
    SCRSDK::CrImageInfo ii;
    if (SCRSDK::GetLiveViewImageInfo(dev, &ii)) return 0;
    std::vector<CrInt8u> buf(ii.GetBufferSize());
    int saved = 0; size_t lastSize = 0; unsigned long lastSum = 0;
    for (int tries = 0; tries < 400 && saved < want; tries++) {
        SCRSDK::CrImageDataBlock blk; blk.SetData(buf.data()); blk.SetSize((CrInt32u)buf.size());
        if (!SCRSDK::GetLiveViewImage(dev, &blk) && blk.GetImageSize() > 0) {
            unsigned long sum = 0; for (CrInt32u i = 0; i < blk.GetImageSize(); i += 97) sum += ((const unsigned char*)blk.GetImageData())[i];
            if (blk.GetImageSize() != lastSize || sum != lastSum) {
                lastSize = blk.GetImageSize(); lastSum = sum;
                char name[512]; snprintf(name, sizeof name, "%s_%d.jpg", prefix.c_str(), saved);
                std::ofstream f(name, std::ios::binary); f.write((const char*)blk.GetImageData(), blk.GetImageSize());
                saved++; usleep(150 * 1000);
            }
        }
        usleep(8 * 1000);
    }
    return saved;
}
} // namespace

int main(int argc, char** argv) {
    if (argc < 2) { fprintf(stderr, "usage: focusprobe <outdir>\n"); return 2; }
    const std::string out = argv[1];
    Callback cb; int64_t dev = 0; SCRSDK::ICrEnumCameraObjectInfo* en = nullptr;
    uint64_t origMag = 0; bool haveOrigMag = false;
    uint64_t origOsd = 0; bool haveOrigOsd = false;
    int rc = 1;

    if (!SCRSDK::Init()) return 1;
    auto err = SCRSDK::EnumCameraObjects(&en, 3);
    if (err || !en || en->GetCount() < 1) { fprintf(stderr, "no camera\n"); goto done; }
    {
        auto* info = const_cast<SCRSDK::ICrCameraObjectInfo*>(en->GetCameraObjectInfo(0));
        std::promise<void> p; auto f = p.get_future(); setPromise(&p);
        err = SCRSDK::Connect(info, &cb, &dev, SCRSDK::CrSdkControlMode_Remote, SCRSDK::CrReconnecting_OFF);
        if (err || f.wait_for(std::chrono::seconds(10)) != std::future_status::ready || !g_connected) { fprintf(stderr, "connect failed\n"); setPromise(nullptr); goto done; }
    }
    usleep(1500 * 1000);

    printf("=== properties relevant to focusing ===\n");
    describe(dev, "FocusMode", SCRSDK::CrDeviceProperty_FocusMode);
    describe(dev, "FocusArea", SCRSDK::CrDeviceProperty_FocusArea);
    describe(dev, "Focus_Magnifier_Setting", SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting);
    describe(dev, "FocusMagnificationTime", SCRSDK::CrDeviceProperty_FocusMagnificationTime);
    describe(dev, "LiveView_Image_Quality", SCRSDK::CrDeviceProperty_LiveView_Image_Quality);
    describe(dev, "LiveViewDisplayEffect", SCRSDK::CrDeviceProperty_LiveViewDisplayEffect);
    describe(dev, "OSDImageMode", SCRSDK::CrDeviceProperty_OSDImageMode);
    describe(dev, "FocusIndication", SCRSDK::CrDeviceProperty_FocusIndication);
    describe(dev, "PeakingDisplay (expected unsupported)", SCRSDK::CrDeviceProperty_PeakingDisplay);

    printf("\n=== baseline live view frames ===\n");
    printf("saved %d\n", grabFrames(dev, out + "/base", 3));

    {
        SCRSDK::CrDeviceProperty mag;
        if (getProp(dev, SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting, mag)) {
            origMag = mag.GetCurrentValue(); haveOrigMag = true;
            auto sets = readList(mag.GetSetValues(), mag.GetSetValueSize(), mag.GetValueType());
            // distinct non-OFF ratios (upper 4 bytes), by increasing ratio
            std::vector<uint64_t> ratios;
            for (auto v : sets) { uint64_t r = v >> 32; if (r != 0 && std::find(ratios.begin(), ratios.end(), r) == ratios.end()) ratios.push_back(r); }
            printf("\n=== focus magnifier: %zu non-off ratios settable ===\n", ratios.size());
            std::vector<uint64_t> pick;
            if (!ratios.empty()) pick.push_back(ratios.front());
            if (ratios.size() > 1) pick.push_back(ratios.back());
            for (auto r : pick) {
                uint64_t v = (r << 32) | 0x014000F0ULL;  // centre of the 640x480 magnifier coordinate space
                printf("setting magnifier ratio code 0x%llx (x%.1f) at centre ... ", (unsigned long long)r, r / 10.0);
                if (!setProp(dev, SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting, v)) { printf("failed\n"); continue; }
                usleep(1800 * 1000);
                SCRSDK::CrDeviceProperty now; getProp(dev, SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting, now);
                printf("read back 0x%llx; ", (unsigned long long)now.GetCurrentValue());
                char pre[600]; snprintf(pre, sizeof pre, "%s/mag_x%.0f", out.c_str(), r / 10.0);
                printf("saved %d frames\n", grabFrames(dev, pre, 2));
            }
        } else printf("\nFocus_Magnifier_Setting could not be read\n");
    }

    printf("\n=== OSD image (the camera's on-screen overlay) ===\n");
    {
        SCRSDK::CrDeviceProperty osd;
        if (getProp(dev, SCRSDK::CrDeviceProperty_OSDImageMode, osd)) {
            origOsd = osd.GetCurrentValue(); haveOrigOsd = true;
            if (setProp(dev, SCRSDK::CrDeviceProperty_OSDImageMode, SCRSDK::CrOSDImageMode_On)) {
                usleep(1500 * 1000);
                std::vector<CrInt8u> b(CR_OSD_IMAGE_MAX_SIZE);
                SCRSDK::CrOSDImageDataBlock blk; blk.SetData(b.data());
                auto e = SCRSDK::GetOSDImage(dev, &blk);
                printf("GetOSDImage: %s, %u bytes\n", e ? CrErrorString(e).c_str() : "ok", e ? 0 : (unsigned)blk.GetImageSize());
                if (!e && blk.GetImageSize() > 0) { std::ofstream f(out + "/osd.png", std::ios::binary); f.write((const char*)blk.GetImageData(), blk.GetImageSize()); }
            }
        }
    }
    rc = 0;

done:
    if (g_connected) {
        if (haveOrigMag) {
            setProp(dev, SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting, origMag); usleep(1000 * 1000);
            SCRSDK::CrDeviceProperty chk; if (getProp(dev, SCRSDK::CrDeviceProperty_Focus_Magnifier_Setting, chk))
                printf("\nrestored magnifier: now 0x%llx (was 0x%llx) %s\n", (unsigned long long)chk.GetCurrentValue(), (unsigned long long)origMag, chk.GetCurrentValue() == origMag ? "OK" : "MISMATCH");
        }
        if (haveOrigOsd) {
            setProp(dev, SCRSDK::CrDeviceProperty_OSDImageMode, origOsd); usleep(800 * 1000);
            SCRSDK::CrDeviceProperty chk; if (getProp(dev, SCRSDK::CrDeviceProperty_OSDImageMode, chk))
                printf("restored OSD mode: now 0x%llx (was 0x%llx) %s\n", (unsigned long long)chk.GetCurrentValue(), (unsigned long long)origOsd, chk.GetCurrentValue() == origOsd ? "OK" : "MISMATCH");
        }
        std::promise<void> p; auto f = p.get_future(); setPromise(&p);
        SCRSDK::Disconnect(dev); f.wait_for(std::chrono::seconds(3)); setPromise(nullptr);
    }
    if (en) en->Release();
    if (dev) SCRSDK::ReleaseDevice(dev);
    SCRSDK::Release();
    return rc;
}
