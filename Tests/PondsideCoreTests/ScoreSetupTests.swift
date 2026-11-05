import Foundation
import XCTest
@testable import PondsideCore

final class InstrumentTests: XCTestCase {
    func testNamesMatchTheirInstruments() {
        let cases: [(String, String?)] = [
            ("Flute", "flute"), ("Piccolo", "piccolo"), ("Alto Flute", "alto-flute"), ("Vln I", "violin"),
            ("Violin II", "violin"), ("Vla", "viola"), ("Violoncello", "cello"), ("Vc", "cello"), ("Contrabass", "double-bass"),
            ("English Horn", "english-horn"), ("Horn in F", "horn"), ("Accordion", "accordion"), ("Recorder", "recorder"),
            ("Bass Clarinet", "bass-clarinet"), ("Clarinet in B♭", "clarinet"), ("Alto Saxophone", "alto-sax"),
            ("Electronics", "electronics"), ("Elec.", "electronics"), ("Fl. 2", "flute"), ("Bass", "bass-voice"),
            ("Theremin", nil),
        ]
        for (name, id) in cases {
            XCTAssertEqual(Instrument.matching(name: name)?.id, id, name)
        }
    }

    func testEveryInstrumentSoundsAndClefsAreKnown() {
        let clefs = Set(Instrument.clefs.map(\.name))
        for i in Instrument.catalog {
            if let midi = i.midi { XCTAssert(Instrument.midiSounds.contains(midi), "\(i.id): \(midi)") }
            XCTAssert(clefs.contains(i.clef), "\(i.id): \(i.clef)")
            // Its own name means it, so a staff named from the catalog is read back as the same instrument.
            XCTAssertEqual(Instrument.matching(name: i.name)?.id, i.id, i.name)
        }
        XCTAssertEqual(Instrument.midiSounds.count, 128)
        XCTAssertEqual(Set(Instrument.catalog.map(\.id)).count, Instrument.catalog.count)
    }
}

final class StaffSetupTests: XCTestCase {
    let quartet = """
    violinI = { \\key bf \\major c''1 }
    viola = \\transpose c c { \\clef alto c'1 }
    \\score {
      \\new StaffGroup <<
        \\new Staff \\with { instrumentName = "Vln I" } \\violinI
        \\new Staff \\viola
        \\new Staff = "vc" \\with {
          instrumentName = \\markup \\italic "Cello"
        } \\relative c { \\clef bass c1 }
      >>
    }
    """

    func apply(_ setup: StaffSetup, _ edits: [Int: [TextEdit]]) -> [String] {
        setup.texts.enumerated().map { i, t in (edits[i] ?? []).apply(to: t) }
    }

    func testReadsNamesAndClefs() {
        let setup = StaffSetup(files: [quartet])
        XCTAssertEqual(setup.staves.count, 3)
        XCTAssertEqual(setup.staves[0].instrumentName?.value, "Vln I")
        XCTAssertNil(setup.staves[0].clef)
        XCTAssertEqual(setup.staves[0].instrument?.id, "violin")
        XCTAssertNil(setup.staves[1].instrumentName)
        XCTAssertEqual(setup.staves[1].clef?.value, "alto")
        XCTAssertEqual(setup.staves[2].name, "vc")
        XCTAssertEqual(setup.staves[2].instrumentName?.value, "Cello")
        XCTAssertEqual(setup.staves[2].instrumentName?.editable, false)
        XCTAssertEqual(setup.staves[2].clef?.value, "bass")
    }

