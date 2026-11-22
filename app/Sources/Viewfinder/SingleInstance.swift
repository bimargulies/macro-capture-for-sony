import AppKit

/// Only one copy can hold the camera, so a second launch hands over to the copy already running.
/// The dev build and the installed app share a bundle identifier, so this covers both.
enum SingleInstance {
    /// Call before the camera model exists. Returns only if this is the copy that should run.
    static func enforce() {
        let me = NSRunningApplication.current
        guard let id = me.bundleIdentifier else { return }  // not in a bundle (e.g. `swift run`)
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id)
        // Defer only to an older copy, so two simultaneous launches cannot both exit.
        guard let running = others.first(where: { $0 != me && !$0.isTerminated && isOlder($0, than: me) }) else { return }

        let args = CommandLine.arguments
        if args.contains("--autotest") || args.contains("--seconds") {
            // A scripted run must not report success without having done its work.
            fputs("Another copy is running (pid \(running.processIdentifier)); quit it first.\n", stderr)
            exit(1)
        }
        bringForward(running)
        exit(0)
    }

    private static func isOlder(_ a: NSRunningApplication, than b: NSRunningApplication) -> Bool {
        if let da = a.launchDate, let db = b.launchDate, da != db { return da < db }
        return a.processIdentifier < b.processIdentifier
    }

    /// Goes through Launch Services because a just-launched, inactive app may not be allowed to activate another.
    private static func bringForward(_ app: NSRunningApplication) {
        guard let url = app.bundleURL else { app.activate(); return }
        let done = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in done.signal() }
        _ = done.wait(timeout: .now() + 3)
    }
}
