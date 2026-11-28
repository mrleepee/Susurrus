import Foundation

/// Spelling fixes that need no vocabulary: the same thing written one way.
/// Runs before the corrector, on every final transcript.
///
/// Every pass is mechanical and fixes text Qwen3-ASR wrote that the user
/// pasted unedited (daily reviews 11-14 to 11-27). Each one leaves ordinary,
/// correctly written text exactly as it was.
public enum TextNormalizer {

    public static func normalize(_ text: String) -> String {
        var s = text
        s = stripNonLatinScript(s)
        s = rejoinContractions(s)
        s = inWordPunctuation(s)
        s = strayPunctuation(s)
        s = gluedWords(s)
        s = splitSentences(s)
        s = spokenFileNames(s)
        s = loneLowercaseI(s)
        s = midSentenceCapitals(s)
        s = collapseRepeats(s)
        s = countryAbbreviations(s)
        s = spokenNumbers(s)
        return s
    }

    // MARK: - Script

    /// Whether `text` holds Han, Kana or Hangul — Qwen3-ASR occasionally
    /// switches language mid-word ("we应该put it all together", 11-24) even
    /// with English forced.
    public static func containsNonLatinScript(_ text: String) -> Bool {
        text.range(of: nonLatinPattern, options: .regularExpression) != nil
    }

    private static let nonLatinPattern = "[\\p{Han}\\p{Hiragana}\\p{Katakana}\\p{Hangul}]+"

