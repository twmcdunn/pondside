/// Score-wide engraving settings, as LilyPond spells them in `\paper`,
/// `\header` and `\layout`. The `.ly` file is where they live: the settings
/// dialog reads each statement from the blocks the score already has and
/// changes it with a minimal edit, as note editing does. Nothing is kept
/// anywhere else.
public enum EngravingValue: Sendable, Hashable {
    case bool(Bool)
    case choice(String)
    case number(Double)

    public var bool: Bool? { if case let .bool(b) = self { b } else { nil } }
    public var choice: String? { if case let .choice(c) = self { c } else { nil } }
    public var number: Double? { if case let .number(n) = self { n } else { nil } }
}

public struct EngravingChoice: Sendable, Hashable {
    public var value: String
    public var label: String

    public init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

public struct EngravingSetting: Sendable, Identifiable {
    /// The block a statement belongs in.
    public enum Location: Sendable, Hashable {
        case paper, header, layout
        /// `\context { \Score … }` (or `\Staff`) inside the score's `\layout`.
        case context(String)
    }

    public enum Kind: Sendable {
        case toggle
        case choice([EngravingChoice])
        case number(unit: String, range: ClosedRange<Double>, step: Double)
    }

    public let id: String
    public let group: String
    public let title: String
    public let help: String
    public let location: Location
    public let kind: Kind
    public let defaultValue: EngravingValue
    /// Statements this setting writes, by their opening words; the first is
    /// the one it writes, the rest are replaced or removed with it.
    public let keys: [String]
    /// Statements it only reads, e.g. a whole alist the user wrote.
    public let readKeys: [String]
    let render: @Sendable (EngravingValue) -> [String]
    let parse: @Sendable ([String: String]) -> EngravingValue?

    init(_ id: String, group: String, title: String, help: String, location: Location, kind: Kind,
         default defaultValue: EngravingValue, keys: [String], readKeys: [String] = [],
         render: @escaping @Sendable (EngravingValue) -> [String],
         parse: @escaping @Sendable ([String: String]) -> EngravingValue?) {
        self.id = id
        self.group = group
        self.title = title
        self.help = help
        self.location = location
        self.kind = kind
        self.defaultValue = defaultValue
        self.keys = keys
        self.readKeys = readKeys
        self.render = render
        self.parse = parse
    }

    /// The statements for `value`; none for the default, unless `explicit`
    /// (something elsewhere in the score sets it otherwise).
    public func statements(for value: EngravingValue, explicit: Bool = false) -> [String] {
        if value == defaultValue, !explicit { return [] }
        return render(value)
    }
}

// MARK: - The catalog

extension EngravingSetting {
    /// Every setting, in dialog order. Defaults are LilyPond's own (2.24 and 2.26).
    public static let all: [EngravingSetting] = page + systems + notes + accidentals + bars + tuplets + collections + text

    public static let groups: [String] = {
        var seen: [String] = []
        for s in all where !seen.contains(s.group) { seen.append(s.group) }
        return seen
    }()

    public static func named(_ id: String) -> EngravingSetting? { all.first { $0.id == id } }

    static let page: [EngravingSetting] = [
        EngravingSetting("paper.size", group: "Page", title: "Paper size",
                         help: "LilyPond's paper sizes; landscape turns the page.",
                         location: .paper, kind: .choice(paperSizes), default: .choice("a4"),
                         keys: ["#(set-paper-size"],
                         render: { ["#(set-paper-size \"\($0.choice ?? "a4")\")"] },
                         parse: { found in found["#(set-paper-size"].flatMap(paperSize) }),
        margin("paper.top", "Top margin", key: "top-margin", default: 10),
        margin("paper.bottom", "Bottom margin", key: "bottom-margin", default: 10),
        margin("paper.left", "Left margin", key: "left-margin", default: 15),
        margin("paper.right", "Right margin", key: "right-margin", default: 15),
        margin("paper.indent", "First system indent", key: "indent", default: 15,
               help: "Room for the instrument names on the first system."),
        margin("paper.shortIndent", "Later systems indent", key: "short-indent", default: 0,
               help: "Room for short instrument names on every later system."),
        toggle("paper.pageNumbers", group: "Page", "Page numbers", key: "print-page-number", default: true,
               location: .paper, help: "Number the pages."),
        toggle("paper.firstPageNumber", group: "Page", "Number the first page", key: "print-first-page-number",
               default: false, location: .paper, help: "LilyPond leaves the first page unnumbered by default."),
    ]

