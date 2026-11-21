// Live-view probe: connects to the first USB camera, polls GetLiveViewImage for
// N seconds, logs per-frame timing/size to CSV, saves a few JPEGs, and ALWAYS
// disconnects (including on SIGINT/SIGTERM) so the camera session is released.
//
// usage: probe [seconds=10] [outdir=.] [save_every=30]
#include <algorithm>
#include <atomic>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <fstream>
#include <future>
#include <iostream>
#include <map>
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
std::atomic<bool> g_stop{false};
void onSignal(int) { g_stop = true; }

std::mutex g_mu;
std::promise<void>* g_promise = nullptr;
std::atomic<bool> g_connected{false};

void setPromise(std::promise<void>* p) { std::lock_guard<std::mutex> l(g_mu); g_promise = p; }
void fulfil() { std::lock_guard<std::mutex> l(g_mu); if (g_promise) { g_promise->set_value(); g_promise = nullptr; } }
void fail()   { std::lock_guard<std::mutex> l(g_mu); if (g_promise) { g_promise->set_exception(std::make_exception_ptr(std::runtime_error("err"))); g_promise = nullptr; } }

class Callback : public SCRSDK::IDeviceCallback {
public:
    void OnConnected(SCRSDK::DeviceConnectionVersioin) override { g_connected = true; fulfil(); }
    void OnDisconnected(CrInt32u) override { g_connected = false; fulfil(); }
    void OnError(CrInt32u e) override { fprintf(stderr, "SDK error: %s\n", CrErrorString(e).c_str()); fail(); }
    void OnWarning(CrInt32u) override {}
    void OnWarningExt(CrInt32u, CrInt32, CrInt32, CrInt32) override {}
    void OnPropertyChanged() override {}
    void OnLvPropertyChanged() override {}
    void OnCompleteDownload(CrChar*, CrInt32u) override {}
    void OnNotifyContentsTransfer(CrInt32u, SCRSDK::CrContentHandle, CrChar*) override {}
    void OnPropertyChangedCodes(CrInt32u, CrInt32u*) override {}
    void OnLvPropertyChangedCodes(CrInt32u, CrInt32u*) override {}
};
uint64_t fnv1a(const unsigned char* p, size_t n) {
    uint64_t h = 1469598103934665603ULL;
    for (size_t i = 0; i < n; ++i) { h ^= p[i]; h *= 1099511628211ULL; }
    return h;
}
double nowMs() {
    using namespace std::chrono;
    return duration<double, std::milli>(steady_clock::now().time_since_epoch()).count();
}
} // namespace

int main(int argc, char** argv) {
    const double seconds = argc > 1 ? atof(argv[1]) : 10.0;
    const std::string outdir = argc > 2 ? argv[2] : ".";
    const int saveEvery = argc > 3 ? atoi(argv[3]) : 30;

    signal(SIGINT, onSignal);
    signal(SIGTERM, onSignal);

    int rc = 1;
    Callback cb;
    int64_t dev = 0;
    SCRSDK::ICrEnumCameraObjectInfo* en = nullptr;
    bool inited = false;

    if (!SCRSDK::Init()) { fprintf(stderr, "Init failed\n"); return 1; }
    inited = true;

    auto err = SCRSDK::EnumCameraObjects(&en, 3);
    if (err || !en || en->GetCount() < 1) { fprintf(stderr, "no camera (%s)\n", CrErrorString(err).c_str()); goto done; }
    {
        auto* info = const_cast<SCRSDK::ICrCameraObjectInfo*>(en->GetCameraObjectInfo(0));
        printf("camera: %s\n", (const char*)info->GetModel());

        std::promise<void> p; auto f = p.get_future(); setPromise(&p);
        err = SCRSDK::Connect(info, &cb, &dev, SCRSDK::CrSdkControlMode_Remote, SCRSDK::CrReconnecting_OFF);
        if (err) { fprintf(stderr, "Connect: %s\n", CrErrorString(err).c_str()); setPromise(nullptr); goto done; }
        if (f.wait_for(std::chrono::seconds(10)) != std::future_status::ready) { fprintf(stderr, "connect timeout\n"); setPromise(nullptr); goto done; }
        try { f.get(); } catch (...) { fprintf(stderr, "connect failed\n"); goto done; }
    }
    usleep(1000 * 1000); // sample waits 1s after connect

    {
        SCRSDK::CrImageInfo ii;
        err = SCRSDK::GetLiveViewImageInfo(dev, &ii);
        if (err) { fprintf(stderr, "GetLiveViewImageInfo: %s\n", CrErrorString(err).c_str()); goto done; }
        std::vector<CrInt8u> buf(ii.GetBufferSize());
        printf("live view buffer: %zu bytes\n", buf.size());

        std::ofstream csv(outdir + "/frames.csv");
        csv << "frame,t_ms,dt_ms,bytes\n";
        std::map<std::string, int> errs;
        int frames = 0, saved = 0;
        long polls = 0, dups = 0;
        uint64_t lastHash = 0;
        double t0 = nowMs(), last = t0;
        std::vector<double> dts;

        while (!g_stop && nowMs() - t0 < seconds * 1000.0) {
            SCRSDK::CrImageDataBlock blk;
            blk.SetData(buf.data());
            blk.SetSize((CrInt32u)buf.size());
            double ts = nowMs();
            err = SCRSDK::GetLiveViewImage(dev, &blk);
            if (err || blk.GetImageSize() == 0) {
                errs[err ? CrErrorString(err) : "empty"]++;
                usleep(2000);
                continue;
            }
            polls++;
            uint64_t h = fnv1a((const unsigned char*)blk.GetImageData(), blk.GetImageSize());
            if (h == lastHash) { dups++; usleep(2000); continue; }  // same cached frame
            lastHash = h;
            double t = nowMs();
            csv << frames << ',' << (t - t0) << ',' << (t - last) << ',' << blk.GetImageSize() << '\n';
            dts.push_back(t - last);
            last = t;
            if (saveEvery > 0 && frames % saveEvery == 0) {
                char name[64]; snprintf(name, sizeof name, "/frame_%04d.jpg", frames);
                std::ofstream o(outdir + name, std::ios::binary);
                o.write((const char*)blk.GetImageData(), blk.GetImageSize());
                saved++;
            }
            frames++;
            (void)ts;
        }
        double el = (nowMs() - t0) / 1000.0;
        printf("unique frames: %d in %.2fs = %.1f fps, saved %d (polls %ld, duplicate polls %ld)\n", frames, el, frames / el, saved, polls, dups);
        if (!dts.empty()) {
            std::sort(dts.begin(), dts.end());
            auto pct = [&](double q) { return dts[std::min(dts.size() - 1, (size_t)(q * dts.size()))]; };
            printf("inter-frame ms: median %.1f  p95 %.1f  max %.1f\n", pct(0.5), pct(0.95), dts.back());
        }
        for (auto& [k, v] : errs) printf("  non-frame result %s x%d\n", k.c_str(), v);
        rc = 0;
    }

done:
    if (en) en->Release();
    if (g_connected) {
        std::promise<void> p; auto f = p.get_future(); setPromise(&p);
        SCRSDK::Disconnect(dev);
        f.wait_for(std::chrono::seconds(3));
        setPromise(nullptr);
    }
    if (dev) SCRSDK::ReleaseDevice(dev);
    if (inited) SCRSDK::Release();
    return rc;
}
