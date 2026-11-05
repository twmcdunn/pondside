/// Byte constants, so the parser reads like the grammar.
enum Ch {
    static let apostrophe = UInt8(ascii: "'")
    static let comma = UInt8(ascii: ",")
    static let bang = UInt8(ascii: "!")
    static let question = UInt8(ascii: "?")
    static let equals = UInt8(ascii: "=")
    static let dot = UInt8(ascii: ".")
    static let star = UInt8(ascii: "*")
    static let slash = UInt8(ascii: "/")
    static let colon = UInt8(ascii: ":")
    static let openParen = UInt8(ascii: "(")
    static let closeParen = UInt8(ascii: ")")
    static let quote = UInt8(ascii: "\"")
    static let semicolon = UInt8(ascii: ";")
    static let hash = UInt8(ascii: "#")
    static let backslash = UInt8(ascii: "\\")
    static let openBrace = UInt8(ascii: "{")
    static let closeBrace = UInt8(ascii: "}")
    static let pipe = UInt8(ascii: "|")
    static let backquote = UInt8(ascii: "`")
    static let at = UInt8(ascii: "@")
    static let newline = UInt8(ascii: "\n")
    static let lt = UInt8(ascii: "<")
    static let gt = UInt8(ascii: ">")
    static let percent = UInt8(ascii: "%")
}

/// A single-pass recursive-descent parser that builds the lossless tree and,
/// in the same lexical pass, resolves what LilyPond resolves lexically:
/// relative octaves, inherited durations, key and note-name language.
///
/// Those rules were established against LilyPond itself (see DESIGN.md §6):
/// the `\relative` chain runs in pure lexical order, across `<< >>` voices and
/// repeat alternatives; a chord's first note is the reference after it;
/// nested `\relative`/`\fixed`/`\absolute` are isolated; `\transpose`
/// arguments join the chain; and the default duration (multiplier included)
/// carries across the whole file.
struct Parser {
    let b: [UInt8]
    let lexer: Lexer
    var pos = 0

    private(set) var notes: [NoteInfo] = []
    private(set) var events: [MusicEvent] = []
    private(set) var issues: [Range<Int>] = []
    private(set) var includes: [IncludeDirective] = []
    private let includedLanguage: (String) -> PitchLanguage?
    var currentLanguage: PitchLanguage { language }

    // Lexical music state.
    private var language: PitchLanguage = .nederlands
    private var defaultDuration: DurationValue = .quarter
    private var key: KeySignature = .cMajor
    private var pendingKeyTonic: Pitch?

    struct Frame {
        var mode: OctaveMode
        var chainRef: Int?
    }
    private var frames: [Frame] = [Frame(mode: .absolute, chainRef: nil)]
    private var pendingScope: Frame?

    /// Expectations set by the previous command; reset inside blocks.
    struct State {
        var pendingMode: LexMode?
        var inlineMarkup = false
        var pitchArgs = 0
        var pitchCommand = ""
        var expectPath = false
        var expectContext = false
        var expectIdentifier = false
        var expectLanguage = false
        var expectInclude = false
    }
    private var st = State()
    private var lastSignificant: SyntaxKind?
    private var lastSignificantStart = 0
    /// End of the most recent event, to recognise bare durations after it.
    private var lastEventEnd = -1
    /// Inside `< >` a number is never a bare duration.
    private var chordDepth = 0

    enum Closer { case brace, simultaneous, chord, embedded }
    enum Context { case document, music, initial, markup }
    private var closers: [Closer] = []

    /// Commands that may sit between `\relative c'` and the music it scopes.
    static let scopeTransparent: Set<String> = [
        "new", "context", "change", "with", "repeat", "tuplet", "times", "grace", "acciaccatura",
        "appoggiatura", "slashedGrace", "afterGrace", "transpose", "tag", "keepWithTag",
        "removeWithTag", "once", "temporary", "unfoldRepeats", "volta", "relative", "fixed", "absolute",
    ]

    init(_ bytes: [UInt8], language: PitchLanguage = .nederlands,
         includedLanguage: @escaping (String) -> PitchLanguage? = { _ in nil }) {
        b = bytes
        lexer = Lexer(bytes)
        self.language = language
        self.includedLanguage = includedLanguage
    }

    // MARK: - Helpers

    private func text(_ s: Int, _ e: Int) -> String {
        String(decoding: b[s..<e], as: UTF8.self)
    }

    private func at(_ i: Int) -> UInt8 { i < b.count ? b[i] : 0 }

    private func lex(_ mode: LexMode) -> Token? {
        pos < b.count ? lexer.token(at: pos, mode: mode) : nil
    }

    private mutating func consume(_ t: Token, as kind: SyntaxKind) -> SyntaxNode {
        pos = t.end
        return SyntaxNode(kind, t.start..<t.end)
    }

