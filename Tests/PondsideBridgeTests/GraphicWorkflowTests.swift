import Foundation
import XCTest
import PondsideLexicon
@testable import PondsideBridge

/// The agent workflow of DESIGN.md §8, headless: what "here" is, inserting
/// a graphic as a minimal edit, drafts and their promotion, the lock.
final class GraphicWorkflowTests: XCTestCase {
    private let score = """
    \\version "2.24.0"
    upper = \\relative c'' { c4 d e f | g1 | a2 g | f1 }
    elec = { s1 | s1 | s1 | s1 }
    \\score { << \\new Staff \\upper \\new Staff \\elec >> }
    """

    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-graphics-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testContextNamesTheEventStaffAndBar() {
        let context = ScoreContext.describe(text: score, file: "score.ly", line: 2, character: 36)
        XCTAssertEqual(context["staff"]?.string, "upper")
        XCTAssertEqual(context["event"]?["text"]?.string, "g1")
        XCTAssertEqual(context["bar"]?.int, 2)
        XCTAssertTrue(context["music"]?["text"]?.string?.contains("\\relative c''") ?? false)
        XCTAssertNil(context["graphic"])
    }

    func testANoGraphicSectionGetsTheLayoutAndDefinitionIndex() {
        let root = #"""
        \version "2.26.0"
        #(define (grob-when g) g)
        score = {
          \layout {
            \context { \Score measureBarType = #"'" }
            \context { \Staff \override BarLine.stencil = #grob-when }
          }
          { c'1 }
        }
        """#
        let files: [ScoreGraphic.File] = [("/score.ly", root), ("/defs.ily", "#(define (span-x g d) 0)\n")]
        let context = ScoreContext.describe(text: root, file: "/score.ly", line: 3, character: 1,
                                            files: files, root: ("/score.ly", root))
        XCTAssertNil(context["graphic"])
        let code = context["code"]
        XCTAssertTrue(code?["layout"]?.array?.first?["text"]?.string?.contains("measureBarType") ?? false)
        XCTAssertTrue(code?["definitions"]?.array?.contains { $0["name"]?.string == "grob-when" } ?? false)
        XCTAssertTrue(code?["definitions"]?.array?.contains { $0["name"]?.string == "span-x" } ?? false)
    }

    func testInsertIsMinimalAndTheContextThenSeesIt() throws {
        let new = try GraphicEdit.insert(into: score, id: "grain-cloud", params: "((height . (swell 2 0.5 2)))",
                                         start: (3, 13), stop: (3, 24))
        XCTAssertEqual(new, score.replacingOccurrences(
            of: "elec = { s1 | s1 | s1 | s1 }",
            with: "elec = { s1 | s1\\startGraphic \"grain-cloud\" #'((height . (swell 2 0.5 2))) | s1 | s1\\stopGraphic }"))
        let graphic = ScoreContext.describe(text: new, file: "score.ly", line: 3, character: 70)["graphic"]
        XCTAssertEqual(graphic?["entry"]?.string, "grain-cloud")
        XCTAssertEqual(graphic?["params"]?["height"], .array([.string("swell"), .number(2), .number(0.5), .number(2)]))
        // A graphic spans one staff.
        XCTAssertThrowsError(try GraphicEdit.insert(into: score, id: "grain-cloud", params: "()", start: (2, 25), stop: (3, 24)))
    }

    func testTheIncludeGoesAfterTheVersion() {
        XCTAssertEqual(GraphicEdit.withLexiconInclude("\\version \"2.24.0\"\nm = { c'1 }\n"),
                       "\\version \"2.24.0\"\n\\include \"lexicon.ily\"\nm = { c'1 }\n")
        XCTAssertEqual(GraphicEdit.withLexiconInclude("m = { c'1 }\n"), "\\include \"lexicon.ily\"\nm = { c'1 }\n")
    }

    func testDraftsAreUsableUntilAcceptedOrDiscarded() throws {
        let project = try temp()
        let toml = """
        schema = 1
        id = "dust"
        version = "0.1.0"
        gloss = "Fine dust"
        kind = "graphic"
        [entry]
        command = "s1\\\\startGraphic \\"dust\\" #'() s1\\\\stopGraphic"
        attaches = "span"
        [params.density]
        type = "float"
        default = 0.5
        [files]
        impl = "impl.ily"
        readme = "README.md"
        """
        // A broken entry.toml is refused with its problems.
        XCTAssertThrowsError(try Lexicon.propose(id: "dust", toml: "id = \"dust\"", impl: "", readme: "", project: project))
        try Lexicon.propose(id: "dust", toml: toml, impl: "#(define-graphic! \"dust\" (lambda (g p) '()))\n",
                            readme: "# dust\n", project: project)
        var lex = Lexicon.load(Lexicon.standardScopes(project: project))
        XCTAssertEqual(lex.entries["dust"]?.scope, .draft)
        XCTAssertTrue(lex.search("dust").first?.contains("\"id\":\"dust\"") ?? false)
        try Lexicon.promote(id: "dust", project: project)
        lex = Lexicon.load(Lexicon.standardScopes(project: project))
        XCTAssertEqual(lex.entries["dust"]?.scope, .project)
        XCTAssertThrowsError(try Lexicon.discard(id: "dust", project: project), "no draft left to discard")
    }

    func testTheLockRecordsVersionsAndReportsDrift() {
        let lex = Lexicon.load(Lexicon.standardScopes(project: nil).filter { $0.0 == .core })
        let locked = LexiconLock.updating(score, lexicon: lex, used: ["grain-cloud", "wedge"])
        XCTAssertEqual(LexiconLock.pins(in: locked).map(\.id), ["grain-cloud", "wedge"])
        XCTAssertTrue(LexiconLock.drift(in: locked, lexicon: lex).isEmpty)
        // Again: replaced in place, not appended twice.
        let again = LexiconLock.updating(locked, lexicon: lex, used: ["wedge"])
        XCTAssertEqual(again.components(separatedBy: "pondside-lexicon-lock").count, 3)
        let old = locked.replacingOccurrences(of: "wedge 1.0.0", with: "wedge 0.9.0")
        XCTAssertEqual(LexiconLock.drift(in: old, lexicon: lex).count, 1)
    }
}
