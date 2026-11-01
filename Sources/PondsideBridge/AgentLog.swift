import Foundation

/// A durable, structured record of everything Pondside's agents do: each
/// run's command line, prompt, every tool call and reply from the agent's
/// event stream, its stderr, exit and outcome, and (from the `pondside mcp`
/// process the agent starts) each MCP tool call with its duration.
///
/// One JSON object per line (JSONL) in `~/Library/Logs/Pondside/agents.jsonl`
/// (Console.app opens it; `jq` reads it). Several processes append to it:
/// each entry is one `write` of one line to a file opened with O_APPEND, so
/// lines never interleave. The app reads the file back (`read(from:)`) for
/// its Agent Log pane, so its own entries and the MCP server's come by one
/// path. Rotated at 8 MB, keeping one older file.
public final class AgentLog: @unchecked Sendable {
    public enum Kind: String, Codable, Sendable {
        /// A request about the selection (the lens's request line).
        case graphics
        /// A SuperCollider patch migration: Pondside's own part, then the agent's.
        case refactor
        /// A request from the lens to the patch agent.
        case patch
        /// A tool call served by `pondside mcp` for a run.
        case mcp
    }

    public enum Level: String, Codable, Sendable, Comparable {
        case debug, info, warning, error

        var rank: Int { [.debug: 0, .info: 1, .warning: 2, .error: 3][self]! }
        public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
    }

    public struct Entry: Codable, Sendable, Equatable {
        /// ISO 8601 with milliseconds, UTC.
        public var time: String
        /// The run this belongs to (a short id); MCP entries carry the run that started their server.
        public var run: String
        public var kind: Kind
        public var level: Level
        /// What happened: start, prompt, tool, result, text, thinking, stderr, exit, outcome, mcp, note…
        public var event: String
        /// One line, for the pane.
        public var message: String
        /// Seconds since the run started, when known.
        public var elapsed: Double?
        /// The full detail (a prompt, a tool's input or output), capped.
        public var detail: String?

        public init(time: String, run: String, kind: Kind, level: Level, event: String, message: String,
                    elapsed: Double? = nil, detail: String? = nil) {
            self.time = time
            self.run = run
            self.kind = kind
            self.level = level
            self.event = event
            self.message = message
            self.elapsed = elapsed
            self.detail = detail
        }
    }

    /// Environment variables an agent's process (and so its MCP server) inherits.
    public static let runVariable = "PONDSIDE_AGENT_RUN"
    public static let kindVariable = "PONDSIDE_AGENT_KIND"
    public static let runFileVariable = "PONDSIDE_AGENT_RUN_FILE"
    public static let startVariable = "PONDSIDE_AGENT_RUN_START"
    public static let directoryVariable = "PONDSIDE_LOG_DIR"

    /// Details are capped so one huge tool result can't bloat the file.
    public static let detailLimit = 16_000
    /// Prompts are kept nearly whole: they are what to read first.
    public static let promptLimit = 64_000
    static let rotateAt: UInt64 = 8 * 1024 * 1024

    public let url: URL
    private let lock = NSLock()

    public init(directory: URL) {
        url = directory.appendingPathComponent("agents.jsonl")
    }

