import AppKit
import CaptureCore
import Foundation

extension CameraModel {
    /// Scripted run for hardware testing (`--autotest <folder>`): exercises the same model methods
    /// the buttons call. Fires three real shots: a capture-mode stack (open marker, two photos,
    /// close marker) into `destination`, then one exploring-mode shot.
    func runAutoTest(destination: URL) {
        Task { @MainActor in
            func log(_ s: String) { print("AUTOTEST: \(s)") }
            func waitFor(_ what: String, timeout: Double = 90, _ cond: () -> Bool) async -> Bool {
                let end = Date().addingTimeInterval(timeout)
                while Date() < end { if cond() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
                log("TIMEOUT waiting for \(what)")
                return false
            }
            func finish(_ ok: Bool) { log(ok ? "PASS" : "FAIL"); NSApp.terminate(nil) }

            try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            guard await waitFor("camera connection", timeout: 120, { self.state == .connected }) else { return finish(false) }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            log("connected; \(statsLine)")

            settings.mode = .capture
            settings.destinationPath = destination.path
            settings.photoDescription = "autotest stack"

            // A marker is stamped just after the previous photo's time, so it needs one photo first.
            toggleStack()
            log("stack toggle before any photo -> error shown: \(errorMessage != nil)  stackOpen=\(stackOpen)")
            errorMessage = nil

            let spacing = 8.0  // seconds between shots; the camera ignores presses while it is still busy writing
            func shootChecked(_ label: String) async -> Bool {
                errorMessage = nil
                log("\(label): pressing")
                shoot()
                guard await waitFor("\(label) to fire", timeout: 20, { !self.awaitingCapture }) else { return false }
                if let e = errorMessage { log("\(label) DID NOT FIRE: \(e)"); return false }
                log("\(label): camera reported the exposure")
                return true
            }

            var lastCount = 0
            func deliveredCount() -> Int {
                ((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).filter { !$0.hasPrefix(".") }.count
            }

            guard await shootChecked("shot 1 (capture, clock learning)") else { return finish(false) }
            guard await waitFor("shot 1 delivery", { self.shotsInFlight == 0 && deliveredCount() > lastCount }) else { return finish(false) }
            lastCount = deliveredCount()
            log("shot 1 delivered: \(lastMessage); last camera time: \(settings.lastCameraTime?.exifDateTime ?? "none")")

            log("open stack")
            toggleStack()
            guard await waitFor("opening marker", { deliveredCount() > lastCount }) else { return finish(false) }
            lastCount = deliveredCount()
            log("\(lastMessage)")

            try? await Task.sleep(nanoseconds: UInt64(spacing * 1e9))
            guard await shootChecked("shot 2") else { return finish(false) }
            guard await waitFor("shot 2 delivery", { self.shotsInFlight == 0 }) else { return finish(false) }
            try? await Task.sleep(nanoseconds: UInt64(spacing * 1e9))
            guard await shootChecked("shot 3") else { return finish(false) }
            log("close stack requested while \(shotsInFlight) photo(s) in flight (marker must wait)")
            toggleStack()
            guard await waitFor("two photos and the closing marker", timeout: 120, { deliveredCount() >= lastCount + 5 && self.shotsInFlight == 0 }) else { return finish(false) }
            lastCount = deliveredCount()
            log("stack delivered: \(lastMessage)")

            try? await Task.sleep(nanoseconds: UInt64(spacing * 1e9))
            settings.mode = .exploring
            let before = lastDelivered
            guard await shootChecked("exploring shot") else { return finish(false) }
            guard await waitFor("exploring delivery", { self.shotsInFlight == 0 && self.lastDelivered != before }) else { return finish(false) }
            log("exploring delivered to \(lastDelivered?.path ?? "?")")

            log("errors: \(errorMessage ?? "none")")
            finish(errorMessage == nil)
        }
    }
}
