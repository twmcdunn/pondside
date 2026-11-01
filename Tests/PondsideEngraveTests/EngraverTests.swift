import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

final class DiagnosticParserTests: XCTestCase {
    /// Real LilyPond 2.24 stderr for `{\tc4 é d4 \foo e }`.
    func testParsesRealLog() throws {
        let log = try String(contentsOf: try fixture("errors.log"), encoding: .utf8)
        let diagnostics = DiagnosticParser.parse(log)
        XCTAssertEqual(diagnostics.map(\.severity), [.error, .error, .error, .fatal])

        let first = diagnostics[0]
        XCTAssertEqual(first.file, "e2.ly")
        XCTAssertEqual(first.line, 2)
        XCTAssertEqual(first.column, 12)
        XCTAssertEqual(first.message, "not a note name: é")
        XCTAssertEqual(first.context.count, 2)

        let source = SourceText("\\version \"2.24.0\"\n{\tc4 é d4 \\foo e }\n")
        XCTAssertEqual(first.position(in: source), SourcePosition(line: 2, character: 5))
        XCTAssertEqual(diagnostics[1].position(in: source), SourcePosition(line: 2, character: 10))
        XCTAssertEqual(diagnostics[3].message, "failed files: \"e2.ly\"")
        XCTAssertNil(diagnostics[3].line)
    }

    func testWarningsAndColonsInPaths() {
        let d = DiagnosticParser.parse("C:/My:Dir/a.ly:10:3: warning: barcheck failed at: 1/4\n")
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].severity, .warning)
        XCTAssertEqual(d[0].file, "C:/My:Dir/a.ly")
        XCTAssertEqual(d[0].line, 10)
        XCTAssertEqual(d[0].message, "barcheck failed at: 1/4")
        XCTAssertEqual(DiagnosticParser.parse("x.ly:3:1: programming error: oops")[0].severity, .programmingError)
    }
}

final class EngraverPolicyTests: XCTestCase {
    let src = URL(fileURLWithPath: "/tmp/score.ly")
    let out = URL(fileURLWithPath: "/tmp/out/score")

    func testCanvasCompilesWithPointAndClick() {
        let args = LilyPondEngraver.arguments(for: .canvas, source: src, outputBase: out)
        XCTAssertTrue(args.contains("-dpoint-and-click"))
        XCTAssertTrue(args.contains("-dbackend=svg"))
    }

    /// Exported files must never carry local paths: point-and-click is
    /// explicitly disabled for every export format.
    func testExportNeverEnablesPointAndClick() {
        for format in ExportFormat.allCases {
            let args = LilyPondEngraver.arguments(for: .export(format), source: src, outputBase: out)
            XCTAssertTrue(args.contains("-dno-point-and-click"), "\(format)")
            XCTAssertFalse(args.contains("-dpoint-and-click"), "\(format)")
        }
    }

    func testLeakScanner() {
        let clean = Array("%PDF-1.4 /Title (Etude)".utf8)
        XCTAssertNil(ExportSafety.findLocalPathLeak(in: clean, sourceDirectory: "/Users/me/scores"))
        let link = Array("/URI (textedit:///Users/me/scores/a.ly:1:2:3)".utf8)
        XCTAssertEqual(ExportSafety.findLocalPathLeak(in: link, sourceDirectory: "/elsewhere/x"), "textedit://")
        let path = Array("/Producer (/Users/me/scores)".utf8)
        XCTAssertEqual(ExportSafety.findLocalPathLeak(in: path, sourceDirectory: "/Users/me/scores"), "/Users/me/scores")
    }

    func testOutputFileOrdering() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["score-10.svg", "score-2.svg", "score-1.svg", "other.svg", "score.midi", "score-page3.png"] {
            try Data().write(to: dir.appendingPathComponent(name))
        }
        XCTAssertEqual(LilyPondEngraver.outputFiles(in: dir, base: "score", extension: "svg").map(\.lastPathComponent),
                       ["score-1.svg", "score-2.svg", "score-10.svg"])
        XCTAssertEqual(LilyPondEngraver.outputFiles(in: dir, base: "score", extension: "png").map(\.lastPathComponent),
                       ["score-page3.png"])
    }
}

