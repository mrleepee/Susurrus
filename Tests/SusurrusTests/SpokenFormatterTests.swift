import Foundation
import Testing
@testable import SusurrusKit

@Suite("SpokenFormatter Tests")
struct SpokenFormatterTests {

    let formatter = SpokenFormatter(commands: ["autopilot", "code-review", "commit", "handoff", "efficient-opus"] + SlashCommandCatalog.builtIns)

    // MARK: - Slash commands

    @Test("Slash plus a known command becomes one token")
    func knownCommand() {
        #expect(formatter.format("slash autopilot continue going as far as you can.") == "/autopilot continue going as far as you can.")
    }

    @Test("Multi-word command names join to the known hyphenated name")
    func multiWordCommand() {
        #expect(formatter.format("Run slash code review on this branch.") == "Run /code-review on this branch.")
        #expect(formatter.format("Use slash efficient opus for this.") == "Use /efficient-opus for this.")
    }

    @Test("A split spoken word still finds the command")
    func splitWord() {
        #expect(formatter.format("Okay, slash auto pilot, keep going.") == "Okay, /autopilot, keep going.")
    }

    @Test("Trailing punctuation and sentence-initial Slash are handled")
    func punctuation() {
        #expect(formatter.format("Slash commit.") == "/commit.")
        #expect(formatter.format("I'd say slash, handoff when I'm done.") == "I'd say /handoff when I'm done.")
    }

    @Test("Known built-ins that are common words still attach")
    func builtInCommonWord() {
        #expect(formatter.format("then slash clear the context") == "then /clear the context")
    }

    @Test("An unknown uncommon word attaches, lowercased")
    func unknownCommand() {
        #expect(formatter.format("try slash Graphify on it") == "try /graphify on it")
    }

    @Test("Slash followed by a common word is left as prose")
    func commonWordUntouched() {
        #expect(formatter.format("We need to slash the budget.") == "We need to slash the budget.")
        #expect(formatter.format("They slash costs every year.") == "They slash costs every year.")
        #expect(formatter.format("The smiles and document slash slash star can be ignored.") == "The smiles and document slash slash star can be ignored.")
    }

    @Test("Disabled slash pass leaves text alone")
    func slashDisabled() {
        let off = SpokenFormatter(commands: ["autopilot"], slashCommands: false)
        #expect(off.format("slash autopilot") == "slash autopilot")
    }

    // MARK: - Numbered lists

    @Test("Spoken numbered list with a preamble")
    func numberedList() {
        let input = "Here is the plan. One, fix the parser. Two, write the tests. Three, ship it."
        #expect(formatter.format(input) == "Here is the plan.\n1. Fix the parser\n2. Write the tests\n3. Ship it")
    }