    func testInstrumentWritesNamesSoundAndClef() {
        let setup = StaffSetup(files: [quartet])
        let out = apply(setup, setup.edits(staff: 1, .init(instrument: Instrument.named("cello")!)))[0]
        XCTAssert(out.contains(#"\new Staff \with { instrumentName = "Violoncello" shortInstrumentName = "Vc." midiInstrument = "cello" } \viola"#), out)
        // The clef already written in the music is changed where it is.
        XCTAssert(out.contains(#"viola = \transpose c c { \clef bass c'1 }"#), out)
        let again = StaffSetup(files: [out])
        XCTAssertEqual(again.staves[1].instrument?.id, "cello")
        XCTAssertEqual(again.staves[1].clef?.value, "bass")
    }

    func testChangesAStringInPlaceAndAddsToAnExistingWith() {
        let setup = StaffSetup(files: [quartet])
        let out = apply(setup, setup.edits(staff: 0, .init(instrumentName: "Violin I", shortInstrumentName: "Vln. I", clef: "treble_8")))[0]
        XCTAssert(out.contains(#"\with { instrumentName = "Violin I" shortInstrumentName = "Vln. I" \clef "treble_8" } \violinI"#), out)
    }

    func testMultilineWithGetsNewLinesAndMarkupIsReplacedOnlyWhenAsked() {
        let setup = StaffSetup(files: [quartet])
        let out = apply(setup, setup.edits(staff: 2, .init(midiInstrument: "cello")))[0]
        XCTAssert(out.contains("    instrumentName = \\markup \\italic \"Cello\"\n      midiInstrument = \"cello\"\n    }"), out)
        let renamed = apply(setup, setup.edits(staff: 2, .init(instrumentName: "Vc.")))[0]
        XCTAssert(renamed.contains(#"instrumentName = "Vc.""#), renamed)
    }

    func testEmptyRemovesAndTrebleIsNotWrittenByDefault() {
        let setup = StaffSetup(files: [quartet])
        let out = apply(setup, setup.edits(staff: 0, .init(instrumentName: "", clef: "treble")))[0]
        XCTAssert(out.contains(#"\new Staff \with { } \violinI"#), out)
        XCTAssertFalse(out.contains("\\clef treble"), out)
    }

    func testFollowsVariablesAcrossFilesAndSetStatements() {
        let root = """
        \\include "parts.ily"
        \\score { << \\new Staff = "up" \\upper \\new Staff \\lower >> }
        """
        let parts = """
        global = { \\key d \\minor \\time 4/4 }
        upper = \\relative c'' { \\global \\set Staff.instrumentName = "Fl." \\clef treble c4 d }
        lower = \\relative c { \\global c4 \\clef bass d }
        """
        let setup = StaffSetup(files: [root, parts])
        XCTAssertEqual(setup.staves.count, 2)
        XCTAssertEqual(setup.staves[0].clef?.value, "treble")
        XCTAssertEqual(setup.staves[0].clef?.file, 1)
        XCTAssertEqual(setup.staves[0].instrumentName?.value, "Fl.")
        // A clef after the first note is a clef change, not the staff's clef.
        XCTAssertNil(setup.staves[1].clef)
        let edits = setup.edits(staff: 0, .init(instrumentName: "Flute", clef: "bass"))
        XCTAssertNil(edits[0])
        let out = apply(setup, edits)
        XCTAssert(out[1].contains(#"\set Staff.instrumentName = "Flute" \clef bass c4"#), out[1])
        let lower = apply(setup, setup.edits(staff: 1, .init(clef: "bass")))
        XCTAssert(lower[0].contains(#"\new Staff \with { \clef bass } \lower"#), lower[0])
    }

    func testEditsKeepTheRestOfTheFileByteForByte() {
        let setup = StaffSetup(files: [quartet])
        for i in setup.staves.indices {
            let edits = setup.edits(staff: i, .init(instrument: Instrument.named("flute")!))[0] ?? []
            XCTAssert(edits.isNonOverlapping)
            let bytes = Array(quartet.utf8)
            let out = edits.apply(to: bytes)
            XCTAssertEqual(edits.inverse(original: bytes).apply(to: out), bytes)
            XCTAssertEqual(SyntaxTree(String(decoding: out, as: UTF8.self)).reconstructed, String(decoding: out, as: UTF8.self))
        }
    }
}

final class FrontMatterTests: XCTestCase {
    func testTemplateHasItsSectionsInOrder() {
        let fm = FrontMatter(FrontMatter.template([.legend, .cover]))
        XCTAssertEqual(fm.sections, [.cover, .legend])
        XCTAssertLessThan(fm.range(of: .cover)!.lowerBound, fm.range(of: .legend)!.lowerBound)
        XCTAssertEqual(fm.heading(.legend)?.value, "Legend")
        XCTAssertNil(fm.paragraphs)
    }

    func testSectionsAreAddedInPlaceAndRemoved() {
        var fm = FrontMatter(FrontMatter.template([.cover, .legend]))
        fm = FrontMatter(fm.edits(section: .notes, enabled: true).apply(to: fm.text))
        XCTAssertEqual(fm.sections, [.cover, .notes, .legend])
        XCTAssertLessThan(fm.range(of: .notes)!.lowerBound, fm.range(of: .legend)!.lowerBound)
        XCTAssertGreaterThan(fm.range(of: .notes)!.lowerBound, fm.range(of: .cover)!.lowerBound)
        fm = FrontMatter(fm.edits(section: .cover, enabled: false).apply(to: fm.text))
        XCTAssertEqual(fm.sections, [.notes, .legend])
        XCTAssertEqual(FrontMatter(fm.edits(section: .notes, enabled: false).apply(to: fm.text)).sections, [.legend])
    }

    func testParagraphsRoundTrip() {
        var fm = FrontMatter(FrontMatter.template([.notes]))
        XCTAssertEqual(fm.paragraphs?.values, [])
        let paragraphs = ["Play without pause.", "Quotes \"like this\" and a back\\slash."]
        fm = FrontMatter(fm.edits(paragraphs: paragraphs).apply(to: fm.text))
        XCTAssertEqual(fm.paragraphs?.values, paragraphs)
        fm = FrontMatter(fm.edits(heading: .notes, to: "Programme Note").apply(to: fm.text))
        XCTAssertEqual(fm.heading(.notes)?.value, "Programme Note")
        XCTAssertEqual(fm.paragraphs?.values, paragraphs)
    }

    func testLegendItems() {
        var fm = FrontMatter(FrontMatter.template([.cover]))
        let item = FrontMatter.NewLegendItem(id: "grain-cloud", title: "Grain cloud", text: "Grainy texture",
                                             example: FrontMatter.example(graphic: "grain-cloud"))
        fm = FrontMatter(fm.edits(adding: [item]).apply(to: fm.text))
        XCTAssertEqual(fm.sections, [.cover, .legend])
        fm = FrontMatter(fm.edits(adding: [.init(id: "slap", title: "Slap tongue", text: "x", example: "\\null")]).apply(to: fm.text))
        XCTAssertEqual(fm.legendItems.map(\.id), ["grain-cloud", "slap"])
        XCTAssertEqual(fm.legendItems[0].title?.value, "Grain cloud")
        XCTAssertEqual(fm.legendItems[1].text?.value, "x")
        fm = FrontMatter(fm.edits(legend: "slap", text: "Slap the reed").apply(to: fm.text))
        XCTAssertEqual(fm.legendItems[1].text?.value, "Slap the reed")
        fm = FrontMatter(fm.edits(removingLegend: "grain-cloud").apply(to: fm.text))
        XCTAssertEqual(fm.legendItems.map(\.id), ["slap"])
        XCTAssertTrue(fm.text.contains("\\pondside-heading \"Legend\""))
    }

    /// A file written before the legend could be arranged: its old
    /// definitions, rows spaced by `\vspace` lines.
    private var legacyLegend: FrontMatter {
        let old = "#(define-markup-command (pondside-heading layout props text) (string?)\n   (old \"heading\"))\n\n"
            + "% A legend row\n#(define-markup-command (pondside-legend-item layout props title text example) (string? string? markup?)\n   (old (row)))"
        var fm = FrontMatter(FrontMatter.template([.legend]).replacingOccurrences(of: FrontMatter.legendDefinitions, with: old))
        let items = ["wind", "slap"].map { FrontMatter.NewLegendItem(id: $0, title: $0, text: "x", example: FrontMatter.example(music: "c'1")) }
        fm = FrontMatter(fm.edits(adding: items).apply(to: fm.text))
        XCTAssertTrue(fm.text.contains("\\markup \\vspace #1"))
        return fm
    }

    func testArrangingALegendUpgradesItsFile() {
        var fm = legacyLegend
        XCTAssertNil(fm.legendLayout)
        XCTAssertFalse(fm.upgradeEdits.isEmpty)
        var layout = FrontMatter.LegendLayout()
        layout.x = 12.5
        layout.rowGap = 3
        let edits = fm.edits(legendLayout: layout)
        XCTAssertTrue(edits.isNonOverlapping)
        fm = FrontMatter(edits.apply(to: fm.text))
        XCTAssertEqual(fm.legendLayout, layout)
        XCTAssertTrue(fm.text.contains("pondside-legend-get"))
        XCTAssertFalse(fm.text.contains("(old"), fm.text)
        XCTAssertFalse(fm.text.contains("\\vspace #1"), fm.text)
        XCTAssertTrue(fm.text.contains("  \\paper {\n    bookTitleMarkup = ##f\n    pondside-legend = #'((x . 12.5) (top . 0)"), fm.text)
        XCTAssertTrue(fm.upgradeEdits.isEmpty)
        XCTAssertEqual(fm.legendItems.map(\.id), ["wind", "slap"])
        // A second write changes only the numbers.
        layout.text = 80
        let again = fm.edits(legendLayout: layout)
        XCTAssertEqual(again.count, 1)
        fm = FrontMatter(again.apply(to: fm.text))
        XCTAssertEqual(fm.legendLayout?.text, 80)
        // It stays one quote: a doubled #'#'( broke the score's engraving.
        XCTAssertFalse(fm.text.contains("#'#'"), fm.text)
        XCTAssertEqual(fm.text.components(separatedBy: "pondside-legend = #'((x . 12.5)").count, 2, fm.text)
        // A file an older writer left doubled is repaired by the next write.
        fm = FrontMatter(fm.text.replacingOccurrences(of: "pondside-legend = #'(", with: "pondside-legend = #'#'("))
        XCTAssertEqual(fm.legendLayout?.text, 80)
        layout.text = 70
        fm = FrontMatter(fm.edits(legendLayout: layout).apply(to: fm.text))
        XCTAssertFalse(fm.text.contains("#'#'"), fm.text)
        XCTAssertEqual(fm.legendLayout?.text, 70)
        // New rows need no spacer now.
        fm = FrontMatter(fm.edits(adding: [.init(id: "air", title: "Air", text: "y", example: "\\null")]).apply(to: fm.text))
        XCTAssertFalse(fm.text.contains("\\vspace #1"))
    }

    func testExampleCropAndScale() {
        var fm = FrontMatter(FrontMatter.template([.legend]))
        fm = FrontMatter(fm.edits(adding: [.init(id: "wind", title: "Wind", text: "x", example: FrontMatter.example(music: "c'1"))]).apply(to: fm.text))
        XCTAssertEqual(fm.legendItems[0].example, .init())
        XCTAssertTrue(fm.edits(legend: "wind", example: .init()).isEmpty)
        fm = FrontMatter(fm.edits(legend: "wind", example: .init(left: 3.25, right: 0, scale: 1.2)).apply(to: fm.text))
        XCTAssertTrue(fm.text.contains("\\pondside-example #'((left . 3.25) (scale . 1.2)) \\score {"), fm.text)
        XCTAssertEqual(fm.legendItems[0].example, .init(left: 3.25, right: 0, scale: 1.2))
        fm = FrontMatter(fm.edits(legend: "wind", example: .init(left: 0, right: 5, scale: 1)).apply(to: fm.text))
        XCTAssertEqual(fm.legendItems[0].example, .init(left: 0, right: 5, scale: 1))
        XCTAssertEqual(fm.legendItems[0].title?.value, "Wind")
    }

    func testIncludeGoesBeforeTheFirstScore() {
        let root = "\\version \"2.24.0\"\n\\header { title = \"x\" }\nm = { \\score { } }\n\\score {\n  { c'1 }\n}\n"
        let out = [FrontMatter.includeEdit(root: root)!].apply(to: root)
        XCTAssert(out.contains("\\header { title = \"x\" }\nm = { \\score { } }\n\\include \"front-matter.ily\"\n\n\\score {"), out)
        XCTAssertNil(FrontMatter.includeEdit(root: out))
    }

    func testHeaderFields() {
        let root = "\\header {\n  title = \"Pond\"\n  composer = \\markup \\bold \"T\"\n}\n\\score { c'1 }\n"
        let doc = EngravingSettingsDocument(root: root)
        XCTAssertEqual(doc.headerField("title").value, "Pond")
        XCTAssertEqual(doc.headerField("composer").editable, false)
        XCTAssertEqual(doc.headerField("year").value, "")
        let out = doc.edits(headerField: "year", to: "2026").apply(to: root)
        XCTAssert(out.contains("  title = \"Pond\"\n  composer = \\markup \\bold \"T\"\n  year = \"2026\"\n}"), out)
        let renamed = EngravingSettingsDocument(root: out).edits(headerField: "title", to: "Pond \"II\"").apply(to: out)
        XCTAssert(renamed.contains("title = \"Pond \\\"II\\\"\""), renamed)
        let removed = EngravingSettingsDocument(root: out).edits(headerField: "title", to: "").apply(to: out)
        XCTAssertFalse(removed.contains("title"), removed)
    }
}

final class LegendScanTests: XCTestCase {
    let defs = """
    %% ---------------------------------------------------------- wind tone
    % Air in the tone: 1 = all air
    wind =
    #(define-event-function (fraction) (number?)
       #{ ^\\markup \\circle #fraction #})

    % Slap tongue: an accent-shaped head
    slapOn = {
      \\override NoteHead.stencil = #ly:text-interface::print
    }
    slapOff = { \\revert NoteHead.stencil }
    featherOnce = \\once \\override Beam.grow-direction = #RIGHT
    timeField =
    #(define-event-function (text duration) (markup? markup?)
       #{ -\\tweak style #'line \\startTextSpan #})
    playTempo =
    #(define-music-function (bpm) (number?)
       #{ \\once \\omit Score.MetronomeMark \\tempo 4 = #bpm #})
    improvisation =
    #(define-music-function (n music) (index? ly:music?) music)
    global = { \\key c \\major \\time 4/4 }
    startBox = #((fixed-span box) #{ \\startTextSpan #})
    stopBox = \\stopTextSpan
    """

    let flute = """
    flute = {
      \\global
      \\improvisation 1 { d'1 \\wind #1 \\timeField "improvise" "30″" g'1 \\wind #0.75 }
      d''8 \\wind #0.5 r8 \\stopTextSpan
      \\slapOn e'8 d'8 a'8 \\slapOff
      \\featherOnce c''16[ d'' e'' f'']
      \\playTempo 60 c''4 \\playTempo 80 c''4 \\playTempo 100 c''4 \\playTempo 120 c''4 \\playTempo 50 c''4
      \\xNote c''4 \\harmonic
    }
    boxes = { s1\\startBox s1\\stopBox }
    elec = { \\slapOn c'1 \\slapOff \\wind #0.25 }
    """

    let root = """
    \\include "defs.ily"
    \\include "flute.ly"
    \\score { <<
      \\new Staff \\with { instrumentName = "Flute" } << \\flute \\new Voice \\boxes >>
      \\new PianoStaff \\with { instrumentName = "Electronics" } << \\new Staff \\elec >>
    >> }
    """

    func testFindsTheScoresOwnSymbolsInInstrumentalStaves() {
        let found = LegendScan.candidates(files: [root, defs, flute])
        let ids = found.map(\.id)
        XCTAssertEqual(ids, ["improvisation", "wind-1", "timeField", "wind-0.75", "wind-0.5", "slapOn", "featherOnce",
                             "playTempo", "xNote", "harmonic", "startBox"], ids.description)
        // Electronics are the patch's: their \wind #0.25 is not a performer's symbol.
        XCTAssertFalse(ids.contains("wind-0.25"))
        let wind = found.first { $0.id == "wind-0.75" }!
        XCTAssertEqual(wind.title, "Wind 0.75")
        XCTAssertEqual(wind.text, "Air in the tone: 1 = all air")
        XCTAssertEqual(wind.invocation, "\\wind #0.75")
        XCTAssert(wind.example.contains("{ \\cadenzaOn g'1 \\wind #0.75 }"), wind.example)
        let slap = found.first { $0.id == "slapOn" }!
        XCTAssertEqual(slap.title, "Slap")
        XCTAssert(slap.example.contains("\\slapOn e'8 d'8 a'8 \\slapOff"), slap.example)
        XCTAssert(found.first { $0.id == "timeField" }!.example.contains("d'1 \\timeField \"improvise\" \"30″\" g'1 d''8\\stopTextSpan"))
        XCTAssert(found.first { $0.id == "featherOnce" }!.example.contains("\\featherOnce c''16[ d''16 e''16]"))
        // Five tempos are a parameter, not five symbols; and it prints nothing.
        let tempo = found.first { $0.id == "playTempo" }!
        XCTAssertEqual(tempo.uses, 5)
        XCTAssertFalse(tempo.printed)
        XCTAssertTrue(found.first { $0.id == "wind-1" }!.printed)
        // A Scheme-built spanner leans on the score's machinery: its notation is left for the user to try.
        XCTAssert(found.first { $0.id == "startBox" }!.example.hasPrefix("\\null %"))
    }

    func testPredicates() {
        XCTAssertEqual(Definitions.predicates("(define-event-function (text duration) (markup? markup?) #{ #})"), ["markup?", "markup?"])
        XCTAssertEqual(Definitions.predicates("(define-music-function (n music)\n (index? ly:music?) music)"), ["index?", "ly:music?"])
        XCTAssertEqual(Definitions.predicates("(define-music-function (a b) ((number? 1) string?) x)"), ["number?", "string?"])
    }
}

final class PerformanceFrontMatterTests: XCTestCase {
    func testDownloadLinkCanBeHiddenWithoutLosingAddress() {
        let original = FrontMatter(FrontMatter.template([.cover]))
        let url = "https://github.com/owner/piece/releases/latest/download/Piece.zip"
        let shown = FrontMatter(original.edits(performanceDownload: url, enabled: true).apply(to: original.text))
        XCTAssertEqual(shown.performanceDownload, url)
        XCTAssertTrue(shown.printsPerformanceDownload)
        let hidden = FrontMatter(shown.edits(performanceDownload: url, enabled: false).apply(to: shown.text))
        XCTAssertEqual(hidden.performanceDownload, url)
        XCTAssertFalse(hidden.printsPerformanceDownload)
        XCTAssertEqual(FrontMatter(hidden.edits(performanceDownload: url, enabled: true).apply(to: hidden.text)).text, shown.text)
        XCTAssertTrue(shown.edits(performanceDownload: url, enabled: true).isEmpty)
    }
    func testDownloadLinkRejectsSourceInjection() {
        let original = FrontMatter(FrontMatter.template([.cover]))
        for address in ["file:///tmp/app", "https://github.com/o/r\ncode", "https://github.com/o/\"r", "https://github.com/o/\\r"] {
            XCTAssertTrue(original.edits(performanceDownload: address, enabled: true).isEmpty)
        }
    }
}
