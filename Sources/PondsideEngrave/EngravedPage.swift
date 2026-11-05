import Foundation
import PondsideCore

/// An RGBA colour with components in 0...1.
public struct RGBA: Hashable, Sendable, Codable {
    public var r, g, b, a: Double

    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    public static let black = RGBA(0, 0, 0)
    public static let white = RGBA(1, 1, 1)
}

public struct StrokeStyle: Hashable, Sendable {
    public enum Cap: String, Sendable { case butt, round, square }
    public enum Join: String, Sendable { case miter, round, bevel }

    public var width: Double
    public var cap: Cap
    public var join: Join
    public var dash: [Double]

    public init(width: Double, cap: Cap = .butt, join: Join = .miter, dash: [Double] = []) {
        self.width = width
        self.cap = cap
        self.join = join
        self.dash = dash
    }
}

public struct TextRun: Hashable, Sendable {
    public enum Anchor: String, Sendable { case start, middle, end }

    public var string: String
    /// Maps text space (origin at the baseline start, y down) to page space.
    public var transform: AffineTransform
    public var fontFamily: String
    public var fontSize: Double
    public var bold: Bool
    public var italic: Bool
    public var anchor: Anchor
    public var color: RGBA
}

/// One drawable element of an engraved page, in page (viewBox) coordinates.
public struct Graphic: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case path(VectorPath, fill: RGBA?, stroke: RGBA?, style: StrokeStyle)
        case text(TextRun)
    }

    public var content: Content
    /// Approximate bounds in page coordinates, for hit-testing and culling.
    public var bounds: Rect
    /// Source location, when the grob was compiled with point-and-click.
    public var link: PointAndClickLocation?
    /// Only this part of it shows (a cropped legend example); `bounds` is
    /// already within it.
    public var clip: Rect?

    public init(content: Content, bounds: Rect, link: PointAndClickLocation? = nil, clip: Rect? = nil) {
        self.content = content
        self.bounds = bounds
        self.link = link
        self.clip = clip
    }
}

extension Graphic {
    /// Whether `point` lies on what is drawn: inside a filled shape, or
    /// within `tolerance` (plus half the stroke) of its outline. Text is
    /// its bounds.
    public func shapeContains(_ point: Point, tolerance: Double) -> Bool {
        guard case .path(let path, let fill, let stroke, let style) = content else {
            return bounds.insetBy(-tolerance).contains(point)
        }
        let polygons = path.flattened()
        if fill != nil, polygons.contains(where: { Self.encloses($0, point) }) { return true }
        let reach = tolerance + (stroke != nil ? style.width / 2 : 0)
        for poly in polygons {
            for (a, b) in zip(poly, poly.dropFirst() + [poly[0]]) where Self.distance(point, a, b) <= reach {
                return true
            }
        }
        return false
    }

