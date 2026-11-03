import PondsideCore

/// The legend as the canvas arranges it (DESIGN.md §11, "Arranging the
/// legend"): its rows found from the markers its markup leaves in the SVG,
/// the handles a drag can take, and what a drag writes, with snapping.
/// Portable so the geometry is tested without AppKit; the canvas only draws
/// what this returns and turns mouse events into `drag` calls.
public struct LegendArrangement: Sendable {
    /// One row of the table on a page.
    public struct Row: Sendable, Hashable {
        /// Its place among all the legend's rows (pages before count).
        public var index: Int
        /// From the table's left edge to the end of the meaning column.
        public var frame: Rect
        /// The example as shown (cropped and scaled); nil for `\null`.
        public var example: Rect?
        /// The whole example before cropping, where it would be.
        public var full: Rect?
        public var words: Rect?
    }

    /// A legend page.
    public struct Sheet: Sendable {
        public var page: Int
        public var rows: [Row]
        /// The line: left margin to right margin, over the rows.
        public var line: Rect
        public var viewBox: Rect
        /// Page units per millimetre.
        public var unitsPerMM: Double
        /// All rows' frames.
        public var table: Rect { rows.dropFirst().reduce(rows[0].frame) { $0.union($1.frame) } }

        /// The sheet as a committed drag leaves it, before the next engraving
        /// replaces the page: the baseline for another drag made while that
        /// engraving is still running.
        public func applying(_ outcome: Outcome) -> Sheet {
            /// A move applies to an element when it covers the element's
            /// whole width: the table covers every row, a row-gap covers one
            /// row's frame, a column drag covers the words, a scale the
            /// example. Their midpoints alone would confuse them.
            func transform(_ r: Rect) -> AffineTransform? {
                outcome.moves.first {
                    $0.region.contains(Point(r.minX, r.midY)) && $0.region.contains(Point(r.maxX, r.midY))
                }?.transform
            }
            func moved(_ r: Rect) -> Rect {
                transform(r).map { r.transformed(by: $0) } ?? r
            }
            var rows: [Row] = []
            for row in self.rows {
                var r = row
                r.frame = moved(row.frame)
                r.words = row.words.map(moved)
                let shown = row.example.map(moved)
                r.example = shown
                if let full = row.full {
                    // A cropped example is narrower than what the scale
                    // transform names; its shown part still says how it moved.
                    if let old = row.example, let t = transform(old) {
                        r.full = full.transformed(by: t)
                    } else {
                        r.full = moved(full)
                    }
                }
                if let e = shown {
                    var lo = e.minX, hi = e.maxX
                    for h in outcome.hidden where h.minY < e.maxY && h.maxY > e.minY {
                        if h.minX <= lo + 0.01, h.maxX > lo { lo = min(hi, h.maxX) }
                        if h.maxX >= hi - 0.01, h.minX < hi { hi = max(lo, h.minX) }
                    }
                    r.example = Rect(x: lo, y: e.y, width: hi - lo, height: e.height)
                }
                rows.append(r)
            }
            var sheet = self
            sheet.rows = rows
            return sheet
        }
    }

    public var sheets: [Sheet]

    /// The legend pages among `pages`, with their rows numbered across them.
    public init(pages: [EngravedPage]) {
        var sheets: [Sheet] = []
        var next = 0
        for (n, page) in pages.enumerated() where !page.markers.isEmpty {
            var rows: [Row] = []
            var line: Rect?
            var pending = Row(index: 0, frame: Rect(x: 0, y: 0, width: 0, height: 0))
            for m in page.markers {
                switch m.name {
                case "full": pending.full = m.rect
                case "example": pending.example = m.rect
                case "words": pending.words = m.rect
                case "row": pending.frame = m.rect
                case "line":
                    pending.index = next
                    next += 1
                    rows.append(pending)
                    line = line.map { $0.union(m.rect) } ?? m.rect
                    pending = Row(index: 0, frame: Rect(x: 0, y: 0, width: 0, height: 0))
                default: break
                }
            }
            guard let line, !rows.isEmpty, page.widthMM > 0 else { continue }
            sheets.append(Sheet(page: n, rows: rows, line: line, viewBox: page.viewBox,
                                unitsPerMM: page.viewBox.width / page.widthMM))
        }
        self.sheets = sheets
    }

