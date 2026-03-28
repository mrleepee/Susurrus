import SwiftUI
import SusurrusKit

struct MenuBarView: View {
    let appState: AppState

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
            Button("Preferences...") {
                // R3 placeholder — implemented in Phase 5
            }
            Divider()
            Button("Quit Susurrus") {
                NSApplication.shared.terminate(nil)
            }
        }
    }
}
