/// `front-matter.ily`: the cover, notes and legend printed before the
/// score, as `\bookpart`s the root includes before its first `\score`
/// (DESIGN.md §11). It is plain LilyPond the user can edit; Pondside finds
/// its parts by the `%% ---- cover` comment lines it writes and changes
/// them with minimal edits, as it does the score.
///
/// The cover reads the score's own `\header` (title, subtitle, composer,
/// dedication, instrumentation, duration, year), so it never repeats what
/// the root says. Legend items show real notation: each is a `\score` in
/// markup calling the same Lexicon entry the score uses.
public struct FrontMatter: Sendable {
    public enum Section: String, Sendable, CaseIterable, Identifiable {
        case cover, notes, legend
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .cover: "Cover Page"
            case .notes: "Notes"
            case .legend: "Legend"
            }
        }
    }

    public static let fileName = "front-matter.ily"
    public static let headerFields: [(key: String, label: String)] = [
        ("title", "Title"), ("subtitle", "Subtitle"), ("composer", "Composer"), ("dedication", "Dedication"),
        ("instrumentation", "Instrumentation"), ("duration", "Duration"), ("year", "Year"),
    ]

    public let text: String
    private let bytes: [UInt8]

    public init(_ text: String) {
        self.text = text
        bytes = Array(text.utf8)
    }

    // MARK: The file

    static let markerPrefix = "%% ---- "

    /// A new file with `sections`, in reading order.
    public static func template(_ sections: Set<Section>) -> String {
        preamble + Section.allCases.filter(sections.contains).map { "\n" + body(of: $0) }.joined()
    }

    static let preamble = """
    %% The pages before the score: cover, notes and legend. Pondside's Score
    %% Setup writes this file and finds its parts by the "%% ----" lines;
    %% everything else is yours to edit. The cover reads the score's \\header.

    % Paragraphs that flow from page to page.
    #(define-markup-list-command (pondside-paragraphs layout props paragraphs) (list?)
       (interpret-markup-list layout props
         (append-map (lambda (p)
                       (append (make-justified-lines-markup-list
                                (filter (lambda (w) (not (string-null? w))) (string-split p #\\space)))
                               (list (make-vspace-markup 0.8))))
                     paragraphs)))

    """ + legendDefinitions + """

    """

    /// The heading and the legend's machinery: its layout (`pondside-legend`
    /// in the legend's `\paper`), cropped and scaled examples, the markers
    /// the canvas arranges it by (SVG only) and the rows. Files written
    /// before the layout existed get it in place of their old definitions
    /// (`upgradeEdits`).
    static let legendDefinitions = """
    #(define-markup-command (pondside-heading layout props text) (string?)
       (let ((h (interpret-markup layout props
                  (make-column-markup (list (make-fill-line-markup (list (make-fontsize-markup 4 (make-bold-markup text))))
                                            (make-vspace-markup 1.5)))))
             (top (* (ly:output-def-lookup layout 'mm) (pondside-legend-get layout 'top 0))))
         (ly:make-stencil (ly:stencil-expr h) (ly:stencil-extent h X)
                          (let ((y (ly:stencil-extent h Y))) (cons (- (car y) top) (cdr y))))))

    % While a legend example is drawn, Pondside's timing listener ignores it.
    #(define pondside-in-example #f)

    % The legend's table, from its \\paper block's pondside-legend (in mm, and a
    % scale): x and top place it, example and text are its columns' widths
    % (text 0: to the right margin), gap the space between them, row-gap the
    % space under each row. Score Setup › Legend › Arrange on Page writes it.
    #(define (pondside-legend-get layout key default)
       (let ((v (assq key (ly:output-def-lookup layout 'pondside-legend '()))))
         (if (and v (number? (cdr v))) (cdr v) default)))

    % In SVG only (Pondside's canvas; never in a PDF): an invisible rectangle
    % naming a part of the legend, so it can be arranged on the page.
    #(define (pondside-mark name stil . extent)
       (if (eq? (ly:get-option 'backend) 'svg)
           (let ((x (if (pair? extent) (car extent) (ly:stencil-extent stil X)))
                 (y (if (pair? extent) (cadr extent) (ly:stencil-extent stil Y))))
             (if (or (interval-empty? x) (interval-empty? y) (ly:stencil-empty? stil)) stil
                 ; (a point inside the stencil: an empty one would be dropped)
                 (let ((at (lambda (a) (let ((e (ly:stencil-extent stil a))) (cons (car e) (car e))))))
                   (ly:stencil-add stil (ly:make-stencil (list 'url-link (string-append "pondside-legend:" name) x y)
                                                         (at X) (at Y))))))
           stil))

    % Shows only x0..x1 of a stencil: a clip in the PDF and on the canvas.
    #(define (pondside-clip stil x0 x1)
       (let* ((y (ly:stencil-extent stil Y))
              (y0 (- (car y) 4)) (y1 (+ (cdr y) 4))
              (backend (ly:get-option 'backend)))
         (ly:make-stencil
          (cond ((eq? backend 'svg)
                 (list 'output-attributes '((data-pondside-clip . "x"))
                       (list 'combine-stencil (list 'url-link "pondside-clip:" (cons x0 x1) (cons y0 y1))
                             (ly:stencil-expr stil))))
                ((eq? backend 'ps)
                 (list 'combine-stencil
                       (list 'embedded-ps (ly:format "gsave currentpoint exch ~4f add exch ~4f add ~4f ~4f rectclip\\n"
                                                     x0 y0 (- x1 x0) (- y1 y0)))
                       (ly:stencil-expr stil)
                       (list 'embedded-ps "grestore\\n")))
                (else (ly:stencil-expr stil)))
          (cons x0 x1) y)))

    % A legend example, cropped (left and right, mm of the example as engraved)
    % and scaled (times the table's scale).
    #(define-markup-command (pondside-example layout props opts example) (list? markup?)
       (let* ((mm (ly:output-def-lookup layout 'mm))
              (opt (lambda (k d) (let ((v (assq k opts))) (if (and v (number? (cdr v))) (cdr v) d))))
              (s (* (opt 'scale 1) (pondside-legend-get layout 'scale 1)))
              (drawn (dynamic-wind (lambda () (set! pondside-in-example #t))
                                   (lambda () (interpret-markup layout props example))
                                   (lambda () (set! pondside-in-example #f))))
              (x (ly:stencil-extent drawn X)))
         (if (or (interval-empty? x) (<= (interval-length x) 0)) drawn
             (let* ((x0 (min (cdr x) (+ (car x) (* mm (max 0 (opt 'left 0))))))
                    (x1 (max x0 (- (cdr x) (* mm (max 0 (opt 'right 0))))))
                    (cropped (if (and (= x0 (car x)) (= x1 (cdr x))) drawn (pondside-clip drawn x0 x1)))
                    (marked (pondside-mark "full" cropped x (ly:stencil-extent drawn Y)))
                    (placed (ly:stencil-scale (ly:stencil-translate-axis marked (- x0) X) s s)))
               (pondside-mark "example" placed)))))

    % A legend row: the example in the first column, its name and meaning in
    % the second, both centred on the row.
    #(define-markup-command (pondside-legend-item layout props title text example) (string? string? markup?)
       (let* ((mm (ly:output-def-lookup layout 'mm))
              (get (lambda (k d) (* mm (pondside-legend-get layout k d))))
              (line (chain-assoc-get 'line-width props (* 170 mm)))
              (x (get 'x 0))
              (words-x (+ x (get 'example 40) (get 'gap 7.5)))
              (width (let ((t (get 'text 0))) (if (> t 0) t (max (* 20 mm) (- line words-x)))))
              (drawn (interpret-markup layout props
                       (if (and (pair? example) (eq? (car example) pondside-example-markup))
                           example
                           (make-pondside-example-markup '() example))))
              (words (interpret-markup layout props
                       (make-override-markup (cons 'line-width width)
                         (make-column-markup (list (make-bold-markup title) (make-wordwrap-string-markup text))))))
              (row (ly:stencil-add (ly:stencil-translate-axis (ly:stencil-aligned-to drawn Y CENTER) x X)
                                   (ly:stencil-translate-axis (pondside-mark "words" (ly:stencil-aligned-to words Y CENTER)) words-x X)))
              (y (ly:stencil-extent row Y))
              (framed (pondside-mark "line" (pondside-mark "row" row (cons x (+ words-x width)) y) (cons 0 line) y))
              (gap (get 'row-gap 0)))
         (ly:make-stencil (ly:stencil-expr framed) (ly:stencil-extent framed X)
                          (if (interval-empty? y) y (cons (- (car y) gap) (cdr y))))))
    """

    static func body(of section: Section) -> String {
        switch section {
        case .cover:
            return """
            \(markerPrefix)cover
            \\bookpart {
              \\paper {
                print-page-number = ##f
                oddHeaderMarkup = ##f
                evenHeaderMarkup = ##f
                oddFooterMarkup = ##f
                evenFooterMarkup = ##f
                bookTitleMarkup = \\markup \\column {
                  \\vspace #10
                  \\fill-line { \\fontsize #8 \\bold \\fromproperty #'header:title }
                  \\vspace #1
                  \\fill-line { \\fontsize #3 \\fromproperty #'header:subtitle }
                  \\vspace #6
                  \\fill-line { \\fontsize #4 \\fromproperty #'header:composer }
                  \\vspace #2
                  \\fill-line { \\italic \\fromproperty #'header:dedication }
                  \\vspace #24
                  \\fill-line { \\fromproperty #'header:instrumentation }
                  \\fill-line { \\fromproperty #'header:duration }
                  \\fill-line { \\fromproperty #'header:year }
                }
              }
              \\markup \\null
            }

            """
        case .notes:
            return """
            \(markerPrefix)notes
            \\bookpart {
              \\paper { bookTitleMarkup = ##f }
              \\markup \\pondside-heading "Performance Notes"
              \\markuplist \\pondside-paragraphs #'(
              )
            }

            """
        case .legend:
            return """
            \(markerPrefix)legend
            \\bookpart {
              \\paper { bookTitleMarkup = ##f }
              \\markup \\pondside-heading "Legend"
            }

            """
        }
    }

    /// The bytes of each section: its marker line up to the next marker.
    public func range(of section: Section) -> Range<Int>? {
        let markers = self.markers
        guard let i = markers.firstIndex(where: { $0.section == section }) else { return nil }
        let end = i + 1 < markers.count ? markers[i + 1].offset : bytes.count
        return markers[i].offset..<end
    }

    public var sections: Set<Section> { Set(markers.compactMap(\.section)) }

    private var markers: [(section: Section?, offset: Int)] {
        var result: [(Section?, Int)] = []
        let prefix = Array(Self.markerPrefix.utf8)
        var line = 0
        while line < bytes.count {
            var end = line
            while end < bytes.count, bytes[end] != 0x0A { end += 1 }
            if end - line >= prefix.count, Array(bytes[line..<(line + prefix.count)]) == prefix {
                let name = String(decoding: bytes[(line + prefix.count)..<end], as: UTF8.self).trimmedSpaces
                result.append((Section(rawValue: name), line))
            }
            line = end + 1
        }
        return result
    }

    /// Adds a section in its place, or removes it.
    public func edits(section: Section, enabled: Bool) -> [TextEdit] {
        if !enabled { return range(of: section).map { [TextEdit($0, "")] } ?? [] }
        guard range(of: section) == nil else { return [] }
        // Before the first section that comes after it, else at the end.
        let later = Section.allCases.drop { $0 != section }.dropFirst()
        if let next = later.compactMap({ range(of: $0) }).first {
            return [.insert(Self.body(of: section) + "\n", at: next.lowerBound)]
        }
        let lead = bytes.isEmpty || bytes.last == 0x0A ? "\n" : "\n\n"
        return [.insert(lead + Self.body(of: section), at: bytes.count)]
    }

    // MARK: Strings

    public struct StringValue: Sendable, Hashable {
        public var value: String
        /// The literal, quotes included.
        public var range: Range<Int>
    }

    /// The string literal starting at or after `offset` (spaces skipped).
    func string(at offset: Int) -> StringValue? {
        var i = offset
        while i < bytes.count, bytes[i] == 0x20 || bytes[i] == 0x09 || bytes[i] == 0x0A { i += 1 }
        guard i < bytes.count, bytes[i] == 0x22 else { return nil }
        var j = i + 1
        var out: [UInt8] = []
        while j < bytes.count, bytes[j] != 0x22 {
            if bytes[j] == 0x5C, j + 1 < bytes.count { j += 1 }
            out.append(bytes[j])
            j += 1
        }
        guard j < bytes.count else { return nil }
        return StringValue(value: String(decoding: out, as: UTF8.self), range: i..<(j + 1))
    }

    func find(_ needle: String, in range: Range<Int>) -> Int? {
        let n = Array(needle.utf8)
        guard !n.isEmpty, range.count >= n.count else { return nil }
        var i = range.lowerBound
        while i + n.count <= range.upperBound {
            if bytes[i] == n[0], Array(bytes[i..<(i + n.count)]) == n { return i }
            i += 1
        }
        return nil
    }

    /// A string as LilyPond and Scheme both read it.
    public static func quoted(_ text: String) -> String { StaffSetup.quoted(text) }

    // MARK: Headings

    /// The heading of the notes or the legend.
    public func heading(_ section: Section) -> StringValue? {
        guard let r = range(of: section), let at = find("\\pondside-heading", in: r) else { return nil }
        return string(at: at + "\\pondside-heading".utf8.count)
    }

    public func edits(heading section: Section, to value: String) -> [TextEdit] {
        guard let h = heading(section), h.value != value else { return [] }
        return [TextEdit(h.range, Self.quoted(value))]
    }

    // MARK: Notes

    /// The notes' paragraphs, when they are the plain list Pondside writes;
    /// nil when the user has written other markup there.
    public var paragraphs: (values: [String], range: Range<Int>)? {
        guard let r = range(of: .notes), let at = find("\\pondside-paragraphs", in: r),
              let open = find("#'(", in: at..<r.upperBound) else { return nil }
        var values: [String] = []
        var i = open + 3
        while true {
            while i < r.upperBound, [0x20, 0x09, 0x0A].contains(bytes[i]) { i += 1 }
            guard i < r.upperBound else { return nil }
            if bytes[i] == 0x29 { return (values, (open + 3)..<i) }      // )
            guard let s = string(at: i) else { return nil }
            values.append(s.value)
            i = s.range.upperBound
        }
    }

    public func edits(paragraphs new: [String]) -> [TextEdit] {
        guard let (old, range) = paragraphs, old != new else { return [] }
        let body = new.filter { !$0.allSatisfy(\.isWhitespace) }.map { "\n    " + Self.quoted($0) }.joined() + "\n  "
        return [TextEdit(range, body)]
    }

    // MARK: Legend

    public struct LegendItem: Sendable, Hashable, Identifiable {
        /// The Lexicon entry, or a name of the user's own for other symbols.
        public var id: String
        public var title: StringValue?
        public var text: StringValue?
        /// From its `%% legend:` line to the next item or the bookpart's end.
        public var range: Range<Int>
        /// Its example's crop and scale (`\pondside-example #'(…)`).
        public var example: ExampleLayout = ExampleLayout()
        /// The `#'(…)` literal of those options, when written.
        public var exampleOptions: Range<Int>?
        /// Where the example markup starts (after the meaning).
        public var exampleStart: Int?
    }

    /// A legend example's crop (mm of the example as engraved, from each
    /// side) and its scale, times the table's.
    public struct ExampleLayout: Sendable, Hashable {
        public var left: Double = 0
        public var right: Double = 0
        public var scale: Double = 1
        public init(left: Double = 0, right: Double = 0, scale: Double = 1) {
            self.left = left
            self.right = right
            self.scale = scale
        }
        var alist: [(String, Double)] {
            var out: [(String, Double)] = []
            if left != 0 { out.append(("left", left)) }
            if right != 0 { out.append(("right", right)) }
            if scale != 1 { out.append(("scale", scale)) }
            return out
        }
    }

    /// The legend's table (`pondside-legend` in its `\paper`): where it sits
    /// from the left margin and below the heading, its columns, the space
    /// under each row (all mm) and the examples' scale.
    public struct LegendLayout: Sendable, Hashable {
        public var x: Double = 0
        public var top: Double = 0
        public var example: Double = 40
        public var gap: Double = 7.5
        /// The meaning column's width; 0 runs it to the right margin.
        public var text: Double = 0
        public var rowGap: Double = 4
        public var scale: Double = 1
        public init() {}

        static let keys = ["x", "top", "example", "gap", "text", "row-gap", "scale"]
        func value(_ key: String) -> Double {
            switch key {
            case "x": x
            case "top": top
            case "example": example
            case "gap": gap
            case "text": text
            case "row-gap": rowGap
            default: scale
            }
        }
        mutating func set(_ key: String, _ v: Double) {
            switch key {
            case "x": x = v
            case "top": top = v
            case "example": example = v
            case "gap": gap = v
            case "text": text = v
            case "row-gap": rowGap = v
            case "scale": scale = v
            default: break
            }
        }
        var literal: String { FrontMatter.alist(Self.keys.map { ($0, value($0)) }) }
    }

    static let layoutKey = "pondside-legend = "

    /// The legend's layout, when it has been arranged.
    public var legendLayout: LegendLayout? {
        guard let (pairs, _) = legendLayoutLiteral else { return nil }
        var layout = LegendLayout()
        for (k, v) in pairs { layout.set(k, v) }
        return layout
    }

    private var legendLayoutLiteral: (pairs: [(String, Double)], range: Range<Int>)? {
        guard let r = range(of: .legend), let at = find(Self.layoutKey, in: r) else { return nil }
        return alist(at: at + Self.layoutKey.utf8.count, limit: r.upperBound)
    }

    /// Writes the table's layout. The first time, it also brings the file's
    /// definitions up to date and drops the `\vspace` lines between rows,
    /// which row-gap replaces.
    public func edits(legendLayout layout: LegendLayout) -> [TextEdit] {
        guard let r = range(of: .legend) else { return [] }
        if let (_, range) = legendLayoutLiteral {
            let new = layout.literal
            return text(range) == new ? [] : [TextEdit(range, new)]
        }
        var edits = upgradeEdits
        // Into the legend's \paper block, else a new one after \bookpart {.
        if let paper = find("\\paper", in: r), let open = find("{", in: paper..<r.upperBound),
           let close = matchingBrace(open, limit: r.upperBound) {
            let inner = text((open + 1)..<close)
            if !inner.contains("\n") {
                // `\paper { bookTitleMarkup = ##f }` on one line: open it up.
                edits.append(TextEdit((open + 1)..<close,
                                      "\n    " + inner.trimmedSpaces + "\n    \(Self.layoutKey)\(layout.literal)\n  "))
            } else {
                var at = close
                while at > open, bytes[at - 1] == 0x20 || bytes[at - 1] == 0x09 { at -= 1 }
                edits.append(.insert("  \(Self.layoutKey)\(layout.literal)\n  ", at: at))
            }
        } else if let book = find("\\bookpart", in: r), let open = find("{", in: book..<r.upperBound) {
            edits.append(.insert("\n  \\paper { \(Self.layoutKey)\(layout.literal) }", at: open + 1))
        } else {
            return []
        }
        // The spacers between rows.
        let spacer = "\\markup \\vspace #1"
        var i = r.lowerBound
        while let at = find(spacer, in: i..<r.upperBound) {
            var start = at
            while start > r.lowerBound, bytes[start - 1] == 0x20 || bytes[start - 1] == 0x09 { start -= 1 }
            var end = at + spacer.utf8.count
            while end < r.upperBound, bytes[end] == 0x20 || bytes[end] == 0x09 { end += 1 }
            if start > r.lowerBound, bytes[start - 1] == 0x0A, end < r.upperBound, bytes[end] == 0x0A {
                edits.append(TextEdit(start..<(end + 1), ""))
            }
            i = end
        }
        return edits
    }

    /// Replaces definitions written before the legend could be arranged
    /// (from `pondside-heading` to the end of `pondside-legend-item`) with
    /// the current ones; nothing when they are current or not there.
    public var upgradeEdits: [TextEdit] {
        guard find("pondside-legend-get", in: 0..<bytes.count) == nil,
              let heading = find("#(define-markup-command (pondside-heading", in: 0..<bytes.count),
              let item = find("#(define-markup-command (pondside-legend-item", in: heading..<bytes.count),
              let end = matchingParen(item + 1, limit: bytes.count) else { return [] }
        return [TextEdit(heading..<(end + 1), Self.legendDefinitions)]
    }

    /// Writes one example's crop and scale: its `\pondside-example`
    /// options, or the wrapper when it has none yet.
    public func edits(legend id: String, example layout: ExampleLayout) -> [TextEdit] {
        guard let item = legendItems.first(where: { $0.id == id }) else { return [] }
        let literal = Self.alist(layout.alist)
        if let options = item.exampleOptions {
            return text(options) == literal ? [] : upgradeEdits + [TextEdit(options, literal)]
        }
        guard layout != ExampleLayout(), let at = item.exampleStart else { return [] }
        return upgradeEdits + [.insert("\\pondside-example \(literal) ", at: at)]
    }

    // MARK: Alists

    /// `#'((key . 1.5) …)`, numbers to two decimals.
    static func alist(_ pairs: [(String, Double)]) -> String {
        "#'(" + pairs.map { "(\($0.0) . \(number($0.1)))" }.joined(separator: " ") + ")"
    }

    public static func number(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if r == r.rounded() { return String(Int(r)) }
        return String(r)
    }

    /// The `#'(…)` alist of numbers at `offset` (`#'` included, spaces skipped).
    func alist(at offset: Int, limit: Int) -> (pairs: [(String, Double)], range: Range<Int>)? {
        var i = offset
        while i < limit, bytes[i] == 0x20 || bytes[i] == 0x09 { i += 1 }
        let start = i
        // #', and a doubled #'#' an earlier writer left (it's replaced whole).
        while i + 1 < limit, bytes[i] == 0x23, bytes[i + 1] == 0x27 { i += 2 }
        guard i < limit, bytes[i] == 0x28, let close = matchingParen(i, limit: limit) else { return nil }
        let inner = text((i + 1)..<close)
        var pairs: [(String, Double)] = []
        for part in inner.split(separator: "(") {
            // `x . 1.5)`: a key, a dot, a number.
            let words = (part.split(separator: ")").first ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            if words.count == 3, words[1] == ".", let v = Double(words[2]) { pairs.append((String(words[0]), v)) }
        }
        let range: Range<Int> = (bytes[start] == 0x23 ? start : i)..<(close + 1)
        return (pairs, range)
    }

    private func text(_ r: Range<Int>) -> String { String(decoding: bytes[r], as: UTF8.self) }

    /// The `)` closing the `(` at `open`, skipping strings and `;` comments.
    func matchingParen(_ open: Int, limit: Int) -> Int? {
        var depth = 0
        var i = open
        var inString = false
        while i < limit {
            let c = bytes[i]
            if inString {
                if c == 0x5C { i += 1 } else if c == 0x22 { inString = false }
            } else if c == 0x22 {
                inString = true
            } else if c == 0x3B {
                while i < limit, bytes[i] != 0x0A { i += 1 }
            } else if c == 0x28 {
                depth += 1
            } else if c == 0x29 {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    /// The `}` closing the `{` at `open`, skipping strings and `%` comments.
    func matchingBrace(_ open: Int, limit: Int) -> Int? {
        var depth = 0
        var i = open
        var inString = false
        while i < limit {
            let c = bytes[i]
            if inString {
                if c == 0x5C { i += 1 } else if c == 0x22 { inString = false }
            } else if c == 0x22 {
                inString = true
            } else if c == 0x25 {
                while i < limit, bytes[i] != 0x0A { i += 1 }
            } else if c == 0x7B {
                depth += 1
            } else if c == 0x7D {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    static let legendPrefix = "%% legend: "

    public var legendItems: [LegendItem] {
        guard let r = range(of: .legend), let close = sectionClose(r) else { return [] }
        var starts: [(id: String, offset: Int)] = []
        var i = r.lowerBound
        while let at = find(Self.legendPrefix, in: i..<close) {
            var end = at
            while end < close, bytes[end] != 0x0A { end += 1 }
            var lineStart = at
            while lineStart > r.lowerBound, bytes[lineStart - 1] == 0x20 || bytes[lineStart - 1] == 0x09 { lineStart -= 1 }
            let id = String(decoding: bytes[(at + Self.legendPrefix.utf8.count)..<end], as: UTF8.self).trimmedSpaces
            starts.append((id, lineStart))
            i = end
        }
        var closeLine = close
        while closeLine > r.lowerBound, bytes[closeLine - 1] == 0x20 || bytes[closeLine - 1] == 0x09 { closeLine -= 1 }
        return starts.enumerated().map { n, start in
            let end = n + 1 < starts.count ? starts[n + 1].offset : closeLine
            var item = LegendItem(id: start.id, title: nil, text: nil, range: start.offset..<end)
            if let at = find("\\pondside-legend-item", in: start.offset..<end),
               let title = string(at: at + "\\pondside-legend-item".utf8.count) {
                item.title = title
                item.text = string(at: title.range.upperBound)
                if let meaning = item.text {
                    var i = meaning.range.upperBound
                    while i < end, [0x20, 0x09, 0x0A].contains(bytes[i]) { i += 1 }
                    item.exampleStart = i
                    let wrapper = "\\pondside-example"
                    if i + wrapper.utf8.count <= end, text(i..<(i + wrapper.utf8.count)) == wrapper,
                       let (pairs, range) = alist(at: i + wrapper.utf8.count, limit: end) {
                        item.exampleOptions = range
                        for (k, v) in pairs {
                            switch k {
                            case "left": item.example.left = v
                            case "right": item.example.right = v
                            case "scale": item.example.scale = v
                            default: break
                            }
                        }
                    }
                }
            }
            return item
        }
    }

    /// The offset of the `}` that closes the section's `\bookpart`.
    private func sectionClose(_ r: Range<Int>) -> Int? {
        var i = r.upperBound
        while i > r.lowerBound {
            i -= 1
            if bytes[i] == 0x7D { return i }
        }
        return nil
    }

    /// What a new legend item says and shows.
    public struct NewLegendItem: Sendable, Hashable {
        public var id: String
        public var title: String
        public var text: String
        /// A markup: `\score { … }` for notation, `\null` for none.
        public var example: String

        public init(id: String, title: String, text: String, example: String) {
            self.id = id
            self.title = title
            self.text = text
            self.example = example
        }
    }

    /// Items appended at the end of the legend, which is added if missing.
    public func edits(adding items: [NewLegendItem]) -> [TextEdit] {
        guard !items.isEmpty else { return [] }
        // A laid-out legend spaces its rows itself (row-gap).
        let spacer = legendLayout == nil ? "  \\markup \\vspace #1\n" : ""
        let lines = items.map { item in
            "  \(Self.legendPrefix)\(item.id)\n  \\markup \\pondside-legend-item \(Self.quoted(item.title)) \(Self.quoted(item.text))\n    \(item.example)\n" + spacer
        }.joined()
        guard let r = range(of: .legend), let close = sectionClose(r) else {
            let added = FrontMatter(edits(section: .legend, enabled: true).apply(to: text))
            return EngravingSettingsDocument.span(from: bytes, to: Array(added.edits(adding: items).apply(to: added.text).utf8))
        }
        var at = close
        while at > r.lowerBound, bytes[at - 1] == 0x20 || bytes[at - 1] == 0x09 { at -= 1 }
        return [.insert(lines, at: at)]
    }

    public func edits(removingLegend id: String) -> [TextEdit] {
        legendItems.filter { $0.id == id }.map { TextEdit($0.range, "") }
    }

    public func edits(legend id: String, title: String? = nil, text: String? = nil) -> [TextEdit] {
        guard let item = legendItems.first(where: { $0.id == id }) else { return [] }
        var edits: [TextEdit] = []
        if let title, let t = item.title, t.value != title { edits.append(TextEdit(t.range, Self.quoted(title))) }
        if let text, let t = item.text, t.value != text { edits.append(TextEdit(t.range, Self.quoted(text))) }
        return edits
    }

    /// The legend example for a Lexicon graphic: two bars of a bare staff.
    public static func example(graphic id: String) -> String {
        "\\score { \\new Staff \\with { \\remove Time_signature_engraver \\remove Clef_engraver \\remove Bar_engraver } "
            + "{ s1\\startGraphic \(quoted(id)) #'() s2.. s16\\stopGraphic } "
            + "\\layout { indent = 0 ragged-right = ##f line-width = 40\\mm } }"
    }

    /// The legend example for any other entry: its example invocation.
    public static func example(music: String) -> String {
        "\\score { \\new Staff \\with { \\remove Time_signature_engraver } { \(music) } "
            + "\\layout { indent = 0 ragged-right = ##t line-width = 40\\mm } }"
    }

    // MARK: The root

    /// `\include "front-matter.ily"` in the root, before its first top-level
    /// `\score` (or `\book`/`\bookpart`), so the pages come first; nil when
    /// it is there already.
    public static func includeEdit(root: String) -> TextEdit? {
        let line = "\\include \"\(fileName)\""
        let tree = SyntaxTree(root)
        if tree.includes.contains(where: { $0.path == fileName }) { return nil }
        let b = Array(root.utf8)
        var depth = 0
        var found: Int?
        tree.root.forEachLeaf { leaf in
            guard found == nil else { return }
            switch leaf.kind {
            case .openBrace, .openSimultaneous: depth += 1
            case .closeBrace, .closeSimultaneous: depth -= 1
            case .command where depth == 0:
                let name = tree.string(leaf.range)
                if name == "\\score" || name == "\\book" || name == "\\bookpart" { found = leaf.range.lowerBound }
            default: break
            }
        }
        guard var at = found else {
            let lead = b.isEmpty || b.last == 0x0A ? "" : "\n"
            return .insert(lead + line + "\n", at: b.count)
        }
        while at > 0, b[at - 1] != 0x0A { at -= 1 }
        return .insert(line + "\n\n", at: at)
    }
}