    private static func encloses(_ poly: [Point], _ p: Point) -> Bool {
        var inside = false
        var j = poly.count - 1
        for i in poly.indices {
            let a = poly[i], b = poly[j]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func distance(_ p: Point, _ a: Point, _ b: Point) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length == 0 ? 0 : max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        let x = a.x + t * dx - p.x, y = a.y + t * dy - p.y
        return (x * x + y * y).squareRoot()
    }
}

extension VectorPath {
    /// The path as polygons, one per subpath, curves sampled finely enough
    /// for hit-testing.
    public func flattened(segments: Int = 12) -> [[Point]] {
        var out: [[Point]] = []
        var current: [Point] = []
        func finish() { if current.count > 1 { out.append(current) }; current = [] }
        for element in elements {
            let from = current.last ?? .zero
            switch element {
            case .move(let p):
                finish()
                current = [p]
            case .line(let p):
                current.append(p)
            case .quad(let c, let p):
                for i in 1...segments {
                    let t = Double(i) / Double(segments), u = 1 - t
                    current.append(Point(u * u * from.x + 2 * u * t * c.x + t * t * p.x,
                                         u * u * from.y + 2 * u * t * c.y + t * t * p.y))
                }
            case .cubic(let c1, let c2, let p):
                for i in 1...segments {
                    let t = Double(i) / Double(segments), u = 1 - t
                    let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
                    current.append(Point(a * from.x + b * c1.x + c * c2.x + d * p.x,
                                         a * from.y + b * c1.y + c * c2.y + d * p.y))
                }
            case .close:
                // Polygons are taken as closed; drawing goes on from the start.
                let start = current.first
                finish()
                if let start { current = [start] }
            }
        }
        finish()
        return out
    }
}

/// An invisible named rectangle a front-matter markup leaves in the SVG
/// (`pondside-legend:<name>` links): where a part of the legend is, so the
/// canvas can arrange it. In document order.
public struct PageMarker: Hashable, Sendable {
    public var name: String
    public var rect: Rect
    public init(name: String, rect: Rect) {
        self.name = name
        self.rect = rect
    }
}

/// A page of engraved music, parsed from LilyPond's SVG output.
///
/// The page model is deliberately renderer-agnostic: the UI draws it with
/// Core Graphics, tests inspect it, and nothing here knows about AppKit.
/// Music is never recoloured — colours are exactly those in the SVG.
public struct EngravedPage: Sendable {
    /// Paper size in millimetres.
    public var widthMM: Double
    public var heightMM: Double
    /// The page's coordinate system (LilyPond uses staff-space-like units).
    public var viewBox: Rect
    public var graphics: [Graphic]
    /// Elements the parser recognised but cannot draw yet (e.g. `<image>`).
    public var unsupportedElements: [String]
    /// The legend's parts, when this is a legend page.
    public var markers: [PageMarker] = []

    /// Every linked graphic, keyed by source line, sorted by character.
    private var linkIndex: [Int: [(character: Int, graphic: Int)]] = [:]

    public init(widthMM: Double, heightMM: Double, viewBox: Rect, graphics: [Graphic], unsupportedElements: [String] = []) {
        self.widthMM = widthMM
        self.heightMM = heightMM
        self.viewBox = viewBox
        self.graphics = graphics
        self.unsupportedElements = unsupportedElements
        var index: [Int: [(character: Int, graphic: Int)]] = [:]
        for (i, g) in graphics.enumerated() {
            guard let link = g.link else { continue }
            index[link.line, default: []].append((link.character, i))
        }
        for key in index.keys { index[key]!.sort { $0.character < $1.character } }
        linkIndex = index
    }

    /// The linked graphic under `point` (page coordinates). When several
    /// overlap, the smallest wins, so a notehead beats the slur over it.
    /// Graphics whose link passes `byOutline` (a slur) are hit only on their
    /// drawn shape, not anywhere in their bounding box: a click on the
    /// empty staff under a slur still means the staff.
    public func hitTest(_ point: Point, tolerance: Double = 0.25,
                        excluding removed: Set<Graphic> = [],
                        byOutline: (PointAndClickLocation) -> Bool = { _ in false }) -> Graphic? {
        var best: Graphic?
        for g in graphics where g.link != nil && !removed.contains(g) {
            guard g.bounds.insetBy(-tolerance).contains(point) else { continue }
            if byOutline(g.link!), !g.shapeContains(point, tolerance: tolerance) { continue }
            if best == nil || g.bounds.area < best!.bounds.area { best = g }
        }
        return best
    }

    /// Linked graphics whose bounds intersect `rect`.
    public func linkedGraphics(in rect: Rect, excluding removed: Set<Graphic> = []) -> [Graphic] {
        graphics.filter { $0.link != nil && !removed.contains($0) && $0.bounds.intersects(rect) }
    }

