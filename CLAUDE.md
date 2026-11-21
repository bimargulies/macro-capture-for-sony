# capture-for-fun-and-profit

A macOS replacement for Sony's Imaging Edge, controlling the user's Sony A7R V (ILCE-7RM5) via Sony's Camera Remote SDK (C++). The A7 III is not supported by the SDK.

## Decisions so far

- GUI in Swift (SwiftUI/AppKit, Metal later if needed). SDK wrapped by an Objective-C++ shim.
- Still images only; live view is a JPEG poll loop.
- Phase 1 spike is done (see PLAN.md): live view 30 fps, auto-reconnect, manual rotate needed. Reference code is in `spike/`.
- The real app is in `app/` (SwiftPM, Swift + Objective-C++ shim). Build the bundle with `app/bundle.sh`; run `open "app/build/Capture Viewfinder.app"`.
- Gotchas: never call the SDK's `Init()` twice in one process (crashes); always disconnect before exit; quit Adobe Bridge before running.
- Sony SDK lives in `third_party/` (gitignored, license-restricted); never commit it.

See [PLAN.md](PLAN.md) for the plan, open items, and the full background and rationale.
