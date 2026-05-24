import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: RecordingEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            Toggle(isOn: Binding(
                get: { !engine.systemMuted },
                set: { engine.systemMuted = !$0 }
            )) {
                Label("System Audio", systemImage: "speaker.wave.2")
            }
            .toggleStyle(.switch)

            Toggle(isOn: Binding(
                get: { !engine.micMuted },
                set: { engine.micMuted = !$0 }
            )) {
                Label("Microphone", systemImage: "mic")
            }
            .toggleStyle(.switch)

            Text("⌥⌘M mic · ⌥⌘S system · ⌥⌘R record")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            HStack {
                Button(engine.isRecording ? "Stop & Reveal" : "Start Recording") {
                    engine.toggle()
                }
                .keyboardShortcut(.return, modifiers: [])
                Spacer()
                Button("Open Folder") {
                    NSWorkspace.shared.open(engine.recordingsDirectory)
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Quit MeetRec") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
        }
        .padding(12)
        .frame(width: 280)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(engine.isRecording ? Color.red : Color.secondary.opacity(0.5))
                .frame(width: 10, height: 10)
            Text(engine.isRecording ? "Recording" : "Idle")
                .font(.headline)
            Spacer()
            if engine.isRecording {
                Text(timeString(engine.elapsed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
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
}