    private mutating func collectTrivia(_ mode: LexMode) -> [SyntaxNode] {
        var out: [SyntaxNode] = []
        while let t = lex(mode), t.kind.isTrivia { out.append(consume(t, as: t.kind)) }
        return out
    }

    private func nextSignificant(from p: Int, mode: LexMode) -> Token? {
        var q = p
        while q < b.count {
            let t = lexer.token(at: q, mode: mode)
            if !t.kind.isTrivia { return t }
            q = t.end
        }
        return nil
    }

    private func closerKind(_ c: Closer) -> SyntaxKind {
        switch c {
        case .brace: return .closeBrace
        case .simultaneous: return .closeSimultaneous
        case .chord: return .closeChord
        case .embedded: return .embeddedClose
        }
    }

    private mutating func takePendingScope() -> Frame? {
        let s = pendingScope
        pendingScope = nil
        return s
    }

    /// A note or rest glued to a duration (`r8.`, `c4`): music, even where a
    /// markup argument might otherwise be expected.
    private func isMusicWord(_ t: Token, mode: LexMode) -> Bool {
        guard mode == .notes, Lexer.isDigit(at(t.end)) else { return false }
        let word = text(t.start, t.end)
        return word == "r" || word == "R" || word == "s" || language.parse(word) != nil
    }

    private func isMusicMode(_ mode: LexMode) -> Bool {
        mode == .notes || mode == .chords || mode == .drums
    }

    /// A duration in music position — right after an event or bar check, or
    /// at the start of a music block — is a note of its own. Anywhere else
    /// (after a command, `=`, a string, another number) it is an argument.
    private func startsBareDuration(_ t: Token) -> Bool {
        if chordDepth > 0 { return false }
        if followsEvent(t) { return true }
        switch lastSignificant {
        case .openBrace?, .openSimultaneous?, .barCheck?: return true
        case .escapedPunct?: return text(lastSignificantStart, min(b.count, lastSignificantStart + 2)) == "\\\\"
        default: return false
        }
    }

    /// Whether `t` comes right after an event, with only trivia and bar
    /// checks between: there a bare number is a duration-only note.
    private func followsEvent(_ t: Token) -> Bool {
        guard lastEventEnd >= 0, lastEventEnd <= t.start else { return false }
        var q = lastEventEnd
        while q < t.start {
            let s = lexer.token(at: q, mode: .notes)
            if !s.kind.isTrivia && s.kind != .barCheck { return false }
            q = s.end
        }
        return q == t.start
    }

    private static func isAlnum(_ c: UInt8) -> Bool {
        Lexer.isLetter(c) || Lexer.isDigit(c) || c == UInt8(ascii: "-")
    }

    // MARK: - Sequences and items

    mutating func parseDocument() -> SyntaxNode {
        let children = parseSequence(mode: .notes, closer: nil, context: .document)
        return SyntaxNode(.document, 0..<b.count, children)
    }

    private mutating func parseSequence(mode: LexMode, closer: Closer?, context: Context) -> [SyntaxNode] {
        var out: [SyntaxNode] = []
        while let t = lex(mode) {
            if let closer, t.kind == closerKind(closer) { break }
            if t.kind == .closeBrace || t.kind == .closeSimultaneous || t.kind == .embeddedClose {
                if closers.contains(where: { closerKind($0) == t.kind }) { break }
                issues.append(t.start..<t.end)
                out.append(consume(t, as: .unknown))
                continue
            }
            let before = pos
            out += parseItem(t, mode: mode, context: context)
            if pos == before { out.append(consume(t, as: .unknown)) }
            if !t.kind.isTrivia {
                lastSignificant = t.kind
                lastSignificantStart = t.start
            }
        }
        return out
    }

