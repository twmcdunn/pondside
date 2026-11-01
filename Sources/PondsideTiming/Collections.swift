import Foundation

/// The pitch collections on one staff (the notes between a `\startGroup`
/// and its `\stopGroup`, as `\collection` writes them), for a patch: the
/// `~ec` and `~ecWhere` arrays the lilypond-supercollider workflow's
/// `piece.ec.scd` has always held, so patches that load it keep working.
public enum Collections {
    public struct Collection: Sendable, Hashable {
        public var moment: Rational
        public var bar: Int
        /// The notes as written, in order.
        public var midi: [Int]
        public var seconds: Double
        /// The last cue at or before it ("cue 7").
        public var cue: String?

        public var pitchClasses: [Int] { Set(midi.map { (($0 % 12) + 12) % 12 }).sorted() }
    }

    public static func find(in log: TimingLog, staff: String) -> [Collection] {
        let map = TempoMap(log)
        let cues = log.texts(startingWith: "cue ")
        var byMoment: [Rational: [TimingLog.Row]] = [:]
        for r in log.rows {
            switch r.kind {
            case .note(let s, _) where s == staff, .group(let s, _) where s == staff: byMoment[r.moment, default: []].append(r)
            default: continue
            }
        }
        var out: [Collection] = []
        var current: Collection?
        for m in byMoment.keys.sorted() {
            let rows = byMoment[m]!
            if rows.contains(where: { if case .group(_, true) = $0.kind { return true }; return false }) {
                let cue = cues.last { $0.moment <= m }?.text
                current = Collection(moment: m, bar: rows[0].bar, midi: [], seconds: map.seconds(at: m), cue: cue)
            }
            for r in rows { if case .note(_, let midi) = r.kind { current?.midi.append(midi) } }
            if let c = current, rows.contains(where: { if case .group(_, false) = $0.kind { return true }; return false }) {
                out.append(c)
                current = nil
            }
        }
        return out
    }

    static let names = ["C", "C#", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]

    /// `~ec = [...]; ~ecWhere = [...];` as SuperCollider code.
    public static func scd(_ list: [Collection], staff: String, score: String, variable: String = "ec") -> String {
        func f(_ x: Double, _ digits: Int) -> String { String(format: "%.\(digits)f", x) }
        var out = "// Collections on staff \(staff), from \(score) (pondside cues --format ec):\n"
        out += "// pitch classes ascending from C; each line: index: bar, time, last cue: the notes as written.\n"
        out += "~\(variable) = [\n"
        for (i, c) in list.enumerated() {
            let label = "\(i): bar \(c.bar), \(f(c.seconds, 1)) s" + (c.cue.map { ", " + $0 } ?? "") + ": "
                + c.midi.map { names[(($0 % 12) + 12) % 12] }.joined(separator: " ")
            out += "\t[" + c.pitchClasses.map(String.init).joined(separator: ", ") + "]"
                + (i < list.count - 1 ? "," : " ") + "   // " + label + "\n"
        }
        out += "];\n"
        out += "// where each one is in the score (seconds at the render's tempo; cue: the last cue\n"
        out += "// at or before it), e.g. to check that the patch plays it in that cue's window\n"
        let where_ = list.map { c in "(bar: \(c.bar), time: \(f(c.seconds, 3)), cue: " + (c.cue.map { "\"\($0)\"" } ?? "nil") + ")" }
        out += "~\(variable)Where = [\n\t" + where_.joined(separator: ",\n\t") + "\n];\n"
        return out
    }
}
