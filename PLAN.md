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

> **Spike code removed:** `spike/app/`, `spike/cli/probe.cpp` and `spike/cli/shoot.cpp` no longer exist, though this file still mentions them as history. Commit `c9c30f2` is the last one containing them (for example, `git show c9c30f2:spike/cli/probe.cpp`). Only the focus-peaking experiments remain in `spike/`.

The real app now lives in `app/` (copied from the spike). `app/bundle.sh` builds `app/build/Macro Capture for Sony.app`; `SIGN_ID="<identity>" ./bundle.sh` signs with a real identity (default is ad hoc). Launching it with `open` connects and shows live video at 30 fps.

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

## In progress: verify the app rename on the Mac with the camera

The app was renamed and passes unit tests, but has not been launched or tested on the camera. Delete this section when done. On the Mac connected to the camera:

1. Quit Adobe Bridge and any running copy of the app, then `git pull --ff-only origin main`.
2. Copy this Mac's saved settings to the new bundle ID, only if it has none yet: `defaults read local.macro-capture-for-sony >/dev/null 2>&1 || defaults export local.capture.viewfinder - | defaults import local.macro-capture-for-sony -`. Skip this if `local.capture.viewfinder` does not exist. Keep the old domain.
3. `cd app && swift test && ./bundle.sh`. The Sony SDK in `third_party/` is not in git, so it must already be on this Mac. Check that the build reports the "Capture Dev" identity.
4. With the camera on and in manual focus, run the hardware test into a new, empty scratch folder: `app/build/Macro\ Capture\ for\ Sony.app/Contents/MacOS/Viewfinder --autotest <folder>`. It takes 3 real shots.
5. Ask the user to `open "app/build/Macro Capture for Sony.app"`, approve any macOS or Little Snitch prompts, and confirm the window title, live view, and restored rotation, description, and window position.
6. If all of that passes, delete the old `app/build/Macro Sony Capture.app` on this Mac, then ask the user before doing the repo rename below. Every clone needs its own `origin` update and folder move.

## Planned: rename the GitHub repo and local folder

The product is now "Macro Capture for Sony". The repo is still `capture-for-fun-and-profit`; the new name is `macro-capture-for-sony` (not taken as of 2026-11-23). Do these after the rename commit is pushed:

1. `gh repo rename macro-capture-for-sony --repo bimargulies/capture-for-fun-and-profit` (GitHub redirects the old URL).
2. `git remote set-url origin git@github.com:bimargulies/macro-capture-for-sony.git`, then `git fetch` to confirm.
3. Quit VS Code and Claude Code, then `mv ~/work/capture-for-fun-and-profit ~/work/macro-capture-for-sony` and reopen the new folder.
4. Delete `app/.build` and `spike/cli/build`, which contain absolute paths, then rebuild with `app/bundle.sh`.
5. Claude Code keys its history and memory by folder path, so the new folder starts a fresh project.

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

# Phase 2: shooting and delivery (implemented and tested on the camera)

Requirements (from user, 2026-11-21): a half-press and a full-press shutter control; two modes, **exploring** and **capture**; a **start stack / stop stack** button; a description text box that ends up in the file's description metadata. No camera-setting controls yet.

## Design decision: descriptions go in a sidecar .xmp, ARW files are never modified (2026-11-21)

