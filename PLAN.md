# Plan: macOS replacement for Sony Imaging Edge

## Strategy

- GUI in **Swift** (SwiftUI for app chrome, AppKit/CALayer, later Metal, for the viewfinder surface).
- Sony **Camera Remote SDK (CrSDK, C++)** wrapped by a thin **Objective-C++ (.mm) shim** that Swift consumes as an ordinary class. Fallback: C++ shim with a plain C API.
- Keep the wrapper interface narrow so the SDK can later move into an XPC helper process if crash isolation or signing demands it.
- Still images only. Live view is a JPEG poll loop, not video.

## Open items to verify before starting

- [x] **Target camera is the Sony A7R V (ILCE-7RM5)**, confirmed on the CrSDK supported list (an earlier plan assumed an A7 III / A7 V; that was a mix-up by the user). The A7 III is not supported by CrSDK.
- [ ] Current CrSDK version supports macOS on Apple Silicon (arm64), and which macOS versions.
- [ ] SDK license terms (download requires accepting Sony's license; check redistribution rules for the dylibs).
- [ ] Camera menu: PC Remote / USB connection mode available and enabled.
- [ ] Xcode and command-line tools installed.

## Findings from Sony SDK page (fetched 2026-11-21)

Source: https://support.d-imaging.sony.co.jp/app/sdk/en/index.html

- Latest listed: CrSDK Ver. 2.02.00 (2026-Jun-10). Ver. 2.01.00 (2026-Feb-3) added ILCE-7M5 (A7 V).
- macOS: 14.1+, 15.1+, 26.0+. Apple Silicon/arm64 is not stated on the page (the ARM exclusion footnote applies only to Windows 11). Check the package contents for arm64 or universal dylibs.
- **A7 V (ILCE-7M5): supported.**
- **A7 III (ILCE-7M3): NOT on the supported list** (not mentioned anywhere on the page). Same for ILCE-7M2/7M3 generally; the list's oldest bodies are the 7C, 7RM4/4A, 9M2.
- Interfaces: USB, wired LAN, Wi-Fi (per-device support is in the API reference PDFs).
- Cameras must be on the latest firmware.
- Access: free, but you apply via a regional route (US/Canada: pro.sony contact-us form; Europe: pro.sony.com SDK-download page). There is no public direct macOS download link, and you must accept Sony's license agreement yourself.
- No per-model live-view table on the page; check the API reference.

Implication: the A7 III is not a CrSDK target. The user's camera is the A7R V, which is supported.

## Findings from the unpacked SDK (v2.02.00)

Unpacked under `third_party/CrSDK_v2.02.00_20260610a_Mac/unpacked/` (`api/`, `RemoteCli/`, `SimpleCli/`).

- All dylibs checked (`libCr_Core`, `libCr_PTP_USB`, bundled libusb) are **universal: x86_64 + arm64**. Apple Silicon is fine.
- The live-view API is: `GetLiveViewProperties`, `GetLiveViewImageInfo` (size), `GetLiveViewImage` (fills a `CrImageDataBlock` with JPEG data). It matches the polling model assumed above. Reference sample: `SimpleCli/app/getLiveViewAndOSD.cpp`.
- The API support table (`api/html/_static/api_list.csv`) shows the live-view calls are supported on every listed camera, including ILCE-7M5 (A7 V), in R/T (remote and transfer) modes. The A7 III is not a column in the table.
- The SDK is C++ with callbacks via `IDeviceCallback`, as expected, so the Objective-C++ shim plan stands.
- The package ships `RemoteCli` and `SimpleCli` (CMake) as samples; use them as the base for the Phase 1 probe.
- Docs mention "Removing macOS Quarantine Attributes" and "Camera body settings for USB connection". Read both before first run.

## Spike results so far (2026-11-21)

Camera under test: **ILCE-7RM5 (A7R V)**, USB, PC Remote mode. This is the user's actual camera.

- Built Sony's SimpleCli samples (`cmake --preset Mac && cmake --build --preset auto`, needs `brew install cmake`). SDK-only deps are prebuilt.
- `getLiveViewAndOSD` connected, fetched live-view frames, and disconnected cleanly. Frames are **baseline JPEG, 1024x768, about 37 KB**. The shape matches the plan.
- Frame rate and latency are not yet measured; the sample only fetches on demand and overwrites one file.

### Probe measurements (`spike/cli/probe.cpp`, A7R V, USB)

Build: `cd spike/cli && cmake -S . -B build && cmake --build build`; run `build/probe [seconds] [outdir] [save_every]`. It disconnects cleanly on exit and on SIGINT/SIGTERM.

- **30.1 fps** of unique frames over 10 s (301 frames); inter-frame interval median 33.4 ms, p95 40.6 ms, max 54.3 ms. Frames are 1024x768 JPEG, about 37 KB.
- `GetLiveViewImage` is **non-blocking and returns the camera's latest cached frame every time**, even if it has not changed. A tight poll loop sees about 93% duplicates (4172 polls, 3871 duplicates). The shim must either dedupe (e.g. hash) or poll at roughly the frame rate (~every 10 ms) and drop repeats. Check whether a callback (e.g. `OnLvPropertyChanged`) can signal a new frame instead of polling.
- Not yet measured: end-to-end latency from scene to screen.

### Swift app measurements (`spike/app`, run with `./run.sh --seconds 15`)

SwiftPM package: Objective-C++ shim `CCameraShim` (`CameraBridge`) + SwiftUI/AppKit app `Viewfinder`. Frames are decoded with ImageIO and shown via `CALayer.contents`, latest-frame-wins.

- Steady state: **30 fps**, 1024x768, **fetch-to-screen median 6.7 ms (p95 8.2, max 14.2)**, JPEG decode about 2-3 ms, 0 dropped frames. This is app-side latency only; true glass-to-glass latency (camera sensor to screen) still needs a clock test.
- **Slow connect:** about 10 s before the first frame, much of it likely `EnumCameraObjects` (3 s timeout) plus connect plus a 1 s settle; not yet broken down.
- **Firewall prompt:** a macOS network-filter dialog ("Visual Studio Code via Viewfinder wants to accept an incoming connection") appeared while the app launched from the VS Code terminal. It was NOT answered by the assistant; the user decides. The SDK may open a listening socket; an app launched normally from Finder would be prompted as "Viewfinder". Find out what the SDK is listening on (USB mode should not need it).

### Glass-to-glass latency (measured 2026-11-21)

Method: `./run.sh --clock` shows a millisecond clock over the viewfinder; the A7R V was aimed at the Mac screen so the picture contains the window and its clock. The clock inside the picture is older than the live clock; the difference is one full loop (screen -> camera -> USB -> SDK -> app -> screen). Six window screenshots, clocks read by eye (inner digits are small and blurry, so about +/-10 ms):

| live | in picture | delay |
|---|---|---|
| 43.450 | 43.350 | 100 ms |
| 43.975 | 43.858 | 117 ms |
| 44.508 | 44.384 | 124 ms |
| 45.041 | 44.918 | 123 ms |
| 45.575 | 45.460 | 115 ms |
| 46.100 | 45.993 | 107 ms |

**Mean about 114 ms (range 100-124).** The app's own share is small (fetch-to-screen about 2-3 ms, plus up to one 60 Hz display refresh of about 8-16 ms, which also appears in this loop once for the screen the camera watched). So roughly **90-100 ms is camera exposure, camera-side processing, USB and SDK**, and is not under our control. That is fine for composing and focusing; it is noticeable when tracking fast motion. Possible levers to test later: camera live-view quality/frame-rate settings, USB bulk transfer rate setting (see SDK docs), and a shorter poll interval (currently 3 ms sleep).

### Startup breakdown and fix

- `EnumCameraObjects` takes **7-8 s** (the `timeInSec` argument of 3 is not what bounds it). `Connect` itself takes about 40 ms, plus the sample's 1 s settle sleep. While enumerating, the process opens UDP sockets (one on `*:65040`): that is network discovery for IP cameras, and it is what triggers the macOS "incoming connection" firewall prompt.
- **Fast path:** `CreateCameraObjectInfoUSBConnection(model, serial)` skips enumeration. Startup drops from about 9.4 s to **1.2 s to first frame** (1.0 s of that is the settle sleep, which may be shortenable), with no network sockets. Frame rate and latency are unchanged (30 fps, 6.9 ms fetch-to-screen).
- It needs the camera's model enum and USB serial (`<camera-serial>` for this body; the shim logs it as "camera id" after an enumeration). Plan: look up the serial of a connected Sony USB device directly (IOKit), or cache it from the last successful enumeration, and only fall back to full enumeration (which also supports Wi-Fi/Ethernet cameras) when that fails.
- Spike hook: env `CAM_SERIAL=<serial>` selects the fast path (model hard-coded to ILCE-7RM5).
- Not done: the object from `CreateCameraObjectInfoUSBConnection` is never `Release()`d (spike leak).

### Gotchas found (all need handling in the real app)

1. **Quarantine:** the downloaded SDK dylibs carry `com.apple.quarantine` and are ad-hoc signed, so macOS refuses to load them ("library load disallowed by system policy"). Fixed with `xattr -dr com.apple.quarantine` on the SDK folder. A shipped app must bundle and re-sign the dylibs itself.
2. **Other apps hold the camera:** the connect timed out with `Connect_TimeOut` and later `Connect_SessionAlreadyOpened` while **Adobe Bridge** was running. Quitting Bridge fixed it. `ptpcamerad` (Apple) also respawns instantly if killed; killing it was not what fixed the problem. The app should detect this and tell the user which program to quit.
3. **Stale session:** if the process exits without disconnecting, the camera keeps the session open and refuses new connections (`Connect_SessionAlreadyOpened`) until it is power-cycled or the cable is replugged. The probe and app must always disconnect and release, including on Ctrl-C, signals and error paths.
4. The sample's stdin handling is interactive (`l` = get live view, `q` = quit); drive it with piped input and always send `q`.

## Usage model and priorities (from user, 2026-11-21)

- Set up once, stays running for a long time. **Initial connect time is not a concern** (so the slow full enumeration is acceptable; the serial fast path is optional).
- **Reconnect matters:** if the camera is powered off and back on (or unplugged), the app must reconnect with zero or one clicks. Plan: observe USB attach/detach for Sony (vendor 0x054c) via IOKit notifications, release the old SDK session on detach, and reconnect automatically on attach; keep a manual "Reconnect" button as the one-click fallback. The shim currently uses `CrReconnecting_OFF`; the SDK also has `CrReconnecting_ON` and an `OnWarning(CrWarning_Connect_Reconnecting)` callback, which should be tested (power-cycle the camera while the app runs) before deciding whether to rely on it or on our own loop.
- Other apps holding the camera and stale sessions are accepted limitations, same as Sony's own app.

## Reconnect test results (2026-11-21, A7R V over USB, `CAM_RECONNECT=1`)

- With `CrReconnecting_ON` the **SDK reconnects by itself** with no action from us: power-off gives `OnWarning(CrWarning_Connect_Reconnecting = 0x20002)` and live view fails with `0x8402`; power-on gives `OnConnected` then `OnWarning(CrWarning_Connect_Reconnected = 0x20001)` and live view resumes. Short outage (about 17 s) and long outage (**2.5 min**, 13:28:18 to 13:30:48) both recovered on their own. No `CrError_Reconnect_TimeOut` was seen; the SDK's give-up time, if any, is unknown (longer than 2.5 min).
- The app now maps these to states (connected / reconnecting / disconnected) and shows a dimmed frame with "Reconnecting..." until live. No button: reconnection is automatic. If the SDK does report an error or disconnect, the app tears down the session and retries every 5 s. That fallback path is **untested** (the one time it ran it exposed the crash below).
- **Crash found and fixed:** calling `SCRSDK::Init()` a second time after `Release()` in the same process segfaults inside Sony's `libmonitor_protocol` (`VericManager` init). Init once per process; `Release()` only at exit.
- Launch helper: `spike/app/reconnect_test.sh` waits for the camera on USB, then runs the app with auto-reconnect.
- Initial connect in that first test once reported "No camera found" even though the camera was on USB; a retry succeeded. Likely the camera not yet ready right after power-on, which the retry loop covers.

## Portrait orientation (tested 2026-11-21, A7R V)

Rotated the camera to portrait both ways while the probe saved 144 frames over 72 s.

- **Live-view frames never change shape or metadata:** every frame is 1024x768 landscape with **no EXIF at all** (no Orientation tag). When the camera is turned, the scene simply appears sideways inside the same landscape raster (checked by eye: grip-up and grip-down show the scene rotated 90 degrees in opposite directions).
- The SDK headers have no orientation, rotation or gravity property (searched `CrDeviceProperty.h`, `CrDefines.h`, `CrCommandData.h`, `CrImageDataBlock.h`). So the app **cannot learn the camera's orientation from live view**, and a naive viewer shows a sideways picture.
- Design consequences:
  - The viewfinder view needs a **rotation state (0/90/180/270)** and a simple control (button or key) to set it. Make the rotation part of the display layer, not the decode path, so it is cheap.
  - The window layout must handle a rotated picture: a portrait-oriented picture is 768x1024, so the viewer area should be allowed to become taller than wide (resizable/letterboxed canvas, not a fixed 4:3 frame), and side panels should not assume landscape.
  - **Overlays** (focus frames, grid, level, histogram) come from the SDK in sensor coordinates; they must be transformed with the same rotation as the image.
  - Remember the chosen rotation across reconnects and launches.
  - Manual rotate matches Sony's Imaging Edge, which also has buttons to rotate the viewfinder image (per user), so this is expected behavior rather than a workaround.
  - Possible auto-rotate later: look for an orientation value elsewhere (a device property I did not find, the EXIF of captured stills, or a post-view image). Not worth blocking on; manual rotate is enough since the camera "stays set up".

## Packaging results (2026-11-21)

The real app now lives in `app/` (copied from the spike; the spike stays as a reference). `app/bundle.sh` builds `app/build/Capture Viewfinder.app`; `SIGN_ID="<identity>" ./bundle.sh` signs with a real identity (default is ad hoc). Launching it with `open` connects and shows live video at 30 fps.

Answers to the open packaging questions:

- **Where the SDK looks for adapters:** `Contents/Frameworks/CrAdapter/` inside the `.app`, with `libCr_Core.dylib` and the two `libmonitor_protocol*.dylib` in `Contents/Frameworks/`. Sony's samples use an odd `Contents/` folder beside the executable, but inside a real bundle the SDK finds the adapters without it. The executable needs an extra rpath `@executable_path/../Frameworks` (added by `bundle.sh` via `install_name_tool`).
- **Hardened runtime with ad-hoc signing fails:** dyld refuses the Sony libraries ("mapping process and mapped file have different Team IDs"). **Adding the `com.apple.security.cs.disable-library-validation` entitlement fixes it** (`app/Resources/Viewfinder.entitlements`); the connection and adapters load fine under the hardened runtime.
- **No code-signing identity on this Mac** (`security find-identity` shows 0). Ad hoc plus the entitlement is enough for personal use. To make signing independent of the entitlement, re-sign every Sony dylib with one identity (the script already signs inside-out, so setting `SIGN_ID` does that). A free Apple Development certificate from Xcode would do for personal use; notarization needs a paid Developer ID.
- Reconnecting is now always on in `app/` (SDK `CrReconnecting_ON`).
- Not yet done: app icon, a proper bundle identifier and name, version bumps, Xcode project (the package opens in Xcode directly via `app/Package.swift` if wanted), notarization.

## Packaging notes (original assumptions, superseded by the results above) (signing and bundling the SDK libraries)

- SDK files to embed: `libCr_Core.dylib`, `libmonitor_protocol.dylib`, `libmonitor_protocol_pf.dylib`, and `CrAdapter/` (`libCr_PTP_USB`, `libCr_PTP_IP`, `libusb-1.0.0`, `libssh2`). The adapters are loaded at runtime by the SDK, so they must be present and signed too. **Open question:** the Sony samples put them at `<exe dir>/Contents/Frameworks/CrAdapter`; in a real `.app` the executable lives in `Contents/MacOS`, so test where the SDK actually looks.
- SwiftPM does not produce `.app` bundles; use an Xcode project (copy-files phase to `Contents/Frameworks`, embed and sign) or a build script (Info.plist, copy, `codesign`).
- Signing: Sony's dylibs are ad-hoc signed with no Team ID. A hardened-runtime app refuses to load libraries from a different team unless you either re-sign all of them with your own identity (inside-out, nested adapters first), or add the `com.apple.security.cs.disable-library-validation` entitlement. For personal use on the build machine, a locally built, ad-hoc or personally signed app is enough, and the quarantine problem does not arise (it only affects downloaded files).
- Only if distributing to others: Developer ID signing, hardened runtime, notarization, and checking Sony's license terms on redistributing the dylibs. Sandboxing would additionally need the USB (and network) entitlements.

## Phase 1: Spike (camera must be free, so image production is paused)

Camera: A7R V (ILCE-7RM5) over USB.

Goal: prove connection, measure live-view resolution, frame rate and latency.

1. **Download and unpack the SDK** into its own directory outside the repo (license-restricted; do not commit it). Record the version.
2. **C++ CLI tool** (`spike/cli/`): initialise SDK, enumerate cameras over USB, connect, poll live view, write JPEGs to disk. Log per-frame timestamps and sizes.
   - Success: frames arrive continuously; record resolution, fps, and any USB or permission problems.
3. **Objective-C++ wrapper** (`spike/shim/`): a class that owns the connection and live-view thread and delivers the latest frame to a Swift-facing delegate or block ("latest frame wins", no queue).
4. **Minimal SwiftUI app** (`spike/app/`): one window, a `CALayer` showing decoded frames (ImageIO `CGImageSource`). Embed and code-sign the SDK dylibs in the bundle.
5. **Measure**: glass-to-glass latency (point the camera at a running clock next to the screen), CPU use, dropped frames, USB vs. Wi-Fi if available.

Step 6 (optional, if another body becomes available): repeat on it and record differences. Keep camera-specific behavior out of the shim where possible.

Exit criteria: smooth live view in a Swift window at acceptable latency, and a go/no-go note on whether Metal is needed.

## Phase 2: Decisions after the spike (not started)

- CALayer vs. Metal for the viewfinder (needed for histogram, focus peaking, zoom).
- In-process vs. XPC helper for the SDK.
- Overlay data from the SDK (focus frames, faces) and how it is drawn.
- Reconnect and hot-unplug handling; threading model for SDK callbacks.

## Later (out of scope for now)

Camera settings control, shutter release, image transfer, tethered capture workflow.

## Repo layout (proposed)

```
spike/cli/    C++ command-line probe
spike/shim/   Objective-C++ wrapper
spike/app/    SwiftUI app
third_party/  (gitignored) Sony SDK
```

---

# Background and rationale

Written from memory, not checked against Sony's current release notes. Verify the open items above against the actual SDK download.

## How live view works in Sony's SDK

Sony's Camera Remote SDK (CrSDK) is a C++ library with Windows, Linux and macOS builds. It connects over USB (PTP) or Ethernet/Wi-Fi. Live view is a polling model:

1. Connect, and set the camera to PC Remote mode on its menu.
2. Ask the SDK for the live-view image size and allocate a buffer.
3. Call the live-view fetch function repeatedly. Each call returns one JPEG frame.
4. The SDK also reports focus-frame and face-detection rectangles, usable for overlays.

Frames are JPEGs at modest resolution, roughly 640x480 up to about 1024x680 depending on body and settings. That is a "good enough for framing" preview, not full sensor resolution. Frame rate is typically 15-30 fps and depends on transport; USB is much better than Wi-Fi.

Data rate and pixel count are small, so the display side is not the hard part. The hard parts are connection and session management, camera settings and callbacks, and USB quirks on macOS.

## Display pipeline components

| Stage | Options |
|---|---|
| Frame source | CrSDK live-view poll loop on a dedicated thread |
| JPEG decode | ImageIO (`CGImageSource`), hardware-assisted on Apple Silicon. libjpeg-turbo is an alternative. VideoToolbox also decodes JPEG but is overkill. |
| Display | Simplest: set a `CGImage` as `CALayer.contents`, or use an `NSImageView`. Best control: `MTKView` with a Metal texture, the right choice for GPU histograms, zoom, focus peaking, or false color. |
| Overlays | Focus frames, grid, level and histogram as `CALayer`s or SwiftUI shapes over the image, or in the Metal shader |
| Pacing | "Latest frame wins" mailbox. Drop stale frames rather than queueing, so latency stays low. |

Start with the CALayer approach; move to Metal only when adding image-analysis tools.

## Language options for the GUI

- **Swift with SwiftUI and AppKit**: most native; recommended. SwiftUI for most of the UI, AppKit or Metal for the viewfinder surface.
- **Objective-C / Objective-C++**: works fine and is the easiest way to mix directly with C++. A legacy choice for new UI code.
- **C++ with Qt**: cross-platform, no bridge, but less Mac-native and loses SwiftUI conveniences. Reasonable only if Windows or Linux matter later.
- **Rust, Electron, Flutter**: possible, but add a second bridge for little benefit.

## Bridging C++ to Swift

Swift 5.9+ has native C++ interop, but it does not remove the need for a wrapper:

- CrSDK uses callback interfaces implemented by subclassing a C++ class, such as `IDeviceCallback`. Swift cannot subclass C++ classes.
- The SDK headers are large and use types Swift's importer handles poorly.

Three forms of shim:

1. **C++ shim exposing a plain C API**, imported directly by Swift. Simplest and most stable. The shim implements the callbacks, owns the live-view thread, and calls back into Swift through function pointers.
2. **Objective-C++ wrapper (`.mm`) exposing an Objective-C class** with delegate methods or blocks. Swift sees an ordinary class. Most idiomatic; easy to hand back `CGImage` or `IOSurface` frames.
3. **Swift C++ interop over a small hand-written C++ facade.** Workable, but more toolchain fragility.

Choice: option 2 (or 1 as fallback). A Swift package or Xcode target holds the `.mm` wrapper; the SDK dylibs are embedded in the app bundle and code-signed.

**Process isolation:** running the SDK in a helper process behind XPC isolates crashes in a closed-source binary and avoids hardened-runtime or entitlement conflicts, at the cost of some latency and complexity. Not the starting point, but keep the wrapper interface narrow enough to move later.

## Model usage note

Sonnet is sufficient for the spike: mostly well-trodden work (C++ CLI against an SDK, an Objective-C++ wrapper, a small SwiftUI view, code signing), and failures will likely be camera or USB issues rather than reasoning problems. Consider Fable for the Phase 2 decisions (SDK callback threading model, in-process vs. XPC, Metal pipeline design) and for an architecture review before committing to the full app, since those are hard to reverse.