    private mutating func parseItem(_ t: Token, mode: LexMode, context: Context) -> [SyntaxNode] {
        if t.kind.isTrivia { return [consume(t, as: t.kind)] }
        switch t.kind {
        case .openBrace:
            return [parseBraceBlock(t, mode: mode)]
        case .openSimultaneous:
            let blockMode = st.pendingMode ?? (mode == .initial || mode == .markup ? .notes : mode)
            let scope = takePendingScope()
            return [parseBlock(.simultaneous, open: t, closer: .simultaneous, mode: blockMode, context: .music, scope: scope)]
        case .openChord where mode == .notes || mode == .chords || mode == .drums || mode == .figures:
            st.pitchArgs = 0
            return [parseChordEvent(t, mode: mode)]
        case .hash:
            return [parseScheme()]
        case .string:
            return [parseString(t, mode: mode)]
        case .command where isMusicMode(mode) && !st.inlineMarkup && st.pitchArgs == 0
                            && KnownCommands.durationNames.contains(text(t.start + 1, t.end)) && startsBareDuration(t):
            // `<a' a>\longa \breve` — a duration command can be a bare duration too.
            if let d = parseDuration(t) {
                return [finishEvent(kind: .repeatedPitch, nodeKind: .event, start: t.start, children: [d],
                                    notes: [], mode: mode, presetDuration: d.range)]
            }
            return [parseCommand(t, mode: mode)]
        case .command:
            return [parseCommand(t, mode: mode)]
        case .word:
            return [parseWord(t, mode: mode, context: context)]
        case .lyricWord:
            if st.inlineMarkup { st.inlineMarkup = false; return [consume(t, as: .markupWord)] }
            if st.expectPath || st.expectContext || st.expectIdentifier {
                st.expectPath = false; st.expectContext = false; st.expectIdentifier = false
                return [consume(t, as: .word)]
            }
            return [parseLyricEvent(t)]
        case .markupWord:
            st.inlineMarkup = false
            return [consume(t, as: .markupWord)]
        case .number where isMusicMode(mode) && !st.inlineMarkup && st.pitchArgs == 0 && startsBareDuration(t):
            if let d = parseDuration(t) {
                return [finishEvent(kind: .repeatedPitch, nodeKind: .event, start: t.start, children: [d],
                                    notes: [], mode: mode, presetDuration: d.range)]
            }
            return [consume(t, as: .number)]
        default:
            st.inlineMarkup = false
            st.pitchArgs = 0
            return [consume(t, as: t.kind)]
        }
    }

    // MARK: - Blocks

    private mutating func parseBraceBlock(_ open: Token, mode: LexMode) -> SyntaxNode {
        let blockMode: LexMode
        if let p = st.pendingMode { blockMode = p }
        else if st.inlineMarkup || mode == .markup { blockMode = .markup }
        else if mode == .initial { blockMode = .notes }
        else { blockMode = mode }
        let context: Context = blockMode == .initial ? .initial : (blockMode == .markup ? .markup : .music)
        let scope = (blockMode == .initial || blockMode == .markup) ? nil : takePendingScope()
        return parseBlock(.sequential, open: open, closer: .brace, mode: blockMode, context: context, scope: scope)
    }

    private mutating func parseBlock(_ kind: SyntaxKind, open: Token, closer: Closer, mode: LexMode,
                                     context: Context, scope: Frame?) -> SyntaxNode {
        let saved = st
        st = State()
        if let scope { frames.append(scope) }
        closers.append(closer)
        var children = [consume(open, as: open.kind)]
        let outerSignificant = lastSignificant
        lastSignificant = open.kind
        children += parseSequence(mode: mode, closer: closer, context: context)
        lastSignificant = outerSignificant
        closers.removeLast()
        // A `\relative c'` left dangling at the end of a block scopes nothing.
        pendingScope = nil
        if let t = lex(mode), t.kind == closerKind(closer) {
            children.append(consume(t, as: t.kind))
        } else {
            issues.append(open.start..<open.end)
        }
        if scope != nil { frames.removeLast() }
        st = saved
        st.pendingMode = nil
        st.inlineMarkup = false
        st.pitchArgs = 0
        return SyntaxNode(kind, open.start..<pos, children)
    }

    // MARK: - Strings, commands, words

    private mutating func parseString(_ t: Token, mode: LexMode) -> SyntaxNode {
        let terminated = t.end - t.start >= 2 && b[t.end - 1] == Ch.quote
        let content = text(t.start + 1, terminated ? t.end - 1 : t.end)
        if st.expectLanguage {
            if let l = PitchLanguage(languageName: content) { language = l }
            st.expectLanguage = false
        }
        if st.expectInclude {
            includes.append(IncludeDirective(path: content, range: t.start..<t.end, language: language))
            if let l = includedLanguage(content) ?? PitchLanguage(includeFile: content) { language = l }
            st.expectInclude = false
        }
        st.expectIdentifier = false
        st.expectContext = false
        st.pitchArgs = 0
        if st.inlineMarkup {
            st.inlineMarkup = false
            return consume(t, as: .string)
        }
        if mode == .lyrics && lastSignificant != .equals { return parseLyricEvent(t) }
        return consume(t, as: .string)
    }

