/// Fanned (feathered) beams and notes hidden from the page, both written as
/// plain LilyPond around the selection.
///
/// - ⌥F: `\once \override Beam.grow-direction = #RIGHT` before the first
///   note, under one manual beam `[ … ]` over the selection: an accelerando
///   (the beams fan out to the right). ⌥⇧F writes `#LEFT`, a ritardando.
///   Again with the same direction removes the fan; the beam stays.
/// - ⌥H: `\hideNotes … \unHideNotes` around the selection. The notes keep
///   their time and still play in the MIDI; ⌥H again shows them.
extension ScoreEditor {
    public enum BeamFan: Sendable {
        /// Accelerando: the beams fan out towards the end (`#RIGHT`).
        case accelerando
        /// Ritardando: the beams close towards the end (`#LEFT`).
        case ritardando

        var direction: String { self == .accelerando ? "#RIGHT" : "#LEFT" }
    }

    static let fanPrefix = "\\once \\override Beam.grow-direction = "

    public func fanBeam(_ fan: BeamFan, events eventIndices: [Int]) -> ScoreEdit? {
        let sorted = Array(Set(eventIndices)).sorted().filter { tree.events[$0].kind != .lyric }
        guard let first = sorted.first, let last = sorted.last, first != last else { return nil }
        var edits: [TextEdit] = []
        let start = tree.events[first].range.lowerBound
        if let (range, direction) = fanBefore(start) {
            // The same fan again removes it; the other direction replaces it.
            if direction == fan.direction {
                edits.append(TextEdit(range, ""))
            } else {
                let text = Self.fanPrefix + fan.direction + " "
                edits.append(TextEdit(range, text))
            }
        } else {
            let text = Self.fanPrefix + fan.direction + " "
            edits.append(.insert(text, at: start))
        }
        edits += beamEdits(first: first, last: last)
        let name = fanBefore(start)?.1 == fan.direction ? "Remove Fanned Beam"
            : fan == .accelerando ? "Fan Beam (Accelerando)" : "Fan Beam (Ritardando)"
        return ScoreEdit(name: name, edits: edits,
                         selectionAnchors: anchors(edits, events: sorted))
    }

    /// One manual beam from `first` to `last`: `[` and `]` where missing,
    /// and no other beam marks between them (they would nest).
    private func beamEdits(first: Int, last: Int) -> [TextEdit] {
        var edits: [TextEdit] = []
        func marks(_ text: String, on e: Int) -> [Range<Int>] {
            tree.events[e].postEvents.filter { tree.string($0) == text }
        }
        for e in first...last {
            if e != first { edits += marks("[", on: e).map { TextEdit($0, "") } }
            if e != last { edits += marks("]", on: e).map { TextEdit($0, "") } }
        }
        if marks("[", on: first).isEmpty { edits.append(.insert("[", at: tree.events[first].range.upperBound)) }
        if marks("]", on: last).isEmpty { edits.append(.insert("]", at: tree.events[last].range.upperBound)) }
        return edits
    }

    /// `\once \override Beam.grow-direction = #…` just before `offset`, with
    /// the whitespace after it.
    private func fanBefore(_ offset: Int) -> (Range<Int>, String)? {
        for direction in ["#RIGHT", "#LEFT"] {
            if let r = written(Self.fanPrefix + direction, endingBefore: offset) { return (r, direction) }
        }
        return nil
    }

    public func toggleHidden(events eventIndices: [Int]) -> ScoreEdit? {
        let sorted = Array(Set(eventIndices)).sorted().filter { tree.events[$0].kind != .lyric }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let start = tree.events[first].range.lowerBound, end = tree.events[last].range.upperBound
        if let hide = written("\\hideNotes", endingBefore: start), let show = written("\\unHideNotes", startingAfter: end) {
            let edits = [TextEdit(hide, ""), TextEdit(show, "")]
            return ScoreEdit(name: "Show Notes", edits: edits,
                             selectionAnchors: anchors(edits, events: sorted))
        }
        let open = "\\hideNotes "
        let edits: [TextEdit] = [.insert(open, at: start), .insert(" \\unHideNotes", at: end)]
        return ScoreEdit(name: "Hide Notes", edits: edits,
                         selectionAnchors: anchors(edits, events: sorted))
    }

    /// `text` and the whitespace after it, when only whitespace separates it from `offset`.
    private func written(_ text: String, endingBefore offset: Int) -> Range<Int>? {
        let b = tree.bytes, t = Array(text.utf8)
        var end = offset
        while end > 0, [0x20, 0x09, 0x0A, 0x0D].contains(b[end - 1]) { end -= 1 }
        let lower = end - t.count
        guard lower >= 0, Array(b[lower..<end]) == t else { return nil }
        return lower..<offset
    }

    /// Whitespace and then `text` just after `offset`.
    private func written(_ text: String, startingAfter offset: Int) -> Range<Int>? {
        let b = tree.bytes, t = Array(text.utf8)
        var start = offset
        while start < b.count, [0x20, 0x09, 0x0A, 0x0D].contains(b[start]) { start += 1 }
        let upper = start + t.count
        guard upper <= b.count, Array(b[start..<upper]) == t, !isWordByte(at: upper) else { return nil }
        return offset..<upper
    }

    /// The selection after `edits`. An edit ending at an event's start (an
    /// insertion there, or what is removed before it) moves the event, which
    /// `mapOffset` would leave before the insertion.
    private func anchors(_ edits: [TextEdit], events sorted: [Int]) -> [Int] {
        sorted.map { e in
            let start = tree.events[e].range.lowerBound
            return edits.filter { $0.range.upperBound <= start }.reduce(start) { $0 + $1.delta }
        }
    }
}
