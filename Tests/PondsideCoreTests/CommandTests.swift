import XCTest
@testable import PondsideCore

final class KeyboardAuditTests: XCTestCase {
    /// M3 acceptance: every command reachable from the keyboard, no chord
    /// colliding with or shadowing another, none longer than three keys.
    func testEveryCommandIsReachableAndNoChordsCollide() {
        let problems = Keymap().problems()
        XCTAssertTrue(problems.isEmpty, problems.map(\.description).joined(separator: "\n"))
    }

    func testCommandsHaveTitlesGlossesAndUniqueIDs() {
        let specs = CommandCatalog.standard
        XCTAssertEqual(Set(specs.map(\.id)).count, specs.count)
        for s in specs {
            XCTAssertFalse(s.title.isEmpty, s.id.rawValue)
            XCTAssertFalse(s.gloss.isEmpty, s.id.rawValue)
        }
    }

    func testMostCommandsTakeTwoKeysAfterTheLeader() {
        let chords = CommandCatalog.standard.flatMap(\.chords)
        XCTAssertGreaterThan(chords.filter { $0.keys.count <= 2 }.count, chords.count * 9 / 10)
    }
}

final class KeyStrokeTests: XCTestCase {
    func testParsingAndDisplay() {
        XCTAssertEqual(KeyStroke(parsing: "⌘⇧S"), KeyStroke("s", [.command, .shift]))
        XCTAssertEqual(KeyStroke(parsing: "cmd+shift+s"), KeyStroke("s", [.command, .shift]))
        XCTAssertEqual(KeyStroke(parsing: "ctrl+tab")?.description, "⌃⇥")
        XCTAssertEqual(KeyStroke(parsing: "⌃⇥"), KeyStroke("tab", .control))
        XCTAssertEqual(KeyStroke("k", .command).description, "⌘K")
        XCTAssertEqual(KeyStroke("0", [.command, .option]).description, "⌥⌘0")
        XCTAssertNil(KeyStroke(parsing: "⌘"))
        XCTAssertNil(KeyStroke(parsing: "ctrl+bogus"))
        XCTAssertEqual(Chord("gm").description, "␣ g m")
        XCTAssertEqual(Chord(" ").description, "␣ ␣")
    }
}

final class ChordTests: XCTestCase {
    func testChordsResolveThroughGroups() {
        let keymap = Keymap()
        var r = ChordRecognizer()
        guard case .pending(let top) = r.begin(keymap) else { return XCTFail() }
        XCTAssertTrue(top.contains { $0.key == "g" && $0.label == "go" && $0.command == nil })
        XCTAssertTrue(top.contains { $0.key == "?" && $0.command == "help.context" })
        guard case .pending(let go) = r.feed("g", keymap) else { return XCTFail() }
        XCTAssertTrue(go.contains { $0.key == "e" && $0.label == "Go to Error" })
        XCTAssertEqual(r.feed("e", keymap), .command("go.error"))
        XCTAssertFalse(r.isActive)
    }

    func testUnboundKeysAbandonTheChord() {
        let keymap = Keymap()
        var r = ChordRecognizer()
        _ = r.begin(keymap)
        _ = r.feed("g", keymap)
        XCTAssertEqual(r.feed("z", keymap), .unbound("␣ g z"))
        XCTAssertFalse(r.isActive)
        // Without the leader nothing is a chord.
        XCTAssertEqual(r.feed("g", keymap), .unbound("g"))
    }

    func testRemapping() throws {
        let known = Set(CommandCatalog.standard.map(\.id))
        let text = """
        # mine
        go.error = x, ge   # both
        add.slur = none
        """
        let remap = try Keymap.parseRemap(text, known: known)
        XCTAssertEqual(remap["go.error"], ["x", "ge"])
        XCTAssertEqual(remap["add.slur"], [])
        let keymap = Keymap(remap: remap)
        XCTAssertEqual(keymap.bindings["x"], "go.error")
        XCTAssertNil(keymap.bindings["as"])
        XCTAssertTrue(keymap.problems().isEmpty, "\(keymap.problems())")
        XCTAssertThrowsError(try Keymap.parseRemap("go.nowhere = q", known: known))
        XCTAssertThrowsError(try Keymap.parseRemap("go.error", known: known))
        // Binding a group key to a command shadows the whole group.
        XCTAssertFalse(Keymap(remap: ["go.error": ["g"]]).problems().isEmpty)
    }
}

final class PaletteTests: XCTestCase {
    func testFuzzyMatchPrefersWordStarts() throws {
        let slur = try XCTUnwrap(FuzzyMatch.match("as", in: "Add Slur"))
        XCTAssertEqual(slur.positions, [0, 4])
        let a = try XCTUnwrap(FuzzyMatch.match("fw", in: "Fit Width")).score
        let b = try XCTUnwrap(FuzzyMatch.match("fw", in: "Go to the Following Window")).score
        XCTAssertGreaterThan(a, b)
        XCTAssertNil(FuzzyMatch.match("zz", in: "Add Slur"))
        XCTAssertNil(FuzzyMatch.match("rulsa", in: "Add Slur"))
    }

