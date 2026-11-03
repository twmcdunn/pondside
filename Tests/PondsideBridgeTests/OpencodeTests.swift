import Foundation
import XCTest
@testable import PondsideBridge

final class OpencodeTests: XCTestCase {
    func testModelsAreParsedFromOpencodeModels() {
        let out = "opencode/big-pickle\nopenrouter/anthropic/claude-sonnet-5-5\n\nSome warning line\nopencode/big-pickle\n"
        XCTAssertEqual(AgentRun.parseModels(out), ["opencode/big-pickle", "openrouter/anthropic/claude-sonnet-5-5"])
    }

    func testTheChosenModelGoesInOpencodesInlineConfig() throws {
        var run = AgentRun(harness: .opencode, executable: "/bin/true")
        XCTAssertEqual(run.opencodeConfigContent(), AgentRun.opencodeConfig)
        run.model = "openrouter/anthropic/claude-sonnet-5-5"
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(run.opencodeConfigContent().utf8)) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "openrouter/anthropic/claude-sonnet-5-5")
        let permissions = try XCTUnwrap(json["permission"] as? [String: String])
        XCTAssertEqual(permissions["bash"], "deny")
        XCTAssertEqual(permissions["edit"], "deny")
        XCTAssertEqual(permissions["write"], "deny")
        let claude = AgentRun.claudeTools.joined(separator: " ")
        XCTAssertFalse(claude.contains("Read,Edit") || claude.contains("Read Edit Write"))
        XCTAssertTrue(claude.contains("mcp__pondside"))
        XCTAssertEqual(run.environment(pondside: "/usr/local/bin/pondside", log: nil)["OPENCODE_CONFIG_CONTENT"].flatMap {
            try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }?["model"] as? String,
                       ProcessInfo.processInfo.environment["OPENCODE_CONFIG_CONTENT"] == nil ? "openrouter/anthropic/claude-sonnet-5-5" : nil)
    }

    /// Lines as opencode 1.19 writes them when the provider refuses.
    let log = """
    timestamp=2026-11-01T01:57:00.729Z level=ERROR run=46c30b13 message="stream error" providerID=opencode modelID=gpt-5.4-nano session.id=ses_A small=true agent=title mode=primary error.error="AI_APICallError: Upstream request failed: Insufficient account funds"
    timestamp=2026-11-01T01:57:04.572Z level=INFO run=46c30b13 message=loop session.id=ses_A step=1
    timestamp=2026-11-01T01:57:04.878Z level=ERROR run=46c30b13 message="stream error" providerID=opencode modelID=big-pickle session.id=ses_A small=false agent=build mode=primary error.error="AI_APICallError: Free usage limit reached. Free models work in OpenCode (https://opencode.ai); subscribe to OpenCode Go to keep going: https://opencode.ai/go"
    timestamp=2026-11-01T01:58:04.878Z level=ERROR run=1 message="stream error" session.id=ses_B small=false error.error="AI_APICallError: 401 Unauthorized"

    """

    func testFindsTheWorkingModelsErrorForItsSession() throws {
        // The small title model's error is not the request's.
        XCTAssertEqual(OpencodeLog.error(in: log, session: "ses_A")?.hasPrefix("AI_APICallError: Free usage limit reached."), true)
        XCTAssertEqual(OpencodeLog.error(in: log, session: "ses_B"), "AI_APICallError: 401 Unauthorized")
        XCTAssertNil(OpencodeLog.error(in: log, session: "ses_C"))

        // Followed from where the watch began: earlier errors don't count.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("opencode-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "old line session.id=ses_A level=ERROR small=false error.error=\"old\"\n".write(to: url, atomically: true, encoding: .utf8)
        let watch = OpencodeLog(url: url)
        XCTAssertNil(watch.error(session: "ses_A"))
        let h = try FileHandle(forWritingTo: url)
        try h.seekToEnd()
        try h.write(contentsOf: Data(log.utf8))
        try h.close()
        XCTAssertEqual(watch.error(session: "ses_A")?.contains("Free usage limit"), true)
    }

    func testErrorsAreExplainedInWordsTheUserCanActOn() {
        let free = OpencodeLog.explain("AI_APICallError: Free usage limit reached.", model: "opencode/big-pickle")
        XCTAssert(free.contains("free usage limit") && free.contains("opencode/big-pickle") && free.contains("Settings (⌘,)"), free)
        XCTAssert(OpencodeLog.explain("Upstream request failed: Insufficient account funds", model: nil).contains("no credit"))
        XCTAssert(OpencodeLog.explain("401 Unauthorized", model: nil).contains("opencode auth login"))
        XCTAssert(OpencodeLog.explain("429 Too Many Requests", model: nil).contains("rate-limiting"))
        XCTAssert(OpencodeLog.explain("AI_APICallError: socket hang up", model: nil).hasSuffix("failed: socket hang up"))
    }

    func testSessionIDFromRunEvents() {
        XCTAssertEqual(AgentRun.sessionID(in: #"{"type":"step_start","sessionID":"ses_e6b2","part":{}}"#), "ses_e6b2")
        XCTAssertNil(AgentRun.sessionID(in: "nothing yet"))
    }
}
