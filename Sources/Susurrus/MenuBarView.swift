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
                // No progress bar during finalization — user just waits
                Text("Finalizing...")
                    .foregroundColor(.secondary)
            } else if !appState.modelReady {
                ProgressView(value: appState.modelLoadProgress) {
                    Text("Loading model...")
                }
            }

            Divider()
            Button("History...") {
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    openWindow(id: "history")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.windows.first(where: { $0.title == "History" })?
                            .orderFrontRegardless()
                    }
                }
            }
            Button("Preferences...") {
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    openWindow(id: "preferences")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        NSApp.windows.first(where: { $0.title == "Susurrus Preferences" })?
                            .orderFrontRegardless()
                    }
                }
            }
            Divider()
            Button("Quit Susurrus") {
                NSApplication.shared.terminate(nil)
            }
        }
        .onAppear {
            onLoad?()
        }
    }
}
