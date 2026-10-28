import AVFoundation
import Foundation
import SusurrusKit
@preconcurrency import WhisperKit

/// Tier D: the user reads prompts aloud. The prompt text is the reference,
/// so clips are written `verified: true`.
///
/// Recording goes through WhisperKit's `AudioProcessor`, the same capture
/// and 16 kHz conversion the app uses. Re-running with the same script and
/// output directory resumes: prompts that already have a clip are skipped.
enum Record {
    static let usage = "record --script <prompts.txt|scripts.jsonl> --out <corpusDir>"

    struct Prompt {
        var scriptID: String
        var text: String
        var tags: [String]
        var clipID: String { "\(scriptID).user.read" }
    }

    static func run(_ args: [String]) throws {
        let parsed = try ParsedArgs.parse(args, valueOptions: ["script", "out"])
        guard parsed.positionals.isEmpty else { throw UsageError(message: "unexpected argument \(parsed.positionals[0])") }
        let scriptURL = expandPath(try parsed.require("script"))
        let corpus = EvalCorpus(directory: expandPath(try parsed.require("out")))

        let prompts = try loadPrompts(scriptURL)
        guard !prompts.isEmpty else { throw ToolError("no prompts in \(scriptURL.path)") }
        let done = Set(try corpus.readManifest().map(\.id))
        let todo = prompts.filter { !done.contains($0.clipID) }
        if todo.count < prompts.count {
            printOut("\(prompts.count - todo.count) of \(prompts.count) prompts already recorded in \(corpus.directory.path); resuming.")
        }
        guard !todo.isEmpty else {
            printOut("All prompts recorded.")
            return
        }
        copyVocabulary(from: scriptURL, to: corpus)

        try requireMicrophoneAccess()
        Terminal.installSignalHandlers()
        let player = ClipPlayer(enabled: true)
        defer { player.stop() }

        printOut("Read each prompt as you would dictate it. Enter starts and stops recording.\n")
        var kept = 0
        prompts: for (index, prompt) in todo.enumerated() {
            printOut(Terminal.bold("[\(index + 1)/\(todo.count)] \(prompt.scriptID)"))
            printOut("  \"\(prompt.text)\"")
            printOut(Terminal.dim("  [Enter] start recording  [s]kip  [q]uit"))
            switch waitFor(enter: true, keys: ["s", "q"]) {
            case "s": printOut("  skipped\n"); continue prompts
            case "q", nil: break prompts
            default: break
            }

            while true {
                let samples = try recordUntilEnter()
                let seconds = Double(samples.count) / Double(WAV.sampleRate)
                let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
                let peakDB = peak > 0 ? 20 * log10(Double(peak)) : -120
                var status = String(format: "  recorded %.1fs, peak %.0f dBFS", seconds, peakDB)
                if peakDB < -50 { status += Terminal.yellow("  (near-silent: is the microphone muted or access denied?)") }
                printOut(status)
                printOut(Terminal.dim("  [Enter] keep  [r]edo  [p]lay  [s]kip  [q]uit"))

                var choice = waitFor(enter: true, keys: ["r", "p", "s", "q"])
                while choice == "p" {
                    let preview = FileManager.default.temporaryDirectory.appendingPathComponent("susurrus-record-preview.wav")
                    try WAV.write(samples: samples, to: preview)
                    player.play(preview)
                    choice = waitFor(enter: true, keys: ["r", "p", "s", "q"])
                    player.stop()
                }
                switch choice {
                case "r":
                    continue
                case "s": printOut("  skipped\n"); continue prompts
                case "q", nil: break prompts
                default:
                    try save(prompt, samples: samples, to: corpus)
                    kept += 1
                    printOut(Terminal.green("  saved \(prompt.clipID)\n"))
                    continue prompts
                }
            }
        }

        let total = (try? corpus.readManifest().count) ?? 0
        printOut("\nkept \(kept) this session; \(total) clip(s) in \(corpus.directory.path)")
        if !FileManager.default.fileExists(atPath: corpus.directory.appendingPathComponent("vocabulary.json").path) {
            printOut("Before `run`, add a vocabulary.json: `susurrus-eval snapshot --out \(corpus.directory.path)`.")
        }
    }

