import Foundation
import XCTest
import PondsideLexicon
import PondsideCore
@testable import PondsideBridge

/// Every project root gets the same structure, and a folder resolves to
/// one root score.
final class ProjectStructureTests: XCTestCase {
    private func temp(_ name: String = "piece") throws -> URL {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-project-\(UUID().uuidString)")
        let dir = parent.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: parent) }
        return dir
    }

    private func write(_ text: String, _ dir: URL, _ file: String) throws {
        try Data(text.utf8).write(to: dir.appendingPathComponent(file))
    }

    private func exists(_ dir: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path)
    }

    static let layout = ["piece.ly", "lexicon.ily", "renders", "patch/piece.scd", "patch/dependencies/pondside.scd", "patch/resources",
                         ".mcp.json", "opencode.json", ".codex/config.toml"]

    func testAdoptsExistingScoreWithoutChangingMusic() throws {
        let dir = try temp()
        try write("{ c'1 }", dir, "original.ly")
        XCTAssertFalse(ProjectStructure.isProjectRoot(dir))
        let score = dir.appendingPathComponent("original.ly")
        try ProjectStructure.adopt(score: score)
        XCTAssertTrue(ProjectStructure.isProjectRoot(dir))
        XCTAssertEqual(ProjectStructure.rootScore(in: dir), .score(score))
        XCTAssertEqual(try String(contentsOf: score, encoding: .utf8), "{ c'1 }")
    }

    func testCreateBuildsTheWholeStructure() throws {
        let dir = try temp()
        let score = try ProjectStructure.create(at: dir)
        XCTAssertEqual(score.lastPathComponent, "piece.ly")
        for path in Self.layout { XCTAssertTrue(exists(dir, path), path) }
        let text = try String(contentsOf: score, encoding: .utf8)
        XCTAssertTrue(text.contains("\\include \"lexicon.ily\""))
        XCTAssertTrue(StructuralEditing.isManaged(SyntaxTree(text)))
        try StructuralEditing.verifyLengths([.init(id: score.path, tree: SyntaxTree(text))], root: score.path)
    }

    /// A score copied without its generated lexicon.ily (the include LilyPond
    /// then can't find) gets the same structure on open.
    func testEnsureRebuildsAMissingLexiconInclude() throws {
        let dir = try temp()
        let text = "\\version \"2.24.0\"\n\\include \"lexicon.ily\"\n{ c'1\\startGraphic \"scribble\" #'() d'1\\stopGraphic }\n"
        try write(text, dir, "piece.ly")
        let changes = ProjectStructure.ensure(score: dir.appendingPathComponent("piece.ly"))
        XCTAssertTrue(changes.allSatisfy { $0.error == nil }, "\(changes)")
        for path in Self.layout { XCTAssertTrue(exists(dir, path), path) }
        let include = try String(contentsOf: dir.appendingPathComponent("lexicon.ily"), encoding: .utf8)
        XCTAssertTrue(include.contains("\"scribble\""), include)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("piece.ly"), encoding: .utf8), text, "the score is not touched")
        // Nothing left to do the second time.
        XCTAssertEqual(ProjectStructure.ensure(score: dir.appendingPathComponent("piece.ly")), [])
    }

    func testEnsureKeepsTheComposersPatch() throws {
        let dir = try temp()
        try write("{ c'1 }\n", dir, "piece.ly")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("patch"), withIntermediateDirectories: true)
        try write("// mine\n", dir.appendingPathComponent("patch"), "piece.scd")
        ProjectStructure.ensure(score: dir.appendingPathComponent("piece.ly"))
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("patch/piece.scd"), encoding: .utf8), "// mine\n")
        XCTAssertTrue(exists(dir, "patch/dependencies/pondside.scd"))
    }

    func testRootScoreOfAFolder() throws {
        let dir = try temp()
        XCTAssertEqual(ProjectStructure.rootScore(in: dir), .none)
        try write("{ c'1 }\n", dir, "flute.ly")
        XCTAssertEqual(ProjectStructure.rootScore(in: dir), .score(dir.appendingPathComponent("flute.ly")))
        // The file nothing else includes is the root.
        try write("\\include \"flute.ly\"\n", dir, "full.ly")
        XCTAssertEqual(ProjectStructure.rootScore(in: dir), .score(dir.appendingPathComponent("full.ly")))
        // Two roots: the one named after the folder.
        try write("{ d'1 }\n", dir, "piece.ly")
        XCTAssertEqual(ProjectStructure.rootScore(in: dir), .score(dir.appendingPathComponent("piece.ly")))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("piece.ly"))
        try write("{ e'1 }\n", dir, "sketch.ly")
        XCTAssertEqual(ProjectStructure.rootScore(in: dir),
                       .ambiguous([dir.appendingPathComponent("full.ly"), dir.appendingPathComponent("sketch.ly")]))
        // pondside.toml settles it.
        try write(ProjectStructure.settingScore("sketch.ly", in: "[lilypond]\nversion = \"2.26.0\"\n"), dir, "pondside.toml")
        XCTAssertEqual(ProjectStructure.rootScore(in: dir), .score(dir.appendingPathComponent("sketch.ly")))
        let toml = try String(contentsOf: dir.appendingPathComponent("pondside.toml"), encoding: .utf8)
        XCTAssertEqual(toml, "[lilypond]\nversion = \"2.26.0\"\n\n[project]\nscore = \"sketch.ly\"\n")
    }
}
