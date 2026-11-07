import XCTest
@testable import PondsideCore

/// Pitch collections (DESIGN.md §13): zero time, context-free accidentals,
/// and editing that keeps every other note's pitch and duration.
final class CollectionTests: XCTestCase {
    private func apply(_ edit: ScoreEdit?, to text: String, file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let edit else { XCTFail("no edit", file: file, line: line); return text }
        let result = edit.edits.apply(to: text)
        XCTAssertEqual(SyntaxTree(result).reconstructed, result, file: file, line: line)
        return result
    }

    private func pitches(_ text: String) -> [Pitch] {
        SyntaxTree(text).notes.filter { $0.role == .event }.map(\.absolute)
    }

    private func collectionPitches(_ text: String) -> [[Pitch]] {
        let tree = SyntaxTree(text)
        return tree.collections.map { $0.notes.map { tree.notes[$0].absolute } }
    }

    func testFindsCollectionsAndTheirNotes() {
        let tree = SyntaxTree("music = { c'4 \\collection { e' g' bes' } d'4 }")
        XCTAssertEqual(tree.collections.count, 1)
        let c = tree.collections[0]
        XCTAssertEqual(c.notes.count, 3)
        XCTAssertEqual(tree.string(c.command), "\\collection { e' g' bes' }")
        XCTAssertNotNil(tree.collection(containingEvent: c.events[1]))
        XCTAssertNil(tree.collection(containingEvent: 0))
    }

    func testCollectionTakesNoTimeInAManagedBar() {
        let text = "music = { \\pondsideMeasure \\pondsideBarA { c'4 \\collection { e' g' b' d'' } d'2. } }"
        let tree = SyntaxTree(text)
        let measure = StructuralEditing.measures(in: tree)[0]
        let meter = StructuralEditing.contentMeter(in: tree, measure: measure)
        XCTAssertEqual(meter?.beats, 1)
        XCTAssertEqual(meter?.beatType, 1)
    }

    func testNotesTypedIntoACollectionIgnoreKeyAndDuration() {
        let text = "music = { \\key g \\major c'8 \\collection { e' } d'4 }"
        let tree = SyntaxTree(text)
        let e = tree.collections[0].events[0]
        let result = apply(ScoreEditor(tree).insert(step: 3, after: e, duration: .quarter), to: text)
        XCTAssertTrue(result.contains("\\collection { e' f' }"), result)
        // An armed sharp is written, with no force mark.
        let sharp = apply(ScoreEditor(tree).insert(step: 3, after: e, duration: nil, accidental: 2), to: text)
        XCTAssertTrue(sharp.contains("\\collection { e' fis' }"), sharp)
        XCTAssertNil(ScoreEditor(tree).insert(step: nil, after: e, duration: nil), "no rests in a collection")
    }

    func testACollectionLeavesNoAccidentalForLaterNotes() {
        let text = "music = { c'4 \\collection { fis' } d'4 }"
        let tree = SyntaxTree(text)
        let d = tree.events.indices.last!
        let result = apply(ScoreEditor(tree).insert(step: 3, after: d, duration: nil), to: text)
        XCTAssertTrue(result.hasSuffix("d'4 f' }"), result)
    }

    func testStepAndAccidentalsInACollectionIgnoreTheKey() {
        let text = "music = { \\key g \\major c'4 \\collection { e' f' } d'4 }"
        let tree = SyntaxTree(text)
        let c = tree.collections[0]
        let up = apply(ScoreEditor(tree).move(events: [c.events[0]], by: .step(1)), to: text)
        XCTAssertEqual(collectionPitches(up)[0][0], Pitch(step: 3, alteration: 0, octave: 1))
        let sharp = apply(ScoreEditor(tree).toggleAccidental(2, events: [c.events[1]]), to: text)
        XCTAssertTrue(sharp.contains("\\collection { e' fis' }"), sharp)
        let back = apply(ScoreEditor(SyntaxTree(sharp)).toggleAccidental(2, events: [SyntaxTree(sharp).collections[0].events[1]]), to: sharp)
        XCTAssertTrue(back.contains("\\collection { e' f' }"), back)
    }

