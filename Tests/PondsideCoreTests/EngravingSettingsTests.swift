import XCTest
@testable import PondsideCore

final class EngravingSettingsTests: XCTestCase {
    private func setting(_ id: String) -> EngravingSetting { EngravingSetting.named(id)! }

    private func change(_ text: String, _ id: String, _ value: EngravingValue,
                        others: [(file: String, text: String)] = []) -> String {
        EngravingSettingsDocument(root: text, others: others).edits(setting: setting(id), to: value).apply(to: text)
    }

    private let score = """
    \\version "2.24.0"
    \\header {
      title = "T"
    }
    \\paper {
      #(set-paper-size "a4landscape")
      left-margin = 30\\mm % room for names
      system-system-spacing = #'((basic-distance . 14) (padding . 2))
    }
    \\score {
      \\new Staff { c'4 }
      \\layout {
        \\context {
          \\Score
          \\omit TimeSignature
          measureBarType = #"'"
        }
      }
    }

    """

    func testReadsWhatTheScoreSays() {
        let doc = EngravingSettingsDocument(root: score)
        XCTAssertEqual(doc.value(of: setting("paper.size")).value, .choice("a4landscape"))
        XCTAssertEqual(doc.value(of: setting("paper.left")).value, .number(30))
        XCTAssertEqual(doc.value(of: setting("paper.right")).value, .number(15))
        XCTAssertEqual(doc.value(of: setting("paper.systemDistance")).value, .number(14))
        // Set in the Score context, which reaches every staff.
        XCTAssertEqual(doc.value(of: setting("staff.showTimeSignatures")).value, .bool(false))
        XCTAssertEqual(doc.value(of: setting("score.barLines")).value, .choice("'"))
        XCTAssertEqual(doc.value(of: setting("score.autoBeaming")).value, .bool(true))
        XCTAssertFalse(doc.value(of: setting("score.autoBeaming")).inRoot)
        XCTAssertEqual(doc.value(of: setting("header.tagline")).value, .bool(true))
    }

    func testChangesAreMinimal() {
        // A value in place, the comment kept.
        XCTAssertEqual(change(score, "paper.left", .number(20)),
                       score.replacingFirst("left-margin = 30\\mm", with: "left-margin = 20\\mm"))
        // A new line at the end of its block, indented like its neighbours.
        XCTAssertEqual(change(score, "score.autoBeaming", .bool(false)),
                       score.replacingFirst("measureBarType = #\"'\"\n", with: "measureBarType = #\"'\"\n      autoBeaming = ##f\n"))
        // Back to the default: the line (and its comment) goes.
        XCTAssertEqual(change(score, "paper.left", .number(15)), score.replacingFirst("  left-margin = 30\\mm % room for names\n", with: ""))
        XCTAssertEqual(change(score, "staff.showTimeSignatures", .bool(true)),
                       score.replacingFirst("      \\omit TimeSignature\n", with: ""))
        // A user's alist is never rewritten; a later key outvotes it.
        XCTAssertEqual(change(score, "paper.systemDistance", .number(20)),
                       score.replacingFirst("(padding . 2))\n", with: "(padding . 2))\n  system-system-spacing.basic-distance = #20\n"))
    }

    func testMissingBlocksAreAddedWhereLilyPondReadsThem() {
        let bare = "\\version \"2.24.0\"\nmusic = { c'4 }\n\\score {\n  \\music\n}\n"
        let tagline = change(bare, "header.tagline", .bool(false))
        XCTAssertEqual(tagline, "\\version \"2.24.0\"\nmusic = { c'4 }\n\\header {\n  tagline = ##f\n}\n\n\\score {\n  \\music\n}\n")
        let beaming = change(bare, "score.autoBeaming", .bool(false))
        XCTAssertEqual(beaming, "\\version \"2.24.0\"\nmusic = { c'4 }\n\\score {\n  \\music\n  \\layout {\n    \\context {\n      \\Score\n      autoBeaming = ##f\n    }\n  }\n}\n")
        // And read back.
        XCTAssertEqual(EngravingSettingsDocument(root: beaming).value(of: setting("score.autoBeaming")).value, .bool(false))
        let size = change(beaming, "layout.staffSize", .number(18))
        XCTAssertTrue(size.contains("  \\layout {\n    \\context {\n      \\Score\n      autoBeaming = ##f\n    }\n    #(layout-set-staff-size 18)\n  }"), size)
    }