final class ToolchainTests: XCTestCase {
    func install(_ v: String, _ path: String = "/x") -> LilyPondInstallation {
        LilyPondInstallation(executable: path + v, resolvedPath: path + v, version: LilyPondVersion(v)!, origin: .homebrew)
    }

    func testVersionBanner() {
        XCTAssertEqual(ToolchainDetector.parseVersionBanner("GNU LilyPond 2.26.0 (running Guile 2.2)\n\nCopyright"), LilyPondVersion(2, 26, 0))
        XCTAssertNil(ToolchainDetector.parseVersionBanner("command not found"))
    }

    func testSelection() {
        let all = [install("2.24.3"), install("2.26.0"), install("2.27.4")]
        XCTAssertEqual(ToolchainDetector.select(from: all, for: LilyPondVersion(2, 26, 0))?.version, LilyPondVersion(2, 26, 0))
        XCTAssertEqual(ToolchainDetector.select(from: all, for: LilyPondVersion(2, 25, 1))?.version, LilyPondVersion(2, 26, 0))
        XCTAssertEqual(ToolchainDetector.select(from: all, for: nil)?.version, LilyPondVersion(2, 26, 0))
        XCTAssertEqual(ToolchainDetector.select(from: all, for: LilyPondVersion(2, 27, 2))?.version, LilyPondVersion(2, 27, 4))
        XCTAssertNil(ToolchainDetector.select(from: [], for: nil))
    }

    func testCandidatesIncludeStandardLocations() {
        let d = ToolchainDetector(environment: ["PATH": "/a/bin:/b/bin", "HOME": "/nonexistent"], bundledDirectory: nil)
        let paths = d.lilyPondCandidates().map { $0.path }
        XCTAssertEqual(Array(paths.prefix(2)), ["/a/bin/lilypond", "/b/bin/lilypond"])
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/lilypond"))
        XCTAssertTrue(paths.contains("/opt/local/bin/lilypond"))
    }

    func testBundledToolchainComesAfterOverrideBeforePath() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-toolchain-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for sub in ["lilypond-2.26.0/bin", "fluidsynth/bin", "soundfonts"] {
            try FileManager.default.createDirectory(at: dir.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        let fluid = dir.appendingPathComponent("fluidsynth/bin/fluidsynth")
        try "#!/bin/sh\n".write(to: fluid, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fluid.path)
        try Data().write(to: dir.appendingPathComponent("soundfonts/GeneralUser-GS.sf2"))

        let d = ToolchainDetector(environment: ["PATH": "/a/bin", "HOME": "/nonexistent", "PONDSIDE_LILYPOND": "/x/lilypond"],
                                  bundledDirectory: dir.path)
        let candidates = d.lilyPondCandidates()
        XCTAssertEqual(candidates.prefix(3).map(\.path), ["/x/lilypond", dir.path + "/lilypond-2.26.0/bin/lilypond", "/a/bin/lilypond"])
        XCTAssertEqual(candidates[1].origin, .bundled)
        XCTAssertEqual(BundledToolchain.fluidSynth(in: dir.path), fluid.path)
        XCTAssertEqual(BundledToolchain.soundFont(in: dir.path)?.lastPathComponent, "GeneralUser-GS.sf2")
        XCTAssertNil(BundledToolchain.fluidSynth(in: "/nonexistent"))
        XCTAssertNil(BundledToolchain.soundFont(in: nil))
    }
}

final class FileWatcherTests: XCTestCase {
    func testReportsForeignWritesOnly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-watch-\(UUID().uuidString).ly")
        try "{ c }".write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let seen = LockedBox<[String]>([])
        let watcher = FileWatcher(url: url, interval: .seconds(3600)) { change in
            seen.value.append(change.text)
        }
        watcher.start()
        defer { watcher.stop() }

        // A foreign, atomic (rename-based) save is reported.
        try "{ d }".write(to: url, atomically: true, encoding: .utf8)
        watcher.pollNow()
        XCTAssertEqual(seen.value, ["{ d }"])

        // Our own write is not echoed back.
        watcher.noteOwnWrite("{ e }")
        try "{ e }".write(to: url, atomically: true, encoding: .utf8)
        watcher.pollNow()
        XCTAssertEqual(seen.value, ["{ d }"])