    private mutating func parseCommand(_ t: Token, mode: LexMode) -> SyntaxNode {
        let name = text(t.start + 1, t.end)
        let node = consume(t, as: .command)
        if st.inlineMarkup { return node }
        st.expectIdentifier = false
        st.expectContext = false
        st.expectPath = false
        st.pitchArgs = 0

        if let tonic = pendingKeyTonic, KeySignature.isMode(name) {
            key = KeySignature(tonic: tonic, mode: name)
            pendingKeyTonic = nil
            return node
        }
        if !Self.scopeTransparent.contains(name) { pendingScope = nil }
        if let m = KnownCommands.modes[name] { st.pendingMode = m }
        if name == "context" {
            if let next = nextSignificant(from: pos, mode: mode), next.kind == .openBrace {
                st.pendingMode = .initial
            } else {
                st.expectContext = true
            }
        } else if KnownCommands.contextSpec.contains(name) {
            st.expectContext = true
        }
        if KnownCommands.propertyPath.contains(name) { st.expectPath = true }
        if KnownCommands.identifierArgument.contains(name) { st.expectIdentifier = true }
        if KnownCommands.markupCommands.contains(name) { st.inlineMarkup = true }
        if name == "language" { st.expectLanguage = true }
        if name == "include" { st.expectInclude = true }
        if let n = KnownCommands.pitchArguments[name] {
            st.pitchArgs = n
            st.pitchCommand = name
        }
        if name == "relative" { pendingScope = Frame(mode: .relative, chainRef: nil) }
        if name == "absolute" { pendingScope = Frame(mode: .absolute, chainRef: nil) }
        return node
    }

    private mutating func parseWord(_ t: Token, mode: LexMode, context: Context) -> SyntaxNode {
        let word = text(t.start, t.end)
        if st.inlineMarkup {
            st.inlineMarkup = false
            // `\markup \filled-box #… #0 r8.`: a note or rest glued to a
            // duration is music, not the markup's text.
            if !isMusicWord(t, mode: mode) { return consume(t, as: .markupWord) }
        }
        if st.expectPath {
            st.expectPath = false
            return parsePropertyPath(t)
        }
        if st.expectContext {
            st.expectContext = false
            return parseContextSpec(t, mode: mode)
        }
        if st.expectIdentifier {
            st.expectIdentifier = false
            return consume(t, as: .word)
        }
        if st.pitchArgs > 0 {
            if let p = language.parse(word) {
                st.pitchArgs -= 1
                return parsePitchArgument(t, step: p.step, alteration: p.alteration)
            }
            st.pitchArgs = 0
        }
        if context == .document || context == .initial,
           let next = nextSignificant(from: t.end, mode: mode), next.kind == .equals {
            return parseAssignment(t, mode: mode)
        }
        switch mode {
        case .initial, .figures, .markup, .lyrics:
            return consume(t, as: .word)
        case .drums:
            return parseEvent(head: t, mode: mode)
        case .notes, .chords:
            if word == "r" || word == "R" || word == "s" || word == "q" || language.parse(word) != nil {
                return parseEvent(head: t, mode: mode)
            }
            return consume(t, as: .word)
        }
    }

    private mutating func parsePropertyPath(_ t: Token) -> SyntaxNode {
        var children = [consume(t, as: .word)]
        while at(pos) == Ch.dot, Lexer.isLetter(at(pos + 1)) {
            children.append(SyntaxNode(.dot, pos..<(pos + 1)))
            pos += 1
            let end = lexer.identifierEnd(from: pos)
            children.append(SyntaxNode(.word, pos..<end))
            pos = end
        }
        return SyntaxNode(.propertyPath, t.start..<pos, children)
    }

    private mutating func parseContextSpec(_ t: Token, mode: LexMode) -> SyntaxNode {
        var children = [consume(t, as: .word)]
        let save = pos
        let trivia1 = collectTrivia(mode)
        if let eq = lex(mode), eq.kind == .equals {
            children += trivia1
            children.append(consume(eq, as: .equals))
            let save2 = pos
            let trivia2 = collectTrivia(mode)
            if let name = lex(mode), name.kind == .string || name.kind == .word || name.kind == .lyricWord {
                children += trivia2
                children.append(consume(name, as: name.kind == .string ? .string : .word))
            } else {
                pos = save2
            }
        } else {
            pos = save
        }
        return SyntaxNode(.contextSpec, t.start..<pos, children)
    }

    private mutating func parseAssignment(_ t: Token, mode: LexMode) -> SyntaxNode {
        var children = [consume(t, as: .word)]
        children += collectTrivia(mode)
        if let eq = lex(mode), eq.kind == .equals { children.append(consume(eq, as: .equals)) }
        return SyntaxNode(.assignment, t.start..<pos, children)
    }

    // MARK: - Pitches

    private mutating func parsePitchArgument(_ t: Token, step: Int, alteration: Int) -> SyntaxNode {
        let command = st.pitchCommand
        let role: NoteInfo.Role
        switch command {
        case "relative", "fixed": role = .scopeArgument
        case "transpose", "inversion", "modalTranspose", "modalInversion": role = .chainArgument
        default: role = .absoluteArgument
        }
        let (node, index) = parseNoteHead(t, step: step, alteration: alteration, role: role, event: nil, chordMode: false)
        let p = notes[index].absolute
        switch command {
        case "relative": pendingScope = Frame(mode: .relative, chainRef: index)
        case "fixed": pendingScope = Frame(mode: .fixed(baseOctave: p.octave), chainRef: nil)
        case "key": pendingKeyTonic = p
        default: break
        }
        return SyntaxNode(.pitchArgument, node.range, [node])
    }

