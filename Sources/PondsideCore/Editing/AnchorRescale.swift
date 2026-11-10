/// When unmetered entry changes a bar's length, the bar's other voices that
/// hold only skips, full-bar rests and zero-length marks (cues on `s4*0`,
/// collections, `\edesc`, `s1*0`) follow it: their skips are rewritten so
/// every mark lands at the same place relative to the edited music.
///
/// The edited voice's events before and after the edit give a piecewise
/// linear map of the bar's moments. A mark at a note's onset stays at that
/// note's new onset, and a mark between notes stays the same fraction of the
/// way between them. The bar's end maps to its new end, so a stretch of
/// marks past the music spreads or tightens with the new length. A voice with
/// notes (or rests within the bar) is music: it keeps its timing, and
/// the bar can't get shorter than it.
extension StructuralEditing {
    /// Old moments of a bar to new ones, piecewise linear between known pairs.
    struct BarTimeMap {
        /// Sorted by `old`, and by `new` among equal `old`s; `new` never decreases.
        var points: [(old: LensFraction, new: LensFraction)]

        func callAsFunction(_ t: LensFraction) -> LensFraction {
            guard let j = points.lastIndex(where: { !(t < $0.old) }) else { return t }
            let a = points[j]
            if a.old == t { return a.new }
            guard j + 1 < points.count else { return a.new + (t - a.old) }
            let b = points[j + 1]
            return a.new + (t - a.old) * ((b.new - a.new) / (b.old - a.old))
        }
    }

    private struct Timed {
        var index: Int
        var onset: LensFraction
        var duration: LensFraction
    }

    /// The events that take part in the bar's time, with their moments.
    private static func timed(_ tree: SyntaxTree, body: Range<Int>, timeless: Set<String>) -> [Timed] {
        let context = LensContextScanner.scan(tree, block: body, timeless: timeless)
        var cursor = LensFraction.zero
        var result: [Timed] = []
        for (i, event) in tree.events.enumerated() where body.contains(event.range.lowerBound) && event.kind != .lyric {
            guard !context.isGrace(at: event.range.lowerBound) else { continue }
            let d = duration(event, in: tree, context: context)
            result.append(Timed(index: i, onset: cursor, duration: d))
            cursor = cursor + d
        }
        return result
    }

    /// The map from the edited voice: events outside the changed bytes pair
    /// up with themselves, and the changed ones pair in order when there are
    /// as many after the edit as before (a duration change).
    static func timeMap(before: SyntaxTree, body old: Range<Int>, after: SyntaxTree, body new: Range<Int>,
                        oldLength: LensFraction, newLength: LensFraction, timeless: Set<String>) -> BarTimeMap {
        let ob = Array(before.bytes[old]), nb = Array(after.bytes[new])
        var p = 0
        while p < ob.count, p < nb.count, ob[p] == nb[p] { p += 1 }
        var q = 0
        while q < ob.count - p, q < nb.count - p, ob[ob.count - 1 - q] == nb[nb.count - 1 - q] { q += 1 }
        func split(_ list: [Timed], _ tree: SyntaxTree, _ body: Range<Int>, count: Int) -> (prefix: [Timed], middle: [Timed], suffix: [Timed]) {
            var prefix: [Timed] = [], middle: [Timed] = [], suffix: [Timed] = []
            for t in list {
                let r = tree.events[t.index].range
                if r.upperBound - body.lowerBound <= p { prefix.append(t) }
                else if r.lowerBound - body.lowerBound >= count - q { suffix.append(t) }
                else { middle.append(t) }
            }
            return (prefix, middle, suffix)
        }
        let o = split(timed(before, body: old, timeless: timeless), before, old, count: ob.count)
        let n = split(timed(after, body: new, timeless: timeless), after, new, count: nb.count)
        var pairs: [(Timed, Timed)] = []
        if o.prefix.count == n.prefix.count { pairs += zip(o.prefix, n.prefix).map { ($0, $1) } }
        if o.middle.count == n.middle.count {
            pairs += zip(o.middle, n.middle).map { ($0, $1) }
        } else {
            // Notes inserted or deleted: the same notes on either side of them pair.
            func text(_ t: Timed, _ tree: SyntaxTree) -> String { tree.string(tree.events[t.index].range) }
            var front = 0
            while front < min(o.middle.count, n.middle.count), text(o.middle[front], before) == text(n.middle[front], after) {
                pairs.append((o.middle[front], n.middle[front]))
                front += 1
            }
            var back = 0
            while back < min(o.middle.count, n.middle.count) - front,
                  text(o.middle[o.middle.count - 1 - back], before) == text(n.middle[n.middle.count - 1 - back], after) {
                pairs.append((o.middle[o.middle.count - 1 - back], n.middle[n.middle.count - 1 - back]))
                back += 1
            }
        }
        if o.suffix.count == n.suffix.count { pairs += zip(o.suffix, n.suffix).map { ($0, $1) } }
        var points: [(old: LensFraction, new: LensFraction)] = [(.zero, .zero)]
        for (a, b) in pairs {
            points.append((a.onset, b.onset))
            points.append((a.onset + a.duration, b.onset + b.duration))
        }
        points.append((oldLength, newLength))
        points.sort { $0.old < $1.old || ($0.old == $1.old && $0.new < $1.new) }
        // A map that would run backwards keeps its earlier points.
        var monotone: [(old: LensFraction, new: LensFraction)] = []
        for point in points where monotone.last.map({ !(point.new < $0.new) }) ?? true { monotone.append(point) }
        return BarTimeMap(points: monotone)
    }

