/// Expression text typed after `\` in the score view: dynamics and words,
/// separated by spaces, as one mark on the note.
///
/// | typed | written |
/// |---|---|
/// | `mf` | `\mf` |
/// | `pppppp` | `-#(make-dynamic-script "pppppp")` |
/// | `dolce` | `-#(make-dynamic-script (markup #:normal-text #:italic "dolce"))` |
/// | `mf dolce` | `-#(make-dynamic-script (markup #:dynamic "mf" #:normal-text #:italic "dolce"))` |
/// | `trill` | `\trill` (any LilyPond post-event command) |
///
/// Words are set in the expression font (italic, not bold) on the dynamics
/// line, so text and dynamics align with each other and with hairpins.
public enum Expression {
    public enum Element: Hashable, Sendable {
        case dynamic(String)
        case text(String)
    }

    /// Phrases offered as completions, most common first.
    public static let vocabulary: [String] = [
        "dolce", "espressivo", "cantabile", "legato", "leggiero", "sostenuto", "tranquillo", "agitato",
        "misterioso", "marcato", "pesante", "con fuoco", "con moto", "grazioso", "semplice", "delicato",
        "cresc.", "dim.", "decresc.", "subito", "sub.", "sempre", "molto", "poco", "poco a poco", "più", "meno",
        "sul pont.", "sul tasto", "ord.", "pizz.", "arco", "con sord.", "senza sord.", "col legno", "flautando",
        "rit.", "rall.", "accel.", "a tempo", "morendo", "smorzando", "perdendosi", "niente", "al niente",
    ]

    /// Dynamics LilyPond predefines (`\sfz`); others are drawn with the dynamic font.
    static let predefinedDynamics: Set<String> = [
        "ppppp", "pppp", "ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "ffff", "fffff",
        "fp", "sf", "sff", "sp", "spp", "sfz", "rfz",
    ]

    /// Any number of p's or f's, mp, mf, and LilyPond's sforzandi.
    public static func isDynamic(_ token: String) -> Bool {
        guard !token.isEmpty else { return false }
        if token.allSatisfy({ $0 == "p" }) || token.allSatisfy({ $0 == "f" }) { return true }
        return predefinedDynamics.contains(token)
    }

    /// Dynamics stay single; neighbouring words join into one phrase.
    public static func parse(_ input: String) -> [Element] {
        var out: [Element] = []
        for token in input.split(separator: " ").map(String.init) {
            if isDynamic(token) { out.append(.dynamic(token)); continue }
            if case .text(let words)? = out.last { out[out.count - 1] = .text(words + " " + token) }
            else { out.append(.text(token)) }
        }
        return out
    }

    /// A LilyPond command typed after `\` (`trill`, `fermata`), kept as itself.
    static func isCommand(_ input: String) -> Bool {
        guard !input.isEmpty, input.allSatisfy({ $0.isLetter && $0.isASCII }), !vocabulary.contains(input), !isDynamic(input) else { return false }
        return KnownCommands.postEvents.contains(input)
    }

    /// The post-event for what was typed after `\`, or nil when it is empty.
    /// `direction` is `^` or `_` when typed before the `\`.
    public static func postEvent(_ input: String, direction: Character? = nil) -> String? {
        let trimmed = input.split(separator: " ").joined(separator: " ")
        guard !trimmed.isEmpty else { return nil }
        let prefix = direction.map(String.init) ?? ""
        if isCommand(trimmed) || (predefinedDynamics.contains(trimmed)) { return prefix + "\\" + trimmed }
        let elements = parse(trimmed)
        let script: String
        if elements.count == 1, case .dynamic(let d) = elements[0] {
            script = quoted(d)
        } else {
            let parts = elements.map { e -> String in
                switch e {
                case .dynamic(let d): return "#:dynamic " + quoted(d)
                case .text(let t): return "#:normal-text #:italic " + quoted(t)
                }
            }
            script = "(markup " + parts.joined(separator: " ") + ")"
        }
        return (direction.map(String.init) ?? "-") + "#(make-dynamic-script " + script + ")"
    }