    /// Parses a pitch name with its adjacent octave marks, accidental mark
    /// and octave check, and resolves its absolute pitch.
    private mutating func parseNoteHead(_ t: Token, step: Int, alteration: Int, role: NoteInfo.Role,
                                        event: Int?, chordMode: Bool) -> (SyntaxNode, Int) {
        pos = t.end
        var children = [SyntaxNode(.pitchName, t.start..<t.end)]
        var marks = 0
        var marksRange = pos..<pos
        if at(pos) == Ch.apostrophe || at(pos) == Ch.comma {
            let s = pos
            while pos < b.count, b[pos] == Ch.apostrophe || b[pos] == Ch.comma {
                marks += b[pos] == Ch.apostrophe ? 1 : -1
                pos += 1
            }
            children.append(SyntaxNode(.octaveMarks, s..<pos))
            marksRange = s..<pos
        }
        var accidentalMark: Range<Int>?
        if at(pos) == Ch.bang || at(pos) == Ch.question {
            accidentalMark = pos..<(pos + 1)
            children.append(SyntaxNode(.accidentalMark, pos..<(pos + 1)))
            pos += 1
        }
        var check: (range: Range<Int>, octave: Int)?
        if role == .event, at(pos) == Ch.equals {
            let s = pos
            pos += 1
            var cm = 0
            while pos < b.count, b[pos] == Ch.apostrophe || b[pos] == Ch.comma {
                cm += b[pos] == Ch.apostrophe ? 1 : -1
                pos += 1
            }
            children.append(SyntaxNode(.octaveCheck, s..<pos))
            check = (s..<pos, cm)
        }

        let frame = frames[frames.count - 1]
        // `\transpose` arguments are written in absolute octaves yet become
        // the chain's reference (verified against LilyPond 2.24).
        let inChain = (role == .event || role == .chainArgument) && !chordMode
        let mode: OctaveMode = (role == .event && !chordMode) ? frame.mode : .absolute
        var referent: Int?
        let octave: Int
        switch mode {
        case .relative:
            referent = frame.chainRef
            let ref = referent.map { notes[$0].absolute } ?? .relativeDefault
            octave = OctaveRules.nearestOctave(step: step, to: ref) + marks
        case .fixed(let base):
            octave = base + marks
        case .absolute:
            octave = marks
        }
        let word = text(t.start, t.end)
        notes.append(NoteInfo(
            role: role, name: t.start..<t.end, marks: marksRange, accidentalMark: accidentalMark, octaveCheck: check?.range,
            writtenStep: step, writtenAlteration: alteration, writtenMarks: marks,
            absolute: Pitch(step: step, alteration: alteration, octave: check?.octave ?? octave),
            mode: mode, referent: referent, language: language, longForm: word.contains("-"), event: event))
        let index = notes.count - 1
        if case .relative = frame.mode, inChain { frames[frames.count - 1].chainRef = index }
        return (SyntaxNode(.note, t.start..<pos, children), index)
    }

    // MARK: - Events

    private mutating func parseEvent(head t: Token, mode: LexMode) -> SyntaxNode {
        let scope = takePendingScope()
        if let scope { frames.append(scope) }
        defer {
            if scope != nil {
                frames.removeLast()
                events[events.count - 1].isScopeOperand = true
            }
        }
        st.pitchArgs = 0
        let word = text(t.start, t.end)
        var children: [SyntaxNode] = []
        var noteIndices: [Int] = []
        let kind: MusicEvent.Kind
        if mode == .drums {
            kind = .drum
            children.append(consume(t, as: .drumName))
        } else if word == "r" || word == "R" || word == "s" {
            kind = word == "r" ? .rest : (word == "R" ? .multiMeasureRest : .spacer)
            let leaf = consume(t, as: .restName)
            children.append(SyntaxNode(.rest, leaf.range, [leaf]))
        } else if word == "q" {
            kind = .chordRepeat
            children.append(consume(t, as: .chordRepeat))
        } else {
            kind = .note
            let p = language.parse(word)!
            let (node, i) = parseNoteHead(t, step: p.step, alteration: p.alteration, role: .event,
                                          event: events.count, chordMode: mode == .chords)
            children.append(node)
            noteIndices = [i]
        }
        return finishEvent(kind: kind, nodeKind: .event, start: t.start, children: children, notes: noteIndices, mode: mode)
    }

