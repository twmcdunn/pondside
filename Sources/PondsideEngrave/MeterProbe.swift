import Foundation
import PondsideCore

/// Measures every shared-bar body as `pondsideMeasure` sees it, without
/// engraving: a parse of temporary copies whose book handlers do nothing,
/// so no score is iterated or laid out (about 0.4 s cold on LilyPond 2.26,
/// against 4 s for the engraving of the same score). Music functions run
/// while LilyPond reads the files, so function-generated bars are measured
/// by the real contract code. Engravers never run, and output goes to a
/// temporary folder, so nothing the score writes while engraving is touched.
/// Its own process: it never waits behind the canvas daemon's engraving.
public enum MeterProbe {
    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var description: String
    }

    static let settings = #"""
#(define (pondside-probe-skip-book book) #f)
toplevel-book-handler = #pondside-probe-skip-book
default-toplevel-book-handler = #pondside-probe-skip-book
toplevel-bookpart-handler = #pondside-probe-skip-book
"""#

    /// Lengths for `files` as given (a snapshot; disk is not read for them).
    public static func measure(files: [StructuralEditing.File], root: String,
                               installation: LilyPondInstallation) async throws -> [StructuralEditing.ProbedLength] {
        guard let rootFile = files.first(where: { $0.id == root }),
              let source = StructuralEditing.lengthProbeSource(rootFile.tree.text) else {
            throw Failure(description: "The shared-measure helper is missing or modified.")
        }
        let stage = try StructuralMigration.Workspace(files: files, root: root)
        defer { stage.remove() }
        try stage.write(files, rootText: source)
        let settingsURL = stage.directory.appendingPathComponent("probe.ily")
        try Data(settings.utf8).write(to: settingsURL)
        let rootDirectory = URL(fileURLWithPath: root).deletingLastPathComponent().path
        // The score's folder, as in a real compile, so Scheme `load` and
        // relative reads resolve; output still goes to the stage.
        let output = try await ProcessRunner.run(installation.executable,
            ["-dinclude-settings=\(settingsURL.path)", "-dno-print-pages", "-I", rootDirectory,
             "-o", stage.directory.appendingPathComponent("probe").path, stage.destinations[root]!.path],
            currentDirectory: rootDirectory)
        try Task.checkCancellation()
        guard output.status == 0 else {
            let log = stage.rebase(output.stderrString)
            let first = DiagnosticParser.parse(log).first { $0.severity != .warning }?.message
            throw Failure(description: first ?? "LilyPond could not read the score.")
        }
        let ids = Dictionary(stage.destinations.map { ($0.value.path, $0.key) }, uniquingKeysWith: { a, _ in a })
        return StructuralEditing.probedLengths(output.stdoutString) { ids[$0] }
    }

    /// Measures the plan's snapshot and judges it; any failure is `.unknown`.
    public static func verify(_ plan: StructuralEditing.MeterPlan, files: [StructuralEditing.File], root: String,
                              installation: LilyPondInstallation?) async -> StructuralEditing.ProbeVerdict {
        guard let installation else { return .unknown }
        do {
            return StructuralEditing.verify(plan, lengths: try await measure(files: files, root: root, installation: installation))
        } catch {
            return .unknown
        }
    }
}