    @Test("Lettered sub-items nest under their numbered item")
    func nestedList() {
        let input = "One, fix the parser. A, handle nulls. B, handle empty strings. Two, write the tests. A, unit tests. B, an eval run."
        #expect(formatter.format(input) == """
        1. Fix the parser
           a. Handle nulls
           b. Handle empty strings
        2. Write the tests
           a. Unit tests
           b. An eval run
        """)
    }

    @Test("Digit markers from the ASR work like spoken ones")
    func digitMarkers() {
        #expect(formatter.format("1. Fix the parser. 2. Write the tests.") == "1. Fix the parser\n2. Write the tests")
    }

    @Test("Comma-separated items in one sentence")
    func commaItems() {
        #expect(formatter.format("One, fix the parser, two, write the tests") == "1. Fix the parser\n2. Write the tests")
    }

    @Test("Cue words open a list without punctuation")
    func cueWords() {
        #expect(formatter.format("Number one fix the parser. Number two write the tests.") == "1. Fix the parser\n2. Write the tests")
        #expect(formatter.format("Point one, the parser is slow. Point two, the cache is cold.") == "1. The parser is slow\n2. The cache is cold")
    }

    @Test("Multi-sentence items keep their full stops")
    func multiSentenceItem() {
        let input = "One, fix the parser. It is slow. Two, write the tests."
        #expect(formatter.format(input) == "1. Fix the parser. It is slow.\n2. Write the tests")
    }

    @Test("Sub-items with no heading text")
    func emptyHead() {
        #expect(formatter.format("One. A, foo. B, bar. Two, baz.") == "1.\n   a. Foo\n   b. Bar\n2. Baz")
    }

    // MARK: - Outline and bullets

    @Test("Outline numbering")
    func outline() {
        let input = "0.1, set up the repo. 0.2, add the build. 2.3, cut a release."
        #expect(formatter.format(input) == "0.1 Set up the repo\n0.2 Add the build\n2.3 Cut a release")
        #expect(formatter.format("Zero point one, set up the repo. Zero point two, add the build.") == "0.1 Set up the repo\n0.2 Add the build")
    }

    @Test("Bullet point lists")
    func bullets() {
        let input = "Bullet point, the parser is slow. Bullet point, the cache is cold."
        #expect(formatter.format(input) == "- The parser is slow\n- The cache is cold")
    }

    // MARK: - Real Parakeet output (TTS probes, 2026-10-30)

    @Test("Parakeet's punctuated forms", arguments: [
        ("Okay, slash autopilot. Continue going as far as you can", "Okay, /autopilot. Continue going as far as you can"),
        ("Run slash code review on this branch and then slash commit.", "Run /code-review on this branch and then /commit."),
        ("Here is the plan. 1. Fix the parser. 2. Write the tests. 3. Ship it.", "Here is the plan.\n1. Fix the parser\n2. Write the tests\n3. Ship it"),
        ("1. Fix the parser. A. Handle nulls. B. Handle empty strings. 2. Write the tests. A. Unit tests. B. An eval run.",
         "1. Fix the parser\n   a. Handle nulls\n   b. Handle empty strings\n2. Write the tests\n   a. Unit tests\n   b. An eval run"),
        ("Point 1. The parser is slow. Point 2. The cache is cold.", "1. The parser is slow\n2. The cache is cold"),
        ("Number 1. Fix the parser. Number 2. Write the tests", "1. Fix the parser\n2. Write the tests"),
    ])
    func parakeetPunctuated(_ input: String, _ expected: String) {
        #expect(formatter.format(input) == expected)
    }

    @Test("Parakeet drops punctuation when there's no pause")
    func parakeetUnpunctuated() {
        #expect(formatter.format("0.1 set up the repo 0.2 add the build 2.3 cut a release") == "0.1 Set up the repo\n0.2 Add the build\n2.3 Cut a release")
        #expect(formatter.format("1 fix the parser 2 write the tests 3 ship it") == "1. Fix the parser\n2. Write the tests\n3. Ship it")
    }

    @Test("Loose digits inside an item don't steal the next item")
    func looseDigitsInsideItem() {
        let input = "One, load 2 files. Two, check 3 hosts. Three, done."
        #expect(formatter.format(input) == "1. Load 2 files\n2. Check 3 hosts\n3. Done")
    }

    @Test("Two loose digit markers are not enough", arguments: [
        "1 is down and 2 are up.",
        "1.2 billion triples went in, and 1.5 billion more next year.",
    ])
    func looseTooShort(_ text: String) {
        #expect(formatter.format(text) == text)
    }

    // MARK: - Must not fire

    @Test("Counting is not a list", arguments: [
        "Hello, I am speaking. One, two, three.",
        "Okay, waiting.  One, two, three, copy.",
    ])
    func counting(_ text: String) {
        #expect(formatter.format(text) == text)
    }

    @Test("Numbers in prose are not a list", arguments: [
        "The index holds 1.2 billion triples across three hosts, and two or three people use it.",
        "One thing that comes up which I still don't really understand. Two people can share an address.",
        "That's my first thought. Second thought is we will have a fallback.",
        "It took 30 minutes to load 10,000 documents, and the index now holds 1.2 billion triples across three hosts.",
        "Why are we doing a three and a half hour run? I asked for examples.",
        "One, fix the parser.",
        "Two, write the tests. Three, ship it.",
        "Bullet points are hard to dictate. The bullet points on slide two are fine.",
        "We have 2 hosts. It took 30 minutes to load 10,000 documents.",
    ])
    func prose(_ text: String) {
        #expect(formatter.format(text) == text)
    }

    @Test("A lone letter is not a sub-list")
    func loneLetter() {
        #expect(formatter.format("One, pick a, the first option. Two, test it.") == "1. Pick a, the first option\n2. Test it")
    }

    @Test("Formatting is idempotent")
    func idempotent() {
        let once = formatter.format("slash autopilot. One, fix the parser. Two, write the tests.")
        #expect(formatter.format(once) == once)
    }

    @Test("Disabled list pass leaves text alone")
    func listsDisabled() {
        let off = SpokenFormatter(lists: false)
        let text = "One, fix the parser. Two, write the tests."
        #expect(off.format(text) == text)
    }

    // MARK: - Catalog

    @Test("Catalog reads commands, skills, frontmatter names and plugins")
    func catalog() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("commands/team"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("commands/autopilot.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("commands/team/standup.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("skills/marklogic-sparql"), withIntermediateDirectories: true)
        try "---\nname: sparql\ndescription: x\n---\nbody".write(to: root.appendingPathComponent("skills/marklogic-sparql/SKILL.md"), atomically: true, encoding: .utf8)
        try fm.createDirectory(at: root.appendingPathComponent("skills/not-a-skill"), withIntermediateDirectories: true)

        let plugin = root.appendingPathComponent("plugins/cache/p/1.0")
        try fm.createDirectory(at: plugin.appendingPathComponent("commands"), withIntermediateDirectories: true)
        try "x".write(to: plugin.appendingPathComponent("commands/commit.md"), atomically: true, encoding: .utf8)
        let manifest = #"{"version": 2, "plugins": {"p@m": [{"installPath": "\#(plugin.path)"}]}}"#
        try manifest.write(to: root.appendingPathComponent("plugins/installed_plugins.json"), atomically: true, encoding: .utf8)

        let names = SlashCommandCatalog.discover(claudeDirectory: root)
        for expected in ["autopilot", "standup", "marklogic-sparql", "sparql", "commit", "clear"] {
            #expect(names.contains(expected), "missing \(expected)")
        }
        #expect(!names.contains("not-a-skill"))
    }

    @Test("Catalog tolerates a missing directory")
    func catalogMissing() {
        let names = SlashCommandCatalog.discover(claudeDirectory: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        #expect(names == SlashCommandCatalog.builtIns.sorted())
    }
}
