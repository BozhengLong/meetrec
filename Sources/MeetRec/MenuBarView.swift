import SwiftUI

struct MenuBarView: View {
    @ObservedObject var engine: RecordingEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            Divider()

            channelRow(
                icon: "speaker.wave.2",
                label: "System Audio",
                muted: Binding(
                    get: { engine.systemMuted },
                    set: { engine.systemMuted = $0 }
                ),
                level: engine.systemLevel
            )

            channelRow(
                icon: "mic",
                label: "Microphone",
                muted: Binding(
                    get: { engine.micMuted },
                    set: { engine.micMuted = $0 }
                ),
                level: engine.micLevel
            )

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
        .frame(width: 300)
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

    private func channelRow(icon: String,
                            label: String,
                            muted: Binding<Bool>,
                            level: Float) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { !muted.wrappedValue },
                set: { muted.wrappedValue = !$0 }
            )) {
                Label(label, systemImage: icon)
            }
            .toggleStyle(.switch)

            LevelBar(level: level, muted: muted.wrappedValue)
                .frame(height: 4)
                .padding(.leading, 22)
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

struct LevelBar: View {
    let level: Float  // 0...1
    let muted: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.15))
                Capsule()
                    .fill(barColor)
                    .frame(width: geo.size.width * CGFloat(displayLevel))
                    .animation(.linear(duration: 0.05), value: displayLevel)
            }
        }
    }

    private var displayLevel: Float {
        muted ? 0 : min(max(level, 0), 1)
    }

    private var barColor: Color {
        if muted { return .gray.opacity(0.5) }
        switch level {
        case ..<0.6:  return .green
        case ..<0.85: return .yellow
        default:      return .red
        }
    }
}
