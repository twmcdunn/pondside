import Foundation
import XCTest
import PondsideEngrave
import PondsideTiming
import PondsideCore
@testable import PondsideLexicon

final class TOMLTests: XCTestCase {
    func testTheSubsetEntryFilesUse() throws {
        let doc = try TOML.parse("""
        # comment
        schema = 1
        id = "x"   # trailing
        ratio = 0.5
        neg = -3
        big = 1_000
        on = true
        tags = ["a", 'b',
                "c",   # inside
        ]
        literal = 'C:\\path'
        esc = "tab\\there \\"q\\" \\u00e9"
        multi = \"\"\"
        line one
        line two\"\"\"
        "quoted key" = 1

        [params.density]
        type = "float"
        min = 0.0

        [sound]
        params = { density = "density", dur = "spanDur * 2" }
        """)
        XCTAssertEqual(doc["schema"], .integer(1))
        XCTAssertEqual(doc["ratio"], .float(0.5))
        XCTAssertEqual(doc["neg"], .integer(-3))
        XCTAssertEqual(doc["big"], .integer(1000))
        XCTAssertEqual(doc["on"], .bool(true))
        XCTAssertEqual(doc["tags"], .array([.string("a"), .string("b"), .string("c")]))
        XCTAssertEqual(doc["literal"], .string("C:\\path"))
        XCTAssertEqual(doc["esc"], .string("tab\there \"q\" é"))
        XCTAssertEqual(doc["multi"], .string("line one\nline two"))
        XCTAssertEqual(doc["quoted key"], .integer(1))
        XCTAssertEqual(doc["params"]?["density"]?["type"], .string("float"))
        XCTAssertEqual(doc["sound"]?["params"]?["dur"], .string("spanDur * 2"))
    }

    func testErrorsNameTheLine() {
        XCTAssertThrowsError(try TOML.parse("a = 1\na = 2")) { XCTAssertEqual(($0 as? TOMLError)?.line, 2) }
        XCTAssertThrowsError(try TOML.parse("a = \"open"))
        XCTAssertThrowsError(try TOML.parse("[t]\n[t]"))
        XCTAssertThrowsError(try TOML.parse("a = 1 b = 2"))
        XCTAssertThrowsError(try TOML.parse("a = [1, 2"))
    }
}

final class ExpressionTests: XCTestCase {
    func testEvaluation() throws {
        let b: [String: Double] = ["density": 0.5, "spanDur": 8, "tempo": 120]
        XCTAssertEqual(try Expression(parsing: "0.2 + 0.6 * density").evaluate(b), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try Expression(parsing: "(0.2 + 0.6) * density").evaluate(b), 0.4, accuracy: 1e-12)
        XCTAssertEqual(try Expression(parsing: "-spanDur / 2").evaluate(b), -4)
        XCTAssertEqual(try Expression(parsing: "min(1, tempo / 60, 3)").evaluate(b), 1)
        XCTAssertEqual(try Expression(parsing: "max(density, 0.9)").evaluate(b), 0.9)
        XCTAssertEqual(try Expression(parsing: "8 - 2 - 1").evaluate([:]), 5, "left-associative")
        XCTAssertEqual(try Expression(parsing: "spanDur * density + tempo").names, ["spanDur", "density", "tempo"])
    }

    func testTheLanguageIsTotal() {
        XCTAssertThrowsError(try Expression(parsing: "sin(1)"))
        XCTAssertThrowsError(try Expression(parsing: "max(1)"))
        XCTAssertThrowsError(try Expression(parsing: "1 +"))
        XCTAssertThrowsError(try Expression(parsing: "(1"))
        XCTAssertThrowsError(try Expression(parsing: "1 2"))
        XCTAssertThrowsError(try Expression(parsing: "1 / x").evaluate(["x": 0]))
        XCTAssertThrowsError(try Expression(parsing: "y").evaluate([:]))
    }
}

