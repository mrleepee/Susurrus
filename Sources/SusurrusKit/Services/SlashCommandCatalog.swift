import Foundation

/// Names `SpokenFormatter` can turn "slash …" into: Claude Code's built-in
/// commands plus the user's own skills, commands and installed plugins, read
/// from `~/.claude`. Knowing the real names is what lets "slash code review"
/// become "/code-review" and "slash auto pilot" become "/autopilot".
public enum SlashCommandCatalog {

    /// Claude Code built-in commands and bundled skills, which live in the
    /// app rather than `~/.claude`. Many are ordinary words ("clear",
    /// "review"), which the formatter's common-word fallback would skip.
    public static let builtIns = [
        "add-dir", "agents", "bug", "claude-api", "clear", "code-review", "compact",
        "config", "context", "cost", "doctor", "exit", "export", "fewer-permission-prompts",
        "help", "hooks", "init", "keybindings-help", "login", "logout", "loop", "mcp",
        "memory", "model", "permissions", "plugin", "pr-comments", "release-notes",
        "resume", "review", "rewind", "run", "schedule", "security-review", "simplify",
        "status", "statusline", "terminal-setup", "update-config", "usage", "vim",
    ]

    /// Built-ins plus everything under `claudeDirectory`. Missing or
    /// unreadable directories contribute nothing rather than failing.
    public static func discover(
        claudeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude"),
        fileManager: FileManager = .default
    ) -> [String] {
        var names = Set(builtIns)
        var roots = [claudeDirectory]
        roots += pluginInstallPaths(claudeDirectory: claudeDirectory)

        for root in roots {
            names.formUnion(commandNames(in: root.appendingPathComponent("commands"), fileManager: fileManager))
            names.formUnion(skillNames(in: root.appendingPathComponent("skills"), fileManager: fileManager))
        }
        return names.sorted()
    }

    /// `commands/<name>.md`, one level of subdirectories included.
    static func commandNames(in directory: URL, fileManager: FileManager) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for entry in entries {
            if entry.pathExtension == "md" {
                names.append(entry.deletingPathExtension().lastPathComponent)
            } else if let nested = try? fileManager.contentsOfDirectory(at: entry, includingPropertiesForKeys: nil) {
                names += nested.filter { $0.pathExtension == "md" }.map { $0.deletingPathExtension().lastPathComponent }
            }
        }
        return names
    }

    /// `skills/<dir>/SKILL.md` — the directory name, and the frontmatter
    /// `name:` when it differs (a skill in `marklogic-sparql/` named `sparql`).
    static func skillNames(in directory: URL, fileManager: FileManager) -> [String] {
        guard let entries = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return [] }
        var names: [String] = []
        for entry in entries {
            let skill = entry.appendingPathComponent("SKILL.md")
            guard fileManager.fileExists(atPath: skill.path) else { continue }
            names.append(entry.lastPathComponent)
            if let name = frontmatterName(of: skill) { names.append(name) }
        }
        return names
    }

    static func frontmatterName(of file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 2048),
              let head = String(data: data, encoding: .utf8),
              head.hasPrefix("---") else { return nil }
        for line in head.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            guard line.hasPrefix("name:") else { continue }
            let value = line.dropFirst("name:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Install paths from `plugins/installed_plugins.json` (format version 2).
    static func pluginInstallPaths(claudeDirectory: URL) -> [URL] {
        struct Installed: Decodable {
            struct Install: Decodable { let installPath: String }
            let plugins: [String: [Install]]
        }
        let file = claudeDirectory.appendingPathComponent("plugins/installed_plugins.json")
        guard let data = try? Data(contentsOf: file),
              let installed = try? JSONDecoder().decode(Installed.self, from: data) else { return [] }
        return installed.plugins.values.flatMap { $0 }.map { URL(fileURLWithPath: $0.installPath) }
    }
}
