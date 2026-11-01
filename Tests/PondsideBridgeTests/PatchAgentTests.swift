import Foundation
import XCTest
import PondsideLexicon
import PondsideTiming
@testable import PondsideBridge

/// The edit tool's edits, the patch agent's context, and the two roles'
/// separate tools and files.
final class PatchAgentTests: XCTestCase {
    func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-patch-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    // MARK: FileEdit

    func testEditsByTextAndByLine() throws {
        let text = "a\nb = 1\nc\nd = 1\n"
        XCTAssertEqual(try FileEdit.apply([.init(old: "b = 1", new: "b = 2")], to: text).text, "a\nb = 2\nc\nd = 1\n")
        // Copied with the context's numbers.
        XCTAssertEqual(try FileEdit.apply([.init(old: "2| b = 1\n3| c", new: "2| b = 3\n3| c")], to: text).text, "a\nb = 3\nc\nd = 1\n")
        let byLine = try FileEdit.apply([.init(new: "B\nB2", fromLine: 2), .init(new: "D", fromLine: 4, toLine: 4)], to: text)
        XCTAssertEqual(byLine.text, "a\nB\nB2\nc\nD\n")
        XCTAssertEqual(byLine.lines, 2...5)
        XCTAssertThrowsError(try FileEdit.apply([.init(old: "= 1", new: "= 2")], to: text)) {
            XCTAssertTrue("\($0)".contains("lines 2, 4"), "\($0)")
        }
        XCTAssertThrowsError(try FileEdit.apply([.init(old: "zzz", new: "")], to: text))
        XCTAssertThrowsError(try FileEdit.apply([.init(new: "x", fromLine: 2, toLine: 3), .init(new: "y", fromLine: 3)], to: text))
        XCTAssertThrowsError(try FileEdit.apply([.init(new: "x", fromLine: 9)], to: text))
    }

    func testTheContextNumbersItsCode() {
        XCTAssertEqual(ScoreContext.numbered("x\ny", from: 9), " 9| x\n10| y")
        XCTAssertEqual(FileEdit.unnumbered(" 9| x\n10| y"), "x\ny")
    }

    // MARK: Patch context