    /// `$PONDSIDE_LOG_DIR`, else ~/Library/Logs/Pondside (macOS) or
    /// $XDG_STATE_HOME/pondside (Linux).
    public static let shared: AgentLog = {
        let env = ProcessInfo.processInfo.environment
        if let dir = env[directoryVariable], !dir.isEmpty { return AgentLog(directory: URL(fileURLWithPath: dir)) }
        let home = FileManager.default.homeDirectoryForCurrentUser
        #if os(macOS)
        return AgentLog(directory: home.appendingPathComponent("Library/Logs/Pondside"))
        #else
        let state = env["XDG_STATE_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".local/state")
        return AgentLog(directory: state.appendingPathComponent("pondside"))
        #endif
    }()

    // MARK: Writing

    public func append(_ entry: Entry) {
        guard var line = try? Self.encoder.encode(entry) else { return }
        line.append(0x0A)
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > Self.rotateAt {
            let old = url.deletingPathExtension().appendingPathExtension("1.jsonl")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        guard fd >= 0 else { return }
        line.withUnsafeBytes { _ = write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    public static func timestamp(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func cap(_ s: String, _ limit: Int = detailLimit) -> String {
        s.count <= limit ? s : String(s.prefix(limit)) + "\n… (\(s.count - limit) more characters)"
    }

    /// A new run's id: 8 hex digits, enough to tell runs apart in a day's log.
    public static func newRunID() -> String {
        String(UInt32.random(in: .min ... .max), radix: 16).leftPadded(to: 8)
    }

    // MARK: Reading

    /// The entries after byte `offset` of the file, and the offset to read
    /// from next. A partial last line is left for the next read; a file
    /// shorter than `offset` (rotated) is read from its start.
    public func read(from offset: UInt64) -> (entries: [Entry], next: UInt64) {
        guard let h = try? FileHandle(forReadingFrom: url) else { return ([], 0) }
        defer { try? h.close() }
        let end = (try? h.seekToEnd()) ?? 0
        var start = offset
        if end < offset { start = 0 }
        guard end > start else { return ([], start) }
        try? h.seek(toOffset: start)
        let data = (try? h.readToEnd()) ?? Data()
        guard let last = data.lastIndex(of: 0x0A) else { return ([], start) }
        let complete = data[data.startIndex...last]
        let decoder = JSONDecoder()
        let entries = complete.split(separator: 0x0A).compactMap { try? decoder.decode(Entry.self, from: Data($0)) }
        return (entries, start + UInt64(complete.count))
    }

    /// The last `limit` entries of the file (for opening the pane), and the offset after them.
    public func tail(_ limit: Int = 2000) -> (entries: [Entry], next: UInt64) {
        let (all, next) = read(from: 0)
        return (Array(all.suffix(limit)), next)
    }
}

extension String {
    func leftPadded(to n: Int) -> String { count >= n ? self : String(repeating: "0", count: n - count) + self }
}

// MARK: - A run

extension AgentLog {
    /// One run's entries: everything it logs carries its id, kind and the
    /// time since it started.
    public final class Run: @unchecked Sendable {
        public let id: String
        public let kind: Kind
        public let started: Date
        private let log: AgentLog
        private let lock = NSLock()
        private var firstEvent: Date?

        public init(kind: Kind, id: String = AgentLog.newRunID(), started: Date = Date(), log: AgentLog = .shared) {
            self.kind = kind
            self.id = id
            self.started = started
            self.log = log
        }

        public var elapsed: Double { Date().timeIntervalSince(started) }

        public func log(_ event: String, _ message: String, level: Level = .info, detail: String? = nil,
                        limit: Int = AgentLog.detailLimit) {
            log.append(Entry(time: AgentLog.timestamp(), run: id, kind: kind, level: level, event: event,
                             message: message, elapsed: (elapsed * 1000).rounded() / 1000,
                             detail: detail.map { AgentLog.cap($0, limit) }))
        }

        /// The environment that lets `pondside mcp`, started by the agent, log into this run.
        public var environment: [String: String] {
            [AgentLog.runVariable: id, AgentLog.kindVariable: kind.rawValue, AgentLog.startVariable: marker]
        }

        /// "<id> <start in seconds since 1970>": the run file's contents.
        public var marker: String { "\(id) \(started.timeIntervalSince1970)" }

        /// A run from `marker`, for the MCP server's entries.
        static func parse(_ marker: String, kind: Kind) -> Run? {
            let parts = marker.split(separator: " ")
            guard let id = parts.first.map(String.init), !id.isEmpty else { return nil }
            let start = parts.count > 1 ? Double(parts[1]).map { Date(timeIntervalSince1970: $0) } : nil
            return Run(kind: kind, id: id, started: start ?? Date())
        }

        /// Logs one line of the agent's event stream (claude's or opencode's
        /// JSON): its tool calls, replies, results and errors. The first
        /// event also records how long the agent took to start.
        public func stream(_ line: Substring, harness: AgentHarness) {
            lock.lock()
            let first = firstEvent == nil
            if first { firstEvent = Date() }
            lock.unlock()
            if first { log("ready", String(format: "First output after %.1f s", elapsed)) }
            for e in AgentStreamEvents.describe(line, harness: harness) {
                log(e.event, e.message, level: e.level, detail: e.detail)
            }
        }

        /// stderr lines, as warnings (agents print real failures there: a
        /// bad flag, an expired login, a provider's error).
        public func stderr(_ text: String) {
            for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
                log("stderr", String(line.prefix(400)), level: .warning)
            }
        }
    }

    /// The run of the agent that started this process (`pondside mcp`), from
    /// its environment; nil when no Pondside run started it. A process kept
    /// across requests (Claude's session) names a file holding the current
    /// request's run instead (`runFileVariable`), read at each call.
    public static func inheritedRun() -> Run? {
        let env = ProcessInfo.processInfo.environment
        if let file = env[runFileVariable], !file.isEmpty,
           let marker = try? String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines),
           let run = Run.parse(marker, kind: .mcp) {
            return run
        }
        guard let id = env[runVariable], !id.isEmpty else { return nil }
        return Run.parse(id + " " + (env[startVariable].flatMap { $0.split(separator: " ").last.map(String.init) } ?? ""), kind: .mcp)
    }
}

// MARK: - Reading agents' event streams

/// What one line of an agent's JSON event stream says, as log entries.
public enum AgentStreamEvents {
    public struct Event: Equatable, Sendable {
        public var event: String
        public var message: String
        public var level: AgentLog.Level
        public var detail: String?
    }

    public static func describe(_ line: Substring, harness: AgentHarness) -> [Event] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        guard let e = try? JSONSerialization.jsonObject(with: Data(trimmed.utf8)) as? [String: Any] else {
            return [Event(event: "output", message: String(trimmed.prefix(300)), level: .debug, detail: nil)]
        }
        switch harness {
        case .claude: return claude(e)
        case .opencode: return opencode(e)
        }
    }

    static func json(_ v: Any?) -> String {
        guard let v else { return "" }
        if let s = v as? String { return s }
        guard JSONSerialization.isValidJSONObject(v),
              let d = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .withoutEscapingSlashes]) else { return "\(v)" }
        return String(decoding: d, as: UTF8.self)
    }

