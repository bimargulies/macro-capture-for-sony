// Probe for Sony's question: with shutter speed, aperture and ISO all fixed (ISO Auto off), does the
// camera return CrDeviceProperty_MeteredManualLevel? Read-only: it changes no settings and takes no pictures.
//
// usage: meterprobe [rounds]   (default 3 rounds, 2 s apart)
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <future>
#include <mutex>
#include <string>
#include <unistd.h>
#include <vector>

#include "CameraRemote_SDK.h"
#include "CrDebugString.h"
#include "CrDeviceProperty.h"
#include "IDeviceCallback.h"

namespace {
std::mutex g_mu;
std::promise<void> *g_promise = nullptr;
std::atomic<bool> g_connected{false};
std::atomic<int> g_meterChangeNotices{0};

void setPromise(std::promise<void> *p) {
    std::lock_guard<std::mutex> l(g_mu);
    g_promise = p;
}

void fulfil() {
    std::lock_guard<std::mutex> l(g_mu);
    if (g_promise) {
        g_promise->set_value();
        g_promise = nullptr;
    }
}

class Callback : public SCRSDK::IDeviceCallback {
  public:
    void OnConnected(SCRSDK::DeviceConnectionVersioin) override {
        g_connected = true;
        fulfil();
    }
    void OnDisconnected(CrInt32u) override {
        g_connected = false;
        fulfil();
    }
    void OnError(CrInt32u e) override {
        printf("OnError %s\n", CrErrorString(e).c_str());
        fulfil();
    }
    void OnPropertyChangedCodes(CrInt32u num, CrInt32u *codes) override {
        for (CrInt32u i = 0; i < num; i++) {
            if (codes[i] == SCRSDK::CrDeviceProperty_MeteredManualLevel) {
                g_meterChangeNotices++;
            }
        }
    }
};

std::string errText(CrInt32 err) {
    char buf[32];
    snprintf(buf, sizeof buf, "0x%x", static_cast<unsigned>(err));
    return std::string(buf) + " " + CrErrorString(err);
}

// The SDK's strings are a UTF-16 length followed by that many characters.
std::string ascii(const CrInt16u *s) {
    std::string out;
    if (!s) {
        return out;
    }
    for (CrInt16u i = 0; i < s[0]; i++) {
        CrInt16u c = s[1 + i];
        if (c == 0) {
            break;
        }
        out += (c < 128) ? static_cast<char>(c) : '?';
    }
    return out;
}

std::string modeName(uint64_t v) {
    switch (v) {
    case SCRSDK::CrExposure_M_Manual:
        return "M (manual)";
    case SCRSDK::CrExposure_P_Auto:
        return "P (program)";
    case SCRSDK::CrExposure_A_AperturePriority:
        return "A (aperture priority)";
    case SCRSDK::CrExposure_S_ShutterSpeedPriority:
        return "S (shutter priority)";
    default: {
        char buf[48];
        snprintf(buf, sizeof buf, "other (0x%llx)", static_cast<unsigned long long>(v));
        return buf;
    }
    }
}

std::string shutterText(uint64_t v) {
    auto raw = static_cast<uint32_t>(v);
    if (raw == 0) {
        return "Bulb";
    }
    uint32_t num = raw >> 16, den = raw & 0xFFFF;
    char buf[48];
    if (den == 0 || raw == 0xFFFFFFFF) {
        snprintf(buf, sizeof buf, "unknown (0x%x)", raw);
    } else if (num == 1) {
        snprintf(buf, sizeof buf, "1/%u", den);
    } else {
        snprintf(buf, sizeof buf, "%.1f\"", static_cast<double>(num) / den);
    }
    return buf;
}

struct Exposure {
    bool haveMode = false, haveShutter = false, haveAperture = false, haveIso = false;
    uint64_t mode = 0, shutter = 0, aperture = 0, iso = 0;
};

Exposure readExposure(int64_t dev) {
    CrInt32u codes[] = {SCRSDK::CrDeviceProperty_ExposureProgramMode, SCRSDK::CrDeviceProperty_ShutterSpeed,
                        SCRSDK::CrDeviceProperty_FNumber, SCRSDK::CrDeviceProperty_IsoSensitivity};
    Exposure e;
    SCRSDK::CrDeviceProperty *list = nullptr;
    CrInt32 n = 0;
    SCRSDK::CrError err =SCRSDK::GetSelectDeviceProperties(dev, 4, codes, &list, &n);
    if (err) {
        printf("  exposure read failed: %s\n", errText(err).c_str());
    }
    for (CrInt32 i = 0; list && i < n; i++) {
        uint64_t v = list[i].GetCurrentValue();
        switch (list[i].GetCode()) {
        case SCRSDK::CrDeviceProperty_ExposureProgramMode:
            e.haveMode = true;
            e.mode = v;
            break;
        case SCRSDK::CrDeviceProperty_ShutterSpeed:
            e.haveShutter = true;
            e.shutter = v;
            break;
        case SCRSDK::CrDeviceProperty_FNumber:
            e.haveAperture = true;
            e.aperture = v;
            break;
        case SCRSDK::CrDeviceProperty_IsoSensitivity:
            e.haveIso = true;
            e.iso = v;
            break;
        default:
            break;
        }
    }
    if (list) {
        SCRSDK::ReleaseDeviceProperties(dev, list);
    }
    return e;
}

enum class Fixed { No, Yes, YesLensReportsNoAperture };

// Prints the exposure settings and says whether all of them are fixed (manual, no ISO Auto). A lens that
// reports no aperture (manual or adapted) still has a fixed aperture, so that case is reported on its own.
Fixed reportExposure(const Exposure &e) {
    bool fixed = true, lensSilent = false;
    auto isoValue = static_cast<uint32_t>(e.iso) & 0x00FFFFFF;
    auto f = static_cast<uint16_t>(e.aperture);

    if (!e.haveMode) {
        printf("  exposure mode: not returned\n");
        fixed = false;
    } else {
        printf("  exposure mode: %s\n", modeName(e.mode).c_str());
        fixed = fixed && e.mode == SCRSDK::CrExposure_M_Manual;
    }
    if (!e.haveShutter) {
        printf("  shutter speed: not returned\n");
        fixed = false;
    } else {
        printf("  shutter speed: %s (raw 0x%llx)\n", shutterText(e.shutter).c_str(),
               static_cast<unsigned long long>(e.shutter));
        fixed = fixed && static_cast<uint32_t>(e.shutter) != 0;
    }
    if (!e.haveAperture) {
        printf("  aperture: not returned\n");
        fixed = false;
    } else if (f == 0 || f >= 0xFFF0) {
        printf("  aperture: not reported by the lens, so set on the lens itself (raw 0x%llx)\n",
               static_cast<unsigned long long>(e.aperture));
        lensSilent = true;
    } else {
        printf("  aperture: F%.1f (raw 0x%llx)\n", f / 100.0, static_cast<unsigned long long>(e.aperture));
    }
    if (!e.haveIso) {
        printf("  ISO: not returned\n");
        fixed = false;
    } else if (isoValue == SCRSDK::CrISO_AUTO) {
        printf("  ISO: AUTO (raw 0x%llx)\n", static_cast<unsigned long long>(e.iso));
        fixed = false;
    } else {
        printf("  ISO: %u, ISO Auto off (raw 0x%llx)\n", isoValue, static_cast<unsigned long long>(e.iso));
    }
    if (!fixed) {
        printf("  all exposure settings fixed: NO\n");
        return Fixed::No;
    }
    printf("  all exposure settings fixed: YES%s\n", lensSilent ? " (aperture fixed on a lens that does not report it)" : "");
    return lensSilent ? Fixed::YesLensReportsNoAperture : Fixed::Yes;
}

// Asks for MeteredManualLevel alone; returns whether the camera returned it.
bool probeMeterAlone(int64_t dev) {
    CrInt32u code = SCRSDK::CrDeviceProperty_MeteredManualLevel;
    SCRSDK::CrDeviceProperty *list = nullptr;
    CrInt32 n = 0;
    SCRSDK::CrError err =SCRSDK::GetSelectDeviceProperties(dev, 1, &code, &list, &n);
    bool found = false;
    printf("  GetSelectDeviceProperties(MeteredManualLevel 0x%x): error %s, %d returned\n", code,
           errText(err).c_str(), static_cast<int>(n));
    for (CrInt32 i = 0; list && i < n; i++) {
        const SCRSDK::CrDeviceProperty &p = list[i];
        printf("    code 0x%x current=0x%llx type=0x%x enableFlag=%d getEnable=%d\n", p.GetCode(),
               static_cast<unsigned long long>(p.GetCurrentValue()), static_cast<unsigned>(p.GetValueType()),
               static_cast<int>(p.GetPropertyEnableFlag()), p.IsGetEnableCurrentValue());
        found = found || p.GetCode() == code;
    }
    if (list) {
        SCRSDK::ReleaseDeviceProperties(dev, list);
    }
    return found;
}

// Reads the full property list; returns whether MeteredManualLevel is in it.
bool probeMeterInFullList(int64_t dev) {
    SCRSDK::CrDeviceProperty *list = nullptr;
    CrInt32 n = 0;
    SCRSDK::CrError err =SCRSDK::GetDeviceProperties(dev, &list, &n);
    bool found = false;
    for (CrInt32 i = 0; list && i < n; i++) {
        found = found || list[i].GetCode() == SCRSDK::CrDeviceProperty_MeteredManualLevel;
    }
    printf("  GetDeviceProperties: error %s, %d properties, MeteredManualLevel %s\n", errText(err).c_str(),
           static_cast<int>(n), found ? "PRESENT" : "absent");
    if (list) {
        SCRSDK::ReleaseDeviceProperties(dev, list);
    }
    return found;
}

std::string readString(int64_t dev, CrInt32u code) {
    SCRSDK::CrDeviceProperty *list = nullptr;
    CrInt32 n = 0;
    std::string out = "(not returned)";
    if (!SCRSDK::GetSelectDeviceProperties(dev, 1, &code, &list, &n) && list && n >= 1) {
        out = ascii(list[0].GetCurrentStr());
    }
    if (list) {
        SCRSDK::ReleaseDeviceProperties(dev, list);
    }
    return out;
}
} // namespace

