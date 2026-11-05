extension StructuralEditing {
    /// Where a bar body opens in source: the `{` LilyPond records as the
    /// body's origin. `character` counts characters, not bytes, from 0.
    public struct ProbeSite: Sendable, Hashable {
        public var file: String
        public var line: Int
        public var character: Int
        public init(file: String, line: Int, character: Int) { self.file = file; self.line = line; self.character = character }
    }

    /// A meter edit ready to apply, and the bodies only LilyPond can measure.
    public struct MeterPlan: Sendable {
        public var changes: [Change]
        public var measure: String
        public var meter: LensTime
        public var previous: LensTime?
        /// Function-generated bodies in a bar that gets shorter.
        public var unverified: [ProbeSite]
        /// Their statically visible music fits the new meter.
        public var knownFits: Bool
        /// Every bar the plan sets to `meter`: `measure` alone, or the run
        /// a removed meter change covered.
        public var measures: [String]

        public init(changes: [Change], measure: String, meter: LensTime, previous: LensTime?,
                    unverified: [ProbeSite], knownFits: Bool) {
            self.changes = changes
            self.measure = measure
            self.meter = meter
            self.previous = previous
            self.unverified = unverified
            self.knownFits = knownFits
            self.measures = [measure]
        }
    }

    /// One bar body's length as `pondsideMeasure` sees it, before an elastic
    /// full-bar rest is stretched (such a rest counts as 0, like `contentLength`).
    public struct ProbedLength: Sendable, Hashable {
        public var site: ProbeSite
        public var length: Ratio
        public init(site: ProbeSite, length: Ratio) { self.site = site; self.length = length }
    }

    public enum ProbeVerdict: Sendable {
        case fits
        case overflow(Overflow)
        /// LilyPond reported no length for some body: nothing is proven.
        case unknown
    }

    /// Prefix of the rows the probe source prints, one per evaluated body:
    /// `PONDSIDE-LENGTH\t<file>\t<line>\t<char>\t<whole notes>`.
    public static let probeMarker = "PONDSIDE-LENGTH\t"

    private static let measuredLength = "(actual (ly:music-length music))"
    private static let reportedLength = #"""
(actual (let ((length (ly:music-length music))
                        (origin (ly:music-property music 'origin)))
                    (if (ly:input-location? origin)
                        (let ((where (ly:input-file-line-char-column origin)))
                          (format #t "PONDSIDE-LENGTH\t~a\t~a\t~a\t~a\n" (car where) (cadr where) (caddr where)
                            (if elastic-rest 0 (ly:moment-main length)))))
                    length))
"""#

    /// The root's text with `pondsideMeasure` reporting each body's length,
    /// for a temporary copy only: the saved helper must stay byte-identical.
    /// Nil when the root has no current helper.
    public static func lengthProbeSource(_ text: String) -> String? {
        guard let range = text.firstRange(of: runtime), runtime.contains(measuredLength) else { return nil }
        var result = text
        result.replaceSubrange(range, with: runtime.replacing(measuredLength, with: reportedLength))
        return result
    }

    /// Reads probe rows; `file` maps the path LilyPond printed to a file id
    /// (nil drops the row).
    public static func probedLengths(_ output: String, file: (String) -> String?) -> [ProbedLength] {
        output.split(separator: "\n").compactMap { line in
            guard let start = line.firstRange(of: probeMarker) else { return nil }
            let fields = line[start.upperBound...].split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 4, let id = file(fields[0]), let row = Int(fields[1]), let column = Int(fields[2]) else { return nil }
            let parts = fields[3].split(separator: "/")
            guard (1...2).contains(parts.count), let n = Int(parts[0]), let d = parts.count == 2 ? Int(parts[1]) : 1, d > 0 else { return nil }
            return ProbedLength(site: ProbeSite(file: id, line: row, character: column), length: Ratio(n, d))
        }
    }

    /// Judges a plan against the probe. A body evaluated more than once
    /// (included twice, say) counts at its longest.
    public static func verify(_ plan: MeterPlan, lengths: [ProbedLength]) -> ProbeVerdict {
        var unknown = false
        for site in plan.unverified {
            var rows = lengths.filter { $0.site == site }
            if rows.isEmpty {
                // Character counts can disagree on unusual text; one body
                // opening on that line is still unambiguous.
                let line = lengths.filter { $0.site.file == site.file && $0.site.line == site.line }
                if Set(line.map(\.site.character)).count == 1 { rows = line }
            }
            guard let longest = rows.map(\.length.value).max() else { unknown = true; continue }
            if longest > plan.meter.wholeNotes {
                return .overflow(Overflow(file: site.file, measure: plan.measure, meter: plan.meter))
            }
        }
        return unknown ? .unknown : .fits
    }

    static func probeSite(_ file: File, _ measure: Measure) -> ProbeSite {
        let brace = measure.body.lowerBound - 1
        var line = 1
        var character = 0
        for byte in file.tree.bytes[..<brace] {
            if byte == 0x0A { line += 1; character = 0 }
            else if byte & 0xC0 != 0x80 { character += 1 }
        }
        return ProbeSite(file: file.id, line: line, character: character)
    }
}