    static let systems: [EngravingSetting] = [
        EngravingSetting("layout.staffSize", group: "Staves & Systems", title: "Staff size",
                         help: "The height of a staff in points; 20 is LilyPond's default, 16–18 suits a full score.",
                         location: .layout, kind: .number(unit: "pt", range: 10...30, step: 0.5), default: .number(20),
                         keys: ["#(layout-set-staff-size"],
                         render: { ["#(layout-set-staff-size \(format($0.number ?? 20)))"] },
                         parse: { found in found["#(layout-set-staff-size"].flatMap { number(in: $0) }.map(EngravingValue.number) }),
        EngravingSetting("staff.distance", group: "Staves & Systems", title: "Distance between staves",
                         help: "In staff spaces, from one staff to the next within a system.",
                         location: .context("Staff"), kind: .number(unit: "spaces", range: 4...30, step: 0.5),
                         default: .number(9), keys: ["\\override VerticalAxisGroup.staff-staff-spacing.basic-distance"],
                         render: { ["\\override VerticalAxisGroup.staff-staff-spacing.basic-distance = #\(format($0.number ?? 9))"] },
                         parse: { found in
                             found["\\override VerticalAxisGroup.staff-staff-spacing.basic-distance"]
                                 .flatMap { value(of: $0).flatMap(number(in:)) }.map(EngravingValue.number)
                         }),
        EngravingSetting("paper.systemDistance", group: "Staves & Systems", title: "Distance between systems",
                         help: "In staff spaces; LilyPond stretches it to fill the page.",
                         location: .paper, kind: .number(unit: "spaces", range: 4...40, step: 0.5), default: .number(12),
                         keys: ["system-system-spacing.basic-distance"], readKeys: ["system-system-spacing"],
                         render: { ["system-system-spacing.basic-distance = #\(format($0.number ?? 12))"] },
                         parse: { found in
                             if let s = found["system-system-spacing.basic-distance"], let n = value(of: s).flatMap(number(in:)) {
                                 return .number(n)
                             }
                             return found["system-system-spacing"].flatMap { alistNumber("basic-distance", in: $0) }.map(EngravingValue.number)
                         }),
        toggle("paper.justify", group: "Staves & Systems", "Justify systems", key: "ragged-right", default: true,
               location: .paper, inverted: true, help: "Stretch every system to the full line width."),
        toggle("paper.justifyLast", group: "Staves & Systems", "Justify the last system", key: "ragged-last",
               default: false, location: .paper, inverted: true, help: "Stretch the final system too."),
        toggle("paper.fillPages", group: "Staves & Systems", "Fill pages to the bottom", key: "ragged-bottom",
               default: true, location: .paper, inverted: true, help: "Spread systems down each page."),
        toggle("paper.fillLastPage", group: "Staves & Systems", "Fill the last page to the bottom",
               key: "ragged-last-bottom", default: false, location: .paper, inverted: true,
               help: "Spread the systems of the last page too."),
    ]