    /// Replaces each Han/Kana/Hangul run with a space. The words are lost
    /// either way; this keeps the English around them readable.
    static func stripNonLatinScript(_ text: String) -> String {
        guard containsNonLatinScript(text) else { return text }
        var s = text.replacingOccurrences(of: nonLatinPattern, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: "[ \\t]{2,}", with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: " +(?=[,.;:!?])", with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Apostrophes

    /// "don''t" → "don't", "it' s" → "it's", "don'. T" → "don't",
    /// "we don' need" → "we don't need", raw "It'S" → "It's".
    static func rejoinContractions(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "(?<=\\p{L})(['’])\\1(?=\\p{L})", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?<=\\p{L}n)(['’])\\.?\\s?[Tt]\\b", with: "$1t", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "(?<=\\p{L})(['’])\\s(s|t|re|ve|ll|d|m)\\b", with: "$1$2", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "\\b(?i:(don|can|won|isn|aren|wasn|weren|didn|doesn|haven|hasn|couldn|wouldn|shouldn))(['’])(?=\\s)",
            with: "$1$2t", options: .regularExpression
        )
        s = s.replacingOccurrences(of: "(?<=\\p{Ll})(['’])S\\b", with: "$1s", options: .regularExpression)
        return s
    }

    // MARK: - Punctuation inside words

    /// "run,s" → "runs", "buildin.g" → "building", "there,'s" → "there's".
    /// A comma or full stop with letters tight on both sides is only moved
    /// when the joined word is an English word and the left part has two or
    /// more letters, so "a.m.", "e.g." and "node.js" stay as they are.
    static func inWordPunctuation(_ text: String, dictionary: EnglishDictionary = .shared) -> String {
        var s = text.replacingOccurrences(of: "(?<=\\p{L}),(?=['’]\\p{L})", with: "", options: .regularExpression)
        guard dictionary.isAvailable else { return s }
        let ns = s as NSString
        let matches = inWordRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let left = ns.substring(with: match.range(at: 1))
            let right = ns.substring(with: match.range(at: 2))
            let joined = left + right
            // The system word list has no plurals: "run,s" → "runs" is
            // checked on "run".
            let known = dictionary.contains(joined) || (right.lowercased() == "s" && dictionary.contains(left))
            guard known,
                  !(dictionary.contains(left) && dictionary.contains(right) && right.count > 1),
                  let range = Range(match.range, in: s) else { continue }
            s.replaceSubrange(range, with: joined)
        }
        return s
    }

    private static let inWordRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}.,'’])(\\p{L}{2,})[.,](\\p{L}{1,2})(?![\\p{L}\\p{N}'’]|\\.\\p{L})"
    )

    // MARK: - Hesitation punctuation

    /// Punctuation Qwen inserts at hesitations: "I, don't, understand",
    /// "to be. published", ". .". A full stop is dropped only when a
    /// lowercase word follows it — Qwen capitalises every sentence it starts,
    /// so a lowercase word after a stop means the sentence never ended.
    static func strayPunctuation(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: "\\.(?:\\s+\\.)+", with: ".", options: .regularExpression)
        s = s.replacingOccurrences(
            of: "\\b(I|I'd|I'm|I've|I’d|I’m|I’ve), (?=(?:\(hesitationVerbs))\\b)",
            with: "$1 ", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "\\b(don't|don’t|didn't|didn’t|do|just|really), (?=(?:understand|know|think|want|need|like|see|get|mean|care|have|remember|believe|feel)\\b)",
            with: "$1 ", options: .regularExpression
        )

        let ns = s as NSString
        let matches = strayStopRegex.matches(in: s, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let word = ns.substring(with: match.range(at: 1)).lowercased()
            guard !abbreviations.contains(word),
                  let stop = Range(match.range(at: 2), in: s) else { continue }
            s.replaceSubrange(stop, with: "")
        }
        return s
    }

    private static let hesitationVerbs =
        "don't|don’t|think|like|want|need|know|mean|guess|see|have|am|was|would|will|can|could|should|do|did|just|really|feel|believe|understand|said|say|wonder|hope|love|get|got|also"

    /// A word, then a stop, then whitespace and a lowercase letter. The word
    /// must be plain letters with nothing glued before it ("e.g." and "v1."
    /// don't qualify).
    private static let strayStopRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}.'’\\-/])(\\p{L}+)(\\.)(?=[ \\t]+\\p{Ll})"
    )

    private static let abbreviations: Set<String> = [
        "etc", "vs", "approx", "cf", "al", "inc", "ltd", "co", "mr", "mrs", "ms", "dr", "st", "no", "fig", "eg", "ie",
    ]

    /// Missing spaces Qwen leaves at a squeezed pause: "andI" → "and I",
    /// "don'tthink" → "don't think".
    static func gluedWords(_ text: String) -> String {
        var s = text.replacingOccurrences(
            of: "\\b(and|but|so|then|because|that|if|when|what|where|why|how|which|or)I\\b",
            with: "$1 I", options: .regularExpression
        )
        s = s.replacingOccurrences(
            of: "\\b(\\p{L}+n['’]t)(\\p{L}{2,})\\b", with: "$1 $2", options: .regularExpression
        )
        return s
    }

    /// A full stop after a word no sentence ends on ("but. I do want",
    /// "the. Data") is a pause, not a sentence end: drop it, and lowercase
    /// the next word if it is a function word.
    static func splitSentences(_ text: String) -> String {
        let ns = text as NSString
        var result = text
        for match in splitRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let next = ns.substring(with: match.range(at: 2))
            guard let range = Range(match.range, in: result) else { continue }
            let previous = ns.substring(with: match.range(at: 1))
            let fixedNext = functionWords.contains(next.lowercased()) && next != "I" ? next.lowercased() : next
            result.replaceSubrange(range, with: previous + " " + fixedNext)
        }
        return result
    }

    private static let splitRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’\\-])((?i:and|but|or|the|an|my|your|our|their|because))\\.[ \\t]+(\\p{Lu}[\\p{L}'’]*)"
    )

    /// "settings dot json" → "settings.json".
    static func spokenFileNames(_ text: String) -> String {
        text.replacingOccurrences(
            of: "\\b(\\p{L}[\\p{L}\\p{N}_\\-]*) dot (json|md|yaml|yml|txt|js|ts|py|swift|xml|csv|html|sh|toml|plist|log)\\b",
            with: "$1.$2", options: [.regularExpression, .caseInsensitive]
        )
    }

    /// A lone lowercase "i" (and "i'm", "i'd"…) → "I". "i.e." is left alone.
    static func loneLowercaseI(_ text: String) -> String {
        text.replacingOccurrences(
            of: "(?<![\\p{L}\\p{N}'’.\\-/])i(?=$|[\\s,;:!?]|['’](?:m|d|ll|ve)\\b|\\.(?!\\p{L}))",
            with: "I", options: .regularExpression
        )
    }

    // MARK: - Casing

    /// Common function words Qwen capitalises mid-sentence where it squeezed
    /// a pause: "we have Our data", "I Can do", "pinned, It doesn't".
    /// Lowercased only mid-sentence, and not inside a run of capitalised
    /// words ("Back To The Future" is left alone).
    static func midSentenceCapitals(_ text: String) -> String {
        let ns = text as NSString
        let matches = titleWordRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            let word = ns.substring(with: match.range)
            guard functionWords.contains(word.lowercased()),
                  let range = Range(match.range, in: result),
                  isMidSentence(before: range.lowerBound, in: result),
                  !neighbourIsTitleCase(match.range, in: ns) else { continue }
            result.replaceSubrange(range, with: word.lowercased())
        }
        return result
    }

    private static let titleWordRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’\\-])\\p{Lu}\\p{Ll}+(?:['’]\\p{Ll}+)?(?![\\p{L}\\p{N}\\-])"
    )

    private static let functionWords: Set<String> = [
        "the", "to", "and", "or", "but", "is", "are", "was", "were", "be", "been", "not",
        "can", "could", "would", "should", "we", "our", "you", "your", "they", "their",
        "it", "it's", "its", "this", "that", "then", "if", "of", "for", "with", "at",
        "from", "think", "know", "see", "want", "do", "does", "have", "has", "there",
    ]

    private static func isMidSentence(before index: String.Index, in text: String) -> Bool {
        guard let previous = text[..<index].last(where: { !$0.isWhitespace }) else { return false }
        return previous.isLetter || previous.isNumber || ",;".contains(previous)
    }

    /// Whether the word before or after `range` is capitalised and isn't
    /// "I" or an acronym — a title or a name, not a sentence.
    private static func neighbourIsTitleCase(_ range: NSRange, in ns: NSString) -> Bool {
        let before = ns.substring(to: range.location)
        let after = ns.substring(from: range.location + range.length)
        func isTitle(_ word: Substring?) -> Bool {
            guard let word, let first = word.first, first.isUppercase else { return false }
            return word.dropFirst().contains(where: \.isLowercase)
        }
        let previousWord = before.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).last
        let nextWord = after.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" }).first
        let beforeIsAdjacent = before.last.map { $0 == " " } ?? false
        let afterIsAdjacent = after.first.map { $0 == " " } ?? false
        return (beforeIsAdjacent && isTitle(previousWord)) || (afterIsAdjacent && isTitle(nextWord))
    }

    // MARK: - Repeats

    /// "I I should" → "I should", "with the with the" → "with the". Doubles
    /// that are normal English ("had had", "bye bye", "very very") stay.
    static func collapseRepeats(_ text: String) -> String {
        var s = text
        for _ in 0..<3 {
            let before = s
            s = collapse(s, regex: repeatTwoRegex) { _ in true }
            // Numbers repeat for real: "twenty twenty", "one one one".
            s = collapse(s, regex: repeatOneRegex) {
                !legitimateDoubles.contains($0.lowercased()) && numberValue[$0.lowercased()] == nil
            }
            if s == before { break }
        }
        return s
    }

    private static func collapse(_ text: String, regex: NSRegularExpression, when allowed: (String) -> Bool) -> String {
        let ns = text as NSString
        var result = text
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed() {
            let first = ns.substring(with: match.range(at: 1))
            guard allowed(first), let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: first)
        }
        return result
    }

    private static let repeatOneRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’\\-])(\\p{L}+(?:['’]\\p{L}+)?)[ \\t]+\\1(?![\\p{L}\\p{N}'’\\-])",
        options: [.caseInsensitive]
    )

    private static let repeatTwoRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}'’\\-])(\\p{L}+(?:['’]\\p{L}+)?[ \\t]+\\p{L}+(?:['’]\\p{L}+)?)[ \\t]+\\1(?![\\p{L}\\p{N}'’\\-])",
        options: [.caseInsensitive]
    )

    private static let legitimateDoubles: Set<String> = [
        "had", "that", "is", "bye", "so", "very", "really", "no", "yeah", "yes", "ha", "hey", "oh", "ah",
        "la", "na", "knock", "tut", "chop", "there", "well", "now", "more", "many", "much", "far", "long",
        "round", "over", "again", "too", "go", "boo", "bla", "blah", "ho", "hip", "hush",
    ]

    // MARK: - Country abbreviations

    /// "U.K.", "U. K.", "U K." → "UK"; likewise "US". One dictation on 11-16
    /// had "UK", "U.K." and "U K." The abbreviation's last dot is kept only
    /// where it also ends the sentence (end of text, or a capital follows),
    /// so a mid-sentence "U K." no longer starts a false sentence.
    static func countryAbbreviations(_ text: String) -> String {
        let ns = text as NSString
        let matches = abbreviationRegex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let letter = ns.substring(with: match.range(at: 1))
            var replacement = "U" + letter
            if ns.substring(with: match.range).hasSuffix("."), endsSentence(after: range.upperBound, in: result) {
                replacement += "."
            }
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    // "U", then a dot and/or spaces, then K or S, then an optional dot — with
    // at least one dot or space between the letters ("UK" itself is left
    // alone) and no letter on either side ("US Open" fine, "USB" untouched).
    private static let abbreviationRegex = try! NSRegularExpression(
        pattern: "(?<![\\p{L}\\p{N}.])U(?:\\.\\s?|\\s)([KS])(?:\\.(?![\\p{L}])|(?![\\p{L}\\p{N}.]))"
    )

    private static func endsSentence(after index: String.Index, in text: String) -> Bool {
        guard let next = text[index...].first(where: { !$0.isWhitespace }) else { return true }
        return next.isUppercase
    }

    // MARK: - Spoken numbers

    /// Spoken numbers to digits, narrowly: a compound ("twenty four",
    /// "a hundred and eighty"), a number of ten or more ("to twelve"), or a
    /// number before a plural unit ("eight seconds"). "one objective",
    /// "seven thirty" (not one number) and sentence-initial numbers stay as
    /// words. A number right after a short acronym joins it: "EC two" →
    /// "EC2", "BM twenty five" → "BM25", "S three" → "S3".
    ///
    /// With `all`, every number that parses becomes digits — the eval
    /// scorer uses this on both sides so "twenty four" and "24" compare equal.
    public static func spokenNumbers(_ text: String, all: Bool = false) -> String {
        let tokens = wordTokens(text)
        guard tokens.contains(where: { numberValue[$0.lower] != nil }) else { return text }
        var edits: [(Range<String.Index>, String)] = []
        var i = 0
        while i < tokens.count {
            guard let run = numberRun(startingAt: i, in: tokens, text: text) else { i += 1; continue }
            if let edit = numberEdit(run, at: i, tokens: tokens, text: text, all: all) {
                edits.append((edit.range, edit.text))
                i = max(edit.end, run.end)
            } else {
                i = run.end
            }
        }
        var result = text
        for (range, replacement) in edits.reversed() {
            result.replaceSubrange(range, with: replacement)
        }
        return result
    }

    /// The replacement for one parsed run, or nil to leave it as words.
    private static func numberEdit(
        _ run: NumberRun, at i: Int, tokens: [Token], text: String, all: Bool
    ) -> (range: Range<String.Index>, text: String, end: Int)? {
        guard run.value >= 0, let rendered = render(run.words) else { return nil }
        let range = tokens[i].range.lowerBound..<tokens[run.end - 1].range.upperBound
        let next = run.end < tokens.count ? tokens[run.end] : nil
        let nextIsAdjacent = next.map { onlySpaces(text[range.upperBound..<$0.range.lowerBound]) } ?? false

        // "seven point five" → "7.5".
        if nextIsAdjacent, next?.lower == "point" {
            var j = run.end + 1
            var decimals = ""
            while j < tokens.count, let d = numberValue[tokens[j].lower], d < 10,
                  onlySpaces(text[tokens[j - 1].range.upperBound..<tokens[j].range.lowerBound]) {
                decimals += String(d)
                j += 1
            }
            if !decimals.isEmpty {
                return (range.lowerBound..<tokens[j - 1].range.upperBound, rendered + "." + decimals, j)
            }
        }

        let previous = i > 0 ? tokens[i - 1] : nil
        let previousIsAdjacent = previous.map { onlySpaces(text[$0.range.upperBound..<tokens[i].range.lowerBound]) } ?? false
        // Two numbers back to back ("sixteen a hundred", "seven twelve")
        // are a list or a dropped "to": leave both as words.
        if !all {
            if previousIsAdjacent, let previous, numberValue[previous.lower] != nil { return nil }
            if nextIsAdjacent, let next {
                if numberValue[next.lower] != nil { return nil }
                if next.lower == "a", run.end + 1 < tokens.count,
                   ["hundred", "thousand"].contains(tokens[run.end + 1].lower) { return nil }
            }
        }
        if let previous, previousIsAdjacent, isJoinableAcronym(previous.text) {
            return (previous.range.lowerBound..<range.upperBound, previous.text + rendered, run.end)
        }
        if !all, let previous, previousIsAdjacent, currencyWords.contains(previous.lower) { return nil }

        let percent = nextIsAdjacent && next?.lower == "percent"
        let unit = nextIsAdjacent && next.map { units.contains($0.lower) } == true
        let kilo = nextIsAdjacent && next?.lower == "k"
        let qualifies = all
            || ((run.words.count > 1 || run.value >= 10 || ((percent || unit || kilo) && run.value > 1))
                && !TranscriptCorrector.isSentenceStart(range.lowerBound, in: text))
        guard qualifies else { return nil }
        if percent, let next {
            return (range.lowerBound..<next.range.upperBound, rendered + "%", run.end + 1)
        }
        if kilo, let next {
            return (range.lowerBound..<next.range.upperBound, rendered + "k", run.end + 1)
        }
        return (range, rendered, run.end)
    }

    private struct Token {
        let text: String
        let lower: String
        let range: Range<String.Index>
    }

    private struct NumberRun {
        let words: [String]
        let value: Int
        let end: Int
    }

    private static func wordTokens(_ text: String) -> [Token] {
        var tokens: [Token] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            var end = index
            while end < text.endIndex, text[end].isLetter || text[end].isNumber {
                end = text.index(after: end)
            }
            let word = String(text[index..<end])
            tokens.append(Token(text: word, lower: word.lowercased(), range: index..<end))
            index = end
        }
        return tokens
    }

    private static func onlySpaces(_ gap: Substring) -> Bool {
        !gap.isEmpty && gap.allSatisfy { $0 == " " }
    }

    /// The longest run of number words from `start` that parses as one
    /// number. Words are joined by single spaces or a hyphen ("twenty-five");
    /// "and" only after hundred/thousand; "a" only before hundred/thousand.
    private static func numberRun(startingAt start: Int, in tokens: [Token], text: String) -> NumberRun? {
        var words: [String] = []
        var j = start
        while j < tokens.count {
            let word = tokens[j].lower
            if j > start {
                let gap = text[tokens[j - 1].range.upperBound..<tokens[j].range.lowerBound]
                guard gap == " " || gap == "-" else { break }
            }
            if numberValue[word] != nil {
                words.append(word)
            } else if word == "a", words.isEmpty, j + 1 < tokens.count,
                      ["hundred", "thousand"].contains(tokens[j + 1].lower) {
                words.append(word)
            } else if word == "and", let last = words.last, ["hundred", "thousand"].contains(last),
                      j + 1 < tokens.count, let v = numberValue[tokens[j + 1].lower], v < 100 {
                words.append(word)
            } else {
                break
            }
            j += 1
        }
        // Number words that don't parse as one number ("seven thirty",
        // "three six nine") are left as words, all of them: converting the
        // part that parses would give "seven 30". A trailing "a"/"and" that
        // led nowhere is dropped first.
        while let last = words.last, last == "a" || last == "and" { words.removeLast() }
        guard !words.isEmpty else { return nil }
        guard let value = parse(words) else {
            return NumberRun(words: words, value: -1, end: start + words.count)
        }
        return NumberRun(words: words, value: value, end: start + words.count)
    }

    /// Standard English number grammar; nil if the words aren't one number
    /// ("seven thirty", "three six nine", "nineteen eighty-four").
    private static func parse(_ words: [String]) -> Int? {
        enum Last { case none, unit, teen, tens, hundred, scale, and }
        var total = 0
        var current = 0
        var last = Last.none
        var lastScale = Int.max
        for word in words {
            if word == "a" {
                guard last == .none else { return nil }
                current = 1
                last = .unit
                continue
            }
            if word == "and" {
                guard last == .hundred || last == .scale else { return nil }
                last = .and
                continue
            }
            guard let value = numberValue[word] else { return nil }
            switch value {
            case 0:
                guard words.count == 1 else { return nil }
                return 0
            case 1...9:
                guard [.none, .tens, .hundred, .scale, .and].contains(last) else { return nil }
                current += value
                last = .unit
            case 10...19:
                guard [.none, .hundred, .scale, .and].contains(last) else { return nil }
                current += value
                last = .teen
            case 20...90:
                guard [.none, .hundred, .scale, .and].contains(last) else { return nil }
                current += value
                last = .tens
            case 100:
                guard last == .unit || last == .teen, current > 0, current < 100 else { return nil }
                current *= 100
                last = .hundred
            default:
                guard current > 0, current < 1000, value < lastScale, last != .and else { return nil }
                total += current * value
                current = 0
                lastScale = value
                last = .scale
            }
        }
        guard last != .and, last != .none else { return nil }
        if words.count == 1, ["hundred", "thousand", "million", "billion"].contains(words[0]) { return nil }
        return total + current
    }

    private static func render(_ words: [String]) -> String? {
        guard let value = parse(words) else { return nil }
        if let scaleWord = words.last, ["million", "billion"].contains(scaleWord),
           let scale = numberValue[scaleWord], value % scale == 0 {
            return "\(value / scale) \(scaleWord)"
        }
        if value >= 10_000 {
            let formatter = NumberFormatter()
            formatter.numberStyle = .decimal
            formatter.locale = Locale(identifier: "en_US")
            return formatter.string(from: NSNumber(value: value))
        }
        return String(value)
    }

    /// One or two capitals, but not words: "EC", "S", "BM", "CR", "V".
    private static func isJoinableAcronym(_ word: String) -> Bool {
        (1...2).contains(word.count)
            && word.allSatisfy { $0.isUppercase && $0.isLetter }
            && !["I", "A", "OK", "AM", "PM"].contains(word)
    }

    private static let numberValue: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
        "eight": 8, "nine": 9, "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16, "seventeen": 17, "eighteen": 18,
        "nineteen": 19, "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
        "seventy": 70, "eighty": 80, "ninety": 90, "hundred": 100, "thousand": 1_000,
        "million": 1_000_000, "billion": 1_000_000_000,
    ]

    private static let units: Set<String> = [
        "seconds", "minutes", "hours", "days", "weeks", "months", "years", "milliseconds", "ms",
        "hosts", "nodes", "entries", "threads", "cores", "servers", "instances", "submissions",
        "records", "documents", "rows", "users", "items", "files", "gb", "mb", "tb", "kb", "gigabytes",
        "megabytes", "terabytes", "times", "people", "steps", "pages", "tokens", "terms", "words",
    ]

    private static let currencyWords: Set<String> = [
        "dollar", "dollars", "pound", "pounds", "euro", "euros", "quid", "bucks", "cents", "pence",
    ]
}