    /// Graphics produced by the token at exactly this source position.
    public func linkedGraphics(at position: SourcePosition, path: String? = nil) -> [Graphic] {
        guard let entries = linkIndex[position.line] else { return [] }
        return entries.filter { $0.character == position.character }
            .map { graphics[$0.graphic] }
            .filter { path == nil || $0.link?.path == path }
    }

    /// The source positions on `line` that produced graphics, ascending.
    public func linkedPositions(onLine line: Int) -> [Int] {
        var out: [Int] = []
        for e in linkIndex[line] ?? [] where out.last != e.character { out.append(e.character) }
        return out
    }

    /// Union of the bounds of the given graphics.
    public static func bounds(of graphics: [Graphic]) -> Rect? {
        guard var r = graphics.first?.bounds else { return nil }
        for g in graphics.dropFirst() { r = r.union(g.bounds) }
        return r
    }

    /// Where a drawing made of many small parts (a grain cloud, a
    /// hand-drawn texture) lies: the parts' bounds merged wherever they are
    /// less than `gap` apart vertically, so a spanner broken across systems
    /// gives one region per system rather than one box over the music
    /// between.
    /// How far apart (in staff spaces) parts of one drawing may be and
    /// still read as one shape.
    public static let clusterGap = 3.0

    public static func regions(of graphics: [Graphic], gap: Double = 2.5) -> [Rect] {
        var out: [Rect] = []
        for r in graphics.map(\.bounds).sorted(by: { $0.y < $1.y }) {
            if let last = out.last, r.minY <= last.maxY + gap {
                out[out.count - 1] = last.union(r)
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// The parts of one drawing grouped into what reads as one shape:
    /// parts closer than `gap` in both directions join (a grain cloud's
    /// dots), so the separate bursts of one spanner, or its pieces on
    /// different systems, are separate rectangles.
    public static func clusters(of graphics: [Graphic], gap: Double) -> [Rect] {
        let rects = graphics.map(\.bounds)
        guard rects.count > 1, gap > 0 else { return rects }
        // A grid of half-gap cells: parts in one cell join, and occupied
        // neighbouring cells join, so parts about a gap apart or closer are
        // one shape. Linear in the parts, which matters for a texture of
        // ten thousand dots.
        let cell = gap / 2
        var parent: [Int] = []
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func join(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[ra] = rb } }
        struct Cell: Hashable { var x: Int, y: Int }
        var owner: [Cell: Int] = [:]   // a cell's set (an index into parent)
        var partSet: [Int] = []
        for r in rects {
            let x0 = Int((r.minX / cell).rounded(.down)), x1 = Int((r.maxX / cell).rounded(.down))
            let y0 = Int((r.minY / cell).rounded(.down)), y1 = Int((r.maxY / cell).rounded(.down))
            var mine: Int?
            // A long part (a line) covers many cells; cap the walk, its ends join.
            let xs = x1 - x0 > 64 ? [x0, x1] : Array(x0...x1), ys = y1 - y0 > 64 ? [y0, y1] : Array(y0...y1)
            for x in xs { for y in ys {
                let c = Cell(x: x, y: y)
                if let o = owner[c] {
                    if let m = mine { join(m, o) } else { mine = o }
                } else {
                    if mine == nil { mine = parent.count; parent.append(parent.count) }
                    owner[c] = mine
                }
            } }
            partSet.append(mine!)
        }
        for (c, o) in owner {
            for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
                if let n = owner[Cell(x: c.x + dx, y: c.y + dy)] { join(o, n) }
            } }
        }
        var out: [Int: Rect] = [:]
        for (i, r) in rects.enumerated() { let root = find(partSet[i]); out[root] = out[root].map { $0.union(r) } ?? r }
        return out.values.sorted { ($0.minY, $0.minX) < ($1.minY, $1.minX) }
    }