    func testInsertCollectionAndItsFirstNote() {
        let text = "music = { c'4 d'4 }"
        let tree = SyntaxTree(text)
        let made = apply(ScoreEditor(tree).insertCollection(after: 0), to: text)
        XCTAssertEqual(made, "music = { c'4 \\collection { } d'4 }")
        let collection = SyntaxTree(made).collections[0]
        // The octave nearest the note before it, as typed notes take it.
        let edit = ScoreEditor(SyntaxTree(made)).insertIntoEmptyCollection(collection, step: 2, accidental: nil)
        let filled = apply(edit, to: made)
        XCTAssertEqual(filled, "music = { c'4 \\collection { e' } d'4 }")
        XCTAssertEqual(edit?.selectionAnchors.count, 1)
    }

    func testInRelativeMusicOtherNotesKeepTheirPitches() {
        let text = "music = \\relative c'' { d4 e4 }"
        let tree = SyntaxTree(text)
        let before = pitches(text)
        let made = apply(ScoreEditor(tree).insertCollection(after: 0), to: text)
        let c = SyntaxTree(made).collections[0]
        let filled = apply(ScoreEditor(SyntaxTree(made)).insertIntoEmptyCollection(c, step: 3, accidental: nil, octave: 0), to: made)
        // f below middle c's octave: f, from d'' needs marks; e keeps e''.
        let after = SyntaxTree(filled)
        XCTAssertEqual(after.collections[0].notes.map { after.notes[$0].absolute }, [Pitch(step: 3, alteration: 0, octave: 0)])
        let outside = after.notes.filter { n in n.role == .event && !after.collections[0].body.contains(n.name.lowerBound) }.map(\.absolute)
        XCTAssertEqual(outside, before)
    }

    func testMovingLaterSplitsASkip() {
        let text = "music = { s4*4 \\collection { c' e' } s4*4 }"
        let tree = SyntaxTree(text)
        let moved = ScoreEditor(tree).shiftCollection(tree.collections[0], by: .quarter, forward: true, copy: false, root: nil)
        let result = apply(moved?.edit, to: text)
        XCTAssertEqual(result, "music = { s4*4 s4 \\collection { c' e' } s4*3 }")
        XCTAssertEqual(moved?.snapped, false)
        // And back.
        let t2 = SyntaxTree(result)
        let back = ScoreEditor(t2).shiftCollection(t2.collections[0], by: .quarter, forward: false, copy: false, root: nil)
        XCTAssertEqual(apply(back?.edit, to: result), "music = { s4*4 s4 \\collection { c' e' } s4*3 }".replacingOccurrences(of: "s4 \\collection { c' e' } s4*3", with: "\\collection { c' e' } s4 s4*3"))
    }

    func testRepeatCopiesByTheInputDurationAndSnapsPastNotes() {
        let text = "music = { c'4 \\collection { e' g' } d'2 e'4 }"
        let tree = SyntaxTree(text)
        let copy = ScoreEditor(tree).shiftCollection(tree.collections[0], by: .quarter, forward: true, copy: true, root: nil)
        // A quarter later is inside d'2: the copy stands after it.
        let result = apply(copy?.edit, to: text)
        XCTAssertEqual(result, "music = { c'4 \\collection { e' g' } d'2 \\collection { e' g' } e'4 }")
        XCTAssertEqual(copy?.snapped, true)
        XCTAssertEqual(SyntaxTree(result).collections.count, 2)
    }

    func testMovingInRelativeMusicKeepsEveryPitch() {
        let text = "music = \\relative c'' { d4 \\collection { f, a } e'4 g4 }"
        let tree = SyntaxTree(text)
        let outsideBefore = [Pitch(step: 1, alteration: 0, octave: 2), Pitch(step: 2, alteration: 0, octave: 2), Pitch(step: 4, alteration: 0, octave: 2)]
        let inside = tree.collections[0].notes.map { tree.notes[$0].absolute }
        let moved = apply(ScoreEditor(tree).shiftCollection(tree.collections[0], by: .quarter, forward: true, copy: false, root: nil)?.edit, to: text)
        let after = SyntaxTree(moved)
        XCTAssertEqual(after.collections[0].notes.map { after.notes[$0].absolute }, inside)
        let outside = after.notes.filter { n in n.role == .event && !after.collections[0].body.contains(n.name.lowerBound) }.map(\.absolute)
        XCTAssertEqual(outside, outsideBefore, moved)
    }

