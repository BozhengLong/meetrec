import SwiftUI
import AppKit
import Combine

// SwiftUI's MenuBarExtra hosts its status item out-of-process via the private
// NSSceneStatusItem/Control Center "scene" machinery. On this macOS version
// (26.4) that machinery fires a spurious NSStatusItemChangeVisibilityAction
// right after the item is created — misread as "user removed the menu bar
// icon" — and NSSceneStatusItem responds by calling -[NSApplication terminate:]
// directly (confirmed via crash-time stack trace: NSSceneStatusItem
// scene:handleActions: -> NSApplication terminate:). This is the same failure
// other MenuBarExtra-based apps have hit on recent macOS (e.g. AeroSpace #1786).
// A manually-managed NSStatusItem (this file) never goes through that scene
// path and isn't subject to terminationOnRemoval, so it doesn't have the bug.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var engine: RecordingEngine!
    private let hotkeys = HotKeyManager()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var cancellable: AnyCancellable?
    private var shownIcon = ""
    private var shownTitle: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        Log.reset()

        let engine = RecordingEngine()
        self.engine = engine

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The status item shares AppKit's default autosave name ("Item-0") with
        // the old MenuBarExtra build, so a persisted "hidden" state from that
        // build's spurious removal event could keep it invisible. This app has
        // no other UI, so always come back visible on launch.
        item.isVisible = true
        // Fixed-width digits so the running timer doesn't shift the menu bar.
        item.button?.font = .monospacedDigitSystemFont(
            ofSize: NSFont.menuBarFont(ofSize: 0).pointSize, weight: .regular)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 260)
        popover.contentViewController = NSHostingController(rootView: MenuBarView(engine: engine))
        self.popover = popover

        wireHotkeys(engine: engine)
        updateStatusItem()
        cancellable = engine.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }

        // Preflight Screen Recording access shortly after launch so missing
        // or stale (post-upgrade) grants get guided fix-up before the first
        // recording silently loses system audio.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            ScreenRecordingPermission.checkAtLaunch()
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            // Clicking a status item doesn't activate an LSUIElement app; without
            // this, keystrokes (Return to record, ⌘Q) go to the frontmost app.
            NSApp.activate()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }
        // The engine publishes ~60×/s while recording (timer + level meters);
        // only touch the button when what it shows actually changes.
        let icon = iconName
        let title = engine.isRecording ? " " + timeString(engine.elapsed) : ""
        if icon != shownIcon {
            button.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            shownIcon = icon
        }
        if title != shownTitle {
            button.title = title
            shownTitle = title
        }
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

    private func wireHotkeys(engine: RecordingEngine) {
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

@main
struct MeetRecApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {}
    }
}