int main(int argc, char **argv) {
    int rounds = argc > 1 ? atoi(argv[1]) : 3;
    if (rounds < 1) {
        fprintf(stderr, "usage: meterprobe [rounds]\n");
        return 2;
    }
    Callback cb;
    int64_t dev = 0;
    SCRSDK::ICrEnumCameraObjectInfo *en = nullptr;
    int fixedRounds = 0, fixedAndFound = 0, fixedAndMissing = 0, silentLensRounds = 0;
    int rc = 1;

    if (!SCRSDK::Init()) {
        fprintf(stderr, "SDK Init failed\n");
        return 1;
    }
    printf("SDK version 0x%08x\n", SCRSDK::GetSDKVersion());
    SCRSDK::CrError err =SCRSDK::EnumCameraObjects(&en, 3);
    if (err || !en || en->GetCount() < 1) {
        fprintf(stderr, "no camera found: is it on, in PC Remote mode, and not held by another app?\n");
        goto done;
    }
    {
        auto *info = const_cast<SCRSDK::ICrCameraObjectInfo *>(en->GetCameraObjectInfo(0));
        printf("camera: %s via %s\n", info->GetModel(), info->GetConnectionTypeName());
        std::promise<void> p;
        auto f = p.get_future();
        setPromise(&p);
        err = SCRSDK::Connect(info, &cb, &dev, SCRSDK::CrSdkControlMode_Remote, SCRSDK::CrReconnecting_OFF);
        if (err || f.wait_for(std::chrono::seconds(10)) != std::future_status::ready || !g_connected) {
            fprintf(stderr, "connect failed\n");
            setPromise(nullptr);
            goto done;
        }
    }
    usleep(2000 * 1000);  // let the camera deliver its first property list
    printf("camera software version: %s\n", readString(dev, SCRSDK::CrDeviceProperty_SoftwareVersion).c_str());

    for (int r = 1; r <= rounds; r++) {
        printf("\n=== round %d of %d ===\n", r, rounds);
        Fixed fixed = reportExposure(readExposure(dev));
        bool alone = probeMeterAlone(dev);
        bool inList = probeMeterInFullList(dev);
        if (fixed == Fixed::YesLensReportsNoAperture) {
            silentLensRounds++;
        }
        if (fixed != Fixed::No) {
            fixedRounds++;
            if (alone || inList) {
                fixedAndFound++;
            } else {
                fixedAndMissing++;
            }
        }
        if (r < rounds) {
            usleep(2000 * 1000);
        }
    }
    printf("\nMeteredManualLevel change notifications received: %d\n", g_meterChangeNotices.load());
    printf("\n=== verdict ===\n");
    if (fixedRounds == 0) {
        printf("INCONCLUSIVE: exposure was never fully fixed. Set M mode, a fixed shutter speed and aperture, and a "
               "fixed ISO (not AUTO), then run again.\n");
    } else if (fixedAndMissing > 0 && fixedAndFound == 0) {
        printf("NOT RETURNED: with all exposure settings fixed (%d of %d rounds), MeteredManualLevel was not returned "
               "by GetSelectDeviceProperties or GetDeviceProperties.\n",
               fixedRounds, rounds);
    } else if (fixedAndMissing == 0) {
        printf("RETURNED: with all exposure settings fixed, MeteredManualLevel was returned (%d of %d rounds).\n",
               fixedAndFound, rounds);
    } else {
        printf("MIXED: with exposure fixed, MeteredManualLevel was returned in %d rounds and missing in %d.\n",
               fixedAndFound, fixedAndMissing);
    }
    if (silentLensRounds > 0) {
        printf("NOTE: in %d of those rounds the lens did not report its aperture (manual or adapted lens). Repeat "
               "with an electronic lens to rule that out.\n",
               silentLensRounds);
    }
    rc = 0;

done:
    if (g_connected) {
        std::promise<void> p;
        auto f = p.get_future();
        setPromise(&p);
        SCRSDK::Disconnect(dev);
        f.wait_for(std::chrono::seconds(3));
        setPromise(nullptr);
    }
    if (en) {
        en->Release();
    }
    if (dev) {
        SCRSDK::ReleaseDevice(dev);
    }
    SCRSDK::Release();
    return rc;
}
