import SwiftUI
import SusurrusKit

struct HistoryView: View {
    @State private var items: [TranscriptionHistoryItem] = []
    @State private var copiedID: UUID?
    @State private var editingID: UUID?
    @State private var editText: String = ""
    @State private var escapeMonitor: Any?
    private let historyManager = TranscriptionHistoryManager()
    private let correctionManager = CorrectionLearningManager()

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                Text("No transcriptions yet")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        if editingID == item.id {
                            TextEditor(text: $editText)
                                .font(.body)
                                .frame(minHeight: 60)
                                .scrollContentBackground(.visible)
                            HStack {
                                Button("Save") {
                                    historyManager.updateText(id: item.id, newText: editText)
                                    editingID = nil
                                    loadItems()
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                                Button("Cancel") {
                                    editingID = nil
                                }
                                .controlSize(.small)
                            }
                        } else {
                            Text(item.text)
                                .font(.body)
                                .lineLimit(nil)
                        }
                        Text(item.date, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.trailing, 56)
                    .padding(.vertical, 4)
                    .overlay(alignment: .topTrailing) {
                        HStack(spacing: 8) {
                            if editingID != item.id {
                                Button {
                                    editingID = item.id
                                    editText = item.text
                                } label: {
                                    Image(systemName: "pencil")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            Button {
                                let pb = NSPasteboard.general
                                pb.clearContents()
                                pb.setString(item.text, forType: .string)
                                copiedID = item.id
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if copiedID == item.id { copiedID = nil }
                                }
                            } label: {
                                if copiedID == item.id {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.green)
                                } else {
                                    Image(systemName: "doc.on.doc")
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .frame(minWidth: 500, idealWidth: 550, minHeight: 350, idealHeight: 400)
        .onAppear {
            historyManager.correctionManager = correctionManager
            loadItems()
            // Close on Escape via local event monitor
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                if event.keyCode == 53 { // Escape
                    if editingID != nil {
                        editingID = nil
                        return nil
                    }
                    NSApp.keyWindow?.close()
                    return nil
                }
                return event
            }
        }
        .onDisappear {
            if let monitor = escapeMonitor {
                NSEvent.removeMonitor(monitor)
                escapeMonitor = nil
            }
        }
    }

    private func loadItems() {
        items = historyManager.items()
    }
}
