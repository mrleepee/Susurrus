import CryptoKit
import Foundation

/// Bad command-line usage: printed with the usage text, exit code 2.
struct UsageError: Error {
    let message: String
}

/// A runtime failure: printed as `error: …`, exit code 1.
struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func printErr(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func printOut(_ message: String) {
    FileHandle.standardOutput.write(Data((message + "\n").utf8))
}

// MARK: - JSON

enum JSON {
    /// Pretty-printed, sorted keys, ISO-8601 dates.
    static func prettyEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// One compact line per value, for `.jsonl` files.
    static func lineEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// ISO-8601 with or without fractional seconds.
    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            let plain = ISO8601DateFormatter()
            if let date = plain.date(from: string) { return date }
            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = fractional.date(from: string) { return date }
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Bad ISO-8601 date: \(string)")
            )
        }
        return d
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try prettyEncoder().encode(value).write(to: url, options: .atomic)
    }

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw ToolError("cannot read \(url.path): \(error.localizedDescription)") }
        do { return try decoder().decode(type, from: data) } catch { throw ToolError("cannot parse \(url.path): \(error)") }
    }

    /// Reads a `.jsonl` file, skipping blank lines.
    static func readLines<T: Decodable>(_ type: T.Type, from url: URL) throws -> [T] {
        let text: String
        do { text = try String(contentsOf: url, encoding: .utf8) } catch { throw ToolError("cannot read \(url.path): \(error.localizedDescription)") }
        let dec = decoder()
        var out: [T] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: true).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            do { out.append(try dec.decode(type, from: Data(trimmed.utf8))) } catch {
                throw ToolError("\(url.lastPathComponent) line \(index + 1): \(error)")
            }
        }
        return out
    }

    static func writeLines<T: Encodable>(_ values: [T], to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let enc = lineEncoder()
        var data = Data()
        for value in values {
            data.append(try enc.encode(value))
            data.append(0x0A)
        }
        try data.write(to: url, options: .atomic)
    }
}

// MARK: - Argument parsing

struct ParsedArgs {
    var options: [String: String] = [:]
    var flags: Set<String> = []
    var positionals: [String] = []

    /// Hand-rolled: `--name value`, `--name=value`, boolean flags, positionals.
    static func parse(_ args: [String], valueOptions: Set<String>, flagOptions: Set<String> = []) throws -> ParsedArgs {
        var parsed = ParsedArgs()
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg.hasPrefix("--") {
                var name = String(arg.dropFirst(2))
                var inline: String?
                if let eq = name.firstIndex(of: "=") {
                    inline = String(name[name.index(after: eq)...])
                    name = String(name[..<eq])
                }
                if flagOptions.contains(name) {
                    if inline != nil { throw UsageError(message: "--\(name) does not take a value") }
                    parsed.flags.insert(name)
                } else if valueOptions.contains(name) {
                    if let inline {
                        parsed.options[name] = inline
                    } else {
                        guard i + 1 < args.count else { throw UsageError(message: "--\(name) needs a value") }
                        i += 1
                        parsed.options[name] = args[i]
                    }
                } else {
                    throw UsageError(message: "unknown option --\(name)")
                }
            } else {
                parsed.positionals.append(arg)
            }
            i += 1
        }
        return parsed
    }

    func require(_ name: String) throws -> String {
        guard let value = options[name] else { throw UsageError(message: "missing required --\(name)") }
        return value
    }
}

func expandPath(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
}

// MARK: - Processes

struct ProcessOutput {
    var status: Int32
    var stdout: String
    var stderr: String
}

func runProcess(_ executable: String, _ arguments: [String], currentDirectory: URL? = nil) throws -> ProcessOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    if let currentDirectory { process.currentDirectoryURL = currentDirectory }
    let out = Pipe(), err = Pipe()
    process.standardOutput = out
    process.standardError = err
    try process.run()
    // Drain stderr on a side thread so a chatty child cannot fill the pipe
    // while we block reading stdout.
    nonisolated(unsafe) var errData = Data()
    let errDone = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        errData = err.fileHandleForReading.readDataToEndOfFile()
        errDone.signal()
    }
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    errDone.wait()
    process.waitUntilExit()
    return ProcessOutput(
        status: process.terminationStatus,
        stdout: String(decoding: outData, as: UTF8.self),
        stderr: String(decoding: errData, as: UTF8.self)
    )
}

func sha256Hex(of url: URL) throws -> String {
    let data = try Data(contentsOf: url, options: .mappedIfSafe)
    return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

// MARK: - Table rendering

/// Left-aligns the first column and right-aligns the rest.
func renderTable(headers: [String], rows: [[String]]) -> String {
    var widths = headers.map(\.count)
    for row in rows {
        for (i, cell) in row.enumerated() where i < widths.count { widths[i] = max(widths[i], cell.count) }
    }
    func pad(_ s: String, _ w: Int, left: Bool) -> String {
        let fill = String(repeating: " ", count: max(0, w - s.count))
        return left ? s + fill : fill + s
    }
    func line(_ cells: [String]) -> String {
        cells.enumerated().map { pad($1, widths[$0], left: $0 == 0) }.joined(separator: "  ")
    }
    var out = [line(headers), widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")]
    out += rows.map(line)
    return out.joined(separator: "\n")
}

func pct(_ x: Double) -> String { String(format: "%.1f%%", x * 100) }

func truncate(_ text: String, to limit: Int = 160) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    return flat.count > limit ? String(flat.prefix(limit - 3)) + "..." : flat
}
