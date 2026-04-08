import SwiftUI
import SusurrusKit

struct MenuBarView: View {
    let appState: AppState
    let notebookManager: NotebookManaging
    let onLoad: (() -> Void)?
    @Environment(\.openWindow) private var openWindow

    // Refreshed each time the menu appears
    @State private var notebookList: [Notebook] = []
    @State private var activeNotebookId: UUID?

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

            Divider()

            // Notebook selector submenu
            Menu {
                Button(activeNotebookId == nil ? "✓ None (clipboard only)" : "None (clipboard only)") {
                    notebookManager.setActiveNotebookId(nil)
                    refreshNotebooks()
                }
                Divider()
                ForEach(notebookList) { notebook in
                    Button {
                        notebookManager.setActiveNotebookId(notebook.id)
                        refreshNotebooks()
                    } label: {
                        HStack {
                            Text(notebook.name)
                            if activeNotebookId == notebook.id {
                                Spacer()
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Label("Notebook", systemImage: "book")
            }

            Divider()
            Button("Notebooks...") {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    openWindow(id: "notebooks")
                }
            }
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
            refreshNotebooks()
        }
    }

    private func refreshNotebooks() {
        notebookList = notebookManager.notebooks()
        activeNotebookId = notebookManager.activeNotebookId()
    }
}