    func testMovingWithinManagedBarsUsesTheSharedTimeline() {
        let root = """
        % pondside-structure v1
        pondsideBarA = { \\time 4/4 s1 }
        pondsideBarB = { \\time 4/4 s1 }
        music = { \\pondsideMeasure \\pondsideBarA { s2 \\collection { c' } } | \\pondsideMeasure \\pondsideBarB { s1*0 } | }
        """
        let tree = SyntaxTree(root)
        // From beat 3 of bar 1, a whole note later: beat 3 of bar 2, whose body is empty (padded).
        let moved = ScoreEditor(tree).shiftCollection(tree.collections[0], by: DurationValue(log: 0), forward: true, copy: false, root: tree)
        let result = apply(moved?.edit, to: root)
        XCTAssertTrue(result.contains("\\pondsideBarA { s2 }"), result)
        XCTAssertTrue(result.contains("\\pondsideBarB { s1*0 s2 \\collection { c' } }"), result)
    }

    func testClipboardRoundTrip() {
        let text = "music = { c'4 \\collection { e' gis' } d'4 }"
        let tree = SyntaxTree(text)
        let clip = ScoreEditor.collectionClipboard(tree.collections[0], in: tree)
        XCTAssertEqual(clip, "\\absolute { \\collection { e' gis' } }")
        let pasted = apply(ScoreEditor(tree).pasteCollection(clip, after: tree.events.indices.last!, step: .quarter, root: nil), to: text)
        XCTAssertEqual(pasted, "music = { c'4 \\collection { e' gis' } d'4 \\collection { e' gis' } }")
    }

    func testStavesFindTheirVoices() {
        let root = """
        flute = { c''4 d'' }
        elec = { s2 }
        \\score { << \\new Staff = "fl" { \\flute } \\new Staff = "el" << \\elec >> >> }
        """
        let voices = CollectionStaves.voices(trees: [SyntaxTree(root)])
        XCTAssertEqual(voices.map(\.name), ["flute", "elec"])
    }

    func testMovingToTheStaffBelowKeepsTheMoment() {
        let root = """
        flute = { c''4 \\collection { e'' g'' } d''4 }
        elec = { s2 }
        \\score { << \\new Staff { \\flute } \\new Staff { \\elec } >> }
        """
        let tree = SyntaxTree(root)
        let move = CollectionStaves.move(collectionAt: tree.collections[0].command.lowerBound, file: 0, direction: 1,
                                         trees: [tree], parse: { _, text in SyntaxTree(text) })
        let result = apply(move.map { ScoreEdit(name: "", edits: $0.edits[0]!, selectionAnchors: []) }, to: root)
        XCTAssertTrue(result.contains("flute = { c''4 d''4 }"), result)
        XCTAssertTrue(result.contains("elec = { s4 \\collection { e'' g'' } s4 }"), result)
    }

    func testInvertAndDeleteAWholeCollection() {
        let text = "music = { c'4 \\collection { c' e' g' } d'4 }"
        let tree = SyntaxTree(text)
        let inverted = apply(ScoreEditor(tree).invert(events: tree.collections[0].events), to: text)
        XCTAssertTrue(inverted.contains("\\collection { g' es' c' }"), inverted)
        let gone = apply(ScoreEditor(tree).deleteCollection(tree.collections[0]), to: text)
        XCTAssertEqual(gone, "music = { c'4 d'4 }")
    }

    func testLensDrawsCollectionNotesStemlessWithTheirOwnAccidentals() {
        let text = "music = { \\key g \\major c'4 \\collection { f' fis' } f'4 }"
        let tree = SyntaxTree(text)
        guard let window = LensScoreBuilder.build(tree: tree, selection: tree.events[0].range) else { return XCTFail("no lens window") }
        XCTAssertTrue(window.xml.contains("<stem>none</stem>"), window.xml)
        // fis in the collection, then f natural after it (G major): the key's sharp is cancelled.
        XCTAssertEqual(window.xml.components(separatedBy: "<accidental>sharp</accidental>").count - 1, 1, window.xml)
        XCTAssertEqual(window.xml.components(separatedBy: "<accidental>natural</accidental>").count - 1, 1, window.xml)
    }
}
