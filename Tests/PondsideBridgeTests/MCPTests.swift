import Foundation
import XCTest
@testable import PondsideBridge

final class MCPTests: XCTestCase {
    func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func call(_ server: MCPServer, _ json: String) async throws -> JSONValue {
        let raw = await server.handle(line: json)
        let reply = try XCTUnwrap(raw)
        return try JSONDecoder().decode(JSONValue.self, from: Data(reply.utf8))
    }

    func testHandshakeAndListing() async throws {
        let server = MCPServer(project: try temp())
        let initialized = try await call(server, #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        XCTAssertEqual(initialized["result"]?["protocolVersion"], "2025-06-18")
        XCTAssertEqual(initialized["result"]?["serverInfo"]?["name"], "pondside")
        let notification = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(notification, "notifications get no reply")

        let tools = try await call(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
        guard case .array(let list)? = tools["result"]?["tools"] else { return XCTFail("\(tools)") }
        let names = list.compactMap { $0["name"]?.string }
        XCTAssertEqual(names.first, "edit")
        for t in ["check", "query", "render", "cues", "lexicon_check", "score_context", "lexicon_search", "lexicon_entry",
                  "graphic_preview", "graphic_insert", "lexicon_propose", "patch_context", "patch_doc", "patch_note",
                  "patch_check", "sc_lexicon_search", "sc_lexicon_entry", "sc_lexicon_add"] {
            XCTAssertTrue(names.contains(t), t)
        }

        // The skills, as prompts and as resources: the two guides first.
        let prompts = try await call(server, #"{"jsonrpc":"2.0","id":7,"method":"prompts/list"}"#)
        guard case .array(let promptList)? = prompts["result"]?["prompts"] else { return XCTFail("\(prompts)") }
        XCTAssertEqual(promptList.compactMap { $0["name"]?.string }, ["graphic-notation", "lexicon-entries", "lilypond",
                       "lilypond-contemporary-notation", "lilypond-electronics-staff", "lilypond-supercollider",
                       "sc-patch-editing", "sc-patch-migration"])
        let guide = try await call(server, #"{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"lexicon://guide/graphics"}}"#)
        guard case .array(let guideContents)? = guide["result"]?["contents"] else { return XCTFail("\(guide)") }
        XCTAssertTrue(guideContents.first?["text"]?.string?.contains("score_context") ?? false)
        // A skill lists its files, and they read as resources, inside the skill only.
        let lily = try await call(server, #"{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"skill://lilypond-electronics-staff"}}"#)
        XCTAssertTrue(lily["result"]?["contents"]?.jsonString().contains("skill://lilypond-electronics-staff/assets/electronics.ily") ?? false)
        let lib = try await call(server, #"{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"skill://lilypond-electronics-staff/assets/electronics.ily"}}"#)
        guard case .array(let libContents)? = lib["result"]?["contents"] else { return XCTFail("\(lib)") }
        XCTAssertTrue(libContents.first?["text"]?.string?.contains("ecue") ?? false)
        let escape = try await call(server, #"{"jsonrpc":"2.0","id":11,"method":"resources/read","params":{"uri":"skill://lilypond/../graphic-notation/SKILL.md"}}"#)
        XCTAssertNotNil(escape["error"])

        let index = try await call(server, #"{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"lexicon://index"}}"#)
        guard case .array(let contents)? = index["result"]?["contents"] else { return XCTFail("\(index)") }
        XCTAssertTrue(contents.first?["text"]?.string?.contains("timed-fermata") ?? false)

        let missing = try await call(server, #"{"jsonrpc":"2.0","id":4,"method":"nope"}"#)
        XCTAssertEqual(missing["error"]?["code"], .number(-32601))
        let garbage = try await call(server, "{not json")
        XCTAssertEqual(garbage["error"]?["code"], .number(-32700))
    }

    func testCheckReturnsTheRawLogWhenTheErrorHasNoUsefulDiagnostic() async throws {
        let dir = try temp()
        try "\\version \"2.26.0\"\n#(car '())\n{ c'1 }\n".write(to: dir.appendingPathComponent("bad.ly"),
                                                        atomically: true, encoding: .utf8)
        let server = MCPServer(project: dir)
        let reply = try await call(server, #"{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"check","arguments":{"file":"bad.ly"}}}"#)
        guard case .array(let content)? = reply["result"]?["content"], let text = content.first?["text"]?.string else {
            return XCTFail("\(reply)")
        }
        if text.contains("LilyPond is not installed") { throw XCTSkip("no LilyPond") }
        let report = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        XCTAssertEqual(report["ok"], false)
        XCTAssertFalse(report["log"]?.string?.isEmpty ?? true, "the raw compiler log is returned")
        XCTAssertTrue(report["log"]?.string?.contains("Wrong type") ?? false, text)
    }

    func testQueryGivesAbsolutePitchesAndPositions() async throws {
        let dir = try temp()
        try "\\relative c' {\n  c4 e8 <g c>\n}\n".write(to: dir.appendingPathComponent("s.ly"), atomically: true, encoding: .utf8)
        let server = MCPServer(project: dir)
        let reply = try await call(server, #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"query","arguments":{"file":"s.ly"}}}"#)
        XCTAssertEqual(reply["result"]?["isError"], false)
        guard case .array(let content)? = reply["result"]?["content"], let text = content.first?["text"]?.string else {
            return XCTFail("\(reply)")
        }
        let events = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        guard case .array(let list) = events else { return XCTFail(text) }
        XCTAssertEqual(list.count, 3)
        XCTAssertEqual(list[2]["pitches"], ["g'", "c''"])
        XCTAssertEqual(list[1]["duration"], "8")
        XCTAssertEqual(list[2]["duration"], "8", "inherited")
        XCTAssertEqual(list[0]["line"], 2)
        XCTAssertEqual(list[0]["character"], 2)

        let bad = try await call(server, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"query","arguments":{"file":"missing.ly"}}}"#)
        XCTAssertEqual(bad["result"]?["isError"], true, "a tool failure is a result the model sees")
    }
}
