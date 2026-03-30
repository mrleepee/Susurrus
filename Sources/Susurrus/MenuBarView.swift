import SwiftUI
import SusurrusKit

struct MenuBarView: View {
    let appState: AppState
    let onLoad: (() -> Void)?
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // R3: Menu items based on state
        Group {
            if appState.recordingState == .recording {
                Button("Stop Recording") {
                    appState.stopRecording()
                }
            } else {
                Button("Start Recording") {
                    appState.startRecording()
                }
                .disabled(!appState.modelReady || appState.recordingState == .processing)
            }

            if appState.recordingState == .processing {
                ProgressView(value: appState.transcriptionProgress) {
                    Text("Transcribing...")
                }
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
