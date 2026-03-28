import Testing
@testable import SusurrusKit

@Suite("MenuBarIcon Tests")
struct MenuBarIconTests {

    @Test("Idle state uses mic icon")
    func idleIcon() {
        #expect(MenuBarIcon.symbolName(for: .idle) == "mic")
    }

    @Test("Recording state uses filled mic icon")
    func recordingIcon() {
        #expect(MenuBarIcon.symbolName(for: .recording) == "mic.fill")
    }

    @Test("Processing state uses badge icon")
    func processingIcon() {
        #expect(MenuBarIcon.symbolName(for: .processing) == "mic.badge.xmark")
    }

    @Test("Each state has a distinct icon")
    func distinctIcons() {
        let icons = RecordingState.allCases.map { MenuBarIcon.symbolName(for: $0) }
        let uniqueIcons = Set(icons)
        #expect(uniqueIcons.count == icons.count)
    }

    @Test("Each state has a non-empty tooltip")
    func nonEmptyTooltips() {
        for state in RecordingState.allCases {
            #expect(!MenuBarIcon.tooltip(for: state).isEmpty)
        }
    }
}
