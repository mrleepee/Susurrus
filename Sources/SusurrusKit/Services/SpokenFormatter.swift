import Foundation

/// Turns spoken formatting into written formatting, after the corrector:
///
/// - **Slash commands** — "slash autopilot" → "/autopilot", "slash code
///   review" → "/code-review" when `code-review` is a known command.
/// - **Lists** — "One, fix the parser. A, handle nulls. B, handle empties.
///   Two, write the tests." → a numbered list with lettered sub-items, and
///   "0.1 …, 0.2 …" / "bullet point …" runs → outline and bulleted lists.
///
/// Deterministic and pure, like `TranscriptCorrector`, so the eval harness
/// runs it unchanged. Both passes are tuned to miss rather than misfire:
/// a list needs at least two items in sequence, each starting at a clause
/// boundary and each with content, so counting ("one, two, three"), prose
/// ("two or three people") and decimals ("1.2 billion") are left alone.
public struct SpokenFormatter: Sendable {

    public var slashCommands: Bool
    public var lists: Bool

    /// Normalized command key (lowercase alphanumerics) → canonical name.
    private let commandsByKey: [String: String]

    /// Longest command, in spoken words, to try after "slash".
    static let maxCommandWords = 4

    public init(commands: [String] = [], slashCommands: Bool = true, lists: Bool = true) {
        self.slashCommands = slashCommands
        self.lists = lists
        var byKey: [String: String] = [:]
        // Shortest name wins a key collision ("code-review" vs "codereview"),
        // and the order is fixed so the result never depends on directory order.
        for name in commands.sorted(by: { ($0.count, $0) < ($1.count, $1) }) {
            let key = Self.key(name)
            guard !key.isEmpty, !name.contains(where: \.isWhitespace), byKey[key] == nil else { continue }
            byKey[key] = name
        }
        commandsByKey = byKey
    }

    public static let slashCommandsKey = "formatSlashCommands"
    public static let listsKey = "formatSpokenLists"

    /// The user's settings (both on unless turned off in Preferences).
    public static func fromUserDefaults(_ defaults: UserDefaults = .standard, commands: [String]) -> SpokenFormatter {
        func flag(_ key: String) -> Bool { defaults.object(forKey: key) == nil || defaults.bool(forKey: key) }
        return SpokenFormatter(commands: commands, slashCommands: flag(slashCommandsKey), lists: flag(listsKey))
    }

    public func format(_ text: String) -> String {
        var result = text
        if slashCommands { result = formatSlashCommands(result) }
        if lists { result = formatLists(result) }
        return result
    }

    // MARK: - Slash commands

    private static let slashPattern = try! NSRegularExpression(
        pattern: #"\bslash,?\s+"#, options: [.caseInsensitive]
    )

    private static let wordPattern = try! NSRegularExpression(
        pattern: #"([A-Za-z0-9][A-Za-z0-9'_-]*)([.,!?;:]*)(\s+|$)"#
    )