    /// The linked drawing whose region holds `point`, for a click that
    /// landed between its parts (the gaps in a texture); the smallest
    /// region wins, so a drawing inside another is still reachable.
    public func regionHit(_ point: Point, excluding removed: Set<Graphic> = [],
                          byOutline: (PointAndClickLocation) -> Bool = { _ in false }) -> Graphic? {
        var groups: [PointAndClickLocation: [Graphic]] = [:]
        for g in graphics where g.link != nil && !removed.contains(g) && !byOutline(g.link!) {
            groups[g.link!, default: []].append(g)
        }
        let gap = Self.clusterGap * (staves.first?.space ?? 1)
        var best: (graphic: Graphic, area: Double)?
        for parts in groups.values where parts.count > 1 {
            // Only drawings that reach the click are worth grouping.
            guard let whole = Self.bounds(of: parts), whole.insetBy(-gap).contains(point) else { continue }
            for r in Self.clusters(of: parts, gap: gap) where r.contains(point) {
                if best == nil || r.area < best!.area { best = (parts[0], r.area) }
            }
        }
        return best?.graphic
    }
}

// MARK: - SVG parsing

extension EngravedPage {
    public init(svg data: Data) {
        self.init(svgBytes: [UInt8](data))
    }

    public init(svg string: String) {
        self.init(svgBytes: Array(string.utf8))
    }

    init(svgBytes: [UInt8]) {
        var builder = SVGSceneBuilder()
        var tokenizer = XMLTokenizer(svgBytes)
        while let token = tokenizer.next() { builder.consume(token) }
        self.init(widthMM: builder.widthMM, heightMM: builder.heightMM, viewBox: builder.viewBox,
                  graphics: builder.graphics, unsupportedElements: builder.unsupported)
        markers = builder.markers
    }
}

/// Inherited presentation state while walking the SVG tree.
private struct SVGState {
    var transform = AffineTransform.identity
    var color = RGBA.black
    var fill: Paint = .color(.black)
    var stroke: Paint = .none
    var strokeWidth = 1.0
    var cap = StrokeStyle.Cap.butt
    var join = StrokeStyle.Join.miter
    var dash: [Double] = []
    var link: PointAndClickLocation?
    /// Inside `<a xlink:href="pondside-…">`: its rect is a marker, not ink.
    var marker: String?
    var fontFamily = "serif"
    var fontSize = 16.0
    var bold = false
    var italic = false
    var anchor = TextRun.Anchor.start
}

private enum Paint {
    case none
    case currentColor
    case color(RGBA)

    func resolve(_ current: RGBA) -> RGBA? {
        switch self {
        case .none: return nil
        case .currentColor: return current
        case .color(let c): return c
        }
    }
}

private struct SVGSceneBuilder {
    var widthMM = 210.0
    var heightMM = 297.0
    var viewBox = Rect(x: 0, y: 0, width: 210, height: 297)
    var graphics: [Graphic] = []
    var unsupported: [String] = []
    var markers: [PageMarker] = []
    /// Open `data-pondside-clip` groups: the element depth and the rect its
    /// first `pondside-clip:` link names.
    private var clips: [(depth: Int, rect: Rect?)] = []

    private var stack: [(name: String, state: SVGState)] = []
    private var state = SVGState()
    // Text being collected for the innermost <text> element.
    private var textState: SVGState?
    private var textBuffer = ""
    private var tspanDepth = 0
    private var styleDepth = 0

    mutating func consume(_ token: XMLTokenizer.Token) {
        switch token {
        case let .start(name, attributes, selfClosing):
            start(name, attributes)
            if selfClosing { end(name) }
        case .end(let name):
            end(name)
        case .text(let s):
            guard textState != nil, styleDepth == 0 else { return }
            if tspanDepth > 0 {
                textBuffer += s
            } else {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { textBuffer += trimmed }
            }
        }
    }