    func testCollectionDisplayIsWrittenAndReadBack() {
        let bare = "\\version \"2.24.0\"\nmusic = { c'4 }\n\\score {\n  \\music\n}\n"
        let hollow = change(bare, "score.collectionHeads", .choice("hollow"))
        XCTAssertTrue(hollow.contains("\\override NoteHead.details.collection-heads = #'hollow"), hollow)
        let doc = EngravingSettingsDocument(root: hollow)
        XCTAssertEqual(doc.value(of: setting("score.collectionHeads")).value, .choice("hollow"))
        XCTAssertEqual(doc.value(of: setting("score.collectionLayout")).value, .choice("row"))
        let both = change(hollow, "score.collectionEnclosure", .choice("brackets"))
        XCTAssertEqual(EngravingSettingsDocument(root: both).value(of: setting("score.collectionEnclosure")).value, .choice("brackets"))
        XCTAssertEqual(EngravingSettingsDocument(root: both).value(of: setting("score.collectionHeads")).value, .choice("hollow"))
        let gap = change(both, "score.collectionGap", .number(1.5))
        XCTAssertEqual(EngravingSettingsDocument(root: gap).value(of: setting("score.collectionGap")).value, .number(1.5))
        // Back to the default removes the line.
        XCTAssertFalse(change(gap, "score.collectionHeads", .choice("filled")).contains("collection-heads"))
    }

    func testAnotherFileIsReportedAndOutvoted() {
        let part = (file: "flute.ly", text: "\\layout {\n  \\context {\n    \\Score\n    autoBeaming = ##f\n  }\n}\n")
        let doc = EngravingSettingsDocument(root: score, others: [part])
        let found = doc.value(of: setting("score.autoBeaming"))
        XCTAssertEqual(found.value, .bool(false))
        XCTAssertEqual(found.elsewhere.map(\.line), [4])
        // Turning it back on must be said out loud in the root.
        XCTAssertTrue(change(score, "score.autoBeaming", .bool(true), others: [part]).contains("      autoBeaming = ##t\n"))
    }

    func testSeveralChangesAreOneEdit() {
        let doc = EngravingSettingsDocument(root: score)
        let edits = doc.edits(for: [(setting("paper.left"), .number(25)), (setting("header.tagline"), .bool(false))])
        XCTAssertEqual(edits.count, 1)
        let out = edits.apply(to: score)
        XCTAssertTrue(out.contains("left-margin = 25\\mm"))
        XCTAssertTrue(out.contains("  title = \"T\"\n  tagline = ##f\n}"), out)
    }

    func testConvertedScoresAreRecognised() {
        let flute = "%% converted by musicxml2ly\n\\pointAndClickOff\n\\layout {\n  \\context {\n    \\Score\n    autoBeaming = ##f\n  }\n}\nflute = { c'4 }\n"
        let findings = ConvertedScoreCheck.findings(in: [("score.ly", score), ("flute.ly", flute)])
        // \pointAndClickOff is left alone: the canvas compile neutralizes it.
        XCTAssertEqual(findings.map(\.line), [6])
        XCTAssertEqual(findings.map(\.setting), ["score.autoBeaming"])
        // A hand-written score with the same setting is left alone.
        XCTAssertTrue(ConvertedScoreCheck.findings(in: [("mine.ly", "\\layout { autoBeaming = ##f }")]).isEmpty)
    }

    func testEveryNonDefaultReadsBack() {
        // Each setting's statement parses to the value it was written for.
        for s in EngravingSetting.all {
            let other: EngravingValue
            switch s.kind {
            case .toggle: other = .bool(!(s.defaultValue.bool ?? true))
            case let .choice(choices): other = .choice(choices.first { .choice($0.value) != s.defaultValue }!.value)
            case let .number(_, range, _): other = .number(range.lowerBound + 1)
            }
            let out = change(score, s.id, other)
            XCTAssertEqual(EngravingSettingsDocument(root: out).value(of: s).value, other, s.id)
        }
    }
}

private extension String {
    func replacingFirst(_ target: String, with replacement: String) -> String {
        guard let r = firstRange(of: target) else { return self }
        return String(self[..<r.lowerBound]) + replacement + String(self[r.upperBound...])
    }
}