final class EntryTests: XCTestCase {
    /// The schema example from DESIGN.md §3.
    static let breathCloud = """
    schema   = 1
    id       = "breath-cloud"
    version  = "1.2.0"
    gloss    = "Widening cloud of stemless noteheads, density rising over a span"
    tags     = ["texture", "aleatoric", "graphic", "winds"]
    kind     = "texture"

    [entry]
    attaches = "span"
    music-arg = true

    [params.span]
    type    = "int"
    default = 4
    min     = 1

    [params.density]
    type    = "float"
    default = 0.6
    min     = 0.0
    max     = 1.0

    [params.shape]
    type    = "enum"
    values  = ["widen", "narrow", "steady"]
    default = "widen"

    [sound]
    synthdef = "granularCloud"
    cue      = "breathCloud"
    params   = { density = "density", dur = "spanDur", amp = "0.2 + 0.6 * density" }
    """

    func testTheDesignExampleIsValid() throws {
        let e = try LexiconEntry(toml: Self.breathCloud, directoryName: "breath-cloud")
        XCTAssertEqual(e.params.map(\.name), ["span", "density", "shape"], "params keep file order")
        XCTAssertEqual(e.sound?.params.map(\.name), ["density", "dur", "amp"])
        let values = try e.resolve(["density": .float(0.8)])
        XCTAssertEqual(values["span"], .integer(4))
        let sound = try e.soundParams(values, beatDur: 0.5, spanDur: 8, tempo: 120)
        XCTAssertEqual(sound.map(\.0), ["density", "dur", "amp"])
        XCTAssertEqual(sound[2].1, 0.68, accuracy: 1e-12)
        XCTAssertEqual(sound[1].1, 8)
    }

    func testEveryProblemIsReportedAtOnce() {
        let bad = """
        schema = 1
        id = "Bad_Name"
        version = "1.2"
        gloss = "\(String(repeating: "x", count: 90))"
        kind = "blob"
        [params.d]
        type = "float"
        default = 2.0
        max = 1.0
        [params.e]
        type = "enum"
        [sound]
        params = { a = "nope * 2" }
        """
        XCTAssertThrowsError(try LexiconEntry(toml: bad, directoryName: "bad")) { error in
            let messages = (error as? LexiconProblems)?.problems.map(\.message) ?? []
            XCTAssertTrue(messages.contains { $0.contains("kebab-case") }, "\(messages)")
            XCTAssertTrue(messages.contains { $0.contains("semver") })
            XCTAssertTrue(messages.contains { $0.contains("tier 0 allows 80") })
            XCTAssertTrue(messages.contains { $0.contains("kind must be") })
            XCTAssertTrue(messages.contains { $0.contains("above the maximum") })
            XCTAssertTrue(messages.contains { $0.contains("enum without values") })
            XCTAssertTrue(messages.contains { $0.contains("reads nope") })
            XCTAssertTrue(messages.contains { $0.contains("sound.cue is required") })
            XCTAssertTrue(messages.contains { $0.contains("differs from its folder") })
        }
    }

    func testResolveRejectsUnknownAndOutOfRange() throws {
        let e = try LexiconEntry(toml: Self.breathCloud)
        XCTAssertThrowsError(try e.resolve(["densty": .float(0.5)]))
        XCTAssertThrowsError(try e.resolve(["density": .float(1.5)]))
        XCTAssertThrowsError(try e.resolve(["shape": .string("round")]))
        XCTAssertThrowsError(try e.resolve(["span": .float(2.5)]))
    }
}