    private mutating func start(_ name: String, _ attrs: [String: String]) {
        stack.append((name, state))
        apply(attrs)
        switch name {
        case "svg":
            if stack.count == 1 { readDocument(attrs) }
        case "style":
            styleDepth += 1
        case "a":
            if let href = attrs["xlink:href"] ?? attrs["href"] {
                if href.hasPrefix("pondside-") {
                    state.marker = href
                } else if let link = PointAndClickLocation(uri: href) {
                    state.link = link
                }
            }
        case "g":
            if attrs["data-pondside-clip"] != nil { clips.append((stack.count, nil)) }
        case "rect" where state.marker != nil:
            // LilyPond's url-link writes the y-up interval as is: flip it.
            let x = num(attrs["x"]), y = num(attrs["y"]), w = num(attrs["width"]), h = num(attrs["height"])
            let corners = [Point(x, -(y + h)), Point(x + w, -y)].map { state.transform.apply($0) }
            guard let r = Rect(enclosing: corners), let name = state.marker else { break }
            if name == "pondside-clip:" {
                if let last = clips.indices.last, clips[last].rect == nil { clips[last].rect = r }
            } else if name.hasPrefix("pondside-legend:") {
                markers.append(PageMarker(name: String(name.dropFirst("pondside-legend:".count)), rect: r))
            }
        case "path":
            if let d = attrs["d"] { emit(VectorPath(svgPathData: d)) }
        case "rect":
            let r = Rect(x: num(attrs["x"]), y: num(attrs["y"]), width: num(attrs["width"]), height: num(attrs["height"]))
            let rx = attrs["rx"].map { num($0) }, ry = attrs["ry"].map { num($0) }
            emit(.rect(r, rx: rx ?? ry ?? 0, ry: ry ?? rx ?? 0))
        case "line":
            emit(VectorPath([.move(Point(num(attrs["x1"]), num(attrs["y1"]))),
                             .line(Point(num(attrs["x2"]), num(attrs["y2"])))]))
        case "circle":
            let r = num(attrs["r"])
            emit(.ellipse(center: Point(num(attrs["cx"]), num(attrs["cy"])), rx: r, ry: r))
        case "ellipse":
            emit(.ellipse(center: Point(num(attrs["cx"]), num(attrs["cy"])), rx: num(attrs["rx"]), ry: num(attrs["ry"])))
        case "polygon", "polyline":
            var scanner = NumberScanner(attrs["points"] ?? "")
            let n = scanner.allNumbers()
            let points = stride(from: 0, to: n.count - 1, by: 2).map { Point(n[$0], n[$0 + 1]) }
            emit(.polyline(points, closed: name == "polygon"))
        case "text":
            textState = state
            textBuffer = ""
        case "tspan":
            tspanDepth += 1
        case "image", "use", "foreignObject":
            unsupported.append(name)
        default:
            break
        }
    }

    private mutating func end(_ name: String) {
        switch name {
        case "style": styleDepth = max(0, styleDepth - 1)
        case "tspan": tspanDepth = max(0, tspanDepth - 1)
        case "text": flushText()
        default: break
        }
        // Pop to the matching element, tolerating malformed nesting.
        while let top = stack.popLast() {
            state = top.state
            if top.name == name { break }
        }
        while let last = clips.last, last.depth > stack.count { clips.removeLast() }
    }

    /// The clip in force, and the graphic's bounds within it; nil when the
    /// graphic is entirely clipped away.
    private func clipped(_ bounds: Rect) -> (bounds: Rect, clip: Rect?)? {
        var clip: Rect?
        for c in clips { if let r = c.rect { clip = clip.map { $0.intersection(r) ?? Rect(x: r.x, y: r.y, width: 0, height: 0) } ?? r } }
        guard let clip else { return (bounds, nil) }
        guard let inside = bounds.intersection(clip) else { return nil }
        return (inside, clip)
    }