    static let notes: [EngravingSetting] = [
        toggle("score.autoBeaming", group: "Notes & Beams", "Automatic beaming", key: "autoBeaming", default: true,
               help: "Beam by the meter. [ ] and \\noBeam still override it where you write them."),
        toggle("score.subdivideBeams", group: "Notes & Beams", "Subdivide beams", key: "subdivideBeams",
               default: false, help: "Break the inner beams of long groups at each beat."),
        EngravingSetting("score.noteSpacing", group: "Notes & Beams", title: "Note spacing",
                         help: "How much room each note value adds; LilyPond's default is 1.2.",
                         location: .context("Score"), kind: .number(unit: "", range: 0.6...3, step: 0.1), default: .number(1.2),
                         keys: ["\\override SpacingSpanner.spacing-increment"],
                         render: { ["\\override SpacingSpanner.spacing-increment = #\(format($0.number ?? 1.2))"] },
                         parse: { found in
                             found["\\override SpacingSpanner.spacing-increment"]
                                 .flatMap { value(of: $0).flatMap(number(in:)) }.map(EngravingValue.number)
                         }),
    ]

    static let accidentals: [EngravingSetting] = [
        EngravingSetting("score.accidentalStyle", group: "Accidentals", title: "Accidental style",
                         help: "When accidentals are repeated or cancelled (LilyPond's accidental styles).",
                         location: .context("Score"), kind: .choice(accidentalStyles), default: .choice("default"),
                         keys: ["\\accidentalStyle"],
                         render: { ["\\accidentalStyle \($0.choice ?? "default")"] },
                         parse: { found in
                             found["\\accidentalStyle"].map { s in
                                 let name = words(s).dropFirst().first ?? "default"
                                 // `Score.modern` written in music; the dialog's form has no context.
                                 return .choice(String(name.split(separator: ".").last ?? Substring(name)))
                             }
                         }),
        toggle("staff.keyCancellation", group: "Accidentals", "Cancel old key signatures", key: "printKeyCancellation",
               default: true, location: .context("Staff"), help: "Naturals for the old key at a key change."),
    ]

    static let bars: [EngravingSetting] = [
        EngravingSetting("staff.showTimeSignatures", group: "Meters & Bar Lines", title: "Show time signatures",
                         help: "Hide them to leave bars proportioned by their content; \\time still counts.",
                         location: .context("Staff"), kind: .toggle, default: .bool(true),
                         keys: ["\\omit TimeSignature"],
                         render: { $0.bool == false ? ["\\omit TimeSignature"] : [] },
                         parse: { found in found["\\omit TimeSignature"] != nil ? .bool(false) : nil }),
        EngravingSetting("staff.timeSignatureStyle", group: "Meters & Bar Lines", title: "Time signature style",
                         help: "C and ¢ for 4/4 and 2/2, or numbers always.",
                         location: .context("Staff"), kind: .choice([EngravingChoice("default", "C for 4/4 and 2/2"),
                                                                     EngravingChoice("numbered", "Numbers")]),
                         default: .choice("default"), keys: ["\\override TimeSignature.style"],
                         render: { ["\\override TimeSignature.style = #'\($0.choice ?? "numbered")"] },
                         parse: { found in
                             found["\\override TimeSignature.style"].flatMap(value(of:)).map {
                                 .choice($0.contains("numbered") ? "numbered" : "default")
                             }
                         }),
        EngravingSetting("score.barLines", group: "Meters & Bar Lines", title: "Bar lines",
                         help: "The line drawn at every bar; repeats and double bars are unaffected.",
                         location: .context("Score"), kind: .choice(barLineStyles), default: .choice("|"),
                         keys: ["measureBarType"],
                         render: { ["measureBarType = #\"\($0.choice ?? "|")\""] },
                         parse: { found in found["measureBarType"].flatMap(value(of:)).flatMap(stringLiteral).map(EngravingValue.choice) }),
        EngravingSetting("score.barNumbers", group: "Meters & Bar Lines", title: "Bar numbers",
                         help: "Where bar numbers appear.",
                         location: .context("Score"),
                         kind: .choice([EngravingChoice("system", "At the start of each system"),
                                        EngravingChoice("every", "Every bar"),
                                        EngravingChoice("none", "None")]),
                         default: .choice("system"),
                         keys: ["\\omit BarNumber", "barNumberVisibility", "\\override BarNumber.break-visibility"],
                         render: { value in
                             switch value.choice {
                             case "every": ["barNumberVisibility = #all-bar-numbers-visible",
                                            "\\override BarNumber.break-visibility = #end-of-line-invisible"]
                             case "none": ["\\omit BarNumber"]
                             default: []
                             }
                         },
                         parse: { found in
                             if found["\\omit BarNumber"] != nil { return .choice("none") }
                             if let v = found["barNumberVisibility"], v.contains("all-bar-numbers-visible") { return .choice("every") }
                             return nil
                         }),
        toggle("score.compressRests", group: "Meters & Bar Lines", "Compress empty bars", key: "skipBars",
               default: false, help: "Draw R1*8 as one multi-bar rest with its count."),
    ]

