import Foundation
import PondsideTiming

/// One agent conversation that lasts across requests, so a follow-up
/// ("taller", "no, the other one") has the earlier ones in context.
/// Claude Code and opencode keep a process open; Codex resumes its explicit
/// thread ID with a fresh exec per turn. Each retains its conversation.
///
/// Claude Code: `claude -p --input-format stream-json`; each request is a
/// message on its stdin, each answer ends with a `result` event.
///
/// opencode: `opencode acp`, the Agent Client Protocol (JSON-RPC 2.0, one
/// message per line): `initialize`, then `session/new` (or `session/resume`)
/// with Pondside's MCP server, then a `session/prompt` per request, which
/// answers when the turn ends; `session/update` notifications stream its
/// text and tool calls meanwhile, and `session/request_permission` is
/// answered "allow", as `opencode run --auto` would.
///
/// If the process stops (a stop, an idle timeout, a crash), the next request
/// starts it again and resumes the session (`--resume`, `session/resume`).
public final class AgentSession: @unchecked Sendable {
    public let agent: AgentRun
    /// Whose tools its MCP server offers: the score's or the patch's.
    public let role: MCPServer.Role
    private let folder: URL
    private let pondside: String
    private let lock = NSLock()

    private var codexHandle: AgentRun.Handle?
    private var process: Process?
    private var input: FileHandle?
    private var pending: ((AgentRun.Outcome) -> Void)?
    /// The process the pending request went to: only its exit ends the request.
    private var pendingProcess: Process?
    private var activity: (@Sendable (String) -> Void)?
    private var buffer = Data()
    private var sessionID: String?
    /// Both agents report the session's cost so far; a request costs the difference.
    private var spent = 0.0
    /// The request being logged; the long-lived process (and its MCP
    /// server) learn which one from `runFile`.
    private var log: AgentLog.Run?
    private let runFile = FileManager.default.temporaryDirectory
        .appendingPathComponent("pondside-agent-run-\(UUID().uuidString.prefix(8))")

    // ACP (opencode)
    private var nextID = 0
    private var calls: [Int: (Result<JSONObject, Error>) -> Void] = [:]
    /// The process has answered `initialize` and has a session open.
    private var ready = false
    private var reply = ""
    private var unloggedText = ""
    private var thought = ""
    private var tools: [String: (title: String, started: Date, input: Any?)] = [:]
    private var sessionCost: Double?
    private var sawOutput = false
    /// The last request was stopped: the agent's history still holds it.
    private var stopped = false
    /// The model the session reported (`session/new`), for error messages.
    private var currentModel: String?
    /// The pending `session/prompt` call, which the watchdog can fail.
    private var promptCallID: Int?
    /// When the agent last said anything (any line on stdout).
    private var lastOutput = Date()
    /// A tool call is running: silence is the tool's, not a stall.
    private var toolRunning: Bool { !tools.isEmpty }

    /// How long a request may hear nothing at all before it is given up.
    public static let stallTimeout: TimeInterval = 180

    /// Requests answered in this conversation (0: the next one starts it).
    public private(set) var turns = 0

    public init(agent: AgentRun, folder: URL, pondside: String, role: MCPServer.Role = .graphics) {
        self.agent = agent
        self.role = role
        self.folder = folder
        self.pondside = pondside
    }

    /// Sends a request and waits for the answer. `log` records it.
    public func send(_ prompt: String, log: AgentLog.Run? = nil,
                     onActivity: (@Sendable (String) -> Void)? = nil) async -> AgentRun.Outcome {
        locked { self.log = log }
        if let log { try? Data(log.marker.utf8).write(to: runFile, options: .atomic) }
        // A stopped request stays in the agent's history unanswered; without
        // this the agent carries it on in the next turn.
        let wasStopped = locked { () -> Bool in defer { stopped = false }; return stopped }
        let requestPrompt = (role == .graphics ? ScoreContract.notice : PatchContract.notice) + "\n\n" + prompt
        let prompt = wasStopped ? "(The user stopped the previous request: drop it, don't carry it on.)\n\n" + requestPrompt : requestPrompt
        let outcome: AgentRun.Outcome
        switch agent.harness {
        case .codex: outcome = await sendToCodex(prompt, onActivity: onActivity)
        case .claude: outcome = await sendToClaude(prompt, onActivity: onActivity)
        case .opencode: outcome = await sendToOpencode(prompt, onActivity: onActivity)
        }
        locked { self.log = nil }
        if !outcome.failed { locked { turns += 1 } }
        return outcome
    }

