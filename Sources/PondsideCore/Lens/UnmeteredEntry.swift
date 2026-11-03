/// Source positions and meter for the measure containing a selected event.
public enum UnmeteredEntry {
    public static func measure(in tree: SyntaxTree, event: Int) -> (first: Int, time: LensTime)? {
        guard tree.events.indices.contains(event),
              let block = LensBlockFinder.block(in: tree, at: tree.events[event].range.lowerBound) else { return nil }
        var context = LensContextScanner.scan(tree, block: block.context)
        let timeline = LensTimeline(tree: tree, block: block, context: &context)
        guard let target = timeline.events.first(where: { $0.sourceEvent == event }),
              let first = timeline.events.first(where: { $0.measureIndex == target.measureIndex && $0.voiceIndex == target.voiceIndex }) else { return nil }
        return (first.sourceEvent, timeline.times[target.measureIndex])
    }

    public static func meter(in tree: SyntaxTree, from first: Int, through last: Int) -> String? {
        guard first <= last, tree.events.indices.contains(first), tree.events.indices.contains(last),
              let block = LensBlockFinder.block(in: tree, at: tree.events[first].range.lowerBound) else { return nil }
        let context = LensContextScanner.scan(tree, block: block.context)
        var total = LensFraction.zero
        var reserved: Set<Range<Int>> = []
        for i in first...last {
            let event = tree.events[i]
            let offset = event.range.lowerBound
            if context.isGrace(at: offset) { continue }
            let duration = event.effectiveDuration.wholeNotes
            if let tuplet = context.tuplets(at: offset).first {
                if reserved.insert(tuplet.body).inserted {
                    total = total + LensFraction(duration.0, duration.1) * LensFraction(tuplet.normalNotes)
                }
            } else {
                total = total + LensFraction(duration.0, duration.1) * context.durationFactor(at: offset)
            }
        }
        guard total > .zero else { return nil }
        return "\(total.numerator)/\(total.denominator)"
    }
}
