import Foundation

/// A coding agent run once, without a person at the keyboard: `claude -p`
/// or `opencode run`, in the score's folder, with Pondside's MCP server.
/// Pondside uses it to finish a patch migration (skill sc-patch-migration).
public enum AgentHarness: String, CaseIterable, Sendable {
    case claude, opencode

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .opencode: return "opencode"
        }
    }
}

public struct AgentRun: Sendable {
    public var harness: AgentHarness
    public var executable: String
    /// opencode's model, as `provider/model` (`opencode models` lists them);
    /// nil uses opencode's own default. Claude Code ignores it.
    public var model: String?

    public init(harness: AgentHarness, executable: String, model: String? = nil) {
        self.harness = harness
        self.executable = executable
        self.model = model
    }

    public struct Outcome: Sendable {
        /// The agent's last words.
        public var summary: String
        public var failed: Bool
        public var costUSD: Double?
        /// The conversation it was part of (opencode's session), to continue it.
        public var sessionID: String?
        /// The model's provider refused or stopped answering (a usage limit,
        /// no credit, a bad key): the user has to act, e.g. pick another model.
        public var providerProblem: Bool

        public init(summary: String, failed: Bool, costUSD: Double?, sessionID: String? = nil, providerProblem: Bool = false) {
            self.summary = summary
            self.failed = failed
            self.costUSD = costUSD
            self.sessionID = sessionID
            self.providerProblem = providerProblem
        }
    }

    // MARK: Finding the agents

    /// The PATH of the user's login shell: an app opened from the Finder
    /// gets a minimal one, without ~/.local/bin or Homebrew.
    public static let loginPath: String = {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-lc", "printf %s \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin") : path
    }()

    /// Where each agent is installed, if it is: the login shell's PATH, then
    /// the installers' usual places.
    public static func find(_ harness: AgentHarness) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let usual: [String]
        switch harness {
        case .claude: usual = ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
        case .opencode: usual = ["\(home)/.opencode/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode"]
        }
        let onPath = loginPath.split(separator: ":").map { "\($0)/\(harness.rawValue)" }
        return (onPath + usual).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The chosen agent: `preference` if it is installed, else the first
    /// installed one; nil when `preference` is "off" or none is installed.
    public static func choose(preference: String?, model: String? = nil) -> AgentRun? {
        if preference == "off" { return nil }
        let order = AgentHarness(rawValue: preference ?? "").map { first in [first] + AgentHarness.allCases.filter { $0 != first } }
            ?? AgentHarness.allCases
        for h in order { if let e = find(h) { return AgentRun(harness: h, executable: e, model: model) } }
        return nil
    }

    /// The models opencode can use with the providers the user has set up
    /// (`opencode models`: one `provider/model` per line), in its order.
    public static func models(opencode executable: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["models"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = loginPath
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return parseModels(String(decoding: data, as: UTF8.self))
    }

    static func parseModels(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                guard let slash = line.firstIndex(of: "/"), slash != line.startIndex, slash != line.index(before: line.endIndex),
                      !line.contains(" ") else { return false }
                return seen.insert(line).inserted
            }
    }

    /// opencode's inline config: no shell, web or subagents, and the model, if one is chosen.
    func opencodeConfigContent() -> String {
        guard let model, !model.isEmpty else { return Self.opencodeConfig }
        let quoted = String(data: (try? JSONSerialization.data(withJSONObject: [model], options: [])) ?? Data(), encoding: .utf8)
            .map { String($0.dropFirst().dropLast()) } ?? "\"\(model)\""
        return String(Self.opencodeConfig.dropLast()) + #","model":"# + quoted + "}"
    }

    // MARK: Running