    private mutating func readDocument(_ attrs: [String: String]) {
        if let w = attrs["width"].flatMap(Self.millimetres) { widthMM = w }
        if let h = attrs["height"].flatMap(Self.millimetres) { heightMM = h }
        var scanner = NumberScanner(attrs["viewBox"] ?? "")
        let v = scanner.allNumbers()
        if v.count == 4 {
            viewBox = Rect(x: v[0], y: v[1], width: v[2], height: v[3])
        } else {
            viewBox = Rect(x: 0, y: 0, width: widthMM, height: heightMM)
        }
    }

    private mutating func apply(_ attrs: [String: String]) {
        if let t = attrs["transform"] { state.transform = SVGTransformParsing.parse(t).then(state.transform) }
        if let c = attrs["color"], let rgba = Self.parseColor(c) { state.color = rgba }
        if let f = attrs["fill"] { state.fill = Self.parsePaint(f) }
        if let s = attrs["stroke"] { state.stroke = Self.parsePaint(s) }
        if let w = attrs["stroke-width"], let v = Double(w) { state.strokeWidth = v }
        if let c = attrs["stroke-linecap"], let v = StrokeStyle.Cap(rawValue: c) { state.cap = v }
        if let j = attrs["stroke-linejoin"], let v = StrokeStyle.Join(rawValue: j) { state.join = v }
        if let d = attrs["stroke-dasharray"] {
            var scanner = NumberScanner(d)
            state.dash = d == "none" ? [] : scanner.allNumbers()
        }
        if let f = attrs["font-family"] { state.fontFamily = f }
        if let s = attrs["font-size"], let v = Double(s) { state.fontSize = v }
        if let w = attrs["font-weight"] { state.bold = w == "bold" || (Int(w) ?? 400) >= 600 }
        if let s = attrs["font-style"] { state.italic = s == "italic" || s == "oblique" }
        if let a = attrs["text-anchor"], let v = TextRun.Anchor(rawValue: a) { state.anchor = v }
    }

    private mutating func emit(_ local: VectorPath) {
        let fill = state.fill.resolve(state.color)
        let stroke = state.stroke.resolve(state.color)
        guard fill != nil || stroke != nil else { return }
        let path = local.transformed(by: state.transform)
        let style = StrokeStyle(width: state.strokeWidth * state.transform.scaleFactor, cap: state.cap, join: state.join,
                                dash: state.dash.map { $0 * state.transform.scaleFactor })
        guard var bounds = path.controlBounds else { return }
        if stroke != nil { bounds = bounds.insetBy(-style.width / 2) }
        guard let (shown, clip) = clipped(bounds) else { return }
        graphics.append(Graphic(content: .path(path, fill: fill, stroke: stroke, style: style), bounds: shown, link: state.link, clip: clip))
    }

    private mutating func flushText() {
        guard let ts = textState else { return }
        textState = nil
        let string = textBuffer
        textBuffer = ""
        guard !string.isEmpty, let color = ts.fill.resolve(ts.color) else { return }
        let run = TextRun(string: string, transform: ts.transform, fontFamily: ts.fontFamily, fontSize: ts.fontSize,
                          bold: ts.bold, italic: ts.italic, anchor: ts.anchor, color: color)
        // Estimated extent; good enough to hit-test and cull a text run.
        let width = Double(string.count) * ts.fontSize * 0.55
        let x0: Double
        switch ts.anchor {
        case .start: x0 = 0
        case .middle: x0 = -width / 2
        case .end: x0 = -width
        }
        let corners = [Point(x0, -ts.fontSize * 0.8), Point(x0 + width, -ts.fontSize * 0.8),
                       Point(x0, ts.fontSize * 0.25), Point(x0 + width, ts.fontSize * 0.25)]
        let bounds = Rect(enclosing: corners.map { ts.transform.apply($0) })!
        guard let (shown, clip) = clipped(bounds) else { return }
        graphics.append(Graphic(content: .text(run), bounds: shown, link: ts.link, clip: clip))
    }

    private func num(_ s: String?) -> Double {
        guard let s else { return 0 }
        var scanner = NumberScanner(s)
        return scanner.number() ?? 0
    }