    static func oneLine(_ s: String, _ n: Int = 160) -> String {
        let flat = s.replacingOccurrences(of: "\n", with: " ⏎ ")
        return flat.count > n ? String(flat.prefix(n)) + "…" : flat
    }

    /// A tool's input in a few words: its file, pattern or command first.
    static func summary(of input: Any?) -> String {
        guard let o = input as? [String: Any] else { return oneLine(json(input)) }
        for k in ["file_path", "filePath", "path", "file", "pattern", "command", "uri", "question", "message"] {
            if let v = o[k] as? String {
                let rest = o.keys.filter { $0 != k }.sorted()
                return oneLine(v, 120) + (rest.isEmpty ? "" : "  (" + rest.joined(separator: ", ") + ")")
            }
        }
        return oneLine(json(o))
    }

    static func claude(_ e: [String: Any]) -> [Event] {
        let type = e["type"] as? String
        switch type {
        case "system":
            guard e["subtype"] as? String == "init" else { return [] }
            let servers = (e["mcp_servers"] as? [[String: Any]] ?? []).map { "\($0["name"] ?? "?"): \($0["status"] ?? "?")" }
            let failed = (e["mcp_servers"] as? [[String: Any]] ?? []).contains { ($0["status"] as? String) != "connected" }
            let tools = (e["tools"] as? [String] ?? [])
            return [Event(event: "init",
                          message: "Claude Code \(e["claude_code_version"] ?? "?") · model \(e["model"] ?? "?") · MCP \(servers.isEmpty ? "none" : servers.joined(separator: ", ")) · \(tools.count) tools",
                          level: failed || servers.isEmpty ? .warning : .info,
                          detail: "session \(e["session_id"] ?? "?")\ncwd \(e["cwd"] ?? "?")\npermission mode \(e["permissionMode"] ?? "?")\ntools: \(tools.joined(separator: ", "))")]
        case "assistant":
            let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { c in
                switch c["type"] as? String {
                case "tool_use":
                    let name = c["name"] as? String ?? "?"
                    return Event(event: "tool", message: "\(name)  \(summary(of: c["input"]))", level: .info, detail: json(c["input"]))
                case "text":
                    let t = c["text"] as? String ?? ""
                    return t.isEmpty ? nil : Event(event: "text", message: oneLine(t, 240), level: .info, detail: t.count > 240 ? t : nil)
                case "thinking":
                    let t = c["thinking"] as? String ?? ""
                    return Event(event: "thinking", message: oneLine(t, 160), level: .debug, detail: t.count > 160 ? t : nil)
                default: return nil
                }
            }
        case "user":
            let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            return content.compactMap { c in
                guard c["type"] as? String == "tool_result" else { return nil }
                let text: String
                if let s = c["content"] as? String { text = s }
                else { text = (c["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }.joined(separator: "\n") }
                let isError = c["is_error"] as? Bool ?? false
                return Event(event: "result", message: (isError ? "Error: " : "") + oneLine(text, 200),
                             level: isError ? .warning : .debug, detail: text)
            }
        case "result":
            let failed = e["is_error"] as? Bool ?? false
            var parts: [String] = []
            if let ms = e["duration_ms"] as? Double { parts.append(String(format: "%.1f s", ms / 1000)) }
            if let api = e["duration_api_ms"] as? Double { parts.append(String(format: "model %.1f s", api / 1000)) }
            if let n = e["num_turns"] as? Int { parts.append("\(n) turns") }
            if let c = e["total_cost_usd"] as? Double { parts.append(String(format: "$%.3f so far", c)) }
            return [Event(event: "done", message: (failed ? "Failed (\(e["subtype"] ?? "error")) · " : "Done · ") + parts.joined(separator: " · "),
                          level: failed ? .error : .info, detail: e["result"] as? String)]
        default:
            return []
        }
    }

    static func opencode(_ e: [String: Any]) -> [Event] {
        let type = e["type"] as? String
        let part = e["part"] as? [String: Any] ?? [:]
        switch type {
        case "tool_use", "tool":
            let state = part["state"] as? [String: Any] ?? [:]
            let name = part["tool"] as? String ?? "?"
            let status = state["status"] as? String ?? ""
            var events = [Event(event: "tool", message: "\(name)  \(summary(of: state["input"]))", level: .info, detail: json(state["input"]))]
            if let time = state["time"] as? [String: Any], let s = time["start"] as? Double, let f = time["end"] as? Double {
                events[0].message += String(format: "  [%.1f s]", (f - s) / 1000)
            }
            if status == "error" {
                let err = json(state["error"])
                events.append(Event(event: "result", message: "Error: " + oneLine(err, 200), level: .warning, detail: err))
            } else if let out = state["output"] {
                let text = json(out)
                events.append(Event(event: "result", message: oneLine(text, 200), level: .debug, detail: text))
            }
            return events
        case "text":
            let t = part["text"] as? String ?? ""
            return t.isEmpty ? [] : [Event(event: "text", message: oneLine(t, 240), level: .info, detail: t.count > 240 ? t : nil)]
        case "reasoning":
            let t = part["text"] as? String ?? ""
            return t.isEmpty ? [] : [Event(event: "thinking", message: oneLine(t, 160), level: .debug, detail: t)]
        case "step_start":
            return [Event(event: "step", message: "Model step", level: .debug, detail: nil)]
        case "step_finish":
            let tokens = part["tokens"] as? [String: Any] ?? [:]
            let cache = tokens["cache"] as? [String: Any] ?? [:]
            var m = "Step done"
            if let i = tokens["input"], let o = tokens["output"] { m += " · in \(i) out \(o)" }
            if let r = cache["read"] { m += " cached \(r)" }
            if let c = part["cost"] as? Double, c > 0 { m += String(format: " · $%.4f", c) }
            if let r = part["reason"] as? String { m += " · \(r)" }
            return [Event(event: "step", message: m, level: .debug, detail: nil)]
        case "error":
            let err = e["error"] ?? e
            let text = json(err)
            return [Event(event: "error", message: oneLine(text, 300), level: .error, detail: text)]
        default:
            return []
        }
    }
}

// MARK: - Presenting

/// The Agent Log pane's text, worked out here so it stays portable and
/// testable: a heading per run, then one line per entry with the time
/// since the run started, and (optionally) each entry's detail indented.
public struct AgentLogPresenter: Sendable {
    public enum Filter: String, CaseIterable, Sendable {
        case all, graphics, patch, refactor

        public var title: String {
            switch self {
            case .all: return "All"
            case .graphics: return "Graphics"
            case .patch: return "Patch"
            case .refactor: return "Refactor"
            }
        }
    }

    public enum Style: Sendable, Equatable {
        case heading, time, normal, quiet, warning, error, detail
    }

    public struct Span: Sendable, Equatable {
        public var text: String
        public var style: Style
    }

    public var filter: Filter = .all
    public var details = false
    /// Debug entries (thinking, steps, raw results) when true.
    public var verbose = false
    /// Lines of a detail shown in the pane; the file keeps it whole.
    public var detailLines = 24

    /// Each run's kind, learned from its own entries (MCP entries carry only the run).
    private var kinds: [String: AgentLog.Kind] = [:]
    private var lastRun: String?

    public init() {}

    public func passes(_ e: AgentLog.Entry) -> Bool {
        if !verbose, e.level == .debug { return false }
        let kind = e.kind == .mcp ? kinds[e.run] : e.kind
        switch filter {
        case .all: return true
        case .graphics: return kind == .graphics
        case .patch: return kind == .patch
        case .refactor: return kind == .refactor
        }
    }

    /// The spans for `entries`, appended after what came before.
    public mutating func spans(for entries: [AgentLog.Entry]) -> [Span] {
        var out: [Span] = []
        for e in entries {
            if e.kind != .mcp, kinds[e.run] == nil { kinds[e.run] = e.kind }
            guard passes(e) else { continue }
            if e.run != lastRun {
                lastRun = e.run
                let kind = (e.kind == .mcp ? kinds[e.run] : e.kind) ?? .mcp
                let title: String
                switch kind {
                case .graphics: title = "Graphics request"
                case .patch: title = "Patch request"
                case .refactor: title = "Patch refactor"
                case .mcp: title = "MCP"
                }
                out.append(Span(text: (out.isEmpty ? "" : "\n") + "\(title) · \(Self.clock(e.time)) · run \(e.run)\n", style: .heading))
            }
            let elapsed = e.elapsed.map { String(format: "%7.1fs", $0) } ?? "        "
            out.append(Span(text: "\(elapsed)  ", style: .time))
            let mark: String
            switch e.level {
            case .error: mark = "✕ "
            case .warning: mark = "! "
            default: mark = "  "
            }
            let label = (e.kind == .mcp && e.event == "mcp" ? "pondside" : e.event).padding(toLength: 9, withPad: " ", startingAt: 0)
            let style: Style = e.level == .error ? .error : e.level == .warning ? .warning : e.level == .debug ? .quiet : .normal
            out.append(Span(text: mark + label + " " + e.message + "\n", style: style))
            if details, let d = e.detail, !d.isEmpty {
                let lines = d.split(separator: "\n", omittingEmptySubsequences: false)
                var shown = lines.prefix(detailLines).map { "             │ " + $0 }.joined(separator: "\n")
                if lines.count > detailLines { shown += "\n             │ … \(lines.count - detailLines) more lines in the log file" }
                out.append(Span(text: shown + "\n", style: .detail))
            }
        }
        return out
    }

    /// "12:47:03" in local time, from an entry's ISO 8601 time.
    static func clock(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let d = f.date(from: iso) else { return iso }
        let c = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
        return String(format: "%02d:%02d:%02d", c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
    }
}
