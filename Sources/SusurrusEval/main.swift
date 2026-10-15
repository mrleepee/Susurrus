import Foundation

let usageText = """
susurrus-eval: offline accuracy harness for Susurrus (see docs/eval-harness.md)

Usage:
  susurrus-eval \(Synth.usage)
  susurrus-eval \(Run.usage)
  susurrus-eval \(Compare.usage)
  susurrus-eval \(Snapshot.usage)

Exit codes: 0 success, 1 failure (or gate failure), 2 usage error.
"""

func runCLI(_ args: [String]) async -> Int32 {
    guard let command = args.first else {
        printErr(usageText)
        return 2
    }
    if ["--help", "-h", "help"].contains(command) {
        printOut(usageText)
        return 0
    }
    let rest = Array(args.dropFirst())
    if rest.contains("--help") || rest.contains("-h") {
        printOut(usageText)
        return 0
    }
    do {
        switch command {
        case "synth": try Synth.run(rest)
        case "run": try await Run.run(rest)
        case "snapshot": try Snapshot.run(rest)
        case "compare": return try Compare.run(rest)
        default: throw UsageError(message: "unknown command '\(command)'")
        }
        return 0
    } catch let error as UsageError {
        printErr("error: \(error.message)\n\n\(usageText)")
        return 2
    } catch {
        printErr("error: \(error)")
        return 1
    }
}

exit(await runCLI(Array(CommandLine.arguments.dropFirst())))