    // MARK: Attribute parsers

    static func millimetres(_ s: String) -> Double? {
        var scanner = NumberScanner(s)
        guard let v = scanner.number() else { return nil }
        if s.hasSuffix("mm") { return v }
        if s.hasSuffix("cm") { return v * 10 }
        if s.hasSuffix("in") { return v * 25.4 }
        if s.hasSuffix("pt") { return v * 25.4 / 72 }
        return v * 25.4 / 96 // px or unitless
    }

    static func parsePaint(_ s: String) -> Paint {
        switch s {
        case "none", "transparent": return .none
        case "currentColor": return .currentColor
        default: return parseColor(s).map(Paint.color) ?? .color(.black)
        }
    }

    static func parseColor(_ s: String) -> RGBA? {
        let s = s.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            let hex = Array(s.dropFirst())
            func h(_ i: Int, _ n: Int) -> Double {
                Double(Int(String(hex[i..<(i + n)]), radix: 16) ?? 0) / (n == 1 ? 15 : 255)
            }
            if hex.count == 6 { return RGBA(h(0, 2), h(2, 2), h(4, 2)) }
            if hex.count == 3 { return RGBA(h(0, 1), h(1, 1), h(2, 1)) }
            return nil
        }
        if s.hasPrefix("rgb") {
            // LilyPond writes rgb(100.0000%, 0.0000%, 0.0000%).
            guard let open = s.firstIndex(of: "("), let close = s.lastIndex(of: ")") else { return nil }
            let parts = s[s.index(after: open)..<close].split(separator: ",")
            let values: [Double] = parts.map { part in
                let p = part.trimmingCharacters(in: .whitespaces)
                if p.hasSuffix("%") { return (Double(p.dropLast()) ?? 0) / 100 }
                return (Double(p) ?? 0) / 255
            }
            guard values.count >= 3 else { return nil }
            return RGBA(values[0], values[1], values[2], values.count > 3 ? values[3] : 1)
        }
        switch s {
        case "black": return .black
        case "white": return .white
        case "red": return RGBA(1, 0, 0)
        case "green": return RGBA(0, 0.5, 0)
        case "blue": return RGBA(0, 0, 1)
        case "grey", "gray": return RGBA(0.5, 0.5, 0.5)
        default: return nil
        }
    }
}

/// Parses SVG `transform` attribute lists.
enum SVGTransformParsing {
    static func parse(_ s: String) -> AffineTransform {
        var result = AffineTransform.identity
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "("), let close = rest[open...].firstIndex(of: ")") {
            let name = rest[..<open].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n"))
            var scanner = NumberScanner(String(rest[rest.index(after: open)..<close]))
            let v = scanner.allNumbers()
            var t = AffineTransform.identity
            switch name {
            case "translate" where !v.isEmpty:
                t = .translation(v[0], v.count > 1 ? v[1] : 0)
            case "scale" where !v.isEmpty:
                t = .scale(v[0], v.count > 1 ? v[1] : v[0])
            case "rotate" where !v.isEmpty:
                t = .rotation(degrees: v[0])
                if v.count >= 3 {
                    t = AffineTransform.translation(-v[1], -v[2]).then(t).then(.translation(v[1], v[2]))
                }
            case "matrix" where v.count == 6:
                t = AffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], e: v[4], f: v[5])
            case "skewX" where !v.isEmpty:
                t = AffineTransform(a: 1, b: 0, c: tan(v[0] * .pi / 180), d: 1, e: 0, f: 0)
            case "skewY" where !v.isEmpty:
                t = AffineTransform(a: 1, b: tan(v[0] * .pi / 180), c: 0, d: 1, e: 0, f: 0)
            default:
                break
            }
            // "translate(..) scale(..)" applies scale first, then translate.
            result = t.then(result)
            rest = rest[rest.index(after: close)...]
        }
        return result
    }
}
