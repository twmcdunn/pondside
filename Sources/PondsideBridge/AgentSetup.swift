import Foundation
import PondsideLexicon

/// The per-folder configs that let an agent started next to a score find
/// `pondside mcp` with no setup: `.mcp.json` for Claude Code and
/// `opencode.json` for opencode, plus `.codex/config.toml` for Codex. A file the user already has is merged into,
/// never replaced: only a missing `pondside` server is added.
public enum AgentSetup {
    public enum Outcome: Equatable, Sendable {
        case created
        /// The `pondside` server was added beside the user's own settings.
        case added
        /// It already names a `pondside` server, which is left as the user has it.
        case present
        /// Unreadable, unsupported syntax, or not shaped as expected.
        case skipped(String)
    }

    public struct Change: Equatable, Sendable {
        public var file: String
        public var outcome: Outcome
    }

    struct Config {
        var file: String
        var container: String
        var server: JSONValue
        var preamble: [String: JSONValue] = [:]
    }

    static let configs = [
        Config(file: ".mcp.json", container: "mcpServers",
               server: ["type": "stdio", "command": "pondside", "args": ["mcp"]]),
        Config(file: "opencode.json", container: "mcp",
               server: ["type": "local", "command": ["pondside", "mcp"], "enabled": true],
               preamble: ["$schema": "https://opencode.ai/config.json"]),
    ]

    public static var fileNames: [String] { configs.map(\.file) + [".codex/config.toml"] }

    /// Writes or merges the configs in `directory`. A file that needs no
    /// change is not touched.
    @discardableResult
    public static func ensure(in directory: URL) -> [Change] {
        let jsonChanges = configs.map { config in
            let url = directory.appendingPathComponent(config.file)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            let (text, outcome) = updated(existing, config)
            if let text {
                do { try text.write(to: url, atomically: true, encoding: .utf8) }
                catch { return Change(file: config.file, outcome: .skipped(error.localizedDescription)) }
            }
            return Change(file: config.file, outcome: outcome)
        }
        return jsonChanges + [ensureCodex(in: directory)]
    }

    static let codexFile = ".codex/config.toml"
    static let codexServer = "[mcp_servers.pondside]\ncommand = \"pondside\"\nargs = [\"mcp\"]\n"

    private static func ensureCodex(in directory: URL) -> Change {
        let url = directory.appendingPathComponent(codexFile)
        do {
            let exists = FileManager.default.fileExists(atPath: url.path)
            let existing = exists ? try String(contentsOf: url, encoding: .utf8) : ""
            let parsed = try TOML.parse(existing)
            if let servers = parsed["mcp_servers"] {
                guard let table = servers.table else {
                    return Change(file: codexFile, outcome: .skipped("mcp_servers is not a table"))
                }
                if table["pondside"] != nil { return Change(file: codexFile, outcome: .present) }
            }
            // Inline tables cannot be extended by a later table declaration.
            // Leave these forms to the user rather than rewriting their TOML.
            if existing.range(of: #"(?m)^\s*(?:mcp_servers|"mcp_servers"|'mcp_servers')\s*="#,
                              options: .regularExpression) != nil {
                return Change(file: codexFile, outcome: .skipped("inline mcp_servers table; add pondside manually"))
            }
            let text = existing + (existing.isEmpty ? "" : "\n\n") + codexServer
            _ = try TOML.parse(text)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return Change(file: codexFile, outcome: exists ? .added : .created)
        } catch {
            return Change(file: codexFile, outcome: .skipped(error.localizedDescription))
        }
    }

    /// The new text for one config, or nil when it stays as it is.
    static func updated(_ existing: String?, _ config: Config) -> (String?, Outcome) {
        guard let existing, !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            var root = config.preamble
            root[config.container] = ["pondside": config.server]
            return (JSONValue.object(root).jsonString(pretty: true) + "\n", .created)
        }
        guard let parsed = try? JSONDecoder().decode(JSONValue.self, from: Data(existing.utf8)),
              case .object(var root) = parsed else {
            return (nil, .skipped("not plain JSON: comments, or not an object"))
        }
        var servers: [String: JSONValue] = [:]
        if let current = root[config.container] {
            guard case .object(let o) = current else { return (nil, .skipped("\"\(config.container)\" is not an object")) }
            servers = o
        }
        if servers["pondside"] != nil { return (nil, .present) }
        servers["pondside"] = config.server
        root[config.container] = .object(servers)
        return (JSONValue.object(root).jsonString(pretty: true) + "\n", .added)
    }
}
