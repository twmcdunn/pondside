import Foundation
import XCTest
import PondsideCore
import PondsideEngrave

final class MeterProbeTests: XCTestCase {
    private func installation() async throws -> LilyPondInstallation {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let lily = ToolchainDetector.select(from: installs, for: nil) else { throw XCTSkip("LilyPond not installed") }
        return lily
    }

    /// A ready score whose first bar holds a function of four quarters in
    /// the flute and an elastic rest after a zero-length function in the
    /// electronics (the \showStaff case).
    private func readyScore(_ lily: LilyPondInstallation) async throws -> (String, [StructuralEditing.File]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-probe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let root = dir.appendingPathComponent("score.ly")
        let definitions = #"""
        motif = #(define-music-function () () #{ c'4 d' e' f' #})
        reveal = { \stopStaff \startStaff }
        """#
        try Data(("\\version \"2.24.3\"\n" + definitions + "\n\\include \"part.ily\"\n\\score { << \\new Staff \\flute \\new Staff \\elec \\new Devnull \\structure >> }").utf8).write(to: root)
        try Data("flute = { \\motif | c'1 }\nelec = { \\reveal R1 | R1 }\nstructure = { s1 | s1 }".utf8).write(to: dir.appendingPathComponent("part.ily"))
        let graph = SourceGraph.load(root: root)
        var files = graph.files.map { StructuralEditing.File(id: $0.url.path, tree: $0.tree, entryLanguage: $0.entryLanguage) }
        let plan = try await StructuralMigration.plan(files: files, root: root.path, installation: lily)
        files = files.map { file in
            var result = file
            result.tree = result.parse(plan.changes.filter { $0.file == file.id }.flatMap(\.edits).apply(to: file.tree.text))
            return result
        }
        XCTAssertTrue(StructuralEditing.isInterpreted(files.first { $0.id == root.path }!.tree))
        return (root.path, files)
    }

    func testProbeMeasuresFunctionsAndIgnoresElasticRests() async throws {
        let lily = try await installation()
        let (root, files) = try await readyScore(lily)
        let lengths = try await MeterProbe.measure(files: files, root: root, installation: lily)
        let part = files.first { $0.id.hasSuffix("part.ily") }!
        let bars = StructuralEditing.measures(in: part.tree).filter { $0.name == "pondsideBarA" }
        XCTAssertEqual(bars.count, 2)
        let measured = Set(lengths.filter { $0.site.file == part.id }.map(\.length))
        XCTAssertTrue(measured.contains(.init(1)), "the flute's function: four quarters")
        XCTAssertTrue(measured.contains(.init(0)), "the electronics' elastic rest counts as nothing")

        // Shorter than the function's music: statically unknown, probe overflows.
        let short = try StructuralEditing.planMeterChange(.init(beats: 3, beatType: 4), measure: "pondsideBarA",
                                                          files: files, root: root, validatingContract: false)
        XCTAssertFalse(short.unverified.isEmpty)
        XCTAssertTrue(short.knownFits, "nothing visible in source")
        guard case .overflow(let overflow) = StructuralEditing.verify(short, lengths: lengths) else { return XCTFail("3/4 must overflow") }
        XCTAssertEqual(overflow.file, part.id)

        // The legacy entry point still refuses rather than guess.
        XCTAssertThrowsError(try StructuralEditing.changeMeter(.init(beats: 3, beatType: 4), measure: "pondsideBarA",
                                                               files: files, root: root, validatingContract: false))

        // Same length after a longer detour: fits, and the elastic rest follows.
        var longer = files
        let wide = try StructuralEditing.changeMeter(.init(beats: 6, beatType: 4), measure: "pondsideBarA", files: files, root: root, validatingContract: false)
        longer = longer.map { file in
            var result = file
            result.tree = result.parse(wide.filter { $0.file == file.id }.flatMap(\.edits).apply(to: file.tree.text))
            return result
        }
        let back = try StructuralEditing.planMeterChange(.init(beats: 4, beatType: 4), measure: "pondsideBarA",
                                                         files: longer, root: root, validatingContract: false)
        let verdict = await MeterProbe.verify(back, files: longer, root: root, installation: lily)
        guard case .fits = verdict else { return XCTFail("4/4 fits the function's four quarters: \(verdict)") }
    }

    func testMissingRowsAreUnknownNotFits() {
        let plan = StructuralEditing.MeterPlan(changes: [], measure: "pondsideBarA", meter: .init(beats: 2, beatType: 4), previous: nil,
                                               unverified: [.init(file: "a.ly", line: 3, character: 30)], knownFits: true)
        guard case .unknown = StructuralEditing.verify(plan, lengths: []) else { return XCTFail() }
        let elsewhere = [StructuralEditing.ProbedLength(site: .init(file: "a.ly", line: 3, character: 31), length: .init(3, 4))]
        guard case .overflow = StructuralEditing.verify(plan, lengths: elsewhere) else { return XCTFail("one body on the line matches") }
    }
}