    private mutating func parseChordEvent(_ open: Token, mode: LexMode) -> SyntaxNode {
        let scope = takePendingScope()
        if let scope { frames.append(scope) }
        defer {
            if scope != nil {
                frames.removeLast()
                events[events.count - 1].isScopeOperand = true
            }
        }
        let eventIndex = events.count
        var chordChildren = [consume(open, as: .openChord)]
        var members: [Int] = []
        closers.append(.chord)
        chordDepth += 1
        while let t = lex(mode) {
            if t.kind == .closeChord {
                chordChildren.append(consume(t, as: .closeChord))
                break
            }
            if t.kind == .closeBrace || t.kind == .closeSimultaneous || t.kind == .embeddedClose || t.kind == .openSimultaneous {
                issues.append(open.start..<open.end)
                break
            }
            if t.kind.isTrivia {
                chordChildren.append(consume(t, as: t.kind))
                continue
            }
            if t.kind == .word, mode == .drums {
                chordChildren.append(consume(t, as: .drumName))
                continue
            }
            if t.kind == .word, mode != .figures, !st.expectPath, let p = language.parse(text(t.start, t.end)) {
                let (node, i) = parseNoteHead(t, step: p.step, alteration: p.alteration, role: .event,
                                              event: eventIndex, chordMode: mode == .chords)
                chordChildren.append(node)
                members.append(i)
                var ignored: [Range<Int>] = []
                parsePostEvents(&chordChildren, &ignored, mode: mode)
                continue
            }
            let before = pos
            chordChildren += parseItem(t, mode: mode, context: .music)
            if pos == before { chordChildren.append(consume(t, as: .unknown)) }
        }
        closers.removeLast()
        chordDepth -= 1
        if let first = members.first, case .relative = frames[frames.count - 1].mode, mode != .chords {
            frames[frames.count - 1].chainRef = first
        }
        let chord = SyntaxNode(.chord, open.start..<pos, chordChildren)
        return finishEvent(kind: .chord, nodeKind: .event, start: open.start, children: [chord], notes: members, mode: mode)
    }

    private mutating func parseLyricEvent(_ t: Token) -> SyntaxNode {
        let word = text(t.start, t.end)
        let leafKind: SyntaxKind = t.kind == .string ? .string : .lyricWord
        if word == "--" || word == "__" { return consume(t, as: leafKind) }
        let head = consume(t, as: leafKind)
        return finishEvent(kind: .lyric, nodeKind: .lyricEvent, start: t.start, children: [head], notes: [], mode: .lyrics)
    }

    /// Duration, chord modifiers / tremolo, and post-events after an event head.
    private mutating func finishEvent(kind: MusicEvent.Kind, nodeKind: SyntaxKind, start: Int,
                                      children headChildren: [SyntaxNode], notes noteIndices: [Int],
                                      mode: LexMode, presetDuration: Range<Int>? = nil) -> SyntaxNode {
        var children = headChildren
        let insertion = presetDuration?.lowerBound ?? pos
        var durationRange = presetDuration
        if presetDuration == nil {
            let save = pos
            let trivia = collectTrivia(mode)
            if let t = lex(mode), let d = parseDuration(t) {
                children += trivia
                children.append(d)
                durationRange = d.range
            } else {
                pos = save
            }
        }
        if at(pos) == Ch.colon || (mode == .chords && at(pos) == Ch.slash) {
            let s = pos
            pos += 1
            if mode == .chords {
                while pos < b.count {
                    let c = b[pos]
                    if Lexer.isSpace(c) || c == Ch.openBrace || c == Ch.closeBrace || c == Ch.lt || c == Ch.gt
                        || c == Ch.quote || c == Ch.backslash || c == Ch.percent { break }
                    pos += 1
                }
                children.append(SyntaxNode(.chordModifier, s..<pos))
            } else {
                while pos < b.count, Lexer.isDigit(b[pos]) { pos += 1 }
                children.append(SyntaxNode(.tremolo, s..<pos))
            }
        }
        var postEvents: [Range<Int>] = []
        if mode != .lyrics { parsePostEvents(&children, &postEvents, mode: mode) }

        let explicit = durationRange.flatMap { DurationValue(text: text($0.lowerBound, $0.upperBound)) }
        if let explicit { defaultDuration = explicit }
        let frame = frames[frames.count - 1]
        events.append(MusicEvent(
            kind: kind, range: start..<pos, notes: noteIndices, duration: durationRange,
            explicitDuration: explicit, effectiveDuration: defaultDuration, durationInsertion: insertion,
            postEvents: postEvents, octaveMode: frame.mode, chainRefAfter: frame.chainRef,
            key: key, language: language, lexMode: mode))
        // Indices are final only now (nested items may have added events).
        for i in noteIndices { notes[i].event = events.count - 1 }
        lastEventEnd = pos
        return SyntaxNode(nodeKind, start..<pos, children)
    }

