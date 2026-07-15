import AppKit
import CoreGraphics

/// Launch-time preflight and guided fix-up flow for the Screen Recording
/// permission (ScreenCaptureKit's system-audio capture is gated by it).
/// Covers both fresh installs and upgrades where a signing-identity change
/// invalidated the old grant — in that case the Settings toggle looks ON
/// but is stale, and capture fails silently.
@MainActor
enum ScreenRecordingPermission {

    static var hasAccess: Bool { CGPreflightScreenCaptureAccess() }

    private static let settingsURL = URL(string:
        "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!

    static func openSettings() {
        NSWorkspace.shared.open(settingsURL)
    }

    /// Show guidance when access is missing. Called once per launch.
    static func checkAtLaunch() {
        guard !hasAccess else { return }
        Log.write("preflight: no Screen Recording access — showing guidance")

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Allow Screen Recording to capture system audio"
        alert.informativeText = """
        MeetRec uses the macOS Screen Recording permission to record system audio. No video is ever saved.

        • New install: click "Open Settings" and enable MeetRec in the list.
        • Upgraded from an older version: the old grant is stale — toggle MeetRec OFF and back ON.

        MeetRec will offer to relaunch once access is granted.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        // On fresh installs this fires the system prompt and adds MeetRec
        // to the Screen Recording list; on stale grants it's a no-op.
        CGRequestScreenCaptureAccess()
        openSettings()
        pollUntilGranted()
    }

    /// Watch for the grant while the user is in System Settings, then offer
    /// a relaunch — the permission only takes effect on the next launch.
    private static func pollUntilGranted() {
        Task { @MainActor in
            for _ in 0..<90 {  // up to 3 minutes
                try? await Task.sleep(for: .seconds(2))
                if hasAccess {
                    offerRelaunch()
                    return
                }
            }
            Log.write("preflight: gave up waiting for Screen Recording grant")
        }
    }

    private static func offerRelaunch() {
        Log.write("preflight: Screen Recording granted — offering relaunch")
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Screen Recording enabled"
        alert.informativeText = "macOS applies the permission on the next launch. Relaunch MeetRec now?"
        alert.addButton(withTitle: "Relaunch Now")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            relaunch()
        }
    }

    private static func relaunch() {
        let path = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.5; /usr/bin/open \"\(path)\""]
        try? task.run()
        NSApp.terminate(nil)
    }
}