    /// Stops the request in progress. The conversation is kept: the next
    /// request resumes it. opencode is asked to cancel the turn and keeps
    /// running; Claude's process is ended.
    public func interrupt() {
        lock.lock()
        let p = process, id = sessionID, isReady = ready, codex = codexHandle
        stopped = true
        lock.unlock()
        codex?.stop()
        if agent.harness == .opencode, isReady, let id {
            notify("session/cancel", ["sessionId": id])
        } else {
            p?.terminate()
        }
    }

    /// Ends the process (idle, window closed); the conversation can resume.
    public func close() {
        lock.lock()
        let p = process, stdin = input, codex = codexHandle
        codexHandle = nil
        process = nil
        input = nil
        ready = false
        // Calls waiting on this process fail now: its exit may come after a
        // new process has started, and must not touch that one's calls.
        let waiting = calls
        calls = [:]
        lock.unlock()
        for k in waiting.values { k(.failure(AgentError("\(agent.harness.title) stopped"))) }
        if p != nil { AgentLog.Run(kind: .graphics, id: "session").log("close", "\(agent.harness.title)'s session process closed", level: .debug) }
        codex?.stop()
        // End of input ends either process cleanly; terminate in case it doesn't.
        try? stdin?.close()
        p?.terminate()
    }

    deinit {
        close()
        try? FileManager.default.removeItem(at: runFile)
    }

    /// Forgets the conversation: the next request starts a new one.
    public func reset() {
        close()
        lock.lock()
        sessionID = nil
        spent = 0
        turns = 0
        lock.unlock()
    }

    private func locked<T>(_ f: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return f()
    }

    private func sendToCodex(_ prompt: String, onActivity: (@Sendable (String) -> Void)?) async -> AgentRun.Outcome {
        let handle = AgentRun.Handle()
        let state = locked { () -> (String?, AgentLog.Run?, Bool) in
            guard codexHandle == nil else { return (nil, log, false) }
            codexHandle = handle
            return (sessionID, log, true)
        }
        guard state.2 else { return .init(summary: "Codex is already working.", failed: true, costUSD: nil) }
        let outcome: AgentRun.Outcome
        do {
            outcome = try await agent.run(prompt: prompt, folder: folder, pondside: pondside, handle: handle,
                                          session: state.0, log: state.1, role: role, onActivity: onActivity)
        } catch { outcome = .init(summary: "Codex didn't start: \(error.localizedDescription)", failed: true, costUSD: nil) }
        locked {
            if codexHandle === handle {
                sessionID = outcome.sessionID ?? sessionID
                codexHandle = nil
            }
        }
        return outcome
    }

    // MARK: The process

