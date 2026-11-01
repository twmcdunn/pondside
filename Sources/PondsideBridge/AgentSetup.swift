import Foundation

/// The per-folder configs that let an agent started next to a score find
/// `pondside mcp` with no setup: `.mcp.json` for Claude Code and
/// `opencode.json` for opencode. A file the user already has is merged into,
/// never replaced: only a missing `pondside` server is added.
public enum AgentSetup {
    public enum Outcome: Equatable, Sendable {
        case created
        /// The `pondside` server was added beside the user's own settings.
        case added
        /// It already names a `pondside` server, which is left as the user has it.
        case present
        /// Not valid JSON (e.g. JSONC comments) or not shaped as expected.
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

    public static var fileNames: [String] { configs.map(\.file) }

    /// Writes or merges both configs in `directory`. A file that needs no
    /// change is not touched.
    @discardableResult
    public static func ensure(in directory: URL) -> [Change] {
        configs.map { config in
            let url = directory.appendingPathComponent(config.file)
            let existing = try? String(contentsOf: url, encoding: .utf8)
            let (text, outcome) = updated(existing, config)
            if let text {
                do { try text.write(to: url, atomically: true, encoding: .utf8) }
                catch { return Change(file: config.file, outcome: .skipped(error.localizedDescription)) }
            }
            return Change(file: config.file, outcome: outcome)
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