        // Touching without changing content is not a change.
        try "{ e }".write(to: url, atomically: false, encoding: .utf8)
        watcher.pollNow()
        XCTAssertEqual(seen.value, ["{ d }"])
    }
}

/// End-to-end against a real LilyPond, when one is installed (CI installs it).
final class LilyPondIntegrationTests: XCTestCase {
    func engraver() async throws -> LilyPondEngraver {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let chosen = ToolchainDetector.select(from: installs, for: nil) else {
            throw XCTSkip("LilyPond not installed")
        }
        return LilyPondEngraver(installation: chosen)
    }

    func scratch() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testCanvasRoundTrip() async throws {
        let engraver = try await engraver()
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("score.ly")
        let text = "\\version \"2.24.0\"\n{ c'4 d'4\te'2 }\n"
        try text.write(to: source, atomically: true, encoding: .utf8)

        let result = try await engraver.engrave(source, purpose: .canvas, outputDirectory: dir.appendingPathComponent("out"))
        XCTAssertTrue(result.succeeded, result.log)
        XCTAssertTrue(result.errors.isEmpty, result.log)
        let page = try XCTUnwrap(result.pages().first)

        // Every note maps back to the token that produced it.
        let sourceText = SourceText(text)
        let tokens = Set(page.graphics.compactMap { g -> String? in
            guard let link = g.link, let i = sourceText.index(of: link.position) else { return nil }
            return String(text[LilyLexing.tokenRange(in: text, at: i)])
        })
        XCTAssertTrue(tokens.isSuperset(of: ["c'4", "d'4", "e'2"]), "\(tokens)")
    }

    /// The fast SVG patch must change nothing but speed.
    func testFastSVGIsByteIdentical() async throws {
        let engraver = try await engraver()
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("score.ly")
        try "\\version \"2.24.0\"\n\\header { title = \"Fast\" }\n{ \\time 3/4 c'4\\p( d'8 e' f'4) | g'2.\\fermata }\n\\addlyrics { la la la la }\n"
            .write(to: source, atomically: true, encoding: .utf8)
        func compile(_ name: String, _ settings: String) async throws -> Data {
            let out = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let file = out.appendingPathComponent("settings.ily")
            try Data(settings.utf8).write(to: file)
            let base = out.appendingPathComponent("score")
            let run = try await ProcessRunner.run(engraver.installation.executable,
                LilyPondEngraver.arguments(for: .canvas, source: source, outputBase: base, sessionSettings: file))
            XCTAssertEqual(run.status, 0, run.stderrString)
            return try Data(contentsOf: base.appendingPathExtension("svg"))
        }
        let stock = try await compile("stock", SessionSettings.canvas)
        let fast = try await compile("fast", SessionSettings.canvas + SessionSettings.fastSVG)
        XCTAssertEqual(stock, fast)
    }

    func testPDFExportHasNoLocalPaths() async throws {
        let engraver = try await engraver()
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("score.ly")
        try "\\version \"2.24.0\"\n{ c'4 d' e' f' }\n".write(to: source, atomically: true, encoding: .utf8)

        let result = try await engraver.engrave(source, purpose: .export(.pdf), outputDirectory: dir.appendingPathComponent("pdf"))
        XCTAssertTrue(result.succeeded, result.log)
        let bytes = [UInt8](try Data(contentsOf: result.outputFiles[0]))
        XCTAssertNil(ExportSafety.findLocalPathLeak(in: bytes, sourceDirectory: dir.path))
    }

    func testDiagnosticsMapToSource() async throws {
        let engraver = try await engraver()
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("bad.ly")
        let text = "\\version \"2.24.0\"\n{ c4 \\nosuchcommand d4 }\n"
        try text.write(to: source, atomically: true, encoding: .utf8)

        let result = try await engraver.engrave(source, purpose: .canvas, outputDirectory: dir.appendingPathComponent("out"))
        let error = try XCTUnwrap(result.errors.first { $0.line != nil }, result.log)
        XCTAssertEqual(error.position(in: SourceText(text)), SourcePosition(line: 2, character: 5))
    }
}
