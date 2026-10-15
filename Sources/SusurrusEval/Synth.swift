import Foundation

enum Synth {
    static let usage = "synth --scripts <scripts.jsonl> --out <corpusDir> [--voices \"Daniel,Flo\"] [--variants clean,paused,noisy]"

    static let knownVariants = ["clean", "paused", "noisy"]

    static func run(_ args: [String]) throws {
        let parsed = try ParsedArgs.parse(args, valueOptions: ["scripts", "out", "voices", "variants"])
        guard parsed.positionals.isEmpty else { throw UsageError(message: "unexpected argument \(parsed.positionals[0])") }
        let scriptsURL = expandPath(try parsed.require("scripts"))
        let outDir = expandPath(try parsed.require("out"))
        let voices = (parsed.options["voices"] ?? "Daniel").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let variants = (parsed.options["variants"] ?? "clean,paused").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
        guard !voices.isEmpty else { throw UsageError(message: "--voices is empty") }
        guard !variants.isEmpty else { throw UsageError(message: "--variants is empty") }
        for v in variants where !knownVariants.contains(v) {
            throw UsageError(message: "unknown variant '\(v)' (known: \(knownVariants.joined(separator: ", ")))")
        }

        let scripts = try JSON.readLines(ScriptEntry.self, from: scriptsURL)
        try validate(scripts)

        let resolvedVoices = try voices.map { (short: $0, say: try resolveVoice($0)) }
        for voice in resolvedVoices where voice.short.lowercased() != voice.say.lowercased() {
            printErr("voice '\(voice.short)' -> '\(voice.say)'")
        }

        let clipsDir = outDir.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("susurrus-eval-synth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var manifest: [ManifestEntry] = []

        func emit(id: String, script: ScriptEntry, voice: String, variant: String, samples: [Float], source: String) throws {
            let rel = "clips/\(id).wav"
            try WAV.write(samples: samples, to: outDir.appendingPathComponent(rel))
            var tags = script.tags
            if !tags.contains(variant) { tags.append(variant) }
            manifest.append(ManifestEntry(
                id: id, script: script.id, audio: rel, reference: script.text, tags: tags,
                source: source, voice: voice, variant: variant, verified: true
            ))
            printErr(String(format: "  %@  %.1fs", id, Double(samples.count) / Double(WAV.sampleRate)))
        }

        for script in scripts {
            if script.isSilence {
                let id = "\(script.id).none.silence"
                let samples = Noise.room(seconds: script.silenceSeconds ?? 6, seed: stableSeed(id))
                try emit(id: id, script: script, voice: "none", variant: "silence", samples: samples, source: "synthetic")
                continue
            }
            for voice in resolvedVoices {
                let lower = voice.short.lowercased()
                var clean: [Float]?
                func cleanSamples() throws -> [Float] {
                    if let clean { return clean }
                    let s = try render(text: script.text, voice: voice.say, scratch: scratch)
                    clean = s
                    return s
                }
                for variant in variants {
                    let id = "\(script.id).\(lower).\(variant)"
                    let samples: [Float]
                    switch variant {
                    case "clean":
                        samples = try cleanSamples()
                    case "paused":
                        samples = try render(text: pausedText(script.text), voice: voice.say, scratch: scratch)
                    default:  // noisy
                        samples = Noise.mix(try cleanSamples(), snrDB: 20, seed: stableSeed(id))
                    }
                    try emit(id: id, script: script, voice: voice.short, variant: variant, samples: samples, source: "tts")
                }
            }
        }

        try JSON.writeLines(manifest, to: outDir.appendingPathComponent("manifest.jsonl"))
        printOut("Wrote \(manifest.count) clips to \(outDir.path)")
        if !FileManager.default.fileExists(atPath: outDir.appendingPathComponent("vocabulary.json").path) {
            printErr("note: no vocabulary.json in \(outDir.path); supply one (or run `snapshot`) before `run`")
        }
    }

    static func validate(_ scripts: [ScriptEntry]) throws {
        var seen = Set<String>()
        for s in scripts {
            guard s.id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
                throw ToolError("script id '\(s.id)' must match [a-z0-9-]+")
            }
            guard seen.insert(s.id).inserted else { throw ToolError("duplicate script id '\(s.id)'") }
            if !s.isSilence, s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw ToolError("script '\(s.id)' has empty text and is not a silence entry")
            }
            if s.isSilence, !s.text.isEmpty {
                throw ToolError("silence script '\(s.id)' must have empty text")
            }
        }
    }

    /// `[[slnc 1500]]` after every second comma and `[[slnc 1000]]` after
    /// each sentence end except the last — thinking pauses. Punctuation
    /// only counts when followed by whitespace, so "10,000" and "3.5" are
    /// left alone.
    static func pausedText(_ text: String) -> String {
        let chars = Array(text)
        var out = ""
        var commas = 0
        for (i, c) in chars.enumerated() {
            out.append(c)
            guard i + 1 < chars.count, chars[i + 1].isWhitespace else { continue }
            if c == "," {
                commas += 1
                if commas % 2 == 0 { out += " [[slnc 1500]]" }
            } else if c == "." || c == "?" || c == "!" {
                if chars[(i + 1)...].contains(where: { !$0.isWhitespace }) { out += " [[slnc 1000]]" }
            }
        }
        return out
    }

    // MARK: - say

    /// Maps a short voice name ("Flo") to what `say -v` accepts. A name that
    /// matches several locale variants prefers en_GB, then en_US, then any
    /// English voice. An exact name match wins outright.
    static func resolveVoice(_ name: String) throws -> String {
        let listing = try runProcess("/usr/bin/say", ["-v", "?"])
        guard listing.status == 0 else { throw ToolError("`say -v ?` failed: \(listing.stderr)") }
        var voices: [(name: String, locale: String)] = []
        for line in listing.stdout.split(separator: "\n") {
            let head = line.split(separator: "#", maxSplits: 1).first.map(String.init) ?? String(line)
            guard let m = head.range(of: "\\s+[a-z]{2,3}[_-][A-Za-z0-9]+\\s*$", options: .regularExpression) else { continue }
            let voiceName = head[..<m.lowerBound].trimmingCharacters(in: .whitespaces)
            let locale = head[m].trimmingCharacters(in: .whitespaces)
            voices.append((voiceName, locale))
        }
        let want = name.lowercased()
        if let exact = voices.first(where: { $0.name.lowercased() == want }) { return exact.name }
        let candidates = voices.filter { $0.name.lowercased().hasPrefix(want + " (") }
        guard !candidates.isEmpty else {
            throw ToolError("no `say` voice matches '\(name)' (see `say -v '?'`)")
        }
        for prefix in ["en_GB", "en_US", "en"] {
            if let hit = candidates.first(where: { $0.locale.hasPrefix(prefix) }) { return hit.name }
        }
        return candidates[0].name
    }

    static func render(text: String, voice: String, scratch: URL) throws -> [Float] {
        let file = scratch.appendingPathComponent("\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: file) }
        let result = try runProcess("/usr/bin/say", [
            "-v", voice, "-o", file.path, "--file-format=WAVE", "--data-format=LEI16@16000", "--", text,
        ])
        guard result.status == 0 else { throw ToolError("say failed for voice '\(voice)': \(result.stderr)") }
        return try WAV.read(url: file)
    }
}