    func scorePatch() throws -> (score: URL, patch: URL, sheet: CueSheet) {
        let dir = try temp()
        let score = dir.appendingPathComponent("s.ly")
        try "\\version \"2.24.0\"\n{ c'1 }\n".write(to: score, atomically: true, encoding: .utf8)
        let log = TimingLog(rows: [.init(moment: Rational(1), bar: 2, kind: .text("cue 1")),
                                   .init(moment: Rational(3), bar: 4, kind: .text("cue 2"))])
        let sheet = CueSheet(log: log, score: "s.ly")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("patch"), withIntermediateDirectories: true)
        let patch = dir.appendingPathComponent("patch/s.scd")
        var text = HandlerSync.patchStarter(sheet, name: "s")
        text = text.replacingOccurrences(of: "~cue[\\cue1] = { |cue|\n", with: "~cue[\\cue1] = { |cue|\n\t~verb = Synth(\\lx_reverb_mono, [\\in, ~live]);\n")
        text = text.replacingOccurrences(of: "\n(\n\n)\n", with: "\n(\n~verbAmp = 0.5;\n)\n")
        try text.write(to: patch, atomically: true, encoding: .utf8)
        return (score, patch, sheet)
    }

    func testThePatchContextGivesTheCuesHandlerAndWhatItTouches() throws {
        let (score, patch, sheet) = try scorePatch()
        let lex = SCLexicon.load(project: nil)
        let ctx = PatchContext.describe(score: score, patch: patch, sheet: sheet, at: .init(bar: 3), lexicon: lex)
        XCTAssertEqual(ctx["cue"]?["name"]?.string, "1")
        XCTAssertEqual(ctx["cue"]?["handler"]?.string, "~cue[\\cue1]")
        XCTAssertTrue(ctx["cue"]?["window"]?.string?.contains("until cue 2") ?? false, "\(ctx)")
        let code = try XCTUnwrap(ctx["cue"]?["code"]?["text"]?.string)
        XCTAssertTrue(code.contains("| \t~verb = Synth(\\lx_reverb_mono"), code)
        XCTAssertEqual(ctx["next_cue"]?["name"]?.string, "2")
        XCTAssertTrue(ctx["doc"]?.string?.contains("## cue ") ?? false)
        XCTAssertTrue(ctx["sc_lexicon"]?.array?.contains { $0.string?.hasPrefix("reverb (effect)") ?? false } ?? false)
        // By cue name too; before the first cue, it says so.
        XCTAssertEqual(PatchContext.describe(score: score, patch: patch, sheet: sheet, at: .init(cue: "2"))["cue"]?["name"]?.string, "2")
        XCTAssertTrue(PatchContext.describe(score: score, patch: patch, sheet: sheet, at: .init(bar: 1))["cue"]?.string?.contains("before the first cue") ?? false)
        // The doc was written beside the patch.
        XCTAssertTrue(FileManager.default.fileExists(atPath: PatchDoc.url(patch: patch).path))
    }

    func testAddingLexiconEntriesWritesTheIncludeAndItsLoadLine() throws {
        let (_, patch, _) = try scorePatch()
        let lex = SCLexicon.load(project: nil)
        XCTAssertEqual(try PatchContext.addLexicon(["cloud"], patch: patch, lexicon: lex), ["grain", "pitches", "glide", "cloud"])
        XCTAssertEqual(try PatchContext.addLexicon(["reverb"], patch: patch, lexicon: lex), ["grain", "pitches", "glide", "cloud", "reverb"])
        let include = try String(contentsOf: SCLexiconInclude.url(patch: patch), encoding: .utf8)
        XCTAssertTrue(include.contains("~lxFx[\\reverb]") && include.contains("~lx[\\cloud]") && include.hasSuffix("~lxBuildFx.value;\n"))
        let text = try String(contentsOf: patch, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: SCLexiconInclude.loadLine).count, 2, "loaded once")
        XCTAssertThrowsError(try PatchContext.addLexicon(["nope"], patch: patch, lexicon: lex))
        XCTAssertEqual(PatchOutline.build(patch: patch).lexicon, ["grain", "pitches", "glide", "cloud", "reverb"])
    }

    // MARK: Roles

    func call(_ server: MCPServer, _ json: String) async throws -> JSONValue {
        let raw = await server.handle(line: json)
        return try JSONDecoder().decode(JSONValue.self, from: Data(try XCTUnwrap(raw).utf8))
    }

    func tools(_ server: MCPServer) async throws -> [String] {
        let reply = try await call(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
        return reply["result"]?["tools"]?.array?.compactMap { $0["name"]?.string } ?? []
    }

    func testEachRoleSeesItsOwnToolsAndEditsOnlyItsOwnFiles() async throws {
        let dir = try temp()
        let all = try await tools(MCPServer(project: dir))
        for t in ["edit", "check", "graphic_insert", "patch_context", "patch_check", "sc_lexicon_add", "patch_migrate"] {
            XCTAssertTrue(all.contains(t), t)
        }
        let graphics = try await tools(MCPServer(project: dir, role: .graphics))
        XCTAssertTrue(graphics.contains("graphic_insert") && graphics.contains("edit") && graphics.contains("check"))
        XCTAssertFalse(graphics.contains("patch_check") || graphics.contains("sc_lexicon_add") || graphics.contains("patch_migrate"))
        let patch = try await tools(MCPServer(project: dir, role: .patch))
        XCTAssertTrue(patch.contains("patch_context") && patch.contains("patch_note") && patch.contains("edit") && patch.contains("sc_lexicon_entry"))
        XCTAssertFalse(patch.contains("graphic_insert") || patch.contains("check") || patch.contains("lexicon_propose"))

        try "x = 1;\n".write(to: dir.appendingPathComponent("a.scd"), atomically: true, encoding: .utf8)
        try "{ c'1 }\n".write(to: dir.appendingPathComponent("a.ily"), atomically: true, encoding: .utf8)
        let edit = { (file: String) in
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"edit","arguments":{"file":"\#(file)","edits":[{"old":"1","new":"2"}]}}}"#
        }
        let refused = try await call(MCPServer(project: dir, role: .graphics), edit("a.scd"))
        XCTAssertEqual(refused["result"]?["isError"], true)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.scd"), encoding: .utf8), "x = 1;\n")
        let done = try await call(MCPServer(project: dir, role: .patch), edit("a.scd"))
        XCTAssertEqual(done["result"]?["isError"], false, "\(done)")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.scd"), encoding: .utf8), "x = 2;\n")
        let wrong = try await call(MCPServer(project: dir, role: .patch), edit("a.ily"))
        XCTAssertEqual(wrong["result"]?["isError"], true)
    }

    func testThePromptsAskForAVisibleChangeAndTheNumberedContext() {
        let p = AgentRun.graphicsPrompt(request: "taller", context: "{}", score: URL(fileURLWithPath: "/s.ly"))
        XCTAssertTrue(p.contains("at a \nglance") || p.contains("at a glance"), p)
        XCTAssertTrue(p.contains("without reading the files") && p.contains("edit tool"))
        let follow = AgentRun.graphicsPrompt(request: "again", context: "{}", score: URL(fileURLWithPath: "/s.ly"), followUp: true)
        XCTAssertTrue(follow.contains("glance"))
        let patch = AgentRun.patchPrompt(request: "more reverb", context: "{}", score: URL(fileURLWithPath: "/s.ly"),
                                         patch: URL(fileURLWithPath: "/patch/s.scd"))
        XCTAssertTrue(patch.contains("patch_check") && patch.contains("patch_note") && patch.contains("never .ly"))
        XCTAssertTrue(patch.contains("# Editing a Pondside patch"), "the skill is in the first prompt")
    }
}