final class LibraryTests: XCTestCase {
    func temp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-lexicon-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: d) }
        return d
    }

    func write(_ root: URL, _ id: String, toml: String, impl: String = "% impl\n") throws {
        let d = root.appendingPathComponent("entries/\(id)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try toml.write(to: d.appendingPathComponent("entry.toml"), atomically: true, encoding: .utf8)
        try impl.write(to: d.appendingPathComponent("impl.ily"), atomically: true, encoding: .utf8)
        try "Readme for \(id).\n".write(to: d.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
    }

    func testCoreEntriesAreValid() {
        let lex = Lexicon.load(Lexicon.standardScopes(project: nil).filter { $0.0 == .core })
        XCTAssertTrue(lex.problems.isEmpty, lex.problems.map(\.description).joined(separator: "\n"))
        XCTAssertEqual(lex.ids, ["air-tone", "aleatoric-box", "arc", "feathered-beam", "grain-cloud", "niente-hairpin",
                                 "pitch-band", "proportional", "scribble", "senza-misura", "squiggle", "staff-ripple",
                                 "swell-shape", "timed-fermata", "wedge"])
        let index = lex.indexJSON()
        XCTAssertEqual(index.split(separator: "\n").count, lex.ids.count + 2, "one line per entry between [ and ]")
        XCTAssertTrue(index.contains("{\"gloss\":\"Air sound"))
        // Tier 0 stays cheap: well under 100 tokens (~400 characters) an entry.
        XCTAssertLessThan(index.count / 4 / lex.ids.count, 60)
        XCTAssertTrue(lex.tier1("air-tone")?.contains("[sound]") ?? false)
        XCTAssertTrue(lex.tier2("air-tone")?.contains("pondside-lexicon-register!") ?? false)
    }

    func testGraphicUsesAreFoundAndChecked() {
        let lex = Lexicon.load(Lexicon.standardScopes(project: nil).filter { $0.0 == .core })
        let score = """
        g = { s1\\startGraphic "grain-cloud" #'((height . (swell 3 0.5 4)) (avoid . (note-head-interface))) s1\\stopGraphic }
        h = { s1\\startGraphic "grain-cloud" #'((height . (wobble 2)) (density . 9)) s1\\stopGraphic }
        """
        let uses = LexiconUse.find(in: score)
        XCTAssertEqual(uses.map(\.id), ["grain-cloud", "grain-cloud"])
        XCTAssertEqual(uses[0].params["height"], .array([.string("swell"), .integer(3), .float(0.5), .integer(4)]))
        let problems = lex.check(score).map(\.message)
        XCTAssertEqual(problems.count, 2, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("wobble is not an envelope") }, "\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("above the maximum") }, "\(problems)")
        // The kit comes with any graphic entry, before the implementations.
        let include = lex.includeFile(for: ["grain-cloud"])
        let kit = include.range(of: "pondside-graphics.ily"), impl = include.range(of: "grain-cloud/impl.ily")
        XCTAssertNotNil(kit)
        XCTAssertTrue(kit!.lowerBound < impl!.lowerBound)
        XCTAssertTrue(include.contains("#(hash-set! pondside-graphics-defaults \"grain-cloud\""))
        XCTAssertFalse(lex.includeFile(for: ["air-tone"]).contains("pondside-graphics.ily"))
    }

    func testLaterScopesOverride() throws {
        let user = try temp(), project = try temp()
        let base = EntryTests.breathCloud
        try write(user, "breath-cloud", toml: base)
        try write(project, "breath-cloud", toml: base.replacingOccurrences(of: "1.2.0", with: "2.0.0"))
        try write(project, "broken", toml: "schema = 1\nid = \"broken\"\n")
        let lex = Lexicon.load([(.user, user), (.project, project)])
        XCTAssertEqual(lex.entries["breath-cloud"]?.entry.version, "2.0.0")
        XCTAssertEqual(lex.entries["breath-cloud"]?.scope, .project)
        XCTAssertEqual(lex.shadowed.map(\.scope), [.user])
        XCTAssertNil(lex.entries["broken"])
        XCTAssertFalse(lex.problems.isEmpty)
    }

    func testUsesAreCheckedBeforeCompiling() throws {
        let user = try temp()
        try write(user, "breath-cloud", toml: EntryTests.breathCloud)
        let lex = Lexicon.load([(.user, user)])
        let score = """
        % \\lexicon "commented-out" #'()
        { \\lexicon "breath-cloud" #'((density . 1) (shape . narrow)) { c'1 }
          \\lexicon "breath-cloud" #'((density . 3/2)) { c'1 }
          \\lexicon "breath-clod" #'() { c'1 } }
        """
        let uses = LexiconUse.find(in: score)
        XCTAssertEqual(uses.map(\.id), ["breath-cloud", "breath-cloud", "breath-clod"])
        XCTAssertEqual(uses[0].params["shape"], .string("narrow"))
        let problems = lex.check(score)
        XCTAssertEqual(problems.map(\.line), [3, 4])
        XCTAssertTrue(problems[0].message.contains("above the maximum"))
        XCTAssertTrue(problems[1].message.contains("did you mean breath-cloud"))
    }
}

/// Every core entry engraves with LilyPond, and sound bindings place cues.
final class LexiconEngravingTests: XCTestCase {
    func compile(_ body: String) async throws -> (EngraveResult, URL, LilyPondInstallation) {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        let lex = Lexicon.load(Lexicon.standardScopes(project: nil).filter { $0.0 == .core })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-lexicon-ly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let include = dir.appendingPathComponent("lexicon.ily")
        try lex.includeFile(for: Set(lex.ids)).write(to: include, atomically: true, encoding: .utf8)
        let file = dir.appendingPathComponent("score.ly")
        try "\\version \"2.24.0\"\n\\include \"lexicon.ily\"\n\(body)\n".write(to: file, atomically: true, encoding: .utf8)
        let result = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .canvas, outputDirectory: dir.appendingPathComponent("out"))
        return (result, file, lily)
    }

    func testEveryCoreEntryEngraves() async throws {
        let (result, _, _) = try await compile("""
        \\relative c'' {
          \\lexicon "niente-hairpin" #'() { c2\\> c4 r\\! }
          \\lexicon "timed-fermata" #'((seconds . 6)) { g1 }
          \\lexicon "air-tone" #'((amount . 0.8) (label . "air")) { d2 e }
          \\lexicon "feathered-beam" #'((direction . "rit")) { c16[ d e f g a b c] }
          \\lexicon "senza-misura" #'((seconds . 20) (label . "senza misura")) { c8 d e f g4 a8 b c2 }
          \\lexicon "proportional" #'((unit . 16)) { c8 c16 c c4 c8. c16 c4 }
        }
        """)
        XCTAssertTrue(result.succeeded, result.log)
        XCTAssertTrue(result.errors.isEmpty, result.log)
        XCTAssertFalse(result.log.contains("Lexicon has no entry"), result.log)
    }
    /// The graphics kit and every graphic entry draw, across a line break,
    /// identically on every compile, and link back to their invocation.
    func testGraphicEntriesDrawDeterministically() async throws {
        let body = """
        \\paper { indent = 0 }
        \\score { << \\new Staff { \\repeat unfold 32 { c''4 } }
          \\new Staff << { s1*8 } {
            s1\\startGraphic "grain-cloud" #'((height . (swell 2 0.3 2)) (avoid . (note-head-interface)))
            s1 s1 s1 \\break s1\\stopGraphic\\startGraphic "staff-ripple" #'()
            s1\\stopGraphic\\startGraphic "wedge" #'((dissolve . 0.3))
            s1\\stopGraphic\\startGraphic "swell-shape" #'((side . up))
            s1\\stopGraphic\\startGraphic "arc" #'((echoes . 2))
            s1\\stopGraphic } >> >> }
        \\score { << \\new Staff { c''4\\startGraphic "aleatoric-box" #'((label . "repeat")) d'' e'' f''\\stopGraphic }
          \\new Staff << { s1*2 } { s1\\startGraphic "squiggle" #'() s1\\stopGraphic\\startGraphic "pitch-band" #'() s1\\stopGraphic } >> >> }
        \\score { << \\new Staff { c''1 c'' } \\new Staff << { s1*2 } { s1\\startGraphic "scribble" #'() s1\\stopGraphic } >> >> }
        """
        let (first, _, _) = try await compile(body)
        XCTAssertTrue(first.succeeded, first.log)
        XCTAssertTrue(first.errors.isEmpty, first.log)
        XCTAssertFalse(first.log.contains("no entry"), first.log)
        let warnings = first.diagnostics.filter { $0.severity == .warning && $0.file?.hasSuffix("score.ly") == true }
        XCTAssertTrue(warnings.isEmpty, "\(warnings.map { "\($0.line ?? 0): \($0.message)" })")
        let (second, _, _) = try await compile(body)
        // The two compiles differ only in their links' file paths.
        func strip(_ s: String) -> String {
            s.replacingOccurrences(of: #"textedit://[^"]*"#, with: "", options: .regularExpression)
        }
        let a = first.outputFiles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        let b = second.outputFiles.compactMap { try? String(contentsOf: $0, encoding: .utf8) }
        XCTAssertEqual(a.map(strip), b.map(strip))
        // The grain cloud is linked to its \startGraphic (line 7 of the score).
        XCTAssertTrue(a.joined().contains("score.ly:7:"))
    }


    func testSoundBindingsPlaceCuesAndHoldsTime() async throws {
        let (result, file, lily) = try await compile("""
        \\score { \\relative c'' {
          \\tempo 4 = 60
          c4 \\lexicon "timed-fermata" #'((seconds . 6) (resume . 60)) { g1 }
          \\lexicon "air-tone" #'() { d2 e } } \\layout { } }
        """)
        XCTAssertTrue(result.succeeded, result.log)
        let log = try await TimingDump.run(lily, source: file)
        let sheet = CueSheet(log: log, score: "score.ly")
        // c4 (1 s) + the hold (6 s): the air-tone cue at 7 s.
        XCTAssertEqual(sheet.cues.map(\.name), ["airTone"])
        XCTAssertEqual(sheet.cues.first?.seconds ?? 0, 7, accuracy: 1e-6)
        XCTAssertEqual(sheet.cues.first?.position.moment, "5/4")
        // Its [sound] params, evaluated with the real timing: amp = 0.05 + 0.4 * amount
        // (default 0.5), dur = spanDur (d2 e at 60 bpm: 4 s), rate = tempo / 60.
        let lex = Lexicon.load(Lexicon.standardScopes(project: nil).filter { $0.0 == .core })
        let timed = CueSheet(log: log, score: "score.ly",
                             soundParams: { lex.soundParams(entry: $0, params: $1, beatDur: $2, spanDur: $3, tempo: $4) })
        let params = try XCTUnwrap(timed.cues.first?.params)
        XCTAssertEqual(timed.cues.first?.entry, "air-tone")
        XCTAssertEqual(params["amp"] ?? 0, 0.25, accuracy: 1e-9)
        XCTAssertEqual(params["dur"] ?? 0, 4, accuracy: 1e-6)
        XCTAssertEqual(params["rate"] ?? 0, 1, accuracy: 1e-9)
    }

    func testSenzaMisuraLastsWhatItSays() async throws {
        let (result, file, lily) = try await compile("""
        timingMark = #(define-event-function (text) (string?)
          (let ((ev #{ -\\tweak stencil ##f ^\\markup #text #})) (ly:music-set-property! ev 'timing-label text) ev))
        \\score { \\relative c'' {
          \\tempo 4 = 60
          c4 \\lexicon "senza-misura" #'((seconds . 20)) { c8 d e f g4 a8 b c2 }
          <>\\timingMark "after" c4 } \\layout { } }
        """)
        XCTAssertTrue(result.succeeded, result.log)
        let log = try await TimingDump.run(lily, source: file)
        let sheet = CueSheet(log: log, score: "score.ly")
        let after = try XCTUnwrap(sheet.marks.first { $0.text == "after" })
        XCTAssertEqual(after.seconds, 21, accuracy: 1e-6, "1 s of c4, then the 20 s passage")
    }
}

/// front-matter.ily as Score Setup writes it: a cover from the header,
/// notes, and a legend drawing real Lexicon entries, before the score.
final class FrontMatterEngravingTests: XCTestCase {
    func testFrontMatterEngravesAndItsExamplesTakeNoTime() async throws {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        let lex = Lexicon.load(Lexicon.standardScopes(project: nil).filter { $0.0 == .core })
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-front-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        try lex.includeFile(for: ["air-tone", "grain-cloud"]).write(to: dir.appendingPathComponent("lexicon.ily"), atomically: true, encoding: .utf8)

        var fm = FrontMatter(FrontMatter.template(Set(FrontMatter.Section.allCases)))
        fm = FrontMatter(fm.edits(paragraphs: ["Play without pause; \"quotes\" survive.", "A second paragraph."]).apply(to: fm.text))
        let items = try ["air-tone", "grain-cloud"].map { try XCTUnwrap(lex.entries[$0]?.entry).legendItem }
        fm = FrontMatter(fm.edits(adding: items).apply(to: fm.text))
        try fm.text.write(to: dir.appendingPathComponent(FrontMatter.fileName), atomically: true, encoding: .utf8)

        var root = """
        \\version "2.24.0"
        \\include "lexicon.ily"
        \\header { title = "Pond" composer = "T. M." instrumentation = "Flute, Cello" }
        \\score { <<
          \\new Staff \\with { instrumentName = "Flute" } \\relative c'' { \\tempo 4 = 60 c4 \\lexicon "air-tone" #'() { d2 e } }
          \\new Staff { c1 c }
        >> \\layout { } }

        """
        root = [FrontMatter.includeEdit(root: root)!].apply(to: root)
        let setup = StaffSetup(files: [root])
        root = (setup.edits(staff: 1, .init(instrument: try XCTUnwrap(Instrument.named("cello"))))[0] ?? []).apply(to: root)
        XCTAssert(root.contains(#"\clef bass"#), root)
        let file = dir.appendingPathComponent("score.ly")
        try root.write(to: file, atomically: true, encoding: .utf8)

        let result = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .canvas, outputDirectory: dir.appendingPathComponent("out"))
        XCTAssertTrue(result.succeeded, result.log)
        XCTAssertTrue(result.errors.isEmpty, result.log)
        let warnings = result.diagnostics.filter { d in
            d.severity == .warning && [FrontMatter.fileName, "score.ly"].contains { d.file?.hasSuffix($0) == true }
        }
        XCTAssertTrue(warnings.isEmpty, "\(warnings.map { "\($0.file ?? ""):\($0.line ?? 0): \($0.message)" })")
        // Cover, notes, legend, then the score.
        XCTAssertEqual(result.outputFiles.count, 4, result.log)

        // The legend's air-tone example is drawn, but only the score's own cue is timed.
        let sheet = CueSheet(log: try await TimingDump.run(lily, source: file), score: "score.ly")
        XCTAssertEqual(sheet.cues.map(\.name), ["airTone"])
        XCTAssertEqual(sheet.cues.first?.seconds ?? 0, 1, accuracy: 1e-6)
    }
}

final class ProjectConfigTests: XCTestCase {
    func testFindsTheNearestConfigAbove() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-proj-\(UUID().uuidString)")
        let score = root.appendingPathComponent("score")
        try FileManager.default.createDirectory(at: score, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try """
        [lilypond]
        version = "2.26.0"
        [audio]
        sample-rate = 44100
        soundfont = "sounds/piano.sf2"
        [supercollider]
        handlers = "patch/cues.scd"
        """.write(to: root.appendingPathComponent("pondside.toml"), atomically: true, encoding: .utf8)
        let config = try ProjectConfig.find(from: score.appendingPathComponent("piece.ly"))
        XCTAssertEqual(config.sampleRate, 44100)
        XCTAssertEqual(config.lilypondVersion, "2.26.0")
        XCTAssertEqual(config.handlers?.lastPathComponent, "cues.scd")
        XCTAssertEqual(config.soundFont?.deletingLastPathComponent().lastPathComponent, "sounds")
        XCTAssertThrowsError(try ProjectConfig(toml: "[audio]\nsample-rate = 12345", root: root))
    }

    func testPinningLilyPondChangesOneLine() {
        XCTAssertEqual(ProjectConfig.settingLilyPond(version: "2.24.3", in: ""), "[lilypond]\nversion = \"2.24.3\"\n")
        let toml = "[audio]\nsample-rate = 44100\n\n[lilypond]\nversion = \"2.26.0\" # pinned\n"
        XCTAssertEqual(ProjectConfig.settingLilyPond(version: "2.24.3", in: toml),
                       "[audio]\nsample-rate = 44100\n\n[lilypond]\nversion = \"2.24.3\"\n")
        XCTAssertEqual(ProjectConfig.settingLilyPond(version: "2.24.3", in: "[audio]\nsample-rate = 44100\n"),
                       "[audio]\nsample-rate = 44100\n\n[lilypond]\nversion = \"2.24.3\"\n")
    }

    func testDefaultsWithoutAFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-noproj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = try ProjectConfig.find(from: dir.appendingPathComponent("x.ly"))
        XCTAssertEqual(config.sampleRate, 48000)
        XCTAssertNil(config.handlers)
    }
}

/// The skills Pondside serves agree with what Pondside writes: every file a
/// skill names exists in it, and the SuperCollider skill describes the cue
/// file the mockup actually writes.
final class SkillConsistencyTests: XCTestCase {
    private var skills: URL { Lexicon.coreDirectory!.appendingPathComponent("Skills") }

    func testEveryFileASkillNamesIsBundledWithIt() throws {
        let folders = try FileManager.default.contentsOfDirectory(atPath: skills.path).filter { !$0.hasPrefix(".") }
        XCTAssertFalse(folders.isEmpty)
        let pattern = try NSRegularExpression(pattern: #"`((?:assets|templates|references|scripts|sc)/[A-Za-z0-9_./-]+)`"#)
        for folder in folders {
            let dir = skills.appendingPathComponent(folder)
            let text = try String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8)
            for m in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let path = String(text[Range(m.range(at: 1), in: text)!])
                XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(path).path),
                              "\(folder)/SKILL.md names \(path), which isn't in the skill")
            }
        }
    }

    /// The one graphic skill and the app's selection JSON name the same fields.
    func testTheGraphicSkillDescribesTheMarkedRange() throws {
        let text = try String(contentsOf: skills.appendingPathComponent("graphic-notation/SKILL.md"), encoding: .utf8)
        for key in ["graphic-section", "from", "to", "page_x", "from.at.moment", "systems", "section-window",
                    "A new graphic", "Envelopes", "The legend", "Not every marked range is a drawing",
                    "skill://lilypond", "(pair? ms)", "(ly:grob? sys)", "(ly:grob-array? cols)"] {
            XCTAssertTrue(text.contains(key), key)
        }
        XCTAssertFalse(text.contains("music_around"), "the clicked-part selection is gone")
        XCTAssertFalse(text.contains("till 7"), "no cue/bar naming for graphics")
    }

    /// The skills describe front-matter.ily as Score Setup writes it.
    func testTheSkillsDescribePondsidesFrontMatter() throws {
        let graphic = try String(contentsOf: skills.appendingPathComponent("graphic-notation/SKILL.md"), encoding: .utf8)
        let lily = try String(contentsOf: skills.appendingPathComponent("lilypond/SKILL.md"), encoding: .utf8)
        var fm = FrontMatter(FrontMatter.template(Set(FrontMatter.Section.allCases)))
        fm = FrontMatter(fm.edits(adding: [.init(id: "wedge", title: "Wedge", text: "x", example: "\\null")]).apply(to: fm.text))
        for written in ["%% legend: wedge", "\\markup \\pondside-legend-item \"Wedge\"", "%% ---- legend", "\\markuplist \\pondside-paragraphs #'("] {
            XCTAssertTrue(fm.text.contains(written), written)
        }
        XCTAssertTrue(graphic.contains("`%% legend: <entry-id>`") && graphic.contains("\\pondside-legend-item") && graphic.contains("`front-matter.ily`"))
        XCTAssertTrue(lily.contains("`%% ---- cover`") && lily.contains("\\pondside-paragraphs #'(") && lily.contains("`front-matter.ily`"))
        XCTAssertEqual(FrontMatter.fileName, "front-matter.ily")
        for (key, _) in FrontMatter.headerFields { XCTAssertTrue(lily.contains("`\(key)`"), key) }
    }

    func testTheSuperColliderSkillDescribesPondsidesCueFile() throws {
        let text = try String(contentsOf: skills.appendingPathComponent("lilypond-supercollider/SKILL.md"), encoding: .utf8)
        XCTAssertTrue(text.contains("`seconds<TAB>bar<TAB>cue N`"))
        let log = TimingLog(rows: [.init(moment: Rational(1, 2), bar: 2, kind: .text("cue 12"))])
        XCTAssertEqual(CueSheet(log: log, score: "s.ly").cuesText, "2.000\t2\tcue 12\n")
        // The patch Pondside starts reads <name>.cues and plays <name>.wav: what the mockup writes.
        XCTAssertTrue(text.contains("`renders/score.cues`"))
        XCTAssertTrue(text.contains(#"`~cue[\cue12] = { |cue| … };`"#))
        let engine = HandlerSync.engine(name: "score")
        XCTAssertTrue(engine.contains(#"e[\renders] +/+ e[\name] ++ ".cues""#) && engine.contains(#"e[\renders] +/+ e[\name] ++ ".wav""#))
        for legacy in ["timing.ily\"", "lily_timing.py ", "export_piece.sh ", "~scoreSync"] {
            XCTAssertFalse(text.contains("`" + legacy), "the skill must not set up a second timing pipeline (\(legacy))")
        }
    }
}

/// The SuperCollider Lexicon's entries load, document every param their
/// code uses, and compile in sclang (skipped without SuperCollider).
final class SCLexiconTests: XCTestCase {
    func testEveryEntryLoadsWithItsParams() throws {
        let lex = SCLexicon.load(project: nil)
        let dir = try XCTUnwrap(SCLexicon.coreDirectory).appendingPathComponent("entries")
        let folders = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".") }
        XCTAssertEqual(Set(lex.ids), Set(folders), "every folder is an entry named by its id")
        XCTAssertGreaterThanOrEqual(lex.ids.count, 14)
        for id in lex.ids {
            let e = try XCTUnwrap(lex.entries[id])
            XCTAssertFalse(e.gloss.isEmpty || e.usage.isEmpty || e.readme.isEmpty, id)
            for r in e.requires { XCTAssertNotNil(lex.entries[r], "\(id) requires \(r)") }
            if e.kind == "effect" {
                XCTAssertTrue(e.impl.hasPrefix("~lxFx[\\\(e.name)] = (defaults: ("), id)
                for p in e.params { XCTAssertTrue(e.impl.contains("\(p.name): \(p.defaultValue)"), "\(id).\(p.name)") }
            }
        }
        XCTAssertEqual(lex.closure(["cloud"]), ["grain", "pitches", "glide", "cloud"])
        XCTAssertEqual(lex.search("echo").first?.hasPrefix("feedback-delay"), true)
        XCTAssertTrue(lex.describe("reverb")?.contains("\\lx_reverb_mono") ?? false)
    }

    func testTheIncludeCompilesInSclang() throws {
        let candidates = ["/Applications/SuperCollider.app/Contents/MacOS/sclang", "/usr/local/bin/sclang", "/usr/bin/sclang"]
        guard let sclang = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw XCTSkip("SuperCollider isn't installed")
        }
        let lex = SCLexicon.load(project: nil)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-sclex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let include = dir.appendingPathComponent("sc-lexicon.scd")
        try lex.includeFile(for: lex.ids).write(to: include, atomically: true, encoding: .utf8)
        let defs = lex.ids.compactMap { lex.entries[$0] }.flatMap { e -> [String] in
            e.kind == "effect" ? ["\\lx_\(e.name)", "\\lx_\(e.name)_mono"] : e.kind == "synth" ? ["\\lx_\(e.name)"] : []
        }
        let script = dir.appendingPathComponent("t.scd")
        try """
        (
        var ok = true;
        try { "\(include.path)".load } { |e| ("PONDSIDE-FAIL load " ++ e.errorString).postln; ok = false };
        [\(defs.joined(separator: ", "))].do { |n| if(SynthDescLib.global[n].isNil) { ("PONDSIDE-FAIL no " ++ n).postln; ok = false } };
        try { ~lx[\\cloud].([0, 3, 7], ~lx[\\glide].(2, 30, 10)).asStream.next(Event.default).isNil.if { ok = false } } { |e| ("PONDSIDE-FAIL cloud " ++ e.errorString).postln; ok = false };
        try { ~lx[\\density].(2, 20, 5).asStream.nextN(3) } { |e| ("PONDSIDE-FAIL density " ++ e.errorString).postln; ok = false };
        (if(ok) { "PONDSIDE-OK" } { "PONDSIDE-FAILED" }).postln;
        0.exit;
        )
        """.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sclang)
        p.arguments = [script.path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let deadline = Date().addingTimeInterval(60)
        var output = Data()
        while p.isRunning, Date() < deadline { output.append(pipe.fileHandleForReading.availableData) }
        if p.isRunning { p.terminate() }
        output.append(pipe.fileHandleForReading.readDataToEndOfFile())
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains("PONDSIDE-OK"), text.split(separator: "\n").filter { $0.contains("PONDSIDE") || $0.contains("ERROR") }.joined(separator: "\n"))
    }
}