    /// The command line. Claude may only read and edit files in the folder
    /// and call Pondside's tools (anything else is denied, not asked);
    /// opencode can't be limited to the folder, so it auto-approves, with
    /// its shell, web and subagent tools denied (`environment`).
    public func arguments(prompt: String, folder: URL, pondside: String, session: String? = nil) -> [String] {
        switch harness {
        case .claude:
            let mcp = #"{"mcpServers":{"pondside":{"type":"stdio","command":"\#(pondside)","args":["mcp"]}}}"#
            return ["-p", prompt, "--output-format", "stream-json", "--verbose"] + Self.claudeTools
                + ["--mcp-config", mcp, "--strict-mcp-config"]
        case .opencode:
            // --title: opencode otherwise asks a second, small model to title
            // the session before it starts, a call that can fail or wait.
            return ["run", "--format", "json", "--dir", folder.path, "--auto", "--title", "Pondside"]
                + (session.map { ["--session", $0] } ?? []) + [prompt]
        }
    }

    /// Claude's tools: only the file tools it may use and Pondside's. With
    /// `--tools` the other built-ins aren't even offered, and with tool
    /// search off (`environment`) Pondside's tools are loaded up front, so
    /// the first request doesn't spend a model turn finding them (measured:
    /// a one-tool request 10 s → 5 s, cost down 60%).
    static let opencodeConfig = #"{"permission":{"bash":"deny","webfetch":"deny","websearch":"deny","task":"deny"}}"#

    static let claudeTools = ["--permission-mode", "dontAsk", "--tools", "Read,Edit,Write,Glob,Grep",
                              "--allowedTools", "Read Edit Write Glob Grep mcp__pondside"]

    /// The agent's last words from its JSON output.
    public func parse(_ output: String, status: Int32) -> Outcome {
        switch harness {
        case .claude:
            // A stream of events ending in { type: result, result, is_error, total_cost_usd, … }
            let json = output.split(separator: "\n").reversed().lazy
                .compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
                .first { $0["type"] as? String == "result" }
            let result = (json?["result"] as? String) ?? output.suffix(600).description
            let failed = status != 0 || (json?["is_error"] as? Bool ?? false)
            return Outcome(summary: result.trimmingCharacters(in: .whitespacesAndNewlines), failed: failed,
                           costUSD: json?["total_cost_usd"] as? Double)
        case .opencode:
            // A stream of events; the reply is the text parts of the last step.
            var texts: [String] = []
            var failed = status != 0
            var session: String?
            for line in output.split(separator: "\n") {
                guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                let type = e["type"] as? String
                session = e["sessionID"] as? String ?? session
                if type == "step_start" { texts = [] }
                if type == "text", let t = (e["part"] as? [String: Any])?["text"] as? String { texts.append(t) }
                if type == "error" { failed = true; texts.append("\(e["error"] ?? e)") }
            }
            let summary = texts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return Outcome(summary: summary.isEmpty ? output.suffix(600).description : summary, failed: failed, costUSD: nil,
                           sessionID: session)
        }
    }