    /// Whether a voice's bar holds only skips, full-bar rests and zero-length
    /// marks, so its timing can follow the bar's new length.
    static func isAnchorVoice(_ tree: SyntaxTree, body: Range<Int>, timeless: Set<String>) -> Bool {
        guard !needsInterpreter(in: tree, body: body, timeless: timeless) else { return false }
        let context = LensContextScanner.scan(tree, block: body, timeless: timeless)
        guard context.tuplets.isEmpty, context.tremolos.isEmpty else { return false }
        var spaces = false
        tree.root.forEachLeaf {
            if body.contains($0.range.lowerBound), $0.kind == .command, tree.string($0.range) == "\\pondsideSpace" { spaces = true }
        }
        guard !spaces else { return false }
        return timed(tree, body: body, timeless: timeless).allSatisfy {
            let kind = tree.events[$0.index].kind
            return kind == .spacer || kind == .multiMeasureRest
        }
    }

    /// The skips of an anchor voice's bar rewritten through `map`. Each keeps
    /// its written base (`s4*54` → `s4*27`), so notes after it that inherit
    /// the duration keep their heads. A timed event after the bar that
    /// inherits its duration from the last skip gets its own.
    static func rescaleEdits(_ tree: SyntaxTree, body: Range<Int>, map: BarTimeMap, timeless: Set<String>) -> [TextEdit] {
        var edits: [TextEdit] = []
        var changed = false
        let events = timed(tree, body: body, timeless: timeless).filter { !$0.duration.isZero || tree.events[$0.index].kind != .spacer }
        // A full-bar rest (`R4*7`) is the bar's length, whatever it said before.
        let fullBar = events.count == 1 && tree.events[events[0].index].kind == .multiMeasureRest
        for t in timed(tree, body: body, timeless: timeless) {
            let event = tree.events[t.index]
            let start = map(t.onset)
            let length = fullBar && event.kind == .multiMeasureRest ? (map.points.last?.new ?? t.duration) : map(t.onset + t.duration) - start
            guard length != t.duration || (changed && event.explicitDuration == nil) else { continue }
            let text = durationText(event.explicitDuration ?? event.effectiveDuration, length: length)
            if let written = event.duration {
                if tree.string(written) != text { edits.append(TextEdit(written, text)) }
            } else {
                edits.append(.insert(text, at: event.durationInsertion))
            }
            changed = true
        }
        guard changed else { return [] }
        let collections = tree.collections.map(\.body)
        if let next = tree.events.first(where: { e in
            e.range.lowerBound >= body.upperBound && e.kind != .lyric && !collections.contains { $0.contains(e.range.lowerBound) }
        }), next.explicitDuration == nil {
            edits.append(.insert(next.effectiveDuration.text, at: next.durationInsertion))
        }
        return edits.normalized.isNonOverlapping ? edits : []
    }

    /// `base` (its note value and dots) scaled to `length` whole notes.
    static func durationText(_ base: DurationValue, length: LensFraction) -> String {
        let plain = DurationValue(log: base.log, dots: base.dots)
        guard !length.isZero else { return plain.text + "*0" }
        let unit = plain.wholeNotes
        let factor = length / LensFraction(unit.0, unit.1)
        return DurationValue(log: base.log, dots: base.dots,
                             factorNumerator: factor.numerator, factorDenominator: factor.denominator).text
    }
}

extension LensFraction {
    static func / (lhs: LensFraction, rhs: LensFraction) -> LensFraction {
        LensFraction(lhs.numerator * rhs.denominator, lhs.denominator * rhs.numerator)
    }
}