    func testTwoLettersAndReturnFindTheCommand() {
        let palette = CommandPalette(keymap: Keymap())
        let ctx = CommandContext(hasSelection: true)
        XCTAssertEqual(palette.items(for: "as", in: ctx).first?.spec.id, "add.slur")
        XCTAssertEqual(palette.items(for: "fit", in: ctx).first?.spec.id, "view.fitWidth")
        XCTAssertEqual(palette.items(for: "undo", in: ctx).first?.spec.id, "edit.undo")
        XCTAssertEqual(palette.items(for: "ge", in: CommandContext(hasErrors: true)).first?.spec.id, "go.error")
        XCTAssertEqual(palette.items(for: "", in: ctx).count, CommandCatalog.standard.count)
    }

    func testContextAndRecencyRank() {
        var palette = CommandPalette(keymap: Keymap())
        let none = CommandContext(hasSelection: false)
        let items = palette.items(for: "add", in: none)
        // Without a selection, Add Slur is listed but not available.
        XCTAssertEqual(items.first { $0.spec.id == "add.slur" }?.available, false)
        XCTAssertTrue(palette.items(for: "", in: none, onlyAvailable: true).allSatisfy(\.available))
        let before = palette.items(for: "zoom", in: none).map(\.spec.id)
        palette.noteUsed("view.zoomOut")
        XCTAssertEqual(before.first, "view.zoomIn")
        XCTAssertEqual(palette.items(for: "zoom", in: none).first?.spec.id, "view.zoomOut")
    }
}

final class PaneTests: XCTestCase {
    func testCyclingKeepsGeometryAndNeverDuplicates() {
        var l = PaneLayout(name: "t", contents: [.lilypond, .score], fractions: [0.4, 0.6], focused: 0)
        l.cycle(available: [.score, .lilypond, .supercollider, .terminal])
        XCTAssertEqual(l.contents, [.supercollider, .score])
        l.cycle(available: [.score, .lilypond, .supercollider, .terminal])
        XCTAssertEqual(l.contents, [.terminal, .score])
        l.cycle(available: [.score, .lilypond, .supercollider, .terminal])
        XCTAssertEqual(l.contents, [.lilypond, .score], "skips the score, shown in the other pane")
        l.cycle(forward: false, available: [.score, .lilypond, .supercollider, .terminal])
        XCTAssertEqual(l.contents, [.terminal, .score])
        XCTAssertEqual(l.fractions, [0.4, 0.6])
    }

    func testShowSwapsRatherThanDuplicating() {
        var l = PaneLayout(name: "t", contents: [.lilypond, .score], focused: 0)
        l.show(.supercollider)
        XCTAssertEqual(l.contents, [.supercollider, .score])
        l.show(.score)
        XCTAssertEqual(l.contents, [.score, .supercollider])
        XCTAssertEqual(l.focused, 0)
    }

    func testToggleAddsAPaneAndGivesItsRoomBack() {
        var l = PaneLayout(name: "W", contents: [.lilypond, .score], fractions: [0.4, 0.6], focused: 1)
        l.toggle(.agentLog)
        XCTAssertEqual(l.contents, [.lilypond, .score, .agentLog])
        XCTAssertEqual(l.fractions.reduce(0, +), 1, accuracy: 1e-9)
        XCTAssertEqual(l.fractions[2], 0.3, accuracy: 1e-9)
        XCTAssertEqual(l.focused, 1, "the keyboard stays where it was")
        l.toggle(.agentLog)
        XCTAssertEqual(l.contents, [.lilypond, .score])
        XCTAssertEqual(l.fractions[0], 0.4, accuracy: 1e-9)
        XCTAssertEqual(l.fractions[1], 0.6, accuracy: 1e-9)
        // Closing a pane before the focused one keeps focus on the same content.
        var m = PaneLayout(name: "M", contents: [.agentLog, .score], focused: 1)
        m.toggle(.agentLog)
        XCTAssertEqual(m.contents, [.score])
        XCTAssertEqual(m.focused, 0)
        m.toggle(.score)
        XCTAssertEqual(m.contents, [.score], "the last pane stays")
    }

    func testWorkspacesAndShortcuts() {
        var w = Workspaces()
        w.save(PaneLayout.presets[0], as: "Mine")
        w.save(PaneLayout.presets[1], as: "Mine")
        XCTAssertEqual(w.saved.count, 1)
        XCTAssertEqual(w.saved[0].contents, [.score])
        XCTAssertEqual(Set(PaneContent.allCases.map(\.number)).count, PaneContent.allCases.count)
        XCTAssertEqual(Set(PaneContent.allCases.map(\.chordKey)).count, PaneContent.allCases.count)
    }
}
