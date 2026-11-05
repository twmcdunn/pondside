/// A node in the lossless concrete syntax tree. Leaves are tokens.
public final class SyntaxNode: Sendable {
    public let kind: SyntaxKind
    /// UTF-8 byte offsets into the source.
    public let range: Range<Int>
    public let children: [SyntaxNode]

    init(_ kind: SyntaxKind, _ range: Range<Int>, _ children: [SyntaxNode] = []) {
        self.kind = kind
        self.range = range
        self.children = children
    }

    public var isLeaf: Bool { children.isEmpty }

    /// Leaves in source order.
    public func forEachLeaf(_ body: (SyntaxNode) -> Void) {
        if children.isEmpty { body(self); return }
        for c in children { c.forEachLeaf(body) }
    }

    /// Nodes in pre-order.
    public func forEachNode(_ body: (SyntaxNode) -> Void) {
        body(self)
        for c in children { c.forEachNode(body) }
    }
}

/// A pitch as it appears in the source, with everything needed to rewrite it.
public struct NoteInfo: Sendable, Hashable {
    public enum Role: Sendable, Hashable {
        /// A note that is (part of) a music event.
        case event
        /// The start pitch of `\relative` / `\fixed`: absolute, outside any chain.
        case scopeArgument
        /// A `\transpose`-style argument: participates in the relative chain.
        case chainArgument
        /// `\key`, `\transposition`, `\octaveCheck`: absolute, outside the chain.
        case absoluteArgument
    }

    public var role: Role
    /// The pitch name word.
    public var name: Range<Int>
    /// The octave marks; empty (at `name.upperBound`) when there are none.
    public var marks: Range<Int>
    /// Explicit `!` or cautionary `?` accidental display mark.
    public var accidentalMark: Range<Int>?
    /// `='` octave check, if any.
    public var octaveCheck: Range<Int>?
    public var writtenStep: Int
    public var writtenAlteration: Int
    public var writtenMarks: Int
    /// The resolved absolute pitch, computed as LilyPond does it.
    public var absolute: Pitch
    public var mode: OctaveMode
    /// In relative mode: the note this one is relative to. nil means the
    /// implicit `\relative` reference (F below middle C).
    public var referent: Int?
    public var language: PitchLanguage
    /// English names written in the long `c-sharp` style.
    public var longForm: Bool
    /// The event this note belongs to, if any.
    public var event: Int?

    /// The full written range: name and marks.
    public var spelledRange: Range<Int> { name.lowerBound..<marks.upperBound }
}

/// A music event: note, chord, rest, lyric syllable or drum hit.
public struct MusicEvent: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case note, chord, rest, multiMeasureRest, spacer, chordRepeat, lyric, drum
        /// A bare duration (`c4~ 8`): LilyPond repeats the previous pitch.
        case repeatedPitch
    }

    public var kind: Kind
    public var range: Range<Int>
    /// Indices into `SyntaxTree.notes`, in source order (chord members).
    public var notes: [Int]
    /// The written duration, if explicit.
    public var duration: Range<Int>?
    public var explicitDuration: DurationValue?
    /// The duration LilyPond gives this event (explicit or inherited).
    public var effectiveDuration: DurationValue
    /// Where a duration would be inserted if absent: right after the head.
    public var durationInsertion: Int
    /// The post-events (articulations, slurs, dynamics …), in order.
    public var postEvents: [Range<Int>]
    public var octaveMode: OctaveMode
    /// The chain reference in effect after this event (relative mode).
    public var chainRefAfter: Int?
    public var key: KeySignature
    public var language: PitchLanguage
    /// The lexer mode the event was read in (notes, chords, lyrics …).
    public var lexMode: LexMode
    /// The event alone is the operand of `\relative`/`\fixed` (`\relative c' c1`).
    public var isScopeOperand = false

    public var isPitched: Bool { !notes.isEmpty }
    /// Whether ordinary note entry (insert, slurs, articulations) applies.
    public var acceptsNoteEntry: Bool { lexMode == .notes && kind != .lyric && kind != .drum }
}

/// An `\include "…"` with the note-name language in effect where it appears.
public struct IncludeDirective: Sendable, Hashable {
    /// The string as written.
    public var path: String
    /// The string token's range (quotes included).
    public var range: Range<Int>
    public var language: PitchLanguage
}

/// A parsed LilyPond document: the lossless tree plus the music it encodes.
public struct SyntaxTree: Sendable {
    public let text: String
    public let bytes: [UInt8]
    public let root: SyntaxNode
    public let notes: [NoteInfo]
    public let events: [MusicEvent]
    /// Places the parser had to recover: stray closers, unterminated blocks.
    public let issues: [Range<Int>]
    public let includes: [IncludeDirective]
    /// The note-name language in effect at the end of the file.
    public let finalLanguage: PitchLanguage

    /// Parses `text`.
    /// - Parameters:
    ///   - language: the language in effect where this file is included.
    ///   - includedLanguage: for an `\include` string, the language the
    ///     included file leaves in effect (so `defs.ily` can switch the rest
    ///     of the score to English). nil means "unchanged".
    public init(_ text: String, language: PitchLanguage = .nederlands,
                includedLanguage: @escaping (String) -> PitchLanguage? = { _ in nil }) {
        let bytes = Array(text.utf8)
        var parser = Parser(bytes, language: language, includedLanguage: includedLanguage)
        let root = parser.parseDocument()
        self.text = text
        self.bytes = bytes
        self.root = root
        self.notes = parser.notes
        self.events = parser.events
        self.issues = parser.issues
        self.includes = parser.includes
        self.finalLanguage = parser.currentLanguage
    }

    public func string(_ range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    /// Concatenation of every leaf. Equal to `text` by construction; tests
    /// assert it for every file in the corpus.
    public var reconstructed: String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        root.forEachLeaf { out.append(contentsOf: bytes[$0.range]) }
        return String(decoding: out, as: UTF8.self)
    }

    /// The event whose range contains `offset` (or ends exactly at it).
    public func eventIndex(at offset: Int) -> Int? {
        var lo = 0, hi = events.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = events[mid].range
            if offset < r.lowerBound { hi = mid - 1 }
            else if offset > r.upperBound { lo = mid + 1 }
            else { return mid }
        }
        return nil
    }

    /// Events overlapping `range`, in order.
    public func eventIndices(overlapping range: Range<Int>) -> [Int] {
        if range.isEmpty { return eventIndex(at: range.lowerBound).map { [$0] } ?? [] }
        return events.indices.filter { events[$0].range.overlaps(range) }
    }

    /// The note whose name starts at `offset` (what point-and-click reports).
    public func noteIndex(startingAt offset: Int) -> Int? {
        notes.firstIndex { $0.name.lowerBound == offset }
    }

    /// Notes whose `referent` is `index`.
    public func dependents(of index: Int) -> [Int] {
        notes.indices.filter { notes[$0].referent == index }
    }
}
