# Macro Capture for Sony

A macOS replacement for Sony's Imaging Edge, controlling the user's Sony A7R V (ILCE-7RM5) via Sony's Camera Remote SDK (C++). The A7 III is not supported by the SDK.

## Decisions so far

- GUI in Swift (SwiftUI/AppKit, Metal later if needed). SDK wrapped by an Objective-C++ shim.
- Still images only; live view is a JPEG poll loop.
- Phase 1 spike is done (see PLAN.md): live view 30 fps, auto-reconnect, manual rotate needed. `spike/` now holds only the focus-peaking experiments (`cli/focusprobe.cpp`, `peaking/peaksim.swift`) and the read-only meter probe (`cli/meterprobe.cpp`, for a Sony support question); the rest of the spike code is in git history at `c72ebaf`.
- The real app is in `app/` (SwiftPM, Swift + Objective-C++ shim). Build the bundle with `app/bundle.sh`; run `open "app/build/Macro Capture for Sony.app"`.
- Gotchas: never call the SDK's `Init()` twice in one process (crashes); always disconnect before exit; quit Adobe Bridge before running.
- Sony SDK lives in `third_party/` (gitignored, license-restricted); never commit it.
- Idea to try someday: wired Ethernet through a hub instead of USB. The SDK's compatibility table (v2.02.00) lists the A7R V for USB and wireless only, but the user has run this camera on wired Ethernet with Sony's app, so it may work. Untested with our app. To test: unplug USB, turn off SSH authentication on the camera (the shim passes no SSH credentials yet), and launch with `CAM_SERIAL` unset so enumeration finds it.
  - 2026-11-27 attempts. Wired LAN: the camera never got an IP address (no DHCP lease, and a manual 192.168.0.240 did not show either). Wi-Fi: with PC Remote's connection method set to Wi-Fi Access Point, the SDK found the camera by IP (it opened ports 15740 and 64321, reported pairing Necessary and SSH off), but Connect failed with `Connect_FailRejected`, which the SDK docs call a pairing error. Never connected.
  - Pairing, per the SDK's environment_setup docs: on the camera, open Network > PC Remote Function > Pairing, then call Connect from the Mac while that screen is up, choose OK on the camera, then turn the camera off for about 10 seconds (it saves the pairing only at power-off). Untried: the next attempt should start here. Enumeration over the network can come back empty at first; retry it.

See [PLAN.md](PLAN.md) for the plan, open items, and the full background and rationale.

## Commands

- Unit tests (no camera needed): `cd app && swift test` (needs ExifTool installed for some tests).
- Build the signed app: `cd app && ./bundle.sh` (signs with the "Capture Dev" keychain identity when present, else ad hoc; a stable identity keeps Little Snitch rules valid across rebuilds) (needs `brew install exiftool` so it can be bundled).
- Restart the app: `pkill -x Viewfinder` (SIGTERM is handled, so it disconnects cleanly), wait for it to exit, then `open "app/build/Macro Capture for Sony.app"`. After every change that rebuilds the bundle, always offer to restart the app.
- Hardware test (camera on, Adobe Bridge quit, manual focus, 3 real shots into a scratch folder): `app/build/Macro\ Capture\ for\ Sony.app/Contents/MacOS/Viewfinder --autotest <folder>`.

## Linting

- Swift: `cd app && swiftlint lint` (config in `app/.swiftlint.yml`).
- C++/Objective-C++ shim: `cd app && /opt/homebrew/opt/llvm/bin/clang-tidy Sources/CCameraShim/CameraBridge.mm -- -x objective-c++ -std=c++17 -fobjc-arc -isysroot "$(xcrun --show-sdk-path)" -ISources/CCameraShim/include -Isdk/app/CRSDK` (config in `app/.clang-tidy`). cppcheck does not understand Objective-C++.
- C++/Objective-C++ format: `cd app && /opt/homebrew/opt/llvm/bin/clang-format --dry-run --Werror Sources/CCameraShim/CameraBridge.mm Sources/CCameraShim/include/CameraBridge.h` (config in `app/.clang-format`; replace `--dry-run --Werror` with `-i` to fix). Every `if`, `else` and loop body uses `{}`, with opening braces on the same line. `spike/` is experimental code and is exempt.
- Races: `cd app && swift test --sanitize=thread` (covers CaptureCore only; the camera code needs a hardware run).
- Shim rules: no owning raw pointers (use `unique_ptr`/`shared_ptr` with the SDK's `Release()` as deleter); every SDK call holds `_devLock` shared, and Connect/Disconnect/ReleaseDevice hold it exclusive.

## Rules

- Never modify an ARW. Every delivered `CAP-` ARW gets a sidecar `.xmp` (description, if any) written AFTER the ARW; the importer waits for it. Markers are stamped previous-item time + 1 ms (no clock sync) and carry a marker keyword in their sidecar. Never write ARW metadata with Exiv2 (it destroys Sony's private data; see PLAN.md).
- The importer is a separate project at `../import-sony-raw-photos` (it has its own CLAUDE.md: bump `version` with every change, commit it, run `pnpm install-bridge`).
