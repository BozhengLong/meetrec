import SwiftUI
import AppKit

@main
struct MeetRecApp: App {
    @StateObject private var engine = RecordingEngine()
    private let hotkeys = HotKeyManager()

    init() {
        // Hide dock icon — this is a menu-bar-only app.
        NSApplication.shared.setActivationPolicy(.accessory)
        Log.reset()
        // Preflight Screen Recording access shortly after launch so missing
        // or stale (post-upgrade) grants get guided fix-up before the first
        // recording silently loses system audio.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            ScreenRecordingPermission.checkAtLaunch()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
                .onAppear { wireHotkeys() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: iconName)
                if engine.isRecording {
                    Text(timeString(engine.elapsed))
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                }
            }
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        guard engine.isRecording else { return "record.circle" }
        // A recording missing system audio outranks mute states — the user
        // must notice before the meeting ends.
        if engine.systemAudioFailed { return "exclamationmark.circle.fill" }
        switch (engine.systemMuted, engine.micMuted) {
        case (false, false): return "record.circle.fill"
        case (false, true):  return "mic.slash.circle.fill"
        case (true,  false): return "speaker.slash.circle.fill"
        case (true,  true):  return "circle.slash"
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func wireHotkeys() {
        hotkeys.unregisterAll()
        hotkeys.register(.optCmdM) {
            engine.micMuted.toggle()
        }
        hotkeys.register(.optCmdS) {
            engine.systemMuted.toggle()
        }
        hotkeys.register(.optCmdR) {
            engine.toggle()
        }
    }
}
