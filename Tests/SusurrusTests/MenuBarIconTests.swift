import Testing
@testable import SusurrusKit

@Suite("MenuBarIcon Tests")
struct MenuBarIconTests {

    @Test("Idle state uses waveform icon")
    func idleIcon() {
        #expect(MenuBarIcon.symbolName(for: .idle) == "waveform")
    }

    @Test("Recording state uses filled waveform icon")
    func recordingIcon() {
        #expect(MenuBarIcon.symbolName(for: .recording) == "waveform.circle.fill")
    }

    @Test("Processing state uses ellipsis icon")
    func processingIcon() {
        #expect(MenuBarIcon.symbolName(for: .processing) == "ellipsis.circle.fill")
    }

    @Test("Each state has a distinct icon or animation")
    func distinctIcons() {
        let icons = RecordingState.allCases.map { MenuBarIcon.symbolName(for: $0) }
        // idle, recording/streaming, processing/finalizing share base symbols
        // but animate differently — at minimum we have 3 distinct static symbols
        let uniqueIcons = Set(icons)
        #expect(uniqueIcons.count >= 3)
    }

    @Test("Each state has a non-empty tooltip")
    func nonEmptyTooltips() {
        for state in RecordingState.allCases {
            #expect(!MenuBarIcon.tooltip(for: state).isEmpty)
        }
    }

    @Test("Processing animation frames are distinct")
    func processingFramesDistinct() {
        #expect(MenuBarIcon.processingFrameA != MenuBarIcon.processingFrameB)
    }

    @Test("Recording and processing frames differ")
    func recordingVsProcessingFrames() {
        #expect(MenuBarIcon.recordingFrameA != MenuBarIcon.processingFrameA)
        #expect(MenuBarIcon.recordingFrameB != MenuBarIcon.processingFrameB)
    }
}