    func formatSlashCommands(_ text: String) -> String {
        let ns = text as NSString
        var output = ""
        var cursor = 0
        for match in Self.slashPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard match.range.location >= cursor else { continue }
            let afterSlash = match.range.location + match.range.length
            guard let command = command(in: ns, at: afterSlash) else { continue }
            output += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            output += "/" + command.name + command.trailing
            cursor = command.end
        }
        output += ns.substring(from: cursor)
        return output
    }

    private struct Command {
        let name: String
        /// Punctuation and whitespace after the last spoken word, kept.
        let trailing: String
        let end: Int
    }

    /// The command spoken at `location`: the longest run of words that names
    /// a known command, else one word that isn't ordinary English.
    private func command(in ns: NSString, at location: Int) -> Command? {
        var words: [(word: String, punctuation: String, space: String, end: Int)] = []
        var position = location
        while words.count < Self.maxCommandWords,
              let m = Self.wordPattern.firstMatch(in: ns as String, options: .anchored, range: NSRange(location: position, length: ns.length - position)) {
            let punctuation = ns.substring(with: m.range(at: 2))
            words.append((ns.substring(with: m.range(at: 1)), punctuation, ns.substring(with: m.range(at: 3)), m.range.location + m.range.length))
            position = m.range.location + m.range.length
            // A command never spans punctuation: "slash autopilot, continue".
            if !punctuation.isEmpty { break }
        }
        // "slash slash star" is an XPath being read out, not a command.
        guard let first = words.first, Self.key(first.word) != "slash" else { return nil }

        for count in stride(from: words.count, through: 1, by: -1) {
            let key = Self.key(words[..<count].map(\.word).joined())
            if let name = commandsByKey[key] {
                let last = words[count - 1]
                return Command(name: name, trailing: last.punctuation + last.space, end: last.end)
            }
        }

        let normalized = Self.key(first.word)
        guard normalized.count >= 3,
              normalized.contains(where: \.isLetter),
              !CommonWords.containsOrInflection(normalized) else { return nil }
        return Command(name: first.word.lowercased(), trailing: first.punctuation + first.space, end: first.end)
    }

    static func key(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    // MARK: - Lists

    private enum MarkerKind: Equatable {
        case number(Int)
        case outline(Int, Int)
        case letter(Int)
        case bullet
    }

    private enum Boundary { case none, weak, strong }

    private struct Marker {
        let kind: MarkerKind
        /// Where the marker starts, and where its item's content starts.
        let start: Int
        let contentStart: Int
        /// `.strong` is the start of text or after sentence-ending
        /// punctuation, `.weak` after a comma or semicolon. Only a strong
        /// boundary can open a list.
        let boundary: Boundary
        /// Set off by punctuation or a cue word ("One, …", "number one …"),
        /// so deliberate rather than a number that happens to start a clause.
        let explicit: Bool
        /// Mid-clause or unpunctuated. Parakeet drops the punctuation when
        /// there's no pause ("1 fix the parser 2 write the tests"), so digit
        /// markers like this are kept, but only count inside a longer run.
        var loose: Bool { boundary == .none || !explicit }
    }

    private static let numberWords: [String: Int] = [
        "zero": 0, "oh": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
        "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12,
    ]

    private static let markerPattern: NSRegularExpression = {
        let number = #"(?:zero|oh|one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|\d{1,2})"#
        let pattern =
            #"(?:^|(?<=\s))"#
            + #"(?:"#
            // 1: bullet cue
            + #"(bullet(?:\s+point)?)[,.:]?\s+"#
            + #"|"#
            // 2: number/point/item/step cue, 3: outline major, 4: outline minor, 5: number
            + #"(?:(number|point|item|step)\s+)?"#
            + #"(?:(\#(number))(?:\.|\s+point\s+)(\#(number))|(\#(number)))"#
            + #"(?:[,.:)]\s+|\s+(?=\S))"#
            + #"|"#
            // 6: letter
            + #"([a-h])[,.:)]\s+"#
            + #")"#
        return try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }()

    private func markers(in ns: NSString) -> [Marker] {
        Self.markerPattern.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)).compactMap { m in
            let start = m.range.location
            let end = start + m.range.length
            let boundary = Self.boundary(before: start, in: ns)
            func group(_ i: Int) -> String? {
                m.range(at: i).location == NSNotFound ? nil : ns.substring(with: m.range(at: i)).lowercased()
            }
            func value(_ s: String) -> Int? { Self.numberWords[s] ?? Int(s) }
            let separated = ns.substring(with: m.range).trimmingCharacters(in: .whitespaces).last.map { ",.:)".contains($0) } ?? false
            let explicit = separated || group(2) != nil
            func marker(_ kind: MarkerKind) -> Marker {
                Marker(kind: kind, start: start, contentStart: end, boundary: boundary, explicit: explicit)
            }

            if group(1) != nil {
                return boundary == .none ? nil : marker(.bullet)
            }
            if let rawMajor = group(3), let major = value(rawMajor), let minor = group(4).flatMap(value) {
                // "zero point one" mid-sentence is prose; "0.1" may be a
                // marker whose punctuation the ASR dropped.
                guard Int(rawMajor) != nil || boundary != .none else { return nil }
                return marker(.outline(major, minor))
            }
            if let raw = group(5), let n = value(raw) {
                // A spoken number must be set off at a clause boundary:
                // "One, fix it" is a marker, "One thing that comes up" and
                // "two or three people" are prose. Digits may be loose.
                guard Int(raw) != nil || (boundary != .none && explicit) else { return nil }
                return marker(.number(n))
            }
            if let letter = group(6)?.unicodeScalars.first {
                return boundary == .none ? nil : marker(.letter(Int(letter.value) - 96))
            }
            return nil
        }
    }

    private static func boundary(before location: Int, in ns: NSString) -> Boundary {
        var i = location - 1
        while i >= 0, let scalar = UnicodeScalar(ns.character(at: i)), CharacterSet.whitespacesAndNewlines.contains(scalar) {
            i -= 1
        }
        guard i >= 0, let scalar = UnicodeScalar(ns.character(at: i)) else { return .strong }
        if ".!?:".unicodeScalars.contains(scalar) { return .strong }
        if ",;".unicodeScalars.contains(scalar) { return .weak }
        return .none
    }

    func formatLists(_ text: String) -> String {
        // Already laid out (an LLM pass, or text this pass produced).
        guard !text.contains("\n") else { return text }
        let ns = text as NSString
        let all = markers(in: ns)

        // The first run that validates wins; anything after it belongs to
        // its last item, since nothing marks where a spoken list ends.
        for (index, opener) in all.enumerated() where opener.boundary == .strong {
            if let list = numberedList(from: index, in: all, ns: ns)
                ?? outlineList(from: index, in: all, ns: ns)
                ?? bulletList(from: index, in: all, ns: ns) {
                let preamble = ns.substring(to: opener.start).trimmingCharacters(in: .whitespaces)
                return preamble.isEmpty ? list : preamble + "\n" + list
            }
        }
        return text
    }

    private func numberedList(from index: Int, in all: [Marker], ns: NSString) -> String? {
        guard case .number(let n) = all[index].kind, n == 1 else { return nil }
        func run(allowingLoose: Bool) -> [Marker] {
            var items = [all[index]]
            for marker in all[(index + 1)...] where allowingLoose || !marker.loose {
                if case .number(let next) = marker.kind, next == items.count + 1 {
                    items.append(marker)
                }
            }
            return items
        }
        // Punctuated markers first, so the "2" in "One, load 2 files. Two, …"
        // can't steal item two. "1 is down, 2 are up" could be prose; three
        // in order rarely is.
        var items = run(allowingLoose: false)
        if items.count < 2 || items[0].loose {
            items = run(allowingLoose: true)
            guard items.count >= 3 else { return nil }
        }

        var lines: [String] = []
        for (i, item) in items.enumerated() {
            let end = i + 1 < items.count ? items[i + 1].start : ns.length
            let letters = all.filter {
                if case .letter = $0.kind { return $0.start >= item.contentStart && $0.start < end }
                return false
            }
            let subItems = sequence(of: letters, from: 1) { if case .letter(let l) = $0 { return l } else { return nil } }
            let headEnd = subItems.first?.start ?? end
            // "One. A, … B, …" — the sub-items alone are content enough.
            if let head = Self.content(ns, item.contentStart, headEnd) {
                lines.append("\(i + 1). \(head)")
            } else if !subItems.isEmpty {
                lines.append("\(i + 1).")
            } else {
                return nil
            }
            for (j, sub) in subItems.enumerated() {
                let subEnd = j + 1 < subItems.count ? subItems[j + 1].start : end
                guard let body = Self.content(ns, sub.contentStart, subEnd) else { return nil }
                let letter = Character(UnicodeScalar(UInt8(96 + j + 1)))
                lines.append("   \(letter). \(body)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// Markers whose values run first, first+1, … — at least two, else none.
    private func sequence(of markers: [Marker], from first: Int, value: (MarkerKind) -> Int?) -> [Marker] {
        var run: [Marker] = []
        for marker in markers where value(marker.kind) == first + run.count {
            run.append(marker)
        }
        return run.count >= 2 ? run : []
    }

    private func outlineList(from index: Int, in all: [Marker], ns: NSString) -> String? {
        // An unpunctuated opener must look like the start of an outline
        // ("0.1", "2.1"), so "1.2 billion triples…" never opens one.
        guard case .outline(_, let firstMinor) = all[index].kind,
              all[index].explicit || firstMinor == 1 else { return nil }
        func run(allowingLoose: Bool) -> [Marker] {
            var items = [all[index]]
            for marker in all[(index + 1)...] where allowingLoose || !marker.loose {
                guard case .outline(let major, let minor) = marker.kind,
                      case .outline(let lastMajor, let lastMinor) = items[items.count - 1].kind,
                      (major, minor) > (lastMajor, lastMinor) else { continue }
                items.append(marker)
            }
            return items
        }
        var items = run(allowingLoose: false)
        if items.count < 2 { items = run(allowingLoose: true) }
        guard items.count >= 2 else { return nil }
        var lines: [String] = []
        for (i, item) in items.enumerated() {
            let end = i + 1 < items.count ? items[i + 1].start : ns.length
            guard case .outline(let major, let minor) = item.kind,
                  let body = Self.content(ns, item.contentStart, end) else { return nil }
            lines.append("\(major).\(minor) \(body)")
        }
        return lines.joined(separator: "\n")
    }

    private func bulletList(from index: Int, in all: [Marker], ns: NSString) -> String? {
        guard all[index].kind == .bullet else { return nil }
        let items = all[index...].filter { $0.kind == .bullet }
        guard items.count >= 2 else { return nil }
        var lines: [String] = []
        for (i, item) in items.enumerated() {
            let end = i + 1 < items.count ? items[i + 1].start : ns.length
            guard let body = Self.content(ns, item.contentStart, end) else { return nil }
            lines.append("- \(body)")
        }
        return lines.joined(separator: "\n")
    }

    /// An item's text: trimmed, capitalized, and without the clause
    /// punctuation that only separated it from the next marker. A trailing
    /// full stop is kept only when the item is more than one sentence.
    /// `nil` when there is no content — the marker was a count, not an item.
    private static func content(_ ns: NSString, _ start: Int, _ end: Int) -> String? {
        guard end > start else { return nil }
        var body = ns.substring(with: NSRange(location: start, length: end - start))
            .trimmingCharacters(in: .whitespaces)
        while let last = body.last, ",;".contains(last) { body.removeLast() }
        if body.hasSuffix("."), !body.dropLast().contains(where: { ".!?".contains($0) }) {
            body.removeLast()
        }
        body = body.trimmingCharacters(in: .whitespaces)
        guard body.contains(where: \.isLetter) else { return nil }
        return body.prefix(1).uppercased() + body.dropFirst()
    }
}
