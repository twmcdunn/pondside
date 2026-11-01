import Foundation
import XCTest
@testable import PondsideBridge

/// The agent log: JSONL that several processes append to, read back in
/// pieces by the app; and what it makes of each agent's event stream.
final class AgentLogTests: XCTestCase {
    private func temp() throws -> AgentLog {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-log-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return AgentLog(directory: dir)
    }

    func testAppendsAndReadsBackIncrementally() throws {
        let log = try temp()
        XCTAssertEqual(log.read(from: 0).entries, [])
        let run = AgentLog.Run(kind: .graphics, log: log)
        run.log("request", "“taller”")
        run.log("prompt", "First request", detail: String(repeating: "x", count: AgentLog.detailLimit + 50))
        let (first, next) = log.read(from: 0)
        XCTAssertEqual(first.map(\.event), ["request", "prompt"])
        XCTAssertEqual(first[0].run, run.id)
        XCTAssertEqual(first[0].kind, .graphics)
        XCTAssertTrue(first[1].detail!.hasSuffix("(50 more characters)"))
        XCTAssertEqual(log.read(from: next).entries, [])

        // A line another process is still writing is left for the next read.
        let h = try FileHandle(forWritingTo: log.url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(#"{"event":"mcp","kind":"mcp""#.utf8))
        XCTAssertEqual(log.read(from: next).entries, [])
        XCTAssertEqual(log.read(from: next).next, next)
        try h.write(contentsOf: Data(#","level":"info","message":"check answered","run":"\#(run.id)","time":"t"}"#.utf8) + Data("\n".utf8))
        try h.close()
        let (later, _) = log.read(from: next)
        XCTAssertEqual(later.map(\.message), ["check answered"])
        // A rotated (shorter) file is read from its start.
        XCTAssertEqual(log.read(from: 1 << 40).entries.count, 3)
    }

    func testRunEnvironmentReachesTheMCPServer() {
        let run = AgentLog.Run(kind: .refactor)
        XCTAssertEqual(run.environment[AgentLog.runVariable], run.id)
        XCTAssertEqual(run.id.count, 8)
    }

    func testClaudeEvents() {
        let initLine = #"{"type":"system","subtype":"init","model":"claude-x","claude_code_version":"2.1.316","session_id":"s1","tools":["Read","mcp__pondside__check"],"mcp_servers":[{"name":"pondside","status":"failed"}]}"#
        let i = AgentStreamEvents.describe(Substring(initLine), harness: .claude)
        XCTAssertEqual(i.first?.event, "init")
        XCTAssertEqual(i.first?.level, .warning, "a server that didn't connect is a warning")
        XCTAssertTrue(i.first!.message.contains("pondside: failed"))
        XCTAssertTrue(i.first!.message.hasPrefix("Claude Code 2.1.316 · model claude-x"))

        let tool = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Looking."},{"type":"tool_use","name":"Read","input":{"file_path":"/s/graphics.ily","offset":10}}]}}"#
        let t = AgentStreamEvents.describe(Substring(tool), harness: .claude)
        XCTAssertEqual(t.map(\.event), ["text", "tool"])
        XCTAssertEqual(t[1].message, "Read  /s/graphics.ily  (offset)")

        let result = #"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"no such file"}]}}"#
        XCTAssertEqual(AgentStreamEvents.describe(Substring(result), harness: .claude).first?.level, .warning)

        let done = #"{"type":"result","subtype":"success","is_error":false,"duration_ms":12300,"num_turns":4,"total_cost_usd":0.05,"result":"Swell taller."}"#
        let d = AgentStreamEvents.describe(Substring(done), harness: .claude)
        XCTAssertEqual(d.first?.event, "done")
        XCTAssertTrue(d.first!.message.contains("12.3 s"))
        XCTAssertTrue(d.first!.message.contains("4 turns"))
    }

    func testOpencodeEvents() {
        // As `opencode run --format json` (1.19) prints them.
        let tool = #"{"type":"tool_use","part":{"type":"tool","tool":"pondside_check","state":{"status":"completed","input":{"file":"/s/score.ly"},"output":"clean","time":{"start":1000,"end":3500}}}}"#
        let t = AgentStreamEvents.describe(Substring(tool), harness: .opencode)
        XCTAssertEqual(t.map(\.event), ["tool", "result"])
        XCTAssertEqual(t[0].message, "pondside_check  /s/score.ly  [2.5 s]")
        let step = #"{"type":"step_finish","part":{"reason":"stop","tokens":{"input":213,"output":2,"cache":{"read":15616}},"cost":0}}"#
        XCTAssertEqual(AgentStreamEvents.describe(Substring(step), harness: .opencode).first?.message,
                       "Step done · in 213 out 2 cached 15616 · stop")
        let error = #"{"type":"error","error":{"name":"UnknownError","data":{"message":"EPROTO: The TLS handshake failed."}}}"#
        let e = AgentStreamEvents.describe(Substring(error), harness: .opencode)
        XCTAssertEqual(e.first?.level, .error)
        XCTAssertTrue(e.first!.message.contains("TLS handshake"))
        XCTAssertEqual(AgentStreamEvents.describe("not json", harness: .opencode).first?.event, "output")
    }

    func testPresenterGroupsRunsAndFilters() {
        func entry(_ run: String, _ kind: AgentLog.Kind, _ event: String, _ level: AgentLog.Level = .info) -> AgentLog.Entry {
            AgentLog.Entry(time: "2026-10-31T12:00:00.000Z", run: run, kind: kind, level: level, event: event,
                           message: event, elapsed: 1.25, detail: "line 1\nline 2")
        }
        let entries = [entry("a", .graphics, "request"), entry("a", .mcp, "mcp"), entry("a", .graphics, "thinking", .debug),
                       entry("b", .refactor, "start"), entry("b", .refactor, "exit", .error)]
        var p = AgentLogPresenter()
        let all = p.spans(for: entries)
        XCTAssertEqual(all.filter { $0.style == .heading }.count, 2)
        XCTAssertFalse(all.contains { $0.text.contains("thinking") }, "debug entries only when verbose")
        XCTAssertTrue(all.contains { $0.style == .error && $0.text.hasPrefix("✕ ") })

        var g = AgentLogPresenter()
        g.filter = .graphics
        g.details = true
        let graphics = g.spans(for: entries)
        XCTAssertTrue(graphics.contains { $0.text.contains("pondside") }, "a graphics run's MCP calls stay with it")
        XCTAssertFalse(graphics.contains { $0.text.contains("start") })
        XCTAssertTrue(graphics.contains { $0.style == .detail && $0.text.contains("│ line 2") })
    }
}
