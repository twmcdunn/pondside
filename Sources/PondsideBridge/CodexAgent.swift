import Foundation

extension AgentRun {
    /// A fresh exec per turn, resumed by its explicit thread ID. Ignore
    /// unrelated user MCP servers, preserve the CLI's existing authentication,
    /// and leave source writes to Pondside's contract-checked MCP server.
    func codexArguments(prompt: String, folder: URL, pondside: String, session: String?, role: MCPServer.Role) -> [String] {
        func quoted(_ value: String) -> String {
            let data = try! JSONSerialization.data(withJSONObject: [value], options: [.withoutEscapingSlashes])
            return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
        }
        let server = "mcp_servers={pondside={command=\(quoted(pondside)),args=[\"mcp\",\"--role\",\(quoted(role.rawValue))],cwd=\(quoted(folder.path)),required=true}}"
        let config = ["approval_policy=\"never\"", "sandbox_mode=\"read-only\"", "web_search=\"disabled\"",
                      "features.shell_tool=false", "features.multi_agent=false", "features.view_image=false", server]
        return ["exec"] + (session == nil ? [] : ["resume"])
            + ["--ignore-user-config", "--json", "--skip-git-repo-check"]
            + config.flatMap { ["--config", $0] }
            + (session.map { [$0, prompt] } ?? ["--cd", folder.path, prompt])
    }

    func parseCodex(_ output: String, status: Int32) -> Outcome {
        var session: String?, summary = "", error = "", completed = false, failed = status != 0
        for line in output.split(separator: "\n") {
            guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            switch event["type"] as? String {
            case "thread.started": session = event["thread_id"] as? String ?? session
            case "item.completed":
                if let item = event["item"] as? [String: Any], item["type"] as? String == "agent_message" {
                    summary = item["text"] as? String ?? summary
                }
            case "turn.completed": completed = true; failed = status != 0; error = ""
            case "turn.failed", "error":
                failed = true
                let detail = event["error"] as? [String: Any]
                error = detail?["message"] as? String ?? event["message"] as? String ?? "Codex could not complete the request."
            default: break
            }
        }
        if !completed { failed = true }
        let provider = failed && ["quota", "usage limit", "rate limit", "credits", "api key", "authentication", "login", "sign in"].contains { error.lowercased().contains($0) }
        if failed, !error.isEmpty { summary = error }
        if summary.isEmpty { summary = output.suffix(600).description }
        return Outcome(summary: summary.trimmingCharacters(in: .whitespacesAndNewlines), failed: failed,
                       costUSD: nil, sessionID: session, providerProblem: provider)
    }

    func codexActivity(_ event: [String: Any]) -> String? {
        if event["type"] as? String == "turn.started" { return "thinking" }
        guard let item = event["item"] as? [String: Any] else { return nil }
        switch item["type"] as? String {
        case "mcp_tool_call": return Self.words(item["tool"] as? String ?? "")
        case "agent_message": return "writing"
        case "reasoning": return "thinking"
        default: return nil
        }
    }
}

extension AgentStreamEvents {
    static func codex(_ event: [String: Any]) -> [Event] {
        switch event["type"] as? String {
        case "thread.started": return [Event(event: "init", message: "Codex session", level: .info, detail: event["thread_id"] as? String)]
        case "turn.completed": return [Event(event: "result", message: "Codex finished", level: .info, detail: json(event["usage"]))]
        case "error", "turn.failed": return [Event(event: "error", message: oneLine(json(event["error"] ?? event["message"])), level: .error, detail: json(event))]
        case "item.started", "item.completed":
            guard let item = event["item"] as? [String: Any] else { return [] }
            if item["type"] as? String == "mcp_tool_call" {
                return [Event(event: "tool", message: "\(item["tool"] ?? "tool") · \(item["status"] ?? "working")", level: .info, detail: json(item))]
            }
            if item["type"] as? String == "agent_message", event["type"] as? String == "item.completed" {
                return [Event(event: "text", message: oneLine(item["text"] as? String ?? ""), level: .info, detail: item["text"] as? String)]
            }
            return []
        default: return []
        }
    }
}
