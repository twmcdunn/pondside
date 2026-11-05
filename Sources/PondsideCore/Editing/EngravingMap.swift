/// Maps between the text that was last engraved and the text being edited.
///
/// Edits land instantly but engraving takes a moment, so for a while the
/// canvas shows music whose point-and-click links refer to an older text.
/// This map lets selection, highlighting and clicks keep working across that
/// gap: the changed span collapses, everything else maps exactly.
public struct EngravingMap: Sendable {
    public let engraved: SourceText
    /// The changed spans, in the engraved text's offsets, in order. Each is
    /// its own: edits in two places (two slurs added before the engraving
    /// lands) leave the music between them mapped exactly.
    private let hunks: [TextHunk]

    public init(engraved: String, current: String) {
        self.engraved = SourceText(engraved)
        hunks = TextDiff.hunks(from: engraved, to: current)
    }

    /// UTF-16 offset in the current text for one in the engraved text. An
    /// offset inside a changed span lands after its new text.
    public func currentOffset(forEngraved o: Int) -> Int {
        var delta = 0
        for h in hunks {
            if o <= h.oldLocation { return o + delta }
            if o < h.oldLocation + h.oldLength { return h.oldLocation + delta + h.newLength }
            delta += h.newLength - h.oldLength
        }
        return o + delta
    }

    /// UTF-16 offset in the engraved text for one in the current text. An
    /// offset inside new text collapses to where that span starts.
    public func engravedOffset(forCurrent o: Int) -> Int {
        var delta = 0
        for h in hunks {
            let start = h.oldLocation + delta
            if o <= start { return o - delta }
            if o < start + h.newLength { return h.oldLocation }
            delta += h.newLength - h.oldLength
        }
        return o - delta
    }

    /// The UTF-16 offset in the engraved text of a point-and-click position.
    public func engravedOffset(of position: SourcePosition) -> Int? {
        engraved.index(of: position).map { engraved.utf16Offset(of: $0) }
    }
}