    /// What the agent is doing, in a word or three, from one line of its
    /// event stream: the tool it calls ("editing", "checking"), or
    /// "thinking"; nil for lines that say nothing new.
    public func activity(_ line: Substring) -> String? {
        guard let e = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return nil }
        switch harness {
        case .claude:
            guard e["type"] as? String == "assistant",
                  let content = (e["message"] as? [String: Any])?["content"] as? [[String: Any]] else { return nil }
            if let tool = content.last(where: { $0["type"] as? String == "tool_use" })?["name"] as? String { return Self.words(tool) }
            return content.contains { $0["type"] as? String == "thinking" } ? "thinking" : "writing"
        case .opencode:
            guard let part = e["part"] as? [String: Any] else { return nil }
            if let tool = part["tool"] as? String { return Self.words(tool) }
            return e["type"] as? String == "step_start" ? "thinking" : nil
        }
    }

    static func words(_ tool: String) -> String {
        let t = tool.lowercased()
        if t.contains("patch_audit") { return "checking" }
        if t.contains("patch_migrate") { return "migrating" }
        if t.contains("score_context") { return "reading the score" }
        if t.hasSuffix("cues") { return "reading cues" }
        if t.hasSuffix("check") { return "checking the score" }
        if ["edit", "multiedit", "write", "apply_patch", "patch"].contains(where: t.hasSuffix) { return "editing" }
        if ["grep", "glob", "search", "list", "ls"].contains(where: t.hasSuffix) { return "searching" }
        if t.hasSuffix("read") { return "reading" }
        if t.hasSuffix("bash") { return "running a command" }
        return "working"
    }

    /// A handle to stop a run.
    public final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var stopped = false

        public init() {}

        func attach(_ p: Process) -> Bool {
            lock.lock(); defer { lock.unlock() }
            process = p
            return !stopped
        }

        public func stop() {
            lock.lock(); defer { lock.unlock() }
            stopped = true
            process?.terminate()
        }

        public var wasStopped: Bool {
            lock.lock(); defer { lock.unlock() }
            return stopped
        }
    }

    /// Runs the agent in `folder` with `prompt` and waits for it.
    /// `pondside` is the CLI the agent's MCP server runs.
    /// `onActivity` hears each change of what it is doing (`activity`).
    /// `log` records the run: command line, every event, stderr, exit.
    public func run(prompt: String, folder: URL, pondside: String, handle: Handle = Handle(),
                    timeout: TimeInterval = 30 * 60, session: String? = nil, log: AgentLog.Run? = nil,
                    onActivity: (@Sendable (String) -> Void)? = nil) async throws -> Outcome {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments(prompt: prompt, folder: folder, pondside: pondside, session: session)
        p.currentDirectoryURL = folder
        p.environment = environment(pondside: pondside, log: log)
        // Claude names its version in its first event; opencode's `run` output doesn't.
        if harness == .opencode, let log { log.log("version", "opencode \(Self.version(of: executable) ?? "?")") }
        log?.log("launch", "\(harness.title) in \(folder.lastPathComponent)" + (session.map { ", continuing session \($0)" } ?? ""),
                 detail: Self.commandLine(executable, p.arguments ?? [], prompt: prompt, folder: folder, environment: p.environment ?? [:]))
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let collected = Collected()
        let me = self
        out.fileHandleForReading.readabilityHandler = { h in
            for line in collected.append(h.availableData, error: false) {
                log?.stream(line, harness: me.harness)
                if let a = me.activity(line) { onActivity?(a) }
            }
        }
        err.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            collected.append(d, error: true)
            if !d.isEmpty { log?.stderr(String(decoding: d, as: UTF8.self)) }
        }
        guard handle.attach(p) else {
            log?.log("exit", "Stopped before it started", level: .warning)
            return Outcome(summary: "Stopped.", failed: true, costUSD: nil)
        }
        do { try p.run() } catch {
            log?.log("exit", "Couldn't start \(executable): \(error.localizedDescription)", level: .error)
            throw error
        }
        log?.log("pid", "Process \(p.processIdentifier)", level: .debug)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        // opencode logs a provider's refusal (free limit, no funds) and may
        // then wait forever: follow its log for this session's errors.
        let watch = harness == .opencode ? OpencodeLog() : nil
        var providerError: String?
        var lastCheck = Date()
        while p.isRunning {
            if Date() > deadline, !timedOut {
                timedOut = true
                log?.log("timeout", String(format: "No answer after %.0f min: stopping it", timeout / 60), level: .error)
                p.terminate()
            }
            if let watch, providerError == nil, Date().timeIntervalSince(lastCheck) > 1.5 {
                lastCheck = Date()
                if let session = Self.sessionID(in: collected.output), let error = watch.error(session: session) {
                    providerError = OpencodeLog.explain(error, model: model)
                    log?.log("provider", "opencode logged: \(error)", level: .error, detail: "from \(watch.url.path)")
                    p.terminate()
                }
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        for line in collected.append(out.fileHandleForReading.readDataToEndOfFile(), error: false) {
            log?.stream(line, harness: harness)
        }
        let status = p.terminationStatus
        log?.log("exit", "Exit status \(status)" + (p.terminationReason == .uncaughtSignal ? " (signal)" : ""),
                 level: status == 0 ? .info : .warning)
        if handle.wasStopped { return Outcome(summary: "Stopped.", failed: true, costUSD: nil) }
        if let providerError { return Outcome(summary: providerError, failed: true, costUSD: nil, providerProblem: true) }
        var outcome = parse(collected.output, status: status)
        if outcome.failed, outcome.summary.isEmpty { outcome.summary = collected.errors.suffix(600).description }
        return outcome
    }

    /// The session opencode's `run` events name (`"sessionID":"ses_…"`).
    static func sessionID(in output: String) -> String? {
        guard let r = output.prefix(20_000).range(of: #""sessionID":""#) else { return nil }
        let id = output[r.upperBound...].prefix { $0 != "\"" }
        return id.isEmpty ? nil : String(id)
    }

    /// `<executable> --version`, trimmed; nil if it doesn't answer.
    static func version(of executable: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = ["--version"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let v = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return p.terminationStatus == 0 && !v.isEmpty ? String(v.prefix(80)) : nil
    }

    /// The agent's environment: the login shell's PATH, with the bundled
    /// `pondside` first (the score's .mcp.json / opencode.json name
    /// `pondside`), and the log's run, which the MCP server inherits.
    func environment(pondside: String, log: AgentLog.Run?) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = URL(fileURLWithPath: pondside).deletingLastPathComponent().path + ":" + Self.loginPath
        switch harness {
        case .claude: env["ENABLE_TOOL_SEARCH"] = "false"
        case .opencode:
            // No shell, web or subagents: an unattended edit doesn't need
            // them, and a model that has them wanders (a request spent a
            // minute rendering pages and cropping them with ImageMagick).
            // Denied tools aren't offered at all. The user's own inline
            // config, if any, wins.
            // The model chosen in Settings goes in the same inline config.
            if env["OPENCODE_CONFIG_CONTENT"] == nil { env["OPENCODE_CONFIG_CONTENT"] = opencodeConfigContent() }
        }
        for (k, v) in log?.environment ?? [:] { env[k] = v }
        return env
    }

    /// The command line as a shell would run it, the prompt elided (it is
    /// logged on its own), with the folder and PATH: enough to rerun it.
    static func commandLine(_ executable: String, _ args: [String], prompt: String?, folder: URL,
                            environment: [String: String]) -> String {
        func quote(_ s: String) -> String {
            s.allSatisfy { $0.isLetter || $0.isNumber || "-_./:=@".contains($0) } ? s : "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let shown = args.map { $0 == prompt ? "<prompt>" : quote($0) }
        return "cd \(quote(folder.path))\n\(quote(executable)) \(shown.joined(separator: " "))\n\nPATH=\(environment["PATH"] ?? "")"
    }

    final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var out = Data(), err = Data()

        private var pending = Data()

        /// Appends `d`; returns the output lines it completed.
        @discardableResult
        func append(_ d: Data, error: Bool) -> [Substring] {
            lock.lock(); defer { lock.unlock() }
            if error { err.append(d); return [] }
            out.append(d)
            pending.append(d)
            guard let last = pending.lastIndex(of: 0x0A) else { return [] }
            let complete = String(decoding: pending[..<last], as: UTF8.self)
            pending.removeSubrange(...last)
            return complete.split(separator: "\n")
        }

        var output: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
        var errors: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
    }

    // MARK: The graphics prompt

    /// A request about the graphic the user selected ("grainy swell till
    /// m. 3"), with the app's context for it and the graphic-notation skill.
    /// What every request from the lens asks for, first turn or not: the
    /// user judges the result by looking at the page, so a change too small
    /// to notice reads as a failure (a run that thinned grains by half in
    /// one band "succeeded" and looked unchanged).
    static let atAGlance = """
    The user looks at the page at normal zoom to judge the result: make the change big enough to see at a \
    glance (about 2× for "taller", "denser", "wider"; a clearly different shape for "different"), unless \
    they gave numbers. Too small to notice counts as not done.
    """

    /// What a marked range is: an existing drawing, or only a range (a new
    /// drawing or a notation/layout change).
    public enum RequestTarget: String, Sendable {
        case existingGraphic
        case emptySection
    }

    static let graphicRules = """
    The context's selection has kind "graphic-section": `from` and `to` are the two edges.
    `from.x` and `to.x` are their fractions of each endpoint's broken piece; `from.page_x` and
    `to.page_x` are the same edges in page coordinates; `from.at` and `to.at` are the moment at
    each edge (interpolated from the engraved notes; the moments identify systems, not the
    boundary); `systems` lists the selected page-x range on every covered system. Follow
    skill://graphic-notation: build its `section-window` from `from.at.moment`, `to.at.moment`,
    `from.x` and `to.x`; change only inside it. Never use the moments as musical boundaries, and
    never change a shared constant, seed or table.
    """

    static let emptySectionRules = """
    The marked range starts where there is no drawing. The range is still the only range: change
    only inside it. Decide what the request asks for before editing:
    - a drawing, texture, shape or gesture: add a new graphic in the marked range with
      graphic_insert, or write the score's own drawing code; follow skill://graphic-notation;
    - notation or layout (barlines, beams, clefs, staff lines, spacing, noteheads, hidden meters,
      dynamics): follow skill://lilypond and edit the score's layout or helpers. Do not create a
      Lexicon entry unless the user asks for a reusable entry.
    Do not force a Lexicon entry for a one-off notation/layout change. The context's `from.at` and
    `to.at` are the moment at each edge, interpolated from the engraved notes; use them for timing,
    and use `from.x`/`to.x` for the visual boundary.
    """

    public static func graphicsPrompt(request: String, context: String, score: URL,
                                      followUp: Bool = false,
                                      target: RequestTarget = .existingGraphic) -> String {
        let rules = target == .emptySection ? Self.emptySectionRules : Self.graphicRules
        let skill = MCPServer.skills.first { $0.folder == "graphic-notation" }.flatMap(MCPServer.skillText) ?? ""
        let lilypond = target == .emptySection
            ? MCPServer.skills.first { $0.folder == "lilypond" }.flatMap(MCPServer.skillText) ?? ""
            : ""
        let targetLine = target == .emptySection
            ? "The marked range has no drawing at its start. A drawing is a new graphic; a notation/layout change is score code."
            : "The marked range starts on an existing drawing; change that drawing, not the music around it."
        if followUp {
            return """
            Next request: "\(request)". The user's selection now (score_context):
            \(context)
            \(targetLine)
            Code in it is numbered as in its file (`412| ` is not part of the line), fresh as of now: \
            edit with the edit tool by from_line/to_line or exact text, without reading the file; it \
            returns the engraving.
            \(rules)
            \(atAGlance) Same rules as before (no renders, images or shell); reply in one short line \
            with the numbers (old → new).
            """
        }
        let quick = target == .emptySection
            ? """
            Be quick: the context has the marked range, the root `\\layout`, and an index of the \
            score's definitions. Read only the lines you need, never the whole graphics file. Edit \
            with the edit tool (from_line/to_line, or exact old text; root: \(score.path) for an .ily); \
            it returns the app's engraving, so no separate check. Fix only what it reports. Don't \
            render pages, look at images or run shell commands: the user sees the app re-engrave.
            """
            : """
            Be quick: the context has the graphic's definition, its drawing code and the helpers it \
            calls, in full, numbered as in their files (`412| ` is a prefix, not part of the line). \
            Change them with the edit tool (from_line/to_line, or exact old text; root: \(score.path) \
            for an .ily) without reading the files: one edit call, which returns the app's engraving, \
            so no separate check. Fix only what it reports. For a new graphic use graphic_insert over \
            the marked range. Don't render pages, look at images or run shell commands: the user sees \
            the app re-engrave.
            """
        return """
        The user marked a section in Pondside's score of \(score.path) and asked: "\(request)".
        Its context (what score_context returns) is below; call score_context again only for another point.
        \(targetLine)
        Follow the skill(s) below. You run in the background: take the most plausible reading; only if \
        two readings really differ, ask with ask_user (offer choices). If you can't carry it out, call \
        warn_user.
        \(atAGlance)
        \(quick)
        \(rules)
        Final reply: one short line saying what changed, with the numbers, e.g. "Swell taller: peak 1.06 → 2.1."
        More requests may follow in this conversation, each with the selection at that moment; \
        "it", "that" and "again" refer to earlier ones.

        Context:
        \(context)

        \(skill)

        \(lilypond)
        """
    }

    // MARK: The patch agent's prompt

    /// A request from the lens for the patch agent: its own conversation,
    /// whose memory is the patch doc (in the context), not the chat.
    public static func patchPrompt(request: String, context: String, score: URL, patch: URL, followUp: Bool = false) -> String {
        if followUp {
            return """
            Next patch request: "\(request)". patch_context at the user's point now (code numbered as in its \
            file, fresh; the doc holds what you noted before):
            \(context)
            Same rules as before: edit the patch with the edit tool without re-reading (wait in the handler \
            when the cue has "wait"), patch_check the cue, \
            patch_note what changed and why; reply in one short line with what you changed and how it sounds.
            """
        }
        let skill = MCPServer.skills.first { $0.folder == "sc-patch-editing" }.flatMap(MCPServer.skillText) ?? ""
        return """
        The user clicked a point in Pondside's score \(score.path) and asked for a change to its SuperCollider \
        patch \(patch.path): "\(request)".
        You are the patch agent: change only the patch's .scd files (never .ly, never \
        dependencies/pondside.scd or dependencies/sc-lexicon.scd, which Pondside writes). Its context \
        (what patch_context returns) is below: the cue at the point and its handler's code, what it touches, \
        the pitch collections there, the patch doc (outline with file:lines, and notes on intent: read them \
        before anything else, they are your memory of this patch) and the SuperCollider Lexicon.
        Follow the skill below. You run in the background: take the most plausible reading; only if two \
        readings really differ, ask with ask_user. If you can't carry it out, call warn_user.
        Be quick: code in the context is numbered as in its file (`412| ` is a prefix). Edit it with the edit \
        tool (from_line/to_line or exact old text) without reading the file; read other lines only by range, \
        as the doc's outline gives them. If the context's cue has "wait", the point is that long after the \
        cue: wait that long in the handler before the change, as the patch already waits (wait_examples). \
        Then patch_check with the cue: it renders the mix and gives the \
        window's levels before and after. Make the change clearly audible unless the user asked for subtle. \
        Then patch_note each item you changed (intent, not code; and "overview" when the patch's plan changed).
        Final reply: one short line, e.g. "Cue 12: grain cloud on [0 3 7], 2 → 30 grains/s over 20 s; \
        electronics −19 dBFS."

        Context:
        \(context)

        \(skill)
        """
    }

    // MARK: The migration prompt

    /// What the agent is asked after `PatchMigration.migrate`: the skill
    /// itself (so nothing depends on prompts or slash commands working
    /// without a person), and the task.
    public static func migrationPrompt(score: URL, patch: URL) -> String {
        let skill = MCPServer.skills.first { $0.folder == "sc-patch-migration" }.flatMap(MCPServer.skillText) ?? ""
        return """
        Finish migrating the SuperCollider patch \(patch.path) for the LilyPond score \(score.path) to a Pondside \
        patch. Pondside has done the automatic part. Fix every line marked `// pondside:`, in the patch and in the \
        files it loads, following the skill below. You run in the background: when something is genuinely the \
        composer's call, ask with ask_user (a dialog; offer choices), or keep the code and its mark if they skip it. \
        If something goes wrong that the user must know (the mix won't render, a file you couldn't fix), call \
        warn_user. You can't run shell commands: use the pondside MCP tools and file edits.
        Loop: patch_audit (file: \(score.path)) lists what is left; fix it; then mix (same file) must render with no \
        errors. Done when both are clean, or only marks you deliberately kept remain.
        Final reply: at most 3 short lines, no headings or bullets, e.g. "Cues 1–12 inlined into their handlers; \
        old cue runner removed. Kept 1 mark: line 1614 (which cue starts the drift?). Mix renders."

        \(skill)
        """
    }
}