    /// `\collection` display (pondside-collections.ily, DESIGN.md §13): read
    /// from NoteHead details, so a staff can also set its own.
    static func collectionChoice(_ id: String, _ title: String, detail: String, help: String,
                                 choices: [EngravingChoice], default value: String) -> EngravingSetting {
        let key = "\\override NoteHead.details.collection-\(detail)"
        return EngravingSetting(id, group: "Collections", title: title, help: help, location: .context("Score"),
                                kind: .choice(choices), default: .choice(value), keys: [key],
                                render: { ["\(key) = #'\($0.choice ?? value)"] },
                                parse: { found in
                                    found[key].flatMap(EngravingSetting.value(of:)).flatMap { v in
                                        choices.first { v.contains($0.value) }.map { .choice($0.value) }
                                    }
                                })
    }

    static let collections: [EngravingSetting] = [
        collectionChoice("score.collectionHeads", "Noteheads", detail: "heads",
                         help: "Filled or white noteheads for the notes of a pitch collection.",
                         choices: [EngravingChoice("filled", "Filled"), EngravingChoice("hollow", "White")], default: "filled"),
        collectionChoice("score.collectionEnclosure", "Enclosure", detail: "enclosure",
                         help: "Around each collection: parentheses, brackets the height of the staff, or nothing.",
                         choices: [EngravingChoice("parentheses", "Parentheses"), EngravingChoice("brackets", "Brackets (whole staff)"),
                                   EngravingChoice("none", "None")], default: "parentheses"),
        collectionChoice("score.collectionLayout", "Layout", detail: "layout",
                         help: "The notes in a row, a fixed distance apart, or stacked as a chord.",
                         choices: [EngravingChoice("row", "In a row"), EngravingChoice("stacked", "Stacked")], default: "row"),
        EngravingSetting("score.collectionGap", group: "Collections", title: "Space between notes",
                         help: "In a row, the room between one note (and its accidental) and the next, in staff spaces.",
                         location: .context("Score"), kind: .number(unit: "spaces", range: 0.2...3, step: 0.1), default: .number(0.8),
                         keys: ["\\override NoteHead.details.collection-gap"],
                         render: { ["\\override NoteHead.details.collection-gap = #\(format($0.number ?? 0.8))"] },
                         parse: { found in
                             found["\\override NoteHead.details.collection-gap"]
                                 .flatMap { value(of: $0).flatMap(number(in:)) }.map(EngravingValue.number)
                         }),
    ]

