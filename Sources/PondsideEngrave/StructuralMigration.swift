import Foundation
import PondsideCore

/// An explicit, cancellable analysis of temporary source copies. Normal canvas
/// engraving never performs migration or supplies its timing evidence.
public enum StructuralMigration {
    public enum Stage: String, Sendable {
        case checking = "Checking LilyPond source…"
        case measuring = "Measuring functions and score structure…"
        case planning = "Building the shared timeline…"
        case validating = "Checking the migrated score…"
        case ready = "Migration is ready"
    }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public var stage: Stage
        public var message: String
        public var log: String
        public var description: String { message + (log.isEmpty ? "" : "\n\n" + log) }
        public init(stage: Stage, message: String, log: String = "") { self.stage = stage; self.message = message; self.log = log }
    }

    public struct Plan: Sendable {
        public var changes: [StructuralEditing.Change]
        public var expected: [String: String]
    }

    /// Every call evaluates the original, a provenance-instrumented copy, and
    /// the candidate independently. The caller owns saving and its undo action.
    public static func plan(files: [StructuralEditing.File], root: String, installation: LilyPondInstallation,
                            repairs: [(EngravingSetting, EngravingValue)] = [], progress: @Sendable (Stage) -> Void = { _ in }) async throws -> Plan {
        guard !files.isEmpty, files.contains(where: { $0.id == root }) else {
            throw Failure(stage: .checking, message: "The root score is not loaded.")
        }
        let stage = try Workspace(files: files, root: root)
        defer { stage.remove() }
        progress(.checking)
        let baseline = try await stage.evaluate(files, installation: installation, phase: .checking)
        try Task.checkCancellation()
        progress(.measuring)
        let normalized = try StructuralEditing.prepareForInterpretation(files)
        let regions = try StructuralEditing.regionsForInterpretation(normalized)
        guard !regions.isEmpty else { throw Failure(stage: .measuring, message: "No editable music streams were found. Open the score's root file and check its includes.") }
        let probed = normalized.map { file -> StructuralEditing.File in
            var copy = file
            let inserts = regions.filter { $0.file == file.id }.flatMap { region in
                [TextEdit.insert(" \\pondsideMigrationProbe \"\(region.id)\" \(region.layout ? "##t" : "##f") { ", at: region.range.lowerBound),
                 TextEdit.insert(" } ", at: region.range.upperBound)]
            }
            copy.tree = copy.parse(inserts.apply(to: file.tree.text))
            return copy
        }
        let measured = try await stage.evaluate(probed, installation: installation, phase: .measuring)
        guard baseline.fingerprint == measured.fingerprint else {
            throw Failure(stage: .measuring, message: "LilyPond could not measure this score without changing its interpretation. A function may depend on its enclosing source structure. The original files were left untouched.")
        }
        let observations = try observations(regions: regions, rows: measured.rows)
        try Task.checkCancellation()
        progress(.planning)
        let proposed: [StructuralEditing.Change]
        do { proposed = try StructuralEditing.migrate(normalized, root: root, sharedBreaks: true, observations: observations) }
        catch { throw Failure(stage: .planning, message: String(describing: error)) }
        var candidate = normalized.map { file -> StructuralEditing.File in
            var copy = file
            copy.tree = copy.parse(proposed.filter { $0.file == file.id }.flatMap(\.edits).apply(to: file.tree.text))
            return copy
        }
        if !repairs.isEmpty, let i = candidate.firstIndex(where: { $0.id == root }) {
            let others = candidate.filter { $0.id != root }.map { (file: $0.id, text: $0.tree.text) }
            let settings = EngravingSettingsDocument(root: candidate[i].tree.text, others: others)
            candidate[i].tree = candidate[i].parse(settings.edits(for: repairs).apply(to: candidate[i].tree.text))
        }
        progress(.validating)
        let validated = try await stage.evaluate(candidate, installation: installation, phase: .validating)
        guard baseline.fingerprint == validated.fingerprint else {
            throw Failure(stage: .validating, message: "The proposed migration changed musical events, timing, or layout boundaries. Nothing was saved. Check for reused passages, conditional music, or functions whose behavior depends on their surrounding structure.", log: comparison(baseline.fingerprint, validated.fingerprint))
        }
        try Task.checkCancellation()
        let changes = files.compactMap { original -> StructuralEditing.Change? in
            let text = candidate.first { $0.id == original.id }!.tree.text
            return difference(file: original.id, before: original.tree.text, after: text)
        }
        progress(.ready)
        return Plan(changes: changes, expected: Dictionary(uniqueKeysWithValues: files.map { ($0.id, $0.tree.text) }))
    }

    /// Used for a meter edit in an already evaluated contract. A temporary
    /// compile checks generated content against the new shared lengths.
    public static func validate(files: [StructuralEditing.File], root: String, installation: LilyPondInstallation) async throws {
        let stage = try Workspace(files: files, root: root)
        defer { stage.remove() }
        _ = try await stage.evaluate(files, installation: installation, phase: .validating)
    }

    private static func difference(file: String, before: String, after: String) -> StructuralEditing.Change? {
        guard let diff = TextDiff.minimalReplacement(from: before, to: after) else { return nil }
        let lo = OffsetConversion.utf8(fromUTF16: diff.location, in: before)
        let hi = OffsetConversion.utf8(fromUTF16: diff.location + diff.length, in: before)
        return .init(file: file, edits: [TextEdit(lo..<hi, diff.replacement)])
    }

    fileprivate struct Output {
        var rows: [[String]]
        var fingerprint: [String]
    }

    private static func comparison(_ before: [String], _ after: [String]) -> String {
        var removed = before
        var added: [String] = []
        for event in after {
            if let index = removed.firstIndex(of: event) { removed.remove(at: index) }
            else { added.append(event) }
        }
        return (["Original events missing after migration:"] + removed.prefix(12)
            + ["New events after migration:"] + added.prefix(12)).joined(separator: "\n")
    }

    struct Workspace {
        let directory: URL
        let destinations: [String: URL]
        let originals: [StructuralEditing.File]
        let root: String

        init(files: [StructuralEditing.File], root: String) throws {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-migration-\(UUID().uuidString)", isDirectory: true)
            let base = URL(fileURLWithPath: root).deletingLastPathComponent().path + "/"
            var destinations: [String: URL] = [:]
            for file in files {
                let relative = file.id.hasPrefix(base) ? String(file.id.dropFirst(base.count)) : "external/\(ContentHash(file.id))/\(URL(fileURLWithPath: file.id).lastPathComponent)"
                destinations[file.id] = directory.appendingPathComponent("sources").appendingPathComponent(relative)
            }
            self.directory = directory; self.destinations = destinations; self.originals = files; self.root = root
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }

        func rebase(_ text: String) -> String {
            destinations.reduce(text) { $0.replacingOccurrences(of: $1.value.path, with: $1.key) }
        }

        /// Writes `files` to their staged paths, includes pointing at the
        /// staged copies. `rootText` replaces the root's text when given.
        func write(_ files: [StructuralEditing.File], rootText: String? = nil) throws {
            for file in files {
                guard let destination = destinations[file.id] else { continue }
                let tree = file.id == root ? rootText.map { file.parse($0) } ?? file.tree : file.tree
                var edits: [TextEdit] = []
                for include in tree.includes {
                    let resolved = SourceGraph.resolve(include.path, from: URL(fileURLWithPath: file.id), root: URL(fileURLWithPath: root), exists: { url in destinations[url.path] != nil || FileManager.default.fileExists(atPath: url.path) })
                    if let resolved, let target = destinations[resolved.path] {
                        let path = target.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                        edits.append(TextEdit(include.range, "\"\(path)\""))
                    }
                }
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(edits.apply(to: tree.text).utf8).write(to: destination, options: .atomic)
            }
        }

        fileprivate func evaluate(_ files: [StructuralEditing.File], installation: LilyPondInstallation, phase: Stage) async throws -> Output {
            try Task.checkCancellation()
            try write(files)
            let settingsURL = directory.appendingPathComponent("analysis.ily")
            try Data(settings.utf8).write(to: settingsURL)
            let output = try await ProcessRunner.run(installation.executable,
                ["-dinclude-settings=\(settingsURL.path)", "-dno-print-pages", "-I", URL(fileURLWithPath: root).deletingLastPathComponent().path,
                 "-o", directory.appendingPathComponent("analysis").path, destinations[root]!.path],
                currentDirectory: destinations[root]!.deletingLastPathComponent().path)
            try Task.checkCancellation()
            let log = rebase(output.stderrString)
            let lower = log.lowercased()
            guard output.status == 0, !lower.contains("barcheck failed"), !lower.contains("bar check failed"),
                  !lower.contains("programming error:"), !lower.contains("error:") else {
                let label: String
                switch phase {
                case .validating: label = "LilyPond rejected the proposed migration. The original files were left untouched."
                case .measuring: label = "The source passed LilyPond's initial check, but its structure could not be measured safely. Nothing was saved. Inspect the reported function or passage before retrying migration."
                default: label = "LilyPond could not interpret the score for migration. Fix the reported source error, then run File → Make Score Pondside-Ready… again."
                }
                let issue = DiagnosticParser.parse(log).first {
                    $0.severity != .warning || $0.message.lowercased().contains("bar check failed") || $0.message.lowercased().contains("barcheck failed")
                }
                let detail = issue.map { diagnostic in
                    let location = diagnostic.file.map { file in
                        file + (diagnostic.line.map { ":\($0)" } ?? "") + ": "
                    } ?? ""
                    return "\n\n" + location + diagnostic.message
                } ?? ""
                throw Failure(stage: phase, message: label + detail, log: String(log.suffix(16_000)))
            }
            let rows = output.stdoutString.split(separator: "\n").compactMap { line -> [String]? in
                guard let start = line.range(of: "PONDSIDE-MIGRATION\t") else { return nil }
                return line[start.upperBound...].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            }
            let ordinary = rows.filter { $0.first == "EVENT" }.map { rebase($0.dropFirst().joined(separator: "\t")) }.sorted()
            let structure = Set(rows.filter { $0.first == "GLOBAL" }.map { $0.dropFirst().joined(separator: "\t") }).sorted()
            return Output(rows: rows, fingerprint: ordinary + structure)
        }
    }

    private static func ratio(_ text: String) throws -> StructuralEditing.Ratio {
        let parts = text.split(separator: "/")
        guard parts.count == 1 || parts.count == 2, let n = Int(parts[0]), abs(n) <= 1_000_000_000,
              let d = parts.count == 1 ? 1 : Int(parts[1]), d > 0, d <= 1_000_000_000 else {
            throw Failure(stage: .measuring, message: "LilyPond returned an unsupported musical moment: \(text)")
        }
        return .init(n, d)
    }

    private static func subtract(_ a: StructuralEditing.Ratio, _ b: StructuralEditing.Ratio) -> StructuralEditing.Ratio {
        let numerator = a.numerator * b.denominator - b.numerator * a.denominator
        let denominator = a.denominator * b.denominator
        func gcd(_ lhs: Int, _ rhs: Int) -> Int { var a = abs(lhs), b = abs(rhs); while b != 0 { (a, b) = (b, a % b) }; return max(1, a) }
        let g = gcd(numerator, denominator)
        return .init(numerator / g, denominator / g)
    }

    private static func observations(regions: [StructuralEditing.Region], rows: [[String]]) throws -> [StructuralEditing.Observation] {
        try regions.map { region in
            let data = rows.filter { $0.count > 1 && $0[1] == region.id }
            if let unsupported = data.first(where: { $0.first == "UNSUPPORTED" }) {
                throw Failure(stage: .measuring, message: "\(region.file): \(unsupported.dropFirst(2).joined(separator: " ")). Resolve this structure and rerun migration.")
            }
            func point(_ token: String, _ phase: String) throws -> [String] {
                let found = data.filter { $0.count == 10 && $0[0] == "POINT" && $0[2] == token && $0[4] == phase }
                let unique = Set(found.map { $0.dropFirst(5).joined(separator: "\t") })
                guard let first = found.first, unique.count == 1 else {
                    throw Failure(stage: .measuring, message: "\(region.file): a source passage is unused, repeated at different times, or interpreted differently across score outputs. Give each occurrence an explicit editable measure boundary.")
                }
                return first
            }
            let start = try point("body", "start"), end = try point("body", "end")
            let origin = try ratio(start[5])
            guard start[8] == "1", end[8] == "1" else { throw Failure(stage: .measuring, message: "\(region.file): unmetered context needs explicit timing boundaries before migration.") }
            if !region.layout, start[9] != "0" || end[9] != "0" {
                throw Failure(stage: .measuring, message: "\(region.file): a written measure does not begin and end at LilyPond's measure boundaries. Fix its durations or bar checks, then retry migration.")
            }
            guard let beats = Int(start[6]), let type = Int(start[7]), beats > 0, type > 0 else {
                throw Failure(stage: .measuring, message: "\(region.file): a compound or independent meter needs an explicit shared timeline.")
            }
            let directives = try data.filter { $0.count == 6 && $0[0] == "STRUCT" }.map { row -> StructuralEditing.Directive in
                guard let kind = StructuralEditing.Directive.Kind(rawValue: row[2]) else { throw Failure(stage: .measuring, message: "Unsupported generated structural command.") }
                let time = kind == .meter ? StructuralEditingTime(row[4], row[5]) : nil
                return .init(kind: kind, offset: subtract(try ratio(row[3]), origin), meter: time)
            }
            let declarations = data.filter { $0.count == 5 && $0[0] == "NODE" }
            var nodes: [Int: [String]] = [:]
            for row in declarations {
                if let id = Int(row[2]) {
                    if let old = nodes[id], old != row { throw Failure(stage: .measuring, message: "A music function produced inconsistent structures during analysis.") }
                    nodes[id] = row
                }
            }
            let slots = try (region.layout ? nodes.keys.sorted() : []).compactMap { id -> StructuralEditing.Slot? in
                let row = nodes[id]!
                guard ["SkipEvent", "SkipMusic", "RestEvent", "MultiMeasureRestMusic"].contains(row[3]) else { return nil }
                let first = try point(String(id), "start"), last = try point(String(id), "end")
                return .init(kind: row[3], written: try ratio(row[4]), start: subtract(try ratio(first[5]), origin), end: subtract(try ratio(last[5]), origin))
            }
            return .init(region: region, length: subtract(try ratio(end[5]), origin), meter: .init(beats: beats, beatType: type),
                         directives: directives, slots: slots, hasNotes: nodes.values.contains { $0[3] == "note" })
        }
    }

    private static func StructuralEditingTime(_ numerator: String, _ denominator: String) -> LensTime? {
        guard let n = Int(numerator), let d = Int(denominator), n > 0, d > 0 else { return nil }
        return .init(beats: n, beatType: d)
    }

    private static let settings = #"""
#(define pondside-in-example #f)
#(define pondside-migration-scores '())
#(define (pondside-migration-score-id context)
   (let* ((score (or (ly:context-find context 'Score) context))
          (existing (assq score pondside-migration-scores)))
     (if existing (cdr existing)
         (let ((id (length pondside-migration-scores)))
           (set! pondside-migration-scores (acons score id pondside-migration-scores))
           id))))
#(define (pondside-migration-active?)
   (not (and (defined? 'pondside-in-example) pondside-in-example)))
#(define (pondside-migration-meter context)
   (let ((meter (ly:context-property context 'timeSignature #f)))
     (if (pair? meter) meter (ly:context-property context 'timeSignatureFraction '(4 . 4)))))
#(define (pondside-migration-duration duration)
   (if (ly:duration? duration) (ly:moment-main (ly:duration->moment duration)) #f))
#(define (pondside-migration-point id token kind phase)
   (make-music 'ApplyContext 'procedure
     (lambda (context)
       (if (pondside-migration-active?)
           (let ((meter (pondside-migration-meter context)))
             (format #t "PONDSIDE-MIGRATION\tPOINT\t~a\t~a\t~a\t~a\t~a\t~a\t~a\t~a\t~a\n"
               id token kind phase (ly:moment-main (ly:context-current-moment context))
               (car meter) (cdr meter) (if (ly:context-property context 'timing #t) 1 0)
               (ly:moment-main (ly:context-property context 'measurePosition ZERO-MOMENT))))))))
pondsideMigrationProbe =
#(define-music-function (id layout music) (string? boolean? ly:music?)
   (let ((serial 0))
     (define (wrap m kind)
       (let ((token serial))
         (set! serial (+ serial 1))
         (format #t "PONDSIDE-MIGRATION\tNODE\t~a\t~a\t~a\t~a\n"
           id token kind (ly:moment-main (ly:music-length m)))
         (if layout
             (let ((result (make-sequential-music
                             (list (pondside-migration-point id token kind "start") m
                                   (pondside-migration-point id token kind "end")))))
               (ly:music-set-property! result 'tags (ly:music-property m 'tags))
               result)
             m)))
     (define (structural m kind meter)
       (let ((result (make-sequential-music
         (list (make-music 'ApplyContext 'procedure
                 (lambda (context)
                   (if (pondside-migration-active?)
                       (format #t "PONDSIDE-MIGRATION\tSTRUCT\t~a\t~a\t~a\t~a\t~a\n"
                         id kind (ly:moment-main (ly:context-current-moment context))
                         (if (pair? meter) (car meter) 0) (if (pair? meter) (cdr meter) 0))))) m))))
         (ly:music-set-property! result 'tags (ly:music-property m 'tags))
         result))
     (define (walk m)
       (let ((name (ly:music-property m 'name)) (types (ly:music-property m 'types)))
         (cond
           ((memq 'tremolo-repeated-music types) (wrap m "note"))
           ((memq 'time-signature-music types)
            (structural m "meter" (ly:music-property m 'time-signature (ly:music-property m 'fraction #f))))
           ((ly:music-property m 'page-marker #f) (structural m "page" #f))
           ((memq name '(LineBreakEvent PageBreakEvent))
            (if (not (eq? (ly:music-property m 'break-permission) 'force))
                (format #t "PONDSIDE-MIGRATION\tUNSUPPORTED\t~a\tconditional or forbidden break\n" id))
            (structural m (if (eq? name 'PageBreakEvent) "page" "line") #f))
           ((or (memq 'note-event types)
                (and (eq? name 'EventChord)
                     (any (lambda (child) (memq 'note-event (ly:music-property child 'types)))
                          (ly:music-property m 'elements)))) (wrap m "note"))
           ((eq? name 'EventChord)
            (let ((rhythmic (filter (lambda (child)
                                     (memq (ly:music-property child 'name) '(SkipEvent SkipMusic RestEvent MultiMeasureRestMusic)))
                                   (ly:music-property m 'elements))))
              (cond ((= (length rhythmic) 1) (wrap m (ly:music-property (car rhythmic) 'name)))
                    ((> (length rhythmic) 1)
                     (format #t "PONDSIDE-MIGRATION\tUNSUPPORTED\t~a\tambiguous mixed-duration chord\n" id) m)
                    (else m))))
           ((memq name '(SkipEvent SkipMusic RestEvent MultiMeasureRestMusic)) (wrap m name))
           (else
             (ly:music-set-property! m 'elements (map walk (ly:music-property m 'elements)))
             (let ((element (ly:music-property m 'element)))
               (if (ly:music? element) (ly:music-set-property! m 'element (walk element))))
             (music-map (lambda (item) item) m)))))
     (make-sequential-music
       (list (pondside-migration-point id "body" "body" "start")
             (walk music) (pondside-migration-point id "body" "body" "end")))))
#(define (pondside-migration-event context kind . values)
   (if (pondside-migration-active?)
       (format #t "PONDSIDE-MIGRATION\tEVENT\t~a\t~a\t~a\t~s\n" (pondside-migration-score-id context) kind
         (ly:moment-main (ly:context-current-moment context)) values)))
#(define (pondside-migration-global context kind . values)
   (if (pondside-migration-active?)
       (format #t "PONDSIDE-MIGRATION\tGLOBAL\t~a\t~a\t~a\t~s\n" (pondside-migration-score-id context) kind
         (ly:moment-main (ly:context-current-moment context)) values)))
#(define* (pondside-migration-listener context #:optional (layout #t))
   (make-translator
     (listeners
       ((note-event engraver event)
        (let ((p (ly:event-property event 'pitch)) (d (ly:event-property event 'duration)))
          (pondside-migration-event context "note" (ly:pitch-octave p) (ly:pitch-notename p) (ly:pitch-alteration p) (pondside-migration-duration d))))
       ((rest-event engraver event) (pondside-migration-event context "rest" (pondside-migration-duration (ly:event-property event 'duration))))
       ((multi-measure-rest-event engraver event)
        (let ((d (ly:event-property event 'duration #f)))
          (pondside-migration-event context "multi-rest" (pondside-migration-duration d))))
       ((spacing-section-event engraver event) (pondside-migration-event context "spacing-section"))
       ((absolute-dynamic-event engraver event) (pondside-migration-event context "dynamic" (markup->string (ly:event-property event 'text))))
       ((articulation-event engraver event) (pondside-migration-event context "articulation" (ly:event-property event 'articulation-type)))
       ((text-script-event engraver event) (pondside-migration-event context "text" (markup->string (ly:event-property event 'text)) (ly:event-property event 'cue-label #f)))
       ((text-span-event engraver event) (pondside-migration-event context "text-span" (ly:event-property event 'span-direction)))
       ((trill-span-event engraver event) (pondside-migration-event context "trill-span" (ly:event-property event 'span-direction)))
       ((slur-event engraver event) (pondside-migration-event context "slur" (ly:event-property event 'span-direction)))
       ((crescendo-event engraver event) (pondside-migration-event context "crescendo" (ly:event-property event 'span-direction)))
       ((decrescendo-event engraver event) (pondside-migration-event context "decrescendo" (ly:event-property event 'span-direction)))
       ((note-grouping-event engraver event) (pondside-migration-event context "group" (ly:event-property event 'span-direction)))
       ((tempo-change-event engraver event) (pondside-migration-event context "tempo" (ly:event-property event 'metronome-count) (pondside-migration-duration (ly:event-property event 'tempo-unit))))
       ((line-break-event engraver event)
        (if layout (pondside-migration-global context "line" (ly:event-property event 'break-permission))))
       ((page-break-event engraver event)
        (if layout (pondside-migration-global context "page" (ly:event-property event 'break-permission)))))))
#(define (pondside-migration-score context)
   (let ((last #f))
     (make-translator
       ((stop-translation-timestep engraver)
        (let ((meter (pondside-migration-meter context)))
          (if (not (equal? meter last))
              (begin (set! last meter) (pondside-migration-global context "meter" meter))))))))
\layout {
  \context { \Score \consists #pondside-migration-score }
  \context { \Voice \consists #pondside-migration-listener }
  \context { \Devnull \consists #pondside-migration-listener }
  \context { \DrumVoice \consists #pondside-migration-listener }
  \context { \TabVoice \consists #pondside-migration-listener }
}
\midi {
  \context { \Score \consists #pondside-migration-score }
  \context { \Voice \consists #(lambda (context) (pondside-migration-listener context #f)) }
  \context { \DrumVoice \consists #(lambda (context) (pondside-migration-listener context #f)) }
}
"""#
}