    private mutating func parseDuration(_ t: Token) -> SyntaxNode? {
        var children: [SyntaxNode]
        if t.kind == .number {
            guard let n = Int(text(t.start, t.end)), n > 0, n & (n - 1) == 0, n <= 1024 else { return nil }
            children = [consume(t, as: .number)]
        } else if t.kind == .command, KnownCommands.durationNames.contains(text(t.start + 1, t.end)) {
            children = [consume(t, as: .command)]
        } else {
            return nil
        }
        while at(pos) == Ch.dot {
            children.append(SyntaxNode(.dot, pos..<(pos + 1)))
            pos += 1
        }
        while at(pos) == Ch.star, Lexer.isDigit(at(pos + 1)) {
            children.append(SyntaxNode(.punctuation, pos..<(pos + 1)))
            pos += 1
            var s = pos
            while pos < b.count, Lexer.isDigit(b[pos]) { pos += 1 }
            children.append(SyntaxNode(.number, s..<pos))
            if at(pos) == Ch.slash, Lexer.isDigit(at(pos + 1)) {
                children.append(SyntaxNode(.punctuation, pos..<(pos + 1)))
                pos += 1
                s = pos
                while pos < b.count, Lexer.isDigit(b[pos]) { pos += 1 }
                children.append(SyntaxNode(.number, s..<pos))
            }
        }
        return SyntaxNode(.duration, t.start..<pos, children)
    }

    private mutating func parsePostEvents(_ children: inout [SyntaxNode], _ ranges: inout [Range<Int>], mode: LexMode) {
        while true {
            let save = pos
            let trivia = collectTrivia(mode)
            guard let t = lex(mode), let pe = parsePostEvent(t, mode: mode) else {
                pos = save
                return
            }
            children += trivia
            children.append(pe)
            ranges.append(pe.range)
        }
    }

    private mutating func parsePostEvent(_ t: Token, mode: LexMode) -> SyntaxNode? {
        switch t.kind {
        case .articulation, .openParen, .closeParen, .openBracket, .closeBracket, .tie:
            return SyntaxNode(.postEvent, t.start..<t.end, [consume(t, as: t.kind)])
        case .escapedPunct where KnownCommands.postEventPunct.contains(text(t.start, t.end)):
            var children = [consume(t, as: .escapedPunct)]
            // `\=2(` — a spanner id: \= takes a number or string.
            if text(t.start, t.end) == "\\=", let a = lex(mode), a.kind == .number || a.kind == .string {
                children.append(consume(a, as: a.kind))
            }
            return SyntaxNode(.postEvent, t.start..<pos, children)
        case .command:
            let name = text(t.start + 1, t.end)
            if KnownCommands.postEvents.contains(name) {
                return SyntaxNode(.postEvent, t.start..<t.end, [consume(t, as: .command)])
            }
            if KnownCommands.postEventsWithArgument.contains(name) {
                var children = [consume(t, as: .command)]
                children += collectTrivia(mode)
                if let a = lex(mode), let arg = parseArgument(a) { children.append(arg) }
                return SyntaxNode(.postEvent, t.start..<pos, children)
            }
            return nil
        case .direction:
            return parseDirectedPostEvent(t, mode: mode)
        default:
            return nil
        }
    }

    private mutating func parseArgument(_ t: Token) -> SyntaxNode? {
        switch t.kind {
        case .hash: return parseScheme()
        case .string, .number: return consume(t, as: t.kind)
        default: return nil
        }
    }

    private mutating func parseDirectedPostEvent(_ d: Token, mode: LexMode) -> SyntaxNode {
        var children = [consume(d, as: .direction)]
        if let t = lex(mode) {
            switch t.kind {
            case .number, .string:
                children.append(consume(t, as: t.kind))
            case .hash:
                children.append(parseScheme())
            case .escapedPunct, .openParen, .closeParen, .openBracket, .closeBracket, .tie:
                children.append(consume(t, as: t.kind))
            case .command:
                let name = text(t.start + 1, t.end)
                children.append(consume(t, as: .command))
                if KnownCommands.markupCommands.contains(name) {
                    children += parseInlineMarkup(mode)
                } else if name == "tweak" {
                    children += collectTrivia(mode)
                    if let p = lex(mode) {
                        if p.kind == .word { children.append(parsePropertyPath(p)) }
                        else if p.kind == .hash { children.append(parseScheme()) }
                    }
                    let save = pos
                    let trivia = collectTrivia(mode)
                    if let v = lex(mode), let arg = parseArgument(v) {
                        children += trivia
                        children.append(arg)
                    } else {
                        pos = save
                    }
                } else if KnownCommands.postEventsWithArgument.contains(name) {
                    let save = pos
                    let trivia = collectTrivia(mode)
                    if let a = lex(mode), let arg = parseArgument(a) {
                        children += trivia
                        children.append(arg)
                    } else {
                        pos = save
                    }
                }
            default:
                break
            }
        }
        return SyntaxNode(.postEvent, d.start..<pos, children)
    }