    static let tuplets: [EngravingSetting] = [
        EngravingSetting("score.tupletBrackets", group: "Tuplets", title: "Tuplet brackets",
                         help: "Automatic leaves them off tuplets that are beamed.",
                         location: .context("Score"),
                         kind: .choice([EngravingChoice("if-no-beam", "Automatic"), EngravingChoice("always", "Always"),
                                        EngravingChoice("never", "Never (number only)")]),
                         default: .choice("if-no-beam"), keys: ["\\override TupletBracket.bracket-visibility"],
                         render: { value in
                             let scheme = ["always": "##t", "never": "##f"][value.choice ?? ""] ?? "#'if-no-beam"
                             return ["\\override TupletBracket.bracket-visibility = \(scheme)"]
                         },
                         parse: { found in
                             found["\\override TupletBracket.bracket-visibility"].flatMap(value(of:)).map { v in
                                 v == "##t" ? .choice("always") : v == "##f" ? .choice("never") : .choice("if-no-beam")
                             }
                         }),
        EngravingSetting("score.tupletNumbers", group: "Tuplets", title: "Tuplet numbers",
                         help: "3, or the full ratio 3:2.",
                         location: .context("Score"),
                         kind: .choice([EngravingChoice("number", "Number (3)"), EngravingChoice("ratio", "Ratio (3:2)")]),
                         default: .choice("number"), keys: ["\\override TupletNumber.text"],
                         render: { value in
                             value.choice == "ratio" ? ["\\override TupletNumber.text = #tuplet-number::calc-fraction-text"]
                                 : ["\\override TupletNumber.text = #tuplet-number::calc-denominator-text"]
                         },
                         parse: { found in
                             found["\\override TupletNumber.text"].map { .choice($0.contains("fraction") ? "ratio" : "number") }
                         }),
    ]

    static let text: [EngravingSetting] = [
        toggle("header.tagline", group: "Text", "LilyPond tagline", key: "tagline", default: true, location: .header,
               help: "“Music engraving by LilyPond” at the foot of the last page."),
    ]

    // MARK: Building blocks

