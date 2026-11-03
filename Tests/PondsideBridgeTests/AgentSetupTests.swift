import Foundation
import XCTest
import PondsideLexicon
@testable import PondsideBridge

/// The per-folder agent configs: written when missing, merged into the
/// user's own, never rewritten or clobbered.
final class AgentSetupTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-agents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func json(_ dir: URL, _ file: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: dir.appendingPathComponent(file)))
    }

    func testWritesAllConfigsInAnEmptyFolder() throws {
        let dir = try temp()
        let changes = AgentSetup.ensure(in: dir)
        XCTAssertEqual(changes.map(\.outcome), [.created, .created, .created])
        let claude = try json(dir, ".mcp.json")["mcpServers"]?["pondside"]
        XCTAssertEqual(claude?["command"]?.string, "pondside")
        XCTAssertEqual(claude?["args"], ["mcp"])
        let opencode = try json(dir, "opencode.json")
        XCTAssertEqual(opencode["mcp"]?["pondside"]?["command"], ["pondside", "mcp"])
        XCTAssertEqual(opencode["mcp"]?["pondside"]?["type"]?.string, "local")
    }

    func testSecondRunChangesNothing() throws {
        let dir = try temp()
        AgentSetup.ensure(in: dir)
        let file = dir.appendingPathComponent(".mcp.json")
        let before = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        Thread.sleep(forTimeInterval: 0.02)
        XCTAssertEqual(AgentSetup.ensure(in: dir).map(\.outcome), [.present, .present, .present])
        let after = try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testMergeKeepsTheUsersOtherServersAndSettings() throws {
        let dir = try temp()
        try #"{"mcpServers": {"other": {"command": "other-server"}}}"#
            .write(to: dir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        try #"{"model": "anthropic/claude", "theme": "dark"}"#
            .write(to: dir.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSetup.ensure(in: dir).map(\.outcome), [.added, .added, .created])
        let claude = try json(dir, ".mcp.json")["mcpServers"]
        XCTAssertEqual(claude?["other"]?["command"]?.string, "other-server")
        XCTAssertEqual(claude?["pondside"]?["command"]?.string, "pondside")
        let opencode = try json(dir, "opencode.json")
        XCTAssertEqual(opencode["model"]?.string, "anthropic/claude")
        XCTAssertEqual(opencode["theme"]?.string, "dark")
        XCTAssertNotNil(opencode["mcp"]?["pondside"])
    }

    func testTheUsersOwnPondsideEntryIsLeftAlone() throws {
        let dir = try temp()
        let mine = #"{"mcpServers": {"pondside": {"command": "/opt/pondside", "args": ["mcp", "--project", ".."]}}}"#
        try mine.write(to: dir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSetup.ensure(in: dir).first?.outcome, .present)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(".mcp.json"), encoding: .utf8), mine)
    }

    func testUnparseableFilesAreNotTouched() throws {
        let dir = try temp()
        let jsonc = "{\n  // my settings\n  \"theme\": \"dark\"\n}\n"
        try jsonc.write(to: dir.appendingPathComponent("opencode.json"), atomically: true, encoding: .utf8)
        try #"{"mcpServers": []}"#.write(to: dir.appendingPathComponent(".mcp.json"), atomically: true, encoding: .utf8)
        let outcomes = AgentSetup.ensure(in: dir).map(\.outcome)
        guard case .skipped = outcomes[0], case .skipped = outcomes[1] else { return XCTFail("\(outcomes)") }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("opencode.json"), encoding: .utf8), jsonc)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(".mcp.json"), encoding: .utf8), #"{"mcpServers": []}"#)
    }
    func testCodexConfigIsMergedWithoutRewritingSettings() throws {
        let dir = try temp()
        let folder = dir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("config.toml")
        let original = "# My settings\nmodel = \"my-model\"\n[mcp_servers.other]\ncommand = \"other\"\n"
        try original.write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(AgentSetup.ensure(in: dir).last?.outcome, .added)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix(original))
        let parsed = try TOML.parse(text)
        XCTAssertEqual(parsed["mcp_servers"]?["pondside"]?["command"]?.string, "pondside")
        XCTAssertEqual(parsed["mcp_servers"]?["pondside"]?["args"]?.array, [.string("mcp")])
        XCTAssertEqual(AgentSetup.ensure(in: dir).last?.outcome, .present)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), text)
    }

    func testCodexExistingServerAndUnsupportedConfigsStayUntouched() throws {
        let dir = try temp()
        let folder = dir.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("config.toml")
        for original in [
            "[mcp_servers.'pondside']\ncommand = 'custom'\nenabled = false\n",
            "mcp_servers = { other = { command = 'other' } }\n",
            "[[unsupported]]\nvalue = true\n",
            "invalid TOML"
        ] {
            try original.write(to: url, atomically: true, encoding: .utf8)
            let outcome = AgentSetup.ensure(in: dir).last?.outcome
            if original.contains("'pondside'") { XCTAssertEqual(outcome, .present) }
            else if case .skipped = outcome {} else { XCTFail("\(String(describing: outcome))") }
            XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), original)
        }
    }

}