    /// `\markup` without braces: commands and Scheme arguments up to and
    /// including the first word, string or brace block.
    private mutating func parseInlineMarkup(_ mode: LexMode) -> [SyntaxNode] {
        var out: [SyntaxNode] = []
        st.inlineMarkup = true
        while st.inlineMarkup, let t = lex(mode) {
            if t.kind == .closeBrace || t.kind == .closeSimultaneous || t.kind == .embeddedClose || t.kind == .closeChord { break }
            // The markup has ended; the music after it is not part of this post-event.
            if t.kind == .word, isMusicWord(t, mode: mode) { break }
            let before = pos
            out += parseItem(t, mode: mode, context: .markup)
            if pos == before { break }
        }
        st.inlineMarkup = false
        return out
    }

    // MARK: - Scheme

    /// `#datum` or `$datum`. Scheme is opaque except for its extent and any
    /// embedded `#{ … #}` LilyPond, which is parsed as music.
    private mutating func parseScheme() -> SyntaxNode {
        let start = pos
        var children = [SyntaxNode(.hash, pos..<(pos + 1))]
        pos += 1
        var textStart = pos
        scanDatum(&children, &textStart)
        if pos > textStart { children.append(SyntaxNode(.schemeText, textStart..<pos)) }
        return SyntaxNode(.scheme, start..<pos, children)
    }

    private mutating func scanDatum(_ children: inout [SyntaxNode], _ textStart: inout Int) {
        while pos < b.count {
            let c = b[pos]
            if c == Ch.apostrophe || c == Ch.backquote { pos += 1 }
            else if c == Ch.comma { pos += at(pos + 1) == Ch.at ? 2 : 1 }
            else { break }
        }
        guard pos < b.count else { return }
        // #@ and $@ splice a list.
        if b[pos] == Ch.at, pos > 0, b[pos - 1] == Ch.hash || b[pos - 1] == UInt8(ascii: "$") { pos += 1 }
        guard pos < b.count else { return }
        let c = b[pos]
        if c == Ch.openParen { scanList(&children, &textStart); return }
        if c == Ch.quote { pos = lexer.stringEnd(from: pos); return }
        if c == Ch.hash {
            let n = at(pos + 1)
            if n == Ch.openBrace { embedded(&children, &textStart); return }
            if n == Ch.openParen { pos += 1; scanList(&children, &textStart); return }
            if n == Ch.backslash { scanCharLiteral(); return }
            pos += 1
            scanAtom()
            return
        }
        if Lexer.isSpace(c) { return }
        scanAtom()
    }

    private mutating func scanAtom() {
        while pos < b.count {
            let c = b[pos]
            if Lexer.isSpace(c) || c == Ch.openParen || c == Ch.closeParen || c == Ch.quote || c == Ch.semicolon
                || c == Ch.openBrace || c == Ch.closeBrace { break }
            pos += 1
        }
    }

    private mutating func scanCharLiteral() {
        pos = min(b.count, lexer.scalarEnd(from: pos + 2))
        while pos < b.count, Self.isAlnum(b[pos]) { pos += 1 }
    }

    private mutating func scanList(_ children: inout [SyntaxNode], _ textStart: inout Int) {
        var depth = 0
        while pos < b.count {
            let c = b[pos]
            switch c {
            case Ch.openParen:
                depth += 1
                pos += 1
            case Ch.closeParen:
                depth -= 1
                pos += 1
                if depth <= 0 { return }
            case Ch.quote:
                pos = lexer.stringEnd(from: pos)
            case Ch.semicolon:
                while pos < b.count, b[pos] != Ch.newline { pos += 1 }
            case Ch.hash:
                let n = at(pos + 1)
                if n == Ch.openBrace {
                    embedded(&children, &textStart)
                } else if n == Ch.pipe {
                    pos += 2
                    while pos < b.count, !(b[pos] == Ch.pipe && at(pos + 1) == Ch.hash) { pos += 1 }
                    pos = min(b.count, pos + 2)
                } else if n == Ch.backslash {
                    scanCharLiteral()
                } else {
                    pos += 1
                }
            default:
                pos += 1
            }
        }
    }

    private mutating func embedded(_ children: inout [SyntaxNode], _ textStart: inout Int) {
        if pos > textStart { children.append(SyntaxNode(.schemeText, textStart..<pos)) }
        let start = pos
        var inner = [SyntaxNode(.embeddedOpen, pos..<(pos + 2))]
        pos += 2
        let saved = st
        st = State()
        closers.append(.embedded)
        inner += parseSequence(mode: .notes, closer: .embedded, context: .music)
        closers.removeLast()
        if let t = lex(.notes), t.kind == .embeddedClose {
            inner.append(consume(t, as: .embeddedClose))
        } else {
            issues.append(start..<(start + 2))
        }
        st = saved
        children.append(SyntaxNode(.embeddedMusic, start..<pos, inner))
        textStart = pos
    }
}