    private static func toggle(_ id: String, group: String, _ title: String, key: String, default on: Bool,
                               location: Location = .context("Score"), inverted: Bool = false,
                               help: String) -> EngravingSetting {
        EngravingSetting(id, group: group, title: title, help: help, location: location, kind: .toggle,
                         default: .bool(on), keys: [key],
                         render: { value in
                             let flag = (value.bool ?? on) != inverted
                             return ["\(key) = \(flag ? "##t" : "##f")"]
                         },
                         parse: { found in
                             guard let statement = found[key], let v = value(of: statement) else { return nil }
                             guard v == "##t" || v == "##f" else { return nil }
                             return .bool((v == "##t") != inverted)
                         })
    }

    private static func margin(_ id: String, _ title: String, key: String, default mm: Double,
                               help: String = "") -> EngravingSetting {
        EngravingSetting(id, group: "Page", title: title, help: help, location: .paper,
                         kind: .number(unit: "mm", range: 0...80, step: 1), default: .number(mm), keys: [key],
                         render: { ["\(key) = \(format($0.number ?? mm))\\mm"] },
                         parse: { found in found[key].flatMap(value(of:)).flatMap(millimetres).map(EngravingValue.number) })
    }

    static let paperSizes: [EngravingChoice] = [
        EngravingChoice("a4", "A4"), EngravingChoice("a4landscape", "A4 landscape"),
        EngravingChoice("letter", "Letter"), EngravingChoice("letterlandscape", "Letter landscape"),
        EngravingChoice("a3", "A3"), EngravingChoice("a3landscape", "A3 landscape"),
        EngravingChoice("b4", "B4"), EngravingChoice("legal", "Legal"),
        EngravingChoice("tabloid", "Tabloid (11 × 17 in)"), EngravingChoice("a5", "A5"),
    ]

    static let accidentalStyles: [EngravingChoice] = [
        EngravingChoice("default", "Default (until the bar line)"),
        EngravingChoice("modern", "Modern (cancel in the next bar too)"),
        EngravingChoice("modern-cautionary", "Modern, cautionaries in parentheses"),
        EngravingChoice("neo-modern", "Neo-modern (repeat in the bar)"),
        EngravingChoice("dodecaphonic", "Dodecaphonic (on every note)"),
        EngravingChoice("piano", "Piano (across both staves)"),
        EngravingChoice("forget", "Forget (only against the key)"),
    ]

    static let barLineStyles: [EngravingChoice] = [
        EngravingChoice("|", "Normal"), EngravingChoice("!", "Dashed"), EngravingChoice(";", "Dotted"),
        EngravingChoice("'", "Tick"), EngravingChoice("", "Hidden"),
    ]

    // MARK: Reading values

    /// What follows `=` in `name = value`.
    static func value(of statement: String) -> String? {
        guard let eq = statement.firstIndex(of: "=") else { return nil }
        let v = statement[statement.index(after: eq)...].trimmedSpaces
        return v.isEmpty ? nil : v
    }

    /// The first number in `text` (`#16`, `12`, `-0.5`).
    static func number(in text: String) -> Double? {
        var digits = ""
        var started = false
        for c in text {
            if c.isNumber || c == "." || (c == "-" && !started) {
                digits.append(c)
                started = started || c.isNumber
            } else if started {
                break
            } else {
                digits = ""
            }
        }
        return Double(digits)
    }

    /// `12\mm`, `1.5\cm`, `0.5\in`, `20\pt` → millimetres.
    static func millimetres(_ text: String) -> Double? {
        guard let n = number(in: text) else { return nil }
        if text.contains("\\cm") { return n * 10 }
        if text.contains("\\in") { return n * 25.4 }
        if text.contains("\\pt") { return n * 25.4 / 72.27 }
        return n
    }

    static func alistNumber(_ key: String, in text: String) -> Double? {
        guard let range = text.firstRange(of: "(\(key)") else { return nil }
        return number(in: String(text[range.upperBound...].drop { $0 == " " || $0 == "." }))
    }

    static func stringLiteral(_ text: String) -> String? {
        guard let open = text.firstIndex(of: "\""), let close = text[text.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return String(text[text.index(after: open)..<close])
    }

    /// `#(set-paper-size "a4")`, `"a4landscape"` or `"a4" 'landscape`.
    static func paperSize(_ statement: String) -> EngravingValue? {
        guard let name = stringLiteral(statement) else { return nil }
        let landscape = statement.contains("'landscape") && !name.hasSuffix("landscape")
        return .choice(name + (landscape ? "landscape" : ""))
    }

    static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// `12`, not `12.0`; one decimal place where needed.
    static func format(_ value: Double) -> String {
        let tenths = (value * 10).rounded()
        if tenths.truncatingRemainder(dividingBy: 10) == 0 { return String(Int(tenths / 10)) }
        return String(Int(tenths) / 10) + "." + String(abs(Int(tenths)) % 10)
    }
}

extension EngravingSetting {
    /// Marks a header value that is not a plain string (shown, not rewritten).
    static let rawMarker = "\u{1}"

    /// A `\header` text field (`title = "…"`), not shown in the settings panel.
    static func headerText(_ key: String) -> EngravingSetting {
        EngravingSetting("header.\(key)", group: "Header", title: key, help: "", location: .header, kind: .choice([]),
                         default: .choice(""), keys: [key],
                         render: { ["\(key) = \(StaffSetup.quoted($0.choice ?? ""))"] },
                         parse: { found in
                             guard let s = found[key], let eq = s.firstIndex(of: "=") else { return nil }
                             let v = s[s.index(after: eq)...].trimmedSpaces
                             if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\""), !v.dropFirst().dropLast().contains("\"") {
                                 return .choice(unescape(String(v.dropFirst().dropLast())))
                             }
                             return .choice(rawMarker + v)
                         })
    }

    static func unescape(_ s: String) -> String {
        var out = ""
        var escaped = false
        for c in s {
            if escaped { out.append(c); escaped = false } else if c == "\\" { escaped = true } else { out.append(c) }
        }
        return out
    }
}

extension StringProtocol {
    var trimmedSpaces: String {
        let s = drop { $0 == " " || $0 == "\t" }
        var end = s.endIndex
        while end > s.startIndex, s[s.index(before: end)] == " " || s[s.index(before: end)] == "\t" {
            end = s.index(before: end)
        }
        return String(s[..<end])
    }
}
