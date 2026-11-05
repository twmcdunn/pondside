import Foundation
import XCTest
@testable import PondsideBridge

final class CodexAgentTests: XCTestCase {
    let agent = AgentRun(harness: .codex, executable: "/fake/codex")
    func testCodexIsAnAgentAndUsesCheckedRoleScopedTools() {
        XCTAssertTrue(AgentHarness.allCases.contains(.codex))
        XCTAssertEqual(AgentHarness.codex.title, "Codex")
        let args = agent.arguments(prompt: "change the cue", folder: URL(fileURLWithPath: "/a score"), pondside: "/app bundle/pondside", role: .patch)
        XCTAssertEqual(args.first, "exec")
        XCTAssertTrue(args.contains("--ignore-user-config"))
        XCTAssertTrue(args.contains("--skip-git-repo-check"))
        XCTAssertTrue(args.contains("sandbox_mode=\"read-only\""))
        XCTAssertTrue(args.contains("features.shell_tool=false"))
        XCTAssertTrue(args.contains("web_search=\"disabled\""))
        XCTAssertTrue(args.contains { $0.contains("args=[\"mcp\",\"--role\",\"patch\"]") && $0.contains("required=true") })
        XCTAssertFalse(args.contains("--dangerously-bypass-approvals-and-sandbox"))
        XCTAssertEqual(args.last, "change the cue")
    }
    func testResumeUsesTheExplicitThread() {
        let args = agent.arguments(prompt: "again", folder: URL(fileURLWithPath: "/score"), pondside: "/pondside", session: "thread-123")
        XCTAssertEqual(Array(args.prefix(2)), ["exec", "resume"])
        XCTAssertEqual(Array(args.suffix(2)), ["thread-123", "again"])
        XCTAssertFalse(args.contains("--last"))
    }
    func testCodexEventsProduceReplyThreadAndActivity() {
        let output = #"{"type":"thread.started","thread_id":"thread-123"}"# + "\n"
            + #"{"type":"item.completed","item":{"id":"1","type":"agent_message","text":"Cue 1: reverb 0.2 → 0.4."}}"# + "\n"
            + #"{"type":"turn.completed","usage":{"input_tokens":10,"output_tokens":20}}"#
        let result = agent.parse(output, status: 0)
        XCTAssertFalse(result.failed)
        XCTAssertEqual(result.sessionID, "thread-123")
        XCTAssertEqual(result.summary, "Cue 1: reverb 0.2 → 0.4.")
        XCTAssertNil(result.costUSD)
        let tool = #"{"type":"item.started","item":{"type":"mcp_tool_call","server":"pondside","tool":"edit","status":"in_progress"}}"#
        XCTAssertEqual(agent.activity(tool[...]), "editing")
        XCTAssertEqual(AgentStreamEvents.describe(tool[...], harness: .codex).first?.event, "tool")
    }
    func testFailureAndInterruptedStreamsAreNotReportedAsSuccess() {
        let error = #"{"type":"turn.failed","error":{"message":"Usage limit reached"}}"#
        XCTAssertTrue(agent.parse(error, status: 1).failed)
        XCTAssertTrue(agent.parse(error, status: 1).providerProblem)
        XCTAssertTrue(agent.parse(#"{"type":"thread.started","thread_id":"x"}"#, status: 0).failed)
        let recovered = #"{"type":"error","message":"Reconnecting"}"# + "\n" + #"{"type":"turn.completed"}"#
        XCTAssertFalse(agent.parse(recovered, status: 0).failed)
    }
    func testExecSessionsResumeAndResetWithThePatchRole() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-codex-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = folder.appendingPathComponent("codex")
        let script = #"""
        #!/usr/bin/env python3
        import json, sys
        with open("arguments.jsonl", "a") as log:
            log.write(json.dumps(sys.argv[1:]) + "\n")
        print(json.dumps({"type":"thread.started","thread_id":"11111111-2222-4333-8444-555555555555"}))
        print(json.dumps({"type":"item.completed","item":{"type":"agent_message","text":"Updated the cue."}}))
        print(json.dumps({"type":"turn.completed","usage":{"input_tokens":1,"output_tokens":2}}))
        """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let session = AgentSession(agent: AgentRun(harness: .codex, executable: executable.path), folder: folder, pondside: "/fake/pondside", role: .patch)
        let first = await session.send("first request")
        let second = await session.send("follow-up")
        XCTAssertFalse(first.failed)
        XCTAssertFalse(second.failed)
        XCTAssertEqual(second.summary, "Updated the cue.")
        XCTAssertEqual(session.turns, 2)
        session.reset()
        let third = await session.send("fresh request")
        XCTAssertFalse(third.failed)
        let lines = try String(contentsOf: folder.appendingPathComponent("arguments.jsonl"), encoding: .utf8).split(separator: "\n")
        let runs = try lines.map { try JSONDecoder().decode([String].self, from: Data($0.utf8)) }
        XCTAssertEqual(runs.count, 3)
        XCTAssertFalse(runs[0].contains("resume"))
        XCTAssertEqual(Array(runs[1].prefix(2)), ["exec", "resume"])
        XCTAssertEqual(runs[1][runs[1].count - 2], first.sessionID)
        XCTAssertFalse(runs[2].contains("resume"))
        XCTAssertTrue(runs.allSatisfy { $0.contains { $0.contains("\"--role\",\"patch\"") } })
        XCTAssertTrue(runs.allSatisfy { $0.last?.contains("pondside://patch-contract") == true })
        session.close()
    }

}
