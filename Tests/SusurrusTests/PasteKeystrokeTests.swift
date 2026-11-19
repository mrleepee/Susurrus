import Testing
@testable import SusurrusKit

/// The key events behind Insert / auto-paste. Remote-desktop clients forward
/// keys from their own modifier tracking, so a ⌘-flagged V without a Command
/// key-down reaches the remote machine as a plain "v".
@Suite("Paste keystrokes")
struct PasteKeystrokeTests {

    @Test("WorkSpaces gets Command down, V down, V up, Command up")
    func workspacesHoldsCommand() {
        let strokes = PasteKeystroke.paste(into: "com.amazon.workspaces")
        #expect(strokes.map(\.keyCode) == [0x37, 0x09, 0x09, 0x37])
        #expect(strokes.map(\.keyDown) == [true, true, false, false])
        #expect(strokes.map(\.command) == [true, true, true, false])
    }

    @Test("WorkSpaces sequence is paced so Command arrives before V")
    func workspacesIsPaced() {
        let strokes = PasteKeystroke.paste(into: "com.amazon.workspaces")
        #expect(strokes[0].pauseAfter > 0)
        #expect(strokes.last?.pauseAfter == 0)
    }

    @Test("WorkSpaces always ends with Command released, never left held")
    func workspacesReleasesCommand() throws {
        let last = try #require(PasteKeystroke.paste(into: "com.amazon.workspaces").last)
        #expect(last.keyCode == 0x37 && !last.keyDown && !last.command)
    }

    @Test("Other apps keep the flagged V down/up", arguments: [
        "com.tinyspeck.slackmacgap", "com.anthropic.claudefordesktop", nil,
    ] as [String?])
    func otherAppsUnchanged(bundleID: String?) {
        let strokes = PasteKeystroke.paste(into: bundleID)
        #expect(strokes.map(\.keyCode) == [0x09, 0x09])
        #expect(strokes.map(\.keyDown) == [true, false])
        #expect(strokes.map(\.command) == [true, true])
    }
}