    public func sheet(page: Int) -> Sheet? { sheets.first { $0.page == page } }

    // MARK: Handles

    public enum Handle: Hashable, Sendable {
        /// The whole table: x and top.
        case table
        /// The meaning column's left edge: the example column's width.
        case wordsLeft
        /// The meaning column's right edge: its width.
        case wordsRight
        /// The space under row `n` (the same under every row).
        case rowGap(Int)
        /// An example's left or right edge: its crop.
        case cropLeft(Int), cropRight(Int)
        /// An example's bottom-right corner: its scale (⌥: every example's).
        case scale(Int)

        /// What the pointer should look like over it.
        public var isHorizontalResize: Bool {
            switch self {
            case .wordsLeft, .wordsRight, .cropLeft, .cropRight: true
            default: false
            }
        }
    }

    /// The handle under `p` on `sheet`, nearest first: an example's corner,
    /// its edges, the meaning column's edges, the gap under a row, then the
    /// table itself.
    public func handle(at p: Point, on sheet: Sheet, tolerance t: Double) -> Handle? {
        for row in sheet.rows {
            guard let e = row.example else { continue }
            if abs(p.x - e.maxX) <= t * 1.5, abs(p.y - e.maxY) <= t * 1.5 { return .scale(row.index) }
        }
        for row in sheet.rows {
            guard let e = row.example, p.y >= e.minY - t, p.y <= e.maxY + t else { continue }
            if abs(p.x - e.minX) <= t { return .cropLeft(row.index) }
            if abs(p.x - e.maxX) <= t { return .cropRight(row.index) }
        }
        let table = sheet.table
        if p.y >= table.minY, p.y <= table.maxY {
            if let w = sheet.rows.compactMap(\.words).first {
                if abs(p.x - w.minX) <= t { return .wordsLeft }
            }
            if abs(p.x - table.maxX) <= t { return .wordsRight }
        }
        for (a, b) in zip(sheet.rows, sheet.rows.dropFirst()) where p.x >= table.minX && p.x <= table.maxX {
            if p.y > a.frame.maxY - t, p.y < b.frame.minY + t { return .rowGap(a.index) }
        }
        if let last = sheet.rows.last, p.x >= table.minX, p.x <= table.maxX,
           p.y > last.frame.maxY - t, p.y < last.frame.maxY + t { return .rowGap(last.index) }
        return table.insetBy(-t).contains(p) ? .table : nil
    }

    // MARK: Dragging

    /// A line the drag snapped to, across the page.
    public struct Guide: Hashable, Sendable {
        public enum Axis: Hashable, Sendable { case vertical, horizontal }
        public var axis: Axis
        /// x for a vertical guide, y for a horizontal one (page units).
        public var at: Double
    }

    /// Part of the page drawn moved while dragging, until the engraving lands.
    public struct Preview: Hashable, Sendable {
        public var region: Rect
        public var transform: AffineTransform
    }

    public struct Outcome: Sendable {
        public var layout: FrontMatter.LegendLayout
        /// A changed example: its row and its crop and scale.
        public var example: (row: Int, layout: FrontMatter.ExampleLayout)?
        public var guides: [Guide] = []
        public var moves: [Preview] = []
        /// Areas that the crop now hides.
        public var hidden: [Rect] = []
        /// Where the meaning column's right edge goes.
        public var marks: [Guide] = []
        /// A few words for the status bar ("x 12 mm · top 4 mm").
        public var summary: String = ""
    }

