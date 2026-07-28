import SwiftUI
import SusurrusKit

struct MenuBarView: View {
    let appState: AppState
    let onLoad: (() -> Void)?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // R3 / Phase 6: Menu items based on state
            if appState.recordingState == .recording || appState.recordingState == .streaming {
                Button("Stop Recording") {
                    appState.stopStreaming()
                }
            } else {
                Button("Start Recording") {
                    appState.startStreaming()
                }
                .disabled(
                    !appState.modelReady
                    || appState.recordingState == .processing
                    || appState.recordingState == .finalizing
                )
            }

            if appState.recordingState == .processing {
                ProgressView(value: appState.transcriptionProgress) {
                    Text("Transcribing...")
                }
            } else if appState.recordingState == .finalizing {
                Text("Finalizing...")
                    .foregroundColor(.secondary)
            } else if !appState.modelReady {
                ProgressView(value: appState.modelLoadProgress) {
                    Text("Loading model...")
                }
            }

            Text("Hold ⌃⌥Space to dictate into an editable panel")
                .font(.caption)
                .foregroundStyle(.secondary)

            Divider()
            Button("History...") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openWindow(id: "history")
                }
            }
            Button("Preferences...") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openWindow(id: "preferences")
                }
            }
            Divider()
            Button("Show Debug Log") {
                let path = NSHomeDirectory() + "/susurrus_debug.log"
                NSWorkspace.shared.open(URL(fileURLWithPath: path))
            }
            Button("Quit Susurrus") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            onLoad?()
        }
    }
}