    /// Whether the post-event applies to every selected note (a single
    /// dynamic or command) rather than once, at the selection's start.
    public static func appliesToEach(_ input: String) -> Bool {
        let trimmed = input.split(separator: " ").joined(separator: " ")
        return isCommand(trimmed) || isDynamic(trimmed)
    }

    /// What Tab would add to complete the phrase being typed, or nil.
    public static func completion(for input: String) -> String? {
        guard let last = input.last, last != " " else { return nil }
        let chars = Array(input)
        // Word starts, longest suffix first: "poco a p" tries "poco a p", "a p", "p".
        var starts: [Int] = []
        for i in chars.indices where i == 0 || chars[i - 1] == " " { starts.append(i) }
        let lastWord = String(chars[starts.last!...])
        // A dynamic is complete on its own, unless it ends a longer phrase.
        for s in isDynamic(lastWord) ? starts.dropLast() : starts[...] {
            let typed = String(chars[s...]).lowercased()
            if let phrase = vocabulary.first(where: { $0.hasPrefix(typed) && $0 != typed }) {
                return String(phrase.dropFirst(typed.count))
            }
        }
        if starts.count == 1, !isDynamic(lastWord) {
            let typed = lastWord
            if let name = commandNames.first(where: { $0.hasPrefix(typed) && $0 != typed }) {
                return String(name.dropFirst(typed.count))
            }
        }
        return nil
    }

    /// Commands offered after the phrases, shortest first.
    static let commandNames: [String] = ScoreEditor.articulationNames
        .union(["fermata", "shortfermata", "longfermata", "verylongfermata", "arpeggio", "glissando", "startTrillSpan"])
        .subtracting(vocabulary)
        .sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for c in s {
            if c == "\\" || c == "\"" { out.append("\\") }
            out.append(c)
        }
        return out + "\""
    }

    /// Whether a post-event (without direction) is one `postEvent` writes.
    static func isScript(_ core: String) -> Bool { core.hasPrefix("#(make-dynamic-script") }

    /// What a post-event (without direction) shows as an expression: a
    /// dynamic command (`\\mf`) or a script `postEvent` wrote, read back.
    public static func elements(of core: String) -> [Element]? {
        if core.hasPrefix("\\"), predefinedDynamics.contains(String(core.dropFirst())) { return [.dynamic(String(core.dropFirst()))] }
        guard isScript(core) else { return nil }
        // Strings in order; one after `#:dynamic` (or a bare one that is a
        // dynamic) is a dynamic, the rest are words.
        var out: [Element] = []
        let chars = Array(core.dropFirst("#(make-dynamic-script".count))
        var i = 0
        var keyword = ""
        var sawMarkup = false
        while i < chars.count {
            let c = chars[i]
            if c == "#", i + 1 < chars.count, chars[i + 1] == ":" {
                var j = i + 2
                var word = ""
                while j < chars.count, !chars[j].isWhitespace, chars[j] != "\"" { word.append(chars[j]); j += 1 }
                keyword = word
                i = j
                continue
            }
            if c == "(" , String(chars[(i + 1)...].prefix(6)) == "markup" { sawMarkup = true }
            if c == "\"" {
                var j = i + 1
                var s = ""
                while j < chars.count, chars[j] != "\"" {
                    if chars[j] == "\\", j + 1 < chars.count { j += 1 }
                    s.append(chars[j]); j += 1
                }
                if keyword == "dynamic" || (!sawMarkup && isDynamic(s)) { out.append(.dynamic(s)) }
                else if case .text(let t)? = out.last { out[out.count - 1] = .text(t + " " + s) }
                else { out.append(.text(s)) }
                keyword = ""
                i = j + 1
                continue
            }
            i += 1
        }
        return out.isEmpty ? nil : out
    }

    /// The elements as one line of text: `mf dolce`.
    public static func display(_ elements: [Element]) -> String {
        elements.map { e -> String in
            switch e { case .dynamic(let d): d; case .text(let t): t }
        }.joined(separator: " ")
    }

    /// Whether a post-event (without direction) is a dynamic or an expression.
    public static func isExpression(_ core: String) -> Bool { elements(of: core) != nil }
}