    /// Starts the agent with `arguments`; its stdout goes to `received`,
    /// its stderr to the log. Called with the lock held.
    private func launch(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: agent.executable)
        p.arguments = arguments
        p.currentDirectoryURL = folder
        var env = agent.environment(pondside: pondside, log: log)
        env[AgentLog.runFileVariable] = runFile.path
        p.environment = env
        log?.log("launch", "\(agent.harness.title) in \(folder.lastPathComponent)"
                    + (sessionID.map { ", resuming session \($0)" } ?? ", new session"),
                 detail: AgentRun.commandLine(agent.executable, arguments, prompt: nil, folder: folder, environment: env))
        let stdin = Pipe(), stdout = Pipe(), stderr = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stderr
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in self?.received(h.availableData) }
        // Agents print real failures here (a bad flag, a login that expired).
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            guard !d.isEmpty, let self else { return }
            (self.locked { self.log } ?? AgentLog.Run(kind: .graphics, id: "session")).stderr(String(decoding: d, as: UTF8.self))
        }
        p.terminationHandler = { [weak self] proc in
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            guard let self else { return }
            self.lock.lock()
            let current = self.process === p
            if current { self.process = nil; self.input = nil; self.ready = false }
            let mine = self.pendingProcess === p
            let log = self.log
            let waiting = current ? self.calls : [:]
            if current { self.calls = [:] }
            self.lock.unlock()
            (log ?? AgentLog.Run(kind: .graphics, id: "session"))
                .log("exit", "\(self.agent.harness.title) exited with status \(proc.terminationStatus)",
                     level: mine ? .warning : .debug)
            for k in waiting.values { k(.failure(AgentError("\(self.agent.harness.title) stopped"))) }
            if mine { self.finish(AgentRun.Outcome(summary: "Stopped.", failed: true, costUSD: nil)) }
        }
        try p.run()
        log?.log("pid", "Process \(p.processIdentifier)", level: .debug)
        process = p
        input = stdin.fileHandleForWriting
        buffer = Data()
    }

    private func received(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        lastOutput = Date()
        buffer.append(data)
        var lines: [Data] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
        }
        lock.unlock()
        for line in lines {
            switch agent.harness {
            case .claude: claudeLine(line)
            case .opencode: acpLine(line)
            case .codex: break // exec streams are handled by AgentRun.
            }
        }
    }

    private func finish(_ outcome: AgentRun.Outcome) {
        lock.lock()
        let k = pending
        pending = nil
        pendingProcess = nil
        activity = nil
        lock.unlock()
        k?(outcome)
    }

    // MARK: Claude: requests on stdin

    private func sendToClaude(_ prompt: String, onActivity: (@Sendable (String) -> Void)?) async -> AgentRun.Outcome {
        do { try startClaudeIfNeeded() } catch {
            locked { log }?.log("exit", "Couldn't start \(agent.executable): \(error.localizedDescription)", level: .error)
            return AgentRun.Outcome(summary: "\(agent.harness.title) didn't start: \(error.localizedDescription)", failed: true, costUSD: nil)
        }
        let message: [String: Any] = ["type": "user", "message": ["role": "user", "content": prompt]]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            return AgentRun.Outcome(summary: "couldn't encode the request", failed: true, costUSD: nil)
        }
        return await withCheckedContinuation { (k: CheckedContinuation<AgentRun.Outcome, Never>) in
            lock.lock()
            pending = { k.resume(returning: $0) }
            pendingProcess = process
            activity = onActivity
            let handle = input
            let log = self.log
            lock.unlock()
            do {
                guard let handle else { throw AgentError("no process") }
                try handle.write(contentsOf: data + Data("\n".utf8))
                log?.log("sent", "Request sent to the running session", level: .debug)
            } catch {
                log?.log("exit", "Couldn't send the request: \(error.localizedDescription)", level: .error)
                finish(AgentRun.Outcome(summary: "\(agent.harness.title) stopped", failed: true, costUSD: nil))
            }
        }
    }

    private func startClaudeIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        if let process, process.isRunning {
            log?.log("reuse", "Continuing \(agent.harness.title)'s running session (process \(process.processIdentifier))", level: .debug)
            return
        }
        let mcp = #"{"mcpServers":{"pondside":{"type":"stdio","command":"\#(pondside)","args":["mcp","--role","\#(role.rawValue)"]}}}"#
        var args = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
            + AgentRun.claudeTools + ["--mcp-config", mcp, "--strict-mcp-config"]
        if let sessionID { args += ["--resume", sessionID] }
        try launch(args)
    }

    private func claudeLine(_ line: Data) {
        let (onActivity, log) = locked { (activity, self.log) }
        let text = Substring(String(decoding: line, as: UTF8.self))
        log?.stream(text, harness: .claude)
        guard let e = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
        if let id = e["session_id"] as? String { locked { sessionID = id } }
        if let words = agent.activity(text) { onActivity?(words) }
        guard e["type"] as? String == "result" else { return }
        let total = e["total_cost_usd"] as? Double
        let cost = locked { () -> Double? in
            let c = total.map { max(0, $0 - spent) }
            if let total { spent = total }
            return c
        }
        let summary = (e["result"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        finish(AgentRun.Outcome(summary: summary, failed: e["is_error"] as? Bool ?? false, costUSD: cost))
    }

    // MARK: opencode: the Agent Client Protocol

    private func sendToOpencode(_ prompt: String, onActivity: (@Sendable (String) -> Void)?) async -> AgentRun.Outcome {
        do { try await startOpencodeIfNeeded() } catch {
            locked { log }?.log("exit", "\(agent.harness.title) didn't start: \(error.localizedDescription)", level: .error)
            close()
            return AgentRun.Outcome(summary: "\(agent.harness.title) didn't start: \(error.localizedDescription)", failed: true, costUSD: nil)
        }
        let (session, log) = locked { () -> (String?, AgentLog.Run?) in
            pendingProcess = process
            activity = onActivity
            reply = ""
            unloggedText = ""
            thought = ""
            tools = [:]
            sawOutput = false
            return (sessionID, self.log)
        }
        guard let session else { return AgentRun.Outcome(summary: "no session", failed: true, costUSD: nil) }
        log?.log("sent", "Request sent to the running session", level: .debug)
        locked { lastOutput = Date() }
        let watchdog = Task { [weak self] in await self?.watch(session: session, log: OpencodeLog()) }
        let result: Result<JSONObject, Error>
        do {
            result = .success(try await call("session/prompt", ["sessionId": session, "prompt": [["type": "text", "text": prompt]]]))
        } catch {
            result = .failure(error)
        }
        watchdog.cancel()
        locked { promptCallID = nil }
        flushText()
        let (text, total) = locked { () -> (String, Double?) in
            pendingProcess = nil
            activity = nil
            return (reply.trimmingCharacters(in: .whitespacesAndNewlines), sessionCost)
        }
        let cost = locked { () -> Double? in
            let c = total.map { max(0, $0 - spent) }
            if let total { spent = total }
            return c
        }
        switch result {
        case .failure(let error):
            log?.log("done", "Failed: \(error.localizedDescription)", level: .error)
            if let e = error as? AgentError, e.provider {
                return AgentRun.Outcome(summary: e.message, failed: true, costUSD: cost, providerProblem: true)
            }
            return AgentRun.Outcome(summary: text.isEmpty ? error.localizedDescription : text, failed: true, costUSD: cost)
        case .success(let r):
            let stop = r.value["stopReason"] as? String ?? "?"
            let usage = r.value["usage"] as? [String: Any] ?? [:]
            var m = "\(stop == "end_turn" ? "Done" : "Stopped: \(stop)")"
            if let i = usage["inputTokens"], let o = usage["outputTokens"] { m += " · in \(i) out \(o)" }
            if let c = usage["cachedReadTokens"] { m += " cached \(c)" }
            log?.log("done", m, level: stop == "end_turn" ? .info : .warning)
            if stop == "cancelled" { return AgentRun.Outcome(summary: "Stopped.", failed: true, costUSD: cost) }
            return AgentRun.Outcome(summary: text, failed: stop != "end_turn", costUSD: cost)
        }
    }

    /// While a request runs: fails it when opencode logs a provider error it
    /// doesn't send over ACP (free limit, no funds, bad key), or when the
    /// agent says nothing at all for `stallTimeout` outside a tool call.
    /// Either way the turn is cancelled, so opencode stops retrying.
    private func watch(session: String, log watch: OpencodeLog) async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1.5))
            if Task.isCancelled { return }
            if let error = watch.error(session: session) {
                let model = locked { currentModel }
                let message = OpencodeLog.explain(error, model: model)
                locked { log }?.log("provider", "opencode logged: \(error)", level: .error, detail: "from \(watch.url.path)")
                failPrompt(session: session, message: message)
                return
            }
            let (quiet, busy) = locked { (Date().timeIntervalSince(lastOutput), toolRunning) }
            if quiet > Self.stallTimeout, !busy {
                let message = "opencode stopped answering: nothing for \(Int(Self.stallTimeout / 60)) minutes. "
                    + "Its log (\(watch.url.path)) may say why; try again, or choose another model in Settings (⌘,)."
                locked { log }?.log("stall", message, level: .error)
                failPrompt(session: session, message: message)
                return
            }
        }
    }

    /// Ends the waiting request with `message` and cancels opencode's turn.
    private func failPrompt(session: String, message: String) {
        let waiting = locked { () -> ((Result<JSONObject, Error>) -> Void)? in
            guard let id = promptCallID else { return nil }
            promptCallID = nil
            return calls.removeValue(forKey: id)
        }
        notify("session/cancel", ["sessionId": session])
        waiting?(.failure(AgentError(message, provider: true)))
    }

    private func startOpencodeIfNeeded() async throws {
        let running = locked { () -> Bool in
            if let process, process.isRunning, ready {
                log?.log("reuse", "Continuing \(agent.harness.title)'s running session (process \(process.processIdentifier))", level: .debug)
                return true
            }
            return false
        }
        if running { return }
        close()
        try lock.withLock { try launch(["acp", "--cwd", folder.path]) }
        let hello = try await call("initialize", [
            "protocolVersion": 1,
            "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
            "clientInfo": ["name": "Pondside", "version": MCPServer.serverVersion],
        ])
        let (log, previous) = locked { (self.log, sessionID) }
        let info = hello.value["agentInfo"] as? [String: Any]
        // The version, so a break can be matched to the release that caused it.
        log?.log("init", "\(info?["name"] ?? "agent") \(info?["version"] ?? "?") over ACP (protocol \(hello.value["protocolVersion"] ?? "?"))")
        // Pondside's MCP server, named as in the folder's opencode.json, so it replaces that entry.
        var env: [[String: String]] = [[ "name": AgentLog.runFileVariable, "value": runFile.path ]]
        for k in [AgentLog.directoryVariable, "PATH"] {
            if let v = agent.environment(pondside: pondside, log: nil)[k] { env.append(["name": k, "value": v]) }
        }
        let mcp: [[String: Any]] = [["name": "pondside", "command": pondside, "args": ["mcp", "--role", role.rawValue], "env": env]]
        var opened: JSONObject?
        if let previous {
            do {
                opened = try await call("session/resume", ["sessionId": previous, "cwd": folder.path, "mcpServers": mcp])
            } catch {
                log?.log("resume", "Couldn't resume session \(previous) (\(error.localizedDescription)): starting a new one", level: .warning)
                locked { sessionID = nil; spent = 0 }
            }
        }
        if opened == nil {
            let new = try await call("session/new", ["cwd": folder.path, "mcpServers": mcp])
            guard let id = new.value["sessionId"] as? String else { throw AgentError("no session id from session/new") }
            locked { sessionID = id; spent = 0 }
            opened = new
        }
        let model = (opened?.value["configOptions"] as? [[String: Any]])?.first { $0["id"] as? String == "model" }?["currentValue"]
        log?.log("init", "Session \(locked { sessionID } ?? "?") · model \(model.map { "\($0)" } ?? "?")")
        locked { currentModel = model as? String ?? agent.model }
        locked { ready = true }
    }

    /// A JSON-RPC request to the agent; waits for its answer.
    private func call(_ method: String, _ params: [String: Any]) async throws -> JSONObject {
        try await withCheckedThrowingContinuation { (k: CheckedContinuation<JSONObject, Error>) in
            lock.lock()
            nextID += 1
            let id = nextID
            calls[id] = { k.resume(with: $0) }
            if method == "session/prompt" { promptCallID = id }
            let handle = input
            lock.unlock()
            do {
                guard let handle else { throw AgentError("\(agent.harness.title) isn't running") }
                try write(["jsonrpc": "2.0", "id": id, "method": method, "params": params], to: handle)
            } catch {
                let waiting = locked { calls.removeValue(forKey: id) }
                waiting?(.failure(error))
            }
        }
    }

    private func notify(_ method: String, _ params: [String: Any]) {
        guard let handle = locked({ input }) else { return }
        try? write(["jsonrpc": "2.0", "method": method, "params": params], to: handle)
    }

    private func respond(_ id: Any, result: Any? = nil, error: (Int, String)? = nil) {
        guard let handle = locked({ input }) else { return }
        var m: [String: Any] = ["jsonrpc": "2.0", "id": id]
        if let error { m["error"] = ["code": error.0, "message": error.1] } else { m["result"] = result ?? [String: Any]() }
        try? write(m, to: handle)
    }

    private func write(_ message: [String: Any], to handle: FileHandle) throws {
        let data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        try handle.write(contentsOf: data + Data("\n".utf8))
    }

    private func acpLine(_ line: Data) {
        guard let m = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            locked { log }?.log("output", String(decoding: line.prefix(300), as: UTF8.self), level: .debug)
            return
        }
        let method = m["method"] as? String
        if method == nil, let id = m["id"] as? Int {
            let k = locked { calls.removeValue(forKey: id) }
            if let e = m["error"] as? [String: Any] {
                k?(.failure(AgentError((e["message"] as? String ?? "error") + ((e["data"]).map { " \(AgentStreamEvents.json($0))" } ?? ""))))
            } else {
                k?(.success(JSONObject(m["result"] as? [String: Any] ?? [:])))
            }
            return
        }
        let params = m["params"] as? [String: Any] ?? [:]
        switch method {
        case "session/update":
            update(params["update"] as? [String: Any] ?? [:])
        case "session/request_permission":
            // As `opencode run --auto`: allow, and say so in the log.
            let options = params["options"] as? [[String: Any]] ?? []
            let allow = options.first { $0["kind"] as? String == "allow_once" } ?? options.first { ($0["kind"] as? String ?? "").hasPrefix("allow") }
            let title = (params["toolCall"] as? [String: Any])?["title"] as? String ?? "a tool"
            locked { log }?.log("permission", "Allowed \(title)", level: .debug, detail: AgentStreamEvents.json(params))
            if let id = m["id"] {
                if let option = allow?["optionId"] {
                    respond(id, result: ["outcome": ["outcome": "selected", "optionId": option]])
                } else {
                    respond(id, result: ["outcome": ["outcome": "cancelled"]])
                }
            }
        default:
            // Pondside offers no files or terminal of its own (initialize said so).
            if let id = m["id"] { respond(id, error: (-32601, "Pondside doesn't offer \(method ?? "?")")) }
        }
    }

    private func update(_ u: [String: Any]) {
        let kind = u["sessionUpdate"] as? String ?? ""
        let (log, onActivity, first) = locked { () -> (AgentLog.Run?, (@Sendable (String) -> Void)?, Bool) in
            let first = !sawOutput && kind != "available_commands_update" && kind != "usage_update"
            if first { sawOutput = true }
            return (self.log, activity, first)
        }
        if first, let log { log.log("ready", String(format: "First output after %.1f s", log.elapsed)) }
        switch kind {
        case "agent_message_chunk":
            let t = (u["content"] as? [String: Any])?["text"] as? String ?? ""
            locked { reply += t; unloggedText += t }
            onActivity?("writing")
        case "agent_thought_chunk":
            let t = (u["content"] as? [String: Any])?["text"] as? String ?? ""
            locked { thought += t }
            onActivity?("thinking")
        case "tool_call":
            flushText()
            let id = u["toolCallId"] as? String ?? ""
            let title = u["title"] as? String ?? "tool"
            locked { tools[id] = (title, Date(), u["rawInput"]) }
            onActivity?(AgentRun.words(title))
        case "tool_call_update":
            let status = u["status"] as? String ?? ""
            let id = u["toolCallId"] as? String ?? ""
            // The input arrives complete on an in-progress update.
            if let raw = u["rawInput"] as? [String: Any], !raw.isEmpty {
                locked { if tools[id] != nil { tools[id]?.input = raw } }
            }
            guard status == "completed" || status == "failed" else { return }
            let known = locked { tools.removeValue(forKey: id) }
            let title = u["title"] as? String ?? known?.title ?? "tool"
            let seconds = known.map { Date().timeIntervalSince($0.started) }
            let input = (u["rawInput"] as? [String: Any]).flatMap { $0.isEmpty ? nil : $0 } ?? known?.input
            var output = AgentStreamEvents.json((u["rawOutput"] as? [String: Any])?["output"] ?? u["rawOutput"])
            if output.isEmpty {
                output = (u["content"] as? [[String: Any]] ?? []).compactMap { (($0["content"] as? [String: Any])?["text"] as? String) }
                    .joined(separator: "\n")
            }
            log?.log("tool", "\(title)  \(AgentStreamEvents.summary(of: input))" + (seconds.map { String(format: "  [%.1f s]", $0) } ?? ""),
                     detail: AgentStreamEvents.json(input))
            log?.log("result", (status == "failed" ? "Error: " : "") + AgentStreamEvents.oneLine(output, 200),
                     level: status == "failed" ? .warning : .debug, detail: output)
        case "usage_update":
            if let amount = (u["cost"] as? [String: Any])?["amount"] as? Double { locked { sessionCost = amount } }
        default:
            break
        }
    }

    /// Logs the reply text and thinking received since the last tool call.
    private func flushText() {
        let (text, thinking, log) = locked { () -> (String, String, AgentLog.Run?) in
            defer { unloggedText = ""; thought = "" }
            return (unloggedText, thought, self.log)
        }
        if !thinking.isEmpty {
            log?.log("thinking", AgentStreamEvents.oneLine(thinking), level: .debug, detail: thinking.count > 160 ? thinking : nil)
        }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { log?.log("text", AgentStreamEvents.oneLine(t, 240), detail: t.count > 240 ? t : nil) }
    }
}

/// A JSON object handed across a continuation (JSONSerialization's values
/// are immutable once parsed).
struct JSONObject: @unchecked Sendable {
    let value: [String: Any]
    init(_ value: [String: Any]) { self.value = value }
}

struct AgentError: LocalizedError {
    let message: String
    /// The provider refused or went quiet: the user must act (another model, credit).
    var provider = false
    init(_ message: String, provider: Bool = false) {
        self.message = message
        self.provider = provider
    }
    var errorDescription: String? { message }
}