    /// Where the arrange overlay's frames go while a drag is previewed: the
    /// same moves as the music they frame (so a frame travels with its
    /// example, the table's with the table), and an example's frame shrunk
    /// to what its crop keeps.
    public struct Overlay: Sendable, Equatable {
        public var table: Rect
        /// The meaning column's left edge, as a rect (its x).
        public var words: Rect?
        /// By row index.
        public var examples: [Int: Rect]
    }

    public static func overlay(of sheet: Sheet, outcome: Outcome?) -> Overlay {
        let moves = outcome?.moves ?? [], hidden = outcome?.hidden ?? []
        func moved(_ r: Rect) -> Rect {
            let c = Point(r.midX, r.midY)
            guard let t = moves.first(where: { $0.region.contains(c) })?.transform else { return r }
            let xs = [r.x, r.x + r.width], ys = [r.y, r.y + r.height]
            let pts = xs.flatMap { x in ys.map { y in (t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f) } }
            let minX = pts.map(\.0).min()!, maxX = pts.map(\.0).max()!, minY = pts.map(\.1).min()!, maxY = pts.map(\.1).max()!
            return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        func cropped(_ e: Rect) -> Rect {
            var lo = e.x, hi = e.x + e.width
            for h in hidden where h.y < e.y + e.height && h.y + h.height > e.y {
                if h.x <= lo + 0.01, h.x + h.width > lo { lo = min(hi, h.x + h.width) }
                if h.x + h.width >= hi - 0.01, h.x < hi { hi = max(lo, h.x) }
            }
            return Rect(x: lo, y: e.y, width: hi - lo, height: e.height)
        }
        var examples: [Int: Rect] = [:]
        for row in sheet.rows { if let e = row.example { examples[row.index] = moved(cropped(e)) } }
        let words = sheet.rows.compactMap(\.words).first.map(moved)
        var table = moved(sheet.table)
        // Rows that moved inside a table that didn't (a row gap, a column):
        // the frame grows to keep them in it.
        for e in examples.values {
            let minX = min(table.x, e.x), minY = min(table.y, e.y)
            let maxX = max(table.x + table.width, e.x + e.width), maxY = max(table.y + table.height, e.y + e.height)
            table = Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        return Overlay(table: table, words: words, examples: examples)
    }

    /// What dragging `handle` from `start` to `to` makes of `layout` and the
    /// rows' `examples` (by row index). `snap` off when ⌘ is held; `all`
    /// (⌥) makes a scale drag the table's.
    public func drag(_ handle: Handle, on sheet: Sheet, from start: Point, to: Point,
                     layout: FrontMatter.LegendLayout, examples: [FrontMatter.ExampleLayout],
                     snap: Bool = true, all: Bool = false, threshold: Double) -> Outcome {
        var out = Outcome(layout: layout)
        let u = sheet.unitsPerMM
        var dx = to.x - start.x, dy = to.y - start.y
        let snapper = Snapper(sheet: sheet, threshold: snap ? threshold : 0)
        let table = sheet.table
        func row(_ i: Int) -> Row? { sheet.rows.first { $0.index == i } }
        func example(_ i: Int) -> FrontMatter.ExampleLayout { examples.indices.contains(i) ? examples[i] : .init() }

        switch handle {
        case .table:
            let moved = Rect(x: table.x + dx, y: table.y + dy, width: table.width, height: table.height)
            // Sides to the margins; the centre to the page's centre or thirds;
            // edges to other legend elements are its own, so none.
            if let s = snapper.x(edges: [moved.minX, moved.maxX], centres: [moved.midX]) {
                dx += s.delta
                out.guides.append(s.guide)
            }
            if let s = snapper.y(edges: [], centres: [moved.midY]) {
                dy += s.delta
                out.guides.append(s.guide)
            }
            out.layout.x = round(layout.x + dx / u)
            out.layout.top = max(0, round(layout.top + dy / u))
            dy = (out.layout.top - layout.top) * u
            dx = (out.layout.x - layout.x) * u
            out.moves = [Preview(region: table, transform: .translation(dx, dy))]
            out.summary = "Table: x \(FrontMatter.number(out.layout.x)) mm · top \(FrontMatter.number(out.layout.top)) mm"

        case .wordsLeft:
            guard let words = sheet.rows.compactMap(\.words).first else { break }
            let others = sheet.rows.compactMap(\.example).map(\.maxX)
            if let s = snapper.x(edges: [words.minX + dx], centres: [], also: others.map { $0 + layout.gap * u }) {
                dx += s.delta
                out.guides.append(s.guide)
            }
            out.layout.example = max(5, round(layout.example + dx / u))
            dx = (out.layout.example - layout.example) * u
            out.moves = sheet.rows.compactMap(\.words).map { Preview(region: $0, transform: .translation(dx, 0)) }
            if layout.text > 0 {
                out.marks = [Guide(axis: .vertical, at: table.maxX + dx)]
            }
            out.summary = "Example column \(FrontMatter.number(out.layout.example)) mm"

        case .wordsRight:
            let right = table.maxX + dx
            if let s = snapper.x(edges: [right], centres: []) {
                dx += s.delta
                out.guides.append(s.guide)
            }
            let left = sheet.rows.compactMap(\.words).first?.minX ?? table.minX
            let width = max(20, round((table.maxX + dx - left) / u))
            // At the right margin it runs to the margin (0), as by default.
            out.layout.text = abs(left + width * u - sheet.line.maxX) < u * 0.6 ? 0 : width
            out.marks = [Guide(axis: .vertical, at: out.layout.text == 0 ? sheet.line.maxX : left + width * u)]
            out.summary = out.layout.text == 0 ? "Meaning column to the right margin" : "Meaning column \(FrontMatter.number(width)) mm"

        case .rowGap(let n):
            // The row after this one follows the pointer; every gap is the same.
            let above = sheet.rows.filter { $0.index <= n }.count
            let gap = max(0, round2(layout.rowGap + dy / u / Double(max(1, above))))
            out.layout.rowGap = gap
            let d = (gap - layout.rowGap) * u
            out.moves = sheet.rows.enumerated().compactMap { k, r in
                k == 0 ? nil : Preview(region: r.frame, transform: .translation(0, d * Double(k)))
            }
            out.summary = "Space under each row \(FrontMatter.number(gap)) mm"

        case .cropLeft(let i), .cropRight(let i):
            guard let r = row(i), let shown = r.example, let full = r.full else { break }
            let left: Bool = if case .cropLeft = handle { true } else { false }
            var edge = (left ? shown.minX : shown.maxX) + dx
            let others = sheet.rows.filter { $0.index != i }.compactMap(\.example)
            if let s = snapper.x(edges: [edge], centres: [], also: others.flatMap { [$0.minX, $0.maxX] }, framing: false) {
                edge += s.delta
                out.guides.append(s.guide)
            }
            var ex = example(i)
            let scale = ex.scale * layout.scale
            // The full example in page units, where it is drawn now.
            let fullLeft = shown.minX - ex.left * u * scale
            let fullWidthMM = full.width / u / scale
            if left {
                ex.left = min(max(0, round2((edge - fullLeft) / u / scale)), fullWidthMM - ex.right - 2)
            } else {
                ex.right = min(max(0, round2((fullLeft + fullWidthMM * u * scale - edge) / u / scale)), fullWidthMM - ex.left - 2)
            }
            out.example = (i, ex)
            let a = fullLeft + ex.left * u * scale, b = fullLeft + (fullWidthMM - ex.right) * u * scale
            let band = Rect(x: fullLeft, y: shown.minY, width: fullWidthMM * u * scale, height: shown.height)
            if a > band.minX { out.hidden.append(Rect(x: band.minX, y: band.minY, width: a - band.minX, height: band.height)) }
            if b < band.maxX { out.hidden.append(Rect(x: b, y: band.minY, width: band.maxX - b, height: band.height)) }
            out.marks = [Guide(axis: .vertical, at: a), Guide(axis: .vertical, at: b)]
            out.summary = "Crop: \(FrontMatter.number(ex.left)) mm left · \(FrontMatter.number(ex.right)) mm right"

        case .scale(let i):
            guard let r = row(i), let shown = r.example, shown.width > 0 else { break }
            var right = shown.maxX + dx
            let others = sheet.rows.filter { $0.index != i }.compactMap(\.example).map(\.maxX)
            if let s = snapper.x(edges: [right], centres: [], also: others, framing: false) {
                right += s.delta
                out.guides.append(s.guide)
            }
            let f = max(0.2, (right - shown.minX) / shown.width)
            if all {
                out.layout.scale = round2(min(4, layout.scale * f))
                let g = out.layout.scale / layout.scale
                out.moves = sheet.rows.compactMap(\.example).map { Preview(region: $0, transform: Self.scaling(g, about: Point($0.minX, $0.midY))) }
                out.summary = "Every example × \(FrontMatter.number(out.layout.scale))"
            } else {
                var ex = example(i)
                ex.scale = round2(min(4, ex.scale * f))
                out.example = (i, ex)
                let g = ex.scale / example(i).scale
                out.moves = [Preview(region: shown, transform: Self.scaling(g, about: Point(shown.minX, shown.midY)))]
                out.summary = "Example × \(FrontMatter.number(ex.scale))"
            }
        }
        return out
    }

    static func scaling(_ s: Double, about p: Point) -> AffineTransform {
        AffineTransform(a: s, b: 0, c: 0, d: s, e: p.x - s * p.x, f: p.y - s * p.y)
    }

    private func round(_ v: Double) -> Double { (v * 2).rounded() / 2 }
    private func round2(_ v: Double) -> Double { (v * 100).rounded() / 100 }
}

/// The lines a dragged element snaps to: its sides to the margins, its centre
/// to the page's centre and thirds, and any edge to the other elements'.
struct Snapper {
    let sheet: LegendArrangement.Sheet
    let threshold: Double

    var marginLines: [Double] { [sheet.line.minX, sheet.line.maxX] }
    var centreLines: [Double] {
        let v = sheet.viewBox
        return [v.minX + v.width / 3, v.midX, v.minX + 2 * v.width / 3]
    }
    var middleLines: [Double] {
        let v = sheet.viewBox
        return [v.minY + v.height / 3, v.midY, v.minY + 2 * v.height / 3]
    }

    /// The smallest move that puts one of `edges` on a margin (or on one of
    /// `also`), or one of `centres` on the page's centre or a third.
    /// `framing` false: the edges snap to `also` only.
    func x(edges: [Double], centres: [Double], also: [Double] = [], framing: Bool = true)
        -> (delta: Double, guide: LegendArrangement.Guide)? {
        best(pairs: edges.map { ($0, (framing ? marginLines : []) + also) } + centres.map { ($0, centreLines) }, axis: .vertical)
    }

    func y(edges: [Double], centres: [Double], also: [Double] = []) -> (delta: Double, guide: LegendArrangement.Guide)? {
        best(pairs: edges.map { ($0, also) } + centres.map { ($0, middleLines) }, axis: .horizontal)
    }

    private func best(pairs: [(Double, [Double])], axis: LegendArrangement.Guide.Axis)
        -> (delta: Double, guide: LegendArrangement.Guide)? {
        guard threshold > 0 else { return nil }
        var found: (delta: Double, guide: LegendArrangement.Guide)?
        for (value, targets) in pairs {
            for t in targets where abs(t - value) <= threshold {
                if found == nil || abs(t - value) < abs(found!.delta) {
                    found = (t - value, .init(axis: axis, at: t))
                }
            }
        }
        return found
    }
}