Decided by the user after the tests below. Writing into the ARW works with ExifTool but is fragile (Sony's private offset tables; Exiv2 broke them) and a firmware change could break any rewriter. So:

- The app **never modifies an ARW**. Delivered ARWs are byte-identical to what the camera produced (a test asserts this).
- A description is saved in `CAP-yyyyMMdd-NNNN.xmp` beside `CAP-yyyyMMdd-NNNN.ARW` (the Adobe convention Bridge/Lightroom read), as XMP `dc:description` (lang `x-default`). The app writes this text itself (`XMPSidecar`); **ExifTool is no longer used to write anything in the app**, only to read the camera's capture time.
- **Order matters: the sidecar is placed first, then the ARW** (each by atomic rename), so the importer never sees a photo without its description.
- The importer (`../import-sony-raw-photos`, v0.6.0, committed there) finds the sidecar (`X.xmp` or `X.ARW.xmp`, case-insensitive), reads the description with ExifTool, writes it into the DNG's IPTC caption, XMP description and EXIF description (dnglab drops them), and deletes the sidecar with the ARW. It falls back to description fields embedded in the ARW. Tested end to end with a real ARW, accents, `<>&"` and Japanese.
- Exploring mode writes no sidecar. Stack markers have none.

## Design update: no clock sync, sidecar last and always, watcher waits (2026-11-21)

Changes decided after the first hardware test (user concerns: clock sync, and slow NAS writes):

1. **Markers are stamped from the previous item, not from a clock.** A marker's EXIF time is the previous delivered photo's (or marker's) own camera time **plus 1 ms**, so it sorts right after that photo and before whatever comes next, whatever the camera's or the Mac's clock says. The last camera time is remembered between runs (UserDefaults); the very first marker still needs one photo taken first. `CameraClock` and the learned offset are gone. (A sidecar tag alone cannot fix ordering, because the importer sorts by EXIF time; this does.)
2. **Every `CAP-` ARW gets a sidecar `.xmp`, even with no description, written AFTER the ARW.** The sidecar means "this photo is complete and visible", which is robust on a NAS where a big file can show up late or out of order. If the sidecar write fails (3 tries), the photo is kept and a warning is shown; the importer then gives up waiting after its timeout.
3. **A marker's sidecar carries the keyword `capture-viewfinder:stack-marker`** (XMP `dc:subject`) and a readable title, so the importer treats it as a marker without judging the picture.
4. **The watcher (import-sony-raw-photos 0.7.0) waits for the sidecar of any file starting with `CAP-`**, up to 30 minutes (`--sidecar-wait`, `--sidecar-prefix`). While one waits, **everything captured after it is held back** (otherwise a stack could be split). After the wait: imported without a description, with a warning. Verified with real ARWs through multi-scan scenarios (wait, hold back, release, give-up, tag-only markers).
5. Fixed a bug found on the way: the importer left a marker's sidecar behind.

Supersedes the earlier "sidecar first, then ARW" and "marker times use the camera's clock offset" statements below.

## Test shot results (2026-11-21, A7R V, `spike/cli/shoot.cpp`)

- **A full press alone (S2 Down/Up) did nothing**, even in manual focus: no capture event, no download. **S1 lock first, then S2 Down/Up, then S1 unlock** fired the shutter. So the app's shutter button must send S1 before S2 (or use `CrCommandId_S1andRelease`, **not yet tested**). A 1.5 s pause after S1 was used in the test (manual focus, no focus confirmation to wait for); the minimum pause needed is unknown.
- Timeline: `CrNotify_Captured_Event` (via `OnWarning`, 0x20011) at about the moment of release, then `OnCompleteDownload` about **2 s later** with the full path. The file was a **65.7 MB compressed ARW** (9600x6376 raw), only the ARW (the camera's file type was RAW, so no JPEG arrived even though `RAW_J_PC_Save_Image` was RAW+JPEG).
- The camera was already set to save to PC and card (`StillImageStoreDestination` = 0x3), so the test changed no camera settings.
- ARW structure (ExifTool): IFD0 `PreviewImage` (141 KB), IFD2 `JpgFromRaw` (4 MB), SubIFD raw strip (61 MB), empty `ImageDescription` slots.
- **Camera clock is one hour ahead of this Mac** (EXIF `DateTimeOriginal` 14:54:39 at about 13:55 Mac time). Not a problem for shots, but see markers below.

## Description metadata: verified

On a copy of the real ARW, `exiftool -overwrite_original -IPTC:Caption-Abstract=... -XMP-dc:Description=... -EXIF:ImageDescription=...`:

- Takes 0.18 s; all three fields read back; the **raw image data is bit-identical** (`ImageDataMD5` unchanged).
- ExifTool rewrites the file (23 KB smaller, raw strip offset moved), and the 6 `-validate` warnings it prints are **also present in the camera's original**, so they are not caused by the edit.
- **`dnglab convert` (what the importer uses) drops all three description fields.** The DNG from the described ARW has no description at all. Copying them across afterward works: `exiftool -overwrite_original -tagsFromFile src.ARW -IPTC:Caption-Abstract -XMP-dc:Description -EXIF:ImageDescription out.dng` (raw data still identical). **So the importer in `../import-sony-raw-photos` needs this extra step for the description to survive.** (Not edited; separate project, to be agreed with the user.)
- **Not yet tested:** reading the description back in Adobe Bridge.
- Conclusion: ARW can carry the description, no DNG wrapping is needed on our side, and ExifTool is a good tool for the job.

## What the importer expects (from `../import-sony-raw-photos`)

- It reads `.ARW` files, sorts them by **EXIF `DateTimeOriginal` plus `SubSecTimeOriginal`** (capture order), and converts them to DNG with `dnglab`.
- A **marker is a real photo, a black frame** (lens cap on): it extracts the embedded JPEG (`exiftool -b -PreviewImage`, falling back to `-JpgFromRaw`, then `-OtherImage`), shrinks it to 64x64, and calls it black if the **center half has mean luma <= 12 and standard deviation <= 5**. Markers come in **open/close pairs**: the first opens a stack, the next closes it; markers are deleted without a DNG, and the photos between them go into `stack-NNN/`. A marker that closes an empty stack triggers a warning.
- It also checks the file is **complete**: from `StripOffsets`/`StripByteCounts` in any IFD, the data must end inside the file; otherwise it is "incomplete" and skipped until it grows. Our delivery must therefore move files into the watched folder only when finished (the atomic-rename plan already does this).
- It needs `ImageWidth`/`ImageHeight` for non-markers and a usable `DateTimeOriginal` for everything.
- Implications for our **synthetic black marker ARW**:
  - It must be a valid TIFF-based ARW that ExifTool reads, with `Make`/`Model`, an `ExifIFD` with `DateTimeOriginal` and `SubSecTimeOriginal`, one or more strip offsets/counts that fit inside the file, and an **embedded black JPEG preview** in a place ExifTool exposes as `PreviewImage` (IFD0 in real files).
  - **Its timestamps must be on the camera's clock** (which is an hour off from the Mac here) so that it sorts correctly between the shots: derive the offset from the previous shot's `DateTimeOriginal` against the Mac time when it arrived, or read the camera clock through the SDK. Marker times must fall strictly between the last shot of a stack and the next one (and the closing marker after the last shot).
  - Cheapest build: a small hand-written TIFF writer in Swift (a few hundred bytes of structure plus a tiny black JPEG). Acceptance test: run the importer's own `detectBlackFrame` and `checkComplete` against our generated files, and `exiftool -validate`. Alternative (wasteful, 60+ MB per marker): clone a real ARW and replace the preview.

## Bundling ExifTool

- ExifTool has **no C/Swift SDK**; it is a Perl library with a command-line script (`Image::ExifTool`). The practical ways to use it from an app are: (a) bundle the script and its `lib` folder (about 19 MB for `lib/perl5/Image/ExifTool`, which can be pruned, e.g. language files) inside the `.app` and run it with the system Perl at `/usr/bin/perl` (5.34 on this Mac, still present on macOS 27); (b) require it to be installed (the importer already requires `exiftool` on `PATH`, here from Homebrew at `/opt/homebrew/bin/exiftool`); (c) link a different library (Exiv2 is C++ but its ARW writing is limited and less proven) or write our own TIFF/XMP code.
- Recommendation: (a) with fallback to a user-installed copy, run with `-stay_open True -@ -` (one long-lived process) if we ever call it often. Per-call cost is about 0.2 s, fine for per-shot use. Risk to note: Apple has been deprecating the system Perl and may remove it in a later macOS; ExifTool's license (Artistic/GPL) allows bundling with attribution.

## Exiv2 evaluated and rejected for writing ARW (2026-11-21)

Tested Exiv2 0.28.9 (Homebrew; GPL-2.0-or-later) on a copy of a real A7R V ARW, writing the same three description fields with `exiv2 -M"set ..." modify`.

- Description fields write and read back, and the raw image data hash is unchanged.
- **But the Sony private block (`SR2Private`) is destroyed:** ExifTool reports "Bad format for SR2Private entry N" and then stops parsing it; the file had **1321** SR2 tags before and after the ExifTool edit, and **0** after the Exiv2 edit. That block holds white balance, color matrices and black level.
- **`dnglab convert` then fails** ("Couldn't find tag SonyOffset") on the Exiv2-edited file; it works on the original and on the ExifTool-edited file. The importer would fail on every described photo.
- Cause (likely): Exiv2 relocates the SR2 data without fixing the offsets stored inside it; ExifTool rewrites them (it changed `SR2SubIFDOffset`/`HiddenDataOffset` and the block still parses).
- Other considerations (moot now): Exiv2 would have removed the Perl dependency and run in-process, but is GPL and does not help the importer, which needs ExifTool anyway.
- **Decision: use ExifTool for all ARW metadata writes.** Keep the metadata code behind one small interface so a different backend could be tried later, but never write ARW with a tool that has not passed this test (raw hash, SR2 tag count, `dnglab` conversion).

## What the SDK provides (from the API reference and headers)

- **Half press (S1):** device property `CrDeviceProperty_S1`, value `CrLockIndicator_Locked` / `Unlocked` (lock = button held half-down). A UI "hold to half-press" button can set Locked on mouse-down and Unlocked on mouse-up, like the physical button.
- **Full press (S2):** command `CrCommandId_Release` with `CrCommandParam_Down` then `Up` (the docs say Down must be followed by Up). `CrCommandId_S1andRelease` does S1 plus S2 in one command.
- **Image transfer to the Mac:** set `CrDeviceProperty_StillImageStoreDestination` to `HostPC` (or `HostPCAndMemoryCard`). Then each capture is transferred automatically into the folder given to `SetSaveInfo(path, prefix, startNo)`, and the SDK calls `OnCompleteDownload(filename)` with the stored path. `CrNotify_Captured_Event` (in `OnWarning`) fires earlier, when the image is in camera memory.
- **What gets transferred** for RAW+JPEG shooting is `CrDeviceProperty_RAW_J_PC_Save_Image` (RAW and JPEG / JPEG only / RAW only / with HEIF). To get only the ARW on the Mac this should be RAW Only. (Camera settings are out of scope for now, but this one decides what arrives.)
- Related status: `CrDeviceProperty_FocusIndication` (focus lock result), live-view focus frames.

## Delivery pipeline

The SDK always writes to a **staging folder** we own, never directly to the final destination. `OnCompleteDownload` then hands the file to our pipeline on a background queue:

- **Exploring mode:** leave (or move) the ARW in a local temporary folder (e.g. under `~/Library/Caches/<app>/exploring/`), tell the UI so a later high-fidelity viewer window can open it (decode via Core Image's RAW engine, to be verified for the A7R V). Purge old files by age/size at launch.
- **Capture mode:** apply the description metadata, name the file from our own counter, then **move it into the destination folder atomically** (write elsewhere, then rename), so downstream tools (stacking software, Bridge) never see a half-written file. Destination comes from a preference (folder chooser in Settings). If the destination is unavailable (e.g. unplugged drive), keep the staged file, show an error, and retry or let the user pick again; never lose a shot.
- Mode switching only changes where the pipeline routes the next file; the SDK keeps writing to staging. Mode is visible in the main window and ideally remembered.
- File naming: we control a counter per destination folder (scan for the highest existing number at start) so ARW files and the black marker images share one ordered sequence.

## Start stack / stop stack

- A toggle button. Press 1 ("Start stack"): write a **black marker image** into the destination folder and relabel to "Stop stack". Press 2: write a second black image, relabel back. Marker images must sort into the same name sequence as the shots so stack boundaries are in the right place.
- Presumably only meaningful in capture mode (disabled in exploring mode). Confirm.
- Open: marker file format and size (see questions below). A JPEG/PNG/TIFF is trivial; a black DNG or ARW is more work.

## Description metadata

- **Can an ARW carry IPTC?** Yes in principle: ARW is TIFF-based, and the IPTC block lives in the TIFF tag `0x83BB` (plus XMP, plus EXIF `ImageDescription`). ExifTool 13.55 (installed here, `/opt/homebrew/bin/exiftool`) lists ARW as writable. **Not yet verified on a real ARW** (none on this machine): the first real capture must be used to test writing, reading back in Adobe Bridge (the user's tool), and that the raw data is untouched.
- Fields to write for "description": IPTC `Caption-Abstract`, XMP `dc:description`, and EXIF `ImageDescription`, so Bridge, Lightroom and others all show it. (Confirm with user which field they actually look at.)
- **How to write it in the app:** (a) bundle ExifTool (a Perl script plus libraries, about 30 MB with homebrew's Perl dependency; or require it installed), (b) write an XMP sidecar (`.xmp` next to the ARW), which is non-destructive and read by Bridge/Lightroom/Capture One but not every tool, or (c) our own small TIFF/XMP writer (more work, more risk).
- **DNG fallback** (only if in-place ARW writing is unsafe or rejected): Adobe DNG Converter (the user has Adobe software) can wrap ARW to DNG on the command line and preserves metadata, so write the description into the ARW first and then convert; or use the DNG SDK. A DNG changes the raw container and may be unwelcome for stacking workflows, so prefer ARW.

## UI sketch

Under the viewfinder: mode selector (Exploring / Capture) with the destination shown in capture mode; a "hold for half-press" button and a "Shutter" button (also keyboard shortcuts, e.g. space for shutter); a Start/Stop stack button; a description text field (kept across shots until edited). Settings: destination folder (and later naming, staging retention). Status line: last delivered file, transfer progress, errors.

## Risks and things to measure

- Transfer time of a full-size A7R V ARW over USB (tens of MB; likely seconds) and what live view does during and after an exposure (freeze, blackout, resume).
- Back-to-back shots while the previous one is still transferring (queueing); whether the camera buffers.
- Sony's callbacks arrive on SDK threads; the pipeline must hand off immediately and never block them.
- Camera must be in a mode that allows remote release (dial and lens switch states).
- Destination on a slow or external volume must not block the UI or lose files.

## Proposed order of work

1. **Test shot with Sony's sample** (needs your OK to fire the shutter) to get a real ARW, then test ExifTool IPTC/XMP writing and Bridge readback. This decides the metadata approach before any UI.
2. Shim: S1 property, S2 command, set destination and `SetSaveInfo`, expose `OnCompleteDownload` and capture events to Swift.
3. Swift: staging, exploring/capture routing, atomic move, counter; Settings for destination.
4. UI controls, stack markers, description field.
5. Measure transfer time and live view behavior around exposures.

## Phase 2 implementation status (2026-11-21)

Built in `app/` (all uncommitted at the time of writing):

- `Sources/CaptureCore` (pure Swift, 25 unit tests, `swift test` from `app/`): `NaiveTime`/`CameraClock` (camera clock offset), `MarkerARW` (black marker ARW writer), `XMPSidecar`, `ExifTool` (read-only: capture time), `DeliveryPipeline` (staging, exploring/capture routing, atomic placement, naming `CAP-yyyyMMdd-NNNN.ARW`, never overwrites, keeps the staged file on any failure).
- Shim (`CameraBridge`): `setSaveFolder`, `setHalfPress`, `fullPress`, capture and download delegate events, and a check at connect that the camera sends photos to the Mac (it switches a card-only camera to "Mac and card" and says so).
- App: Exploring/Capture picker, Half-press (hold) button, Shutter (full press; presses half-way first if not held), Start/Stop stack, description field, Settings window for the destination folder, status and error banner, settings in UserDefaults. A shot's mode, destination and description are **captured at the press** (not when the file arrives).
- Stack markers wait until all photos in flight have been delivered (the importer closes a stack at the closing marker, so a late photo would fall outside it). Marker times are the previous item's camera time plus 1 ms (see "Design update" above); the first marker needs one photo taken first.
- Verified with the real importer: generated markers are recognized as black frames and complete; a stack of open marker, photos, close marker imports into `stack-001` with descriptions, markers removed.
- ExifTool is bundled into the `.app` (`Resources/exiftool`, about 20 MB, run with `/usr/bin/perl`); `bundle.sh` proves the bundled copy runs with a clean environment.
- `--autotest <folder>` runs 3 real shots (a stack of two with markers, one exploring) into a scratch folder with throwaway preferences (Adobe Bridge must be closed first). **Passes on the A7R V** (see below).
- Not done: rotate control, JPEG viewer window for exploring files, minimum S1 settle time (currently 1 s), `S1andRelease` untested, purging staging leftovers at launch, per-shot progress UI beyond a counter.

## Hardware test results: `--autotest` on the A7R V (2026-11-21)

Passing run: shot 1 (capture, description "autotest stack"), opening marker, shot 2, shot 3, closing marker (which waited for shot 3's transfer), then one exploring shot. Verified afterwards:

- Destination had `CAP-...0001.ARW/.xmp`, `0002.ARW` (marker), `0003.ARW/.xmp`, `0004.ARW/.xmp`, `0005.ARW` (marker); no hidden partial files; staging empty; the exploring shot in `~/Library/Caches/Capture Viewfinder/exploring/` with no sidecar.
- **Delivered ARWs are untouched**: 1321 SR2 tags and no `SR2Private` warnings, same as the camera's original; `dnglab` converts them.
- **The real importer** turned it into: shot 1 as a normal photo, `stack-001` with shots 2 and 3, markers consumed, no warnings, all three DNGs carry the description.
- Timing: the capture signal arrives at the shutter press, the ARW (about 66 MB) finishes transferring about 1.5 to 2 s later.
- The camera's clock is **about 3553 s ahead of this Mac** (59 min 13 s, not an exact hour), learned automatically from each shot's EXIF time; markers are stamped on the camera's clock.

**Finding: the camera ignores a press made soon after a capture.** In two runs a press about 3 s after the previous exposure produced no capture signal (the SDK accepted the commands without error); presses 5 s or more after worked, and with 8 s spacing every shot fired. The cause is not known (probably busy writing the 66 MB file to the card; manual focus, so not focus priority). The minimum safe interval has **not been measured**. Consequences built into the app:

- A shot with no capture signal within 8 s is dropped with an error (`captureTimeoutSeconds`); a photo that is captured but never arrives within 180 s is dropped with an error (`transferTimeoutSeconds`). Without this the "transferring" spinner and the pending closing marker waited forever (this happened in the first test run).
- Only one press at a time: the Shutter button is disabled until the previous shot has been reported by the camera, so a capture signal can always be matched to its shot (and its description).
- The first run also showed the test itself must check for errors; `--autotest` now does.

Still open: the minimum interval between shots, whether a press during the transfer ever works (Sony's own app may know), the minimum S1 settle time (1 s now), and `S1andRelease`.

## Hardware retest of the new flow (2026-11-21, after the sidecar/marker redesign)

`--autotest` again, with the importer at 0.7.0 running as the watcher. Result: the capture-mode stack part **passed**; the final exploring-mode shot did not fire, so the run reported FAIL.

- Verified on the output: marker times are the previous item's camera time + 1 ms (`15:30:17.890` photo then `.891` marker; `15:30:40.883` photo then `.884` marker), all sorted correctly; every ARW has a sidecar; markers' sidecars carry `capture-viewfinder:stack-marker`; photos carry the description; no hidden partial files; staging empty. The real importer (0.7.0 rules) imported it as: shot 1 normal, `stack-001` with shots 2 and 3, markers consumed, no warnings, descriptions on all three DNGs.
- **Intermittent non-firing, second observation:** the 4th shot of the run, pressed about 8 s after the previous transfer finished, produced no capture signal (the app dropped it after 8 s with an error, as designed). Earlier a press about 3 s after a capture failed twice, and in one earlier run 4 shots at 8 s spacing all fired. So the failure is not explained by spacing alone. Unknown cause. Things to check: a message on the camera's screen (card full, overheating), shot count, settle time (1 s) after the half-press.
- Possible follow-up: a reliability experiment (fixed series of shots at fixed spacing, logging fire/no-fire) to decide between automatic retry and just reporting.

# Research: can we do focus peaking in the viewfinder? (2026-11-21, offline; camera tests pending)

**Short answer:** yes, we can compute peaking ourselves from the live-view pixels, but the live view is too low-resolution for it to judge fine focus; it becomes useful only if the camera's focus magnifier can be driven remotely (the SDK says it can on the A7R V; not yet tried), or by checking focus on the full-resolution preview after each shot. The camera's own peaking is not available to us.

## What the SDK offers on the A7R V (ILCE-7RM5)

From `device_property_list.csv` (the support table) and the property docs:

- **Camera peaking and zebra: NOT supported on the A7R V.** `PeakingDisplay`, `PeakingLevel`, `PeakingColor` and all `Zebra*` properties are marked unsupported for ILCE-7RM5 (and 7RM4/7RM4A/7M5); the SDK release notes say they exist only for the ILX-LR1 (video body). So the camera's own peaking overlay cannot be switched on or read through the SDK.
- **Focus magnifier: supported and settable.** `CrDeviceProperty_Focus_Magnifier_Setting` carries the ratio (upper 4 bytes, from the values the camera lists, e.g. x1.0, x4.0, x8.0 as 0x0A, 0x28, 0x50) and the centre position (lower 4 bytes, x then y in a 640x480 space). Also supported: `FocusMagnificationTime`, `InitialFocusMagnifier`, `AFInFocusMagnifier`. `CrLiveViewProperty_Focus_Magnifier_Position` / `CrMagPosInfo` give the frame size. Which ratios the A7R V offers, and whether live-view frames then show the magnified region, is **untested**.
- **Live view image:** `LiveView_Image_Quality` is only Low (640 px wide) or High (1024 px wide); we already get High (1024x768). `LiveViewDisplayEffect` (picture-effect on/off) is supported.
- **OSD image** (`OSDImageMode`, `GetOSDImage`): the camera's on-screen overlay as a PNG (up to 640x480). Supported on the A7R V; its contents are **untested**. Since camera peaking is unsupported it very probably does not include peaking.
- **Focus information we do get:** `FocusIndication` (AF-S/AF-C focused / not focused, tracking; meaningful with autofocus, probably nothing in manual focus), `FocusArea`, focus-frame info with live view. **Not available: any contrast map, depth map or phase-detect data.** So camera-side focus information is limited to AF results; for manual focus we have only the image.

## Computing peaking ourselves

A simple, cheap algorithm (blur 3x3, Sobel gradient, threshold relative to the image's own noise level, paint flagged pixels red) is prototyped in `spike/peaking/peaksim.swift`. At 1024x768 and 30 fps it is trivial for the GPU (Core Image or Metal). The limitation is resolution, not computation.

Offline experiment on a real A7R V photo (the ARW's embedded 8448x6336 JPEG), simulating live view as a clean downscale to 1024x768 and the magnifier as a native-resolution 1024x768 crop:

- **At live-view scale it flags every high-contrast edge, in focus or not.** Both the sharper wire and the out-of-focus black cable were outlined equally. A soft edge only a few sensor pixels wide still looks like a crisp edge after an 8x downscale.
- **Discrimination, measured:** adding known blur at sensor scale and measuring the 99th-percentile gradient: at live-view scale it moves 1.5% at 2 to 4 px of blur, 5% at 8 px, 14% at 16 px, 30% at 32 px (so roughly 10 sensor pixels of defocus are needed to see a change). At native (magnified) scale the same measure drops 26% at 2 px and 32% at 4 px. So **a magnified view is about 5 to 8 times more sensitive**, in line with the 8.25x downscale.
- JPEG compression at the real live-view size (about 38 KB per frame) did not change the result (JPEG quality 50 gave the same flagged area as quality 80); very heavy compression flattens flat areas.
- **Caveats:** the simulation uses a clean downscale of a sharp photo; the camera's real live view is produced by its own readout and processing and may be softer still, and the test image was soft at pixel level (no truly sharp subject), so the absolute thresholds are not tuned. The magnifier case is simulated by cropping, not measured.

## Options and recommendation

1. **Peaking on the normal live view:** cheap; good for finding the subject's edges and gross focus; not reliable for fine focus (macro and stacking). Offer as a toggle, with a threshold control.
2. **Peaking or a focus score on the camera's magnified view** (drive the magnifier through the SDK): the real fix for fine focus if the magnified live view carries native detail. **Needs a camera test.**
3. **A numeric or bar-graph focus score** for a chosen region instead of painted peaking: more robust to noise and to JPEG artifacts, and easier to read for stacking.
4. **Check focus on the actual photo after each shot:** the ARW embeds an 8448x6336 JPEG; showing it at 100% in the planned exploring viewer, with peaking or a score computed on it, gives true full-resolution verification (not live). This fits the exploring-mode viewer already planned.

## To do when the camera is back on

`spike/cli/focusprobe.cpp` (built, not yet run: the camera had powered off) will: list the magnifier's possible ratios and the other focus properties, save baseline live-view frames, try the smallest and largest magnifier ratio at the frame centre (saving frames), fetch the OSD image, and restore every setting it changed (verified by read-back). Then decide whether to build option 2.

### Focus probe results (camera run, 2026-11-21)

- A7R V accepts `Focus_Magnifier_Setting` remotely. Settable ratio codes: 0xa (x1.0), 0x2f (x5.4?), 0x5d (x9.3), plus off. Setting x9.3 at the centre gave live-view frames of 1024x680 (vs 1024x768) showing a clearly magnified centre region; read-back confirmed; original value restored.
- `FocusMagnificationTime`, `OSDImageMode`, `PeakingDisplay` not readable. `FocusIndication` readable but read-only.
- So option 2 (peaking/focus score on a magnified live view) is mechanically feasible. Open: whether magnified frames carry native-resolution detail (test with a well-lit, textured subject; the test scene was very dark and the centre was featureless), and the frame rate while magnified.
- Probe saves: base_*.jpg, mag_x1_*.jpg, mag_x9_*.jpg.

## Viewer (exploring photos)

- Two tabs in one window (Capture / Viewer, ⌘1 / ⌘2); the Viewer hides the camera controls and has its own description field and status line. The Viewer shows a carousel of the last 30 exploring photos (`ViewerModel.keep`; older ones are deleted at launch and after each new shot) with the selected one large. ⌘← / ⌘→ step through; double-click toggles fit / 100%; pinch or ⌥-scroll zooms; drag or scroll pans.
- Images come from the ARW's embedded JPEGs via ExifTool (read-only): `PreviewImage` (~1.6k px, for 320 px thumbnails) and `JpgFromRaw` (the large view). They are cached in `<exploring>/.cache/` along with the EXIF orientation; the ARW is never touched.
- "Capture this photo" (⌘K) copies the ARW to the destination as a normal `CAP-` capture, using the current description, sidecar last; the exploring copy stays and gets a green check.
- Caveat: a promoted photo keeps its original camera time. If a stack is open when you capture an older exploring photo, the importer (which sorts by capture time) will not place it inside that stack.
- `--viewer` launch argument opens on the Viewer tab (for screenshots).

## Meter reading (decided 2026-11-21)

The "MM -0.7" meter value the camera shows is not available: the SDK's `MeteredManualLevel` property is absent from the A7R V's 233 properties, and the Sony app never displays any meter info either. The app does not try to show it (code removed). Bottom line: shutter, aperture, ISO, compensation.

## SDK updates

Sony publishes a dated "Notifications" list on https://support.d-imaging.sony.co.jp/app/sdk/en/index.html (no mailing list or feed that we found; check it by hand). As of 2026-11-21 the newest release is v2.02.00 (2026-06-10), the one we use; its only change is ILCE-7RM6 support. The last release with an A7R V item was v1.13.00 (2024-10-16). The page says the camera needs the latest system software.

## White balance (SDK, from the headers; not yet probed on the A7R V)

The SDK mirrors the camera: a mode plus a separate temperature.
- `CrDeviceProperty_WhiteBalance`: enum `CrWhiteBalanceSetting`: AWB, Underwater Auto; presets Daylight, Shadow, Cloudy, Tungsten, Flash; Fluorescent (plain, warm white, cool white, day white, daylight); `ColorTemp`; Custom 1-3 and Custom.
- `CrDeviceProperty_Colortemp`: kelvin, step 100 (step from `ColortempStep`); only meaningful when the mode is `ColorTemp`.
- `CrDeviceProperty_WhiteBalanceTint` (+ `WhiteBalanceTintStep`): green-magenta shift.
- Video-oriented extras, probably not reported on the A7R V: `WhiteBalanceModeSetting` (automatic/manual), `WhiteBalanceSwitch` (preset/memory A/memory B), R/B gain, offsets.
- The camera reports which modes and what temperature range it allows, so probe the A7R V before building a control.
- Possible UI: a mode picker, plus a temperature field shown only for `ColorTemp`, plus tint.
