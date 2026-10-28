import Foundation
@preconcurrency import WhisperKit

/// Downloads a WhisperKit model into the app's model folder, using the same
/// `downloadBase` as `StreamingTranscriptionService.setupModel`, so the result
/// is picked up by `run`/`segment` through `Run.resolveModelFolder`.
enum Download {
    static let usage = "download --model <variant> | download --list"

    /// Same base the app uses: `~/Library/Application Support/Susurrus`.
    static func downloadBase() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Susurrus")
    }

    /// Where WhisperKit's Hub layout places `argmaxinc/whisperkit-coreml` variants.
    static func modelsDirectory() -> URL {
        downloadBase().appendingPathComponent("models/argmaxinc/whisperkit-coreml")
    }

    static func run(_ args: [String]) async throws {
        let parsed = try ParsedArgs.parse(args, valueOptions: ["model"], flagOptions: ["list"])
        guard parsed.positionals.isEmpty else { throw UsageError(message: "unexpected argument \(parsed.positionals[0])") }

        if parsed.flags.contains("list") {
            guard parsed.options["model"] == nil else { throw UsageError(message: "--list takes no --model") }
            for name in try listFolders() { printOut(name) }
            return
        }

        let variant = try parsed.require("model")
        guard !variant.isEmpty, !variant.contains("/") else {
            throw UsageError(message: "--model must be a WhisperKit variant name, e.g. openai_whisper-large-v3-v20240930_turbo")
        }

        printErr("download: \(variant) -> \(modelsDirectory().path)")
        let reporter = ProgressReporter()
        let folder = try await WhisperKit.download(
            variant: variant,
            downloadBase: downloadBase(),
            progressCallback: { progress in
                reporter.report(progress)
            }
        )
        reporter.finish()
        printOut(folder.path)
    }

    static func listFolders() throws -> [String] {
        let dir = modelsDirectory()
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { name in
                guard !name.hasPrefix(".") else { return false }  // skip Hub's .cache
                var isDir: ObjCBool = false
                return FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path, isDirectory: &isDir) && isDir.boolValue
            }
            .sorted()
    }
}

/// Prints `download: N%` to stderr at most once per 5% bucket.
private final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBucket = -1

    func report(_ progress: Progress) {
        guard progress.totalUnitCount > 0 else { return }
        let fraction = Double(progress.completedUnitCount) / Double(progress.totalUnitCount)
        let bucket = min(20, Int(fraction * 20))  // 20 buckets = 5% each
        lock.lock()
        defer { lock.unlock() }
        guard bucket > lastBucket else { return }
        lastBucket = bucket
        printErr("download: \(bucket * 5)%")
    }

    func finish() {
        printErr("download: done")
    }
}
