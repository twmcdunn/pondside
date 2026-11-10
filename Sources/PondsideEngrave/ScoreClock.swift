import PondsideCore
import PondsideTiming

/// A moment as bar, beat and clock time, read from the engraving's timing
/// log (the interpreter's bars and tempi, not guessed from the text): the
/// time stamp on the selection's line. Built once per log; a lookup is a
/// binary search.
public struct ScoreClock: Sendable {
    private struct Mark: Sendable {
        var moment: LensFraction
        var bar: Int
        var position: LensFraction?
        var beat: Int
        /// The bar's length under the meter in force, whole notes.
        var length: LensFraction
    }

    private var marks: [Mark] = []
    private let tempo: TempoMap

    public init(log: TimingLog) {
        tempo = TempoMap(log)
        var beat = 4
        var length = LensFraction.one
        var seen = Set<LensFraction>()
        for row in log.rows.sorted(by: { $0.moment < $1.moment }) {
            if case .meter(let n, let d) = row.kind, n > 0, d > 0 { beat = d; length = LensFraction(n, d) }
            let m = LensFraction(row.moment.numerator, row.moment.denominator)
            guard seen.insert(m).inserted else { continue }
            marks.append(Mark(moment: m, bar: row.bar,
                              position: row.measurePosition.map { LensFraction($0.numerator, $0.denominator) }, beat: beat,
                              length: length))
        }
    }

    public func seconds(at t: LensFraction) -> Double { tempo.seconds(at: Rational(t.numerator, t.denominator)) }

    /// The moment playing at `seconds` (a playhead), to a 1/1920 whole note.
    public func moment(atSeconds seconds: Double) -> LensFraction {
        LensFraction(Int((tempo.moment(atSeconds: max(0, seconds)) * 1920).rounded()), 1920)
    }

    /// The last logged moment's time: the piece's length, near enough for a
    /// timeline before any audio is loaded.
    public var totalSeconds: Double { marks.last.map { seconds(at: $0.moment) } ?? 0 }

    /// "m. 12 · beat 3.00 · 0:41.3"; the beat only where the log says where
    /// in the bar its rows fall.
    public func label(at t: LensFraction) -> String {
        let s = max(0, seconds(at: t))
        let minutes = Int(s) / 60
        let rest = s - Double(minutes * 60)
        let tenths = Int((rest * 10).rounded(.down))
        let clock = "\(minutes):" + (tenths < 100 ? "0" : "") + "\(tenths / 10).\(tenths % 10)"
        var lo = 0, hi = marks.count - 1
        guard hi >= 0, !(t < marks[0].moment) else { return clock }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if marks[mid].moment < t || marks[mid].moment == t { lo = mid } else { hi = mid - 1 }
        }
        let mark = marks[lo]
        guard let position = mark.position else { return "m. \(mark.bar) · " + clock }
        // Past a barline no row marks: on into the next bars.
        var into = position + (t - mark.moment)
        var bar = mark.bar
        while !(into < mark.length), LensFraction.zero < mark.length { into = into - mark.length; bar += 1 }
        let beats = (into * LensFraction(mark.beat)).double + 1
        // Always two decimals: a stamp that ticks during playback keeps its width.
        let hundredths = Int((beats * 100).rounded())
        let shown = "\(hundredths / 100)." + (hundredths % 100 < 10 ? "0" : "") + "\(hundredths % 100)"
        return "m. \(bar) · beat \(shown) · " + clock
    }
}