extension PatchAgentTests {
    func testALineEditWithOldChecksTheLinesFirst() throws {
        let text = "a\nb\nc\n"
        XCTAssertEqual(try FileEdit.apply([.init(old: "2| b", new: "B", fromLine: 2)], to: text).text, "a\nB\nc\n")
        XCTAssertThrowsError(try FileEdit.apply([.init(old: "b", new: "B", fromLine: 3)], to: text)) {
            XCTAssertTrue("\($0)".contains("old is at line 2"), "\($0)")
        }
    }
}

extension PatchAgentTests {
    func testAPointWellAfterItsCueWaitsInTheHandler() throws {
        let (score, patch, sheet) = try scorePatch()
        // Cue 1 is at moment 1; the point is 2.25 s after it.
        let late = PatchContext.describe(score: score, patch: patch, sheet: sheet,
                                         at: .init(bar: 2, moment: Rational(2), seconds: sheet.cues[0].seconds + 2.25))
        XCTAssertEqual(late["cue"]?["point_after_cue"]?.number, 2.25)
        XCTAssertTrue(late["cue"]?["wait"]?.string?.contains("2.250 s") ?? false, "\(late)")
        XCTAssertEqual(late["point"]?["seconds"]?.number.map { ($0 * 100).rounded() / 100 }, ((sheet.cues[0].seconds + 2.25) * 100).rounded() / 100)
        // On the cue (within 0.5 s): no wait.
        let near = PatchContext.describe(score: score, patch: patch, sheet: sheet,
                                         at: .init(bar: 2, moment: Rational(1), seconds: sheet.cues[0].seconds + 0.2))
        XCTAssertNil(near["cue"]?["wait"])
        // The patch's own waits are offered as the style to follow.
        var text = try String(contentsOf: patch, encoding: .utf8)
        text = text.replacingOccurrences(of: "~cue[\\cue2] = { |cue|\n", with: "~cue[\\cue2] = { |cue|\n\t3.wait;\n")
        try text.write(to: patch, atomically: true, encoding: .utf8)
        let styled = PatchContext.describe(score: score, patch: patch, sheet: sheet, at: .init(bar: 2, seconds: sheet.cues[0].seconds + 2))
        XCTAssertTrue(styled["cue"]?["wait_examples"]?.array?.first?.string?.hasSuffix("3.wait;") ?? false, "\(styled)")
    }
}
