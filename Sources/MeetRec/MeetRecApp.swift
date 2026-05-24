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
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(engine: engine)
                .onAppear { wireHotkeys() }
        } label: {
            Image(systemName: iconName)
        }
        .menuBarExtraStyle(.window)
    }

    private var iconName: String {
        guard engine.isRecording else { return "record.circle" }
        switch (engine.systemMuted, engine.micMuted) {
        case (false, false): return "record.circle.fill"
        case (false, true):  return "mic.slash.circle.fill"
        case (true,  false): return "speaker.slash.circle.fill"
        case (true,  true):  return "circle.slash"
        }
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