    /// Returns "\n" for Enter (when allowed), a key from `keys`, or nil at
    /// end of input.
    static func waitFor(enter: Bool, keys: Set<Character>) -> Character? {
        while let key = Terminal.readKey() {
            if enter, Terminal.isEnter(key) { return "\n" }
            let lower = Character(key.lowercased())
            if keys.contains(lower) { return lower }
        }
        return nil
    }

    /// TCC attributes a CLI's microphone use to the terminal app running it.
    /// Uses AVCaptureDevice's completion-handler API: the async
    /// `AVAudioApplication.requestRecordPermission()` (what WhisperKit's
    /// helper calls) crashes resuming its continuation in a command-line tool.
    static func requireMicrophoneAccess() throws {
        let denied = ToolError("microphone access denied. Allow your terminal app in System Settings › Privacy & Security › Microphone, then rerun.")
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            let done = DispatchSemaphore(value: 0)
            nonisolated(unsafe) var granted = false
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                granted = ok
                done.signal()
            }
            done.wait()
            if !granted { throw denied }
        default:
            throw denied
        }
    }

    /// Records from the default input device until Enter (or end of input).
    static func recordUntilEnter() throws -> [Float] {
        let processor: any AudioProcessing = AudioProcessor()
        try processor.startRecordingLive(inputDeviceID: nil, callback: nil)
        printOut(Terminal.red("  ● recording") + Terminal.dim(" — Enter to stop"))
        _ = waitFor(enter: true, keys: [])
        // A short grace period so the final word isn't clipped.
        Thread.sleep(forTimeInterval: 0.25)
        processor.stopRecording()
        return Array(processor.audioSamples)
    }

    static func save(_ prompt: Prompt, samples: [Float], to corpus: EvalCorpus) throws {
        let relative = "clips/\(prompt.clipID).wav"
        try WAV.write(samples: samples, to: corpus.directory.appendingPathComponent(relative))
        let seconds = Double(samples.count) / Double(WAV.sampleRate)
        var tags = prompt.tags
        if !tags.contains("short") && !tags.contains("long") { tags.append(EvalManifestEntry.lengthTag(seconds: seconds)) }
        if !tags.contains("read") { tags.append("read") }
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let entry = EvalManifestEntry(
            id: prompt.clipID, script: prompt.scriptID, audio: relative, reference: prompt.text, tags: tags,
            source: "read", voice: "user", variant: "read", verified: true,
            seconds: (seconds * 100).rounded() / 100, capturedAt: now
        )
        try corpus.update { entries in
            entries.removeAll { $0.id == entry.id }
            entries.append(entry)
        }
    }

    /// `.jsonl`: the `synth` scripts format (ids and tags kept, silence
    /// entries skipped), so the golden scripts can be read in your voice.
    /// Anything else: one prompt per line; blank lines and `#` comments
    /// skipped; ids derived from the text, so reordering the file is safe.
    static func loadPrompts(_ url: URL) throws -> [Prompt] {
        if url.pathExtension == "jsonl" {
            return try JSON.readLines(ScriptEntry.self, from: url)
                .filter { !$0.isSilence && !$0.text.isEmpty }
                .map { Prompt(scriptID: $0.id, text: $0.text, tags: $0.tags) }
        }
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch { throw ToolError("cannot read \(url.path): \(error.localizedDescription)") }
        var seen = Set<String>()
        return text.split(separator: "\n").compactMap { line in
            let prompt = line.trimmingCharacters(in: .whitespaces)
            guard !prompt.isEmpty, !prompt.hasPrefix("#"), seen.insert(prompt).inserted else { return nil }
            return Prompt(scriptID: String(format: "read-%08x", UInt32(truncatingIfNeeded: stableSeed(prompt))), text: prompt, tags: [])
        }
    }

    /// A scripts file with a `vocabulary.json` beside it (the golden set)
    /// brings that vocabulary along, so `run` scores the same terms.
    static func copyVocabulary(from scriptURL: URL, to corpus: EvalCorpus) {
        let source = scriptURL.deletingLastPathComponent().appendingPathComponent("vocabulary.json")
        let target = corpus.directory.appendingPathComponent("vocabulary.json")
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path), !fm.fileExists(atPath: target.path) else { return }
        do {
            try fm.createDirectory(at: corpus.directory, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            printOut("copied \(source.path) to the corpus")
        } catch {
            printErr("note: could not copy vocabulary.json: \(error.localizedDescription)")
        }
    }
}
