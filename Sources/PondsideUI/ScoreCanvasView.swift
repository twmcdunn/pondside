import AppKit
import PondsideCore
import PondsideEngrave

@MainActor
protocol ScoreCanvasDelegate: AnyObject {
    /// The user clicked a linked glyph (or empty paper: nil).
    func canvas(_ canvas: ScoreCanvasView, didClick link: PointAndClickLocation?, extending: Bool)
    /// The user dragged a selection rectangle over these links.
    func canvas(_ canvas: ScoreCanvasView, didSelect links: [PointAndClickLocation])
    /// The user clicked music that carries no point-and-click link.
    func canvasClickedUnlinkedMusic(_ canvas: ScoreCanvasView)
    /// A key pressed while the score has focus. Return true if handled.
    func canvas(_ canvas: ScoreCanvasView, handleKey event: NSEvent) -> Bool
}

/// The score surface: pages floating on the dark field.
///
/// Each page is its own layer-backed view so invalidation, cross-fades and
/// layer sizes stay per page. Drawing is Core Graphics into Core Animation
/// layers, which the window server composites on the GPU (see DESIGN.md on
/// why this is preferred to a hand-written Metal rasteriser for now).
@MainActor
final class ScoreCanvasView: NSView {
    weak var delegate: ScoreCanvasDelegate?

    private(set) var pages: [RenderedPage] = []
    private var pageViews: [PageView] = []
    private(set) var zoom: CGFloat = 1.0
    var lightsOut = false {
        didSet { pageViews.forEach { $0.lightsOut = lightsOut } }
    }
    var onZoomChange: ((CGFloat) -> Void)?

    private let margin: CGFloat = 40
    private let gap: CGFloat = 28
    private static let pointsPerMM: CGFloat = 72 / 25.4

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    /// Called when the canvas gains or loses the keyboard, so the window can
    /// show where keys go.
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Content

    /// Replaces the pages, cross-fading so a recompile never flickers.
    func setPages(_ newPages: [EngravedPage]) {
        lastInserted = nil
        legend = legendArranging ? LegendArrangement(pages: newPages) : nil
        legendPages = Set(LegendArrangement(pages: newPages).sheets.map(\.page))
        let rendered = newPages.map(RenderedPage.init)
        let animate = !pages.isEmpty
        pages = rendered
        while pageViews.count > rendered.count { pageViews.removeLast().removeFromSuperview() }
        while pageViews.count < rendered.count {
            let v = PageView(frame: .zero)
            v.owner = self
            v.lightsOut = lightsOut
            addSubview(v)
            pageViews.append(v)
        }
        for (n, (v, p)) in zip(pageViews, rendered).enumerated() {
            if animate { v.crossFade() }
            v.pageIndex = n
            v.rendered = p
        }
        relayout()
    }

    // MARK: Arranging the legend

    /// Arrange mode: the legend's handles show, and drags on a legend page
    /// move its table, columns and rows, or crop and scale an example.
    var legendArranging = false {
        didSet {
            guard legendArranging != oldValue else { return }
            legend = legendArranging ? LegendArrangement(pages: pages.map(\.page)) : nil
            pageViews.forEach { $0.legendDrag = nil; $0.needsDisplay = true; $0.window?.invalidateCursorRects(for: $0) }
        }
    }
    private(set) var legend: LegendArrangement?
    /// The pages that hold the legend's table.
    private(set) var legendPages: Set<Int> = []

    /// A legend page fills most of what is on screen: the status bar then
    /// offers to arrange it.
    var legendInView: Bool {
        guard !legendPages.isEmpty else { return false }
        let visible = self.visibleRect
        guard visible.height > 0 else { return false }
        var legendArea: CGFloat = 0, all: CGFloat = 0
        for (n, v) in pageViews.enumerated() {
            let r = v.frame.intersection(visible)
            guard !r.isNull else { continue }
            all += r.width * r.height
            if legendPages.contains(n) { legendArea += r.width * r.height }
        }
        return all > 0 && legendArea / all > 0.5
    }
    /// The layout and each row's example options, as the file has them now.
    var legendValues: () -> (FrontMatter.LegendLayout, [FrontMatter.ExampleLayout]) = { (.init(), []) }
    /// A finished drag: write it.
    var onLegendCommit: (LegendArrangement.Outcome) -> Void = { _ in }
    /// What a drag is doing, for the status bar.
    var onLegendStatus: (String) -> Void = { _ in }

    /// Scrolls to the legend's first page.
    func revealLegend() {
        guard let page = legend?.sheets.first?.page, pageViews.indices.contains(page) else { return }
        let v = pageViews[page]
        scrollToVisible(NSRect(x: v.frame.minX, y: v.frame.minY - 12, width: v.frame.width, height: min(v.frame.height, (enclosingScrollView?.contentView.bounds.height ?? 600) - 24)))
    }

    fileprivate func legendSheet(_ v: PageView) -> LegendArrangement.Sheet? {
        guard legendArranging, let n = v.pageIndex else { return nil }
        return legend?.sheet(page: n)
    }

    /// Handle tolerance: 5 points on screen, in page units.
    fileprivate func legendTolerance(_ v: PageView) -> Double {
        guard let vb = v.rendered?.page.viewBox, v.bounds.width > 0 else { return 1 }
        return 5 * vb.width / v.bounds.width
    }

    fileprivate func legendDrag(_ v: PageView, handle: LegendArrangement.Handle, from start: Point, to p: Point,
                                event: NSEvent) -> LegendArrangement.Outcome? {
        guard let legend, let sheet = legendSheet(v) else { return nil }
        let (layout, examples) = legendValues()
        let outcome = legend.drag(handle, on: sheet, from: start, to: p, layout: layout, examples: examples,
                                  snap: !event.modifierFlags.contains(.command), all: event.modifierFlags.contains(.option),
                                  threshold: 2 * legendTolerance(v))
        onLegendStatus(outcome.summary)
        return outcome
    }

    func setZoom(_ z: CGFloat, anchor: NSPoint? = nil) {
        let clamped = min(max(z, 0.25), 6)
        guard abs(clamped - zoom) > 0.001 else { return }
        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let focus = anchor ?? NSPoint(x: visible.midX, y: visible.midY)
        let fx = bounds.width > 0 ? focus.x / bounds.width : 0.5
        let fy = bounds.height > 0 ? focus.y / bounds.height : 0
        zoom = clamped
        relayout()
        // Keep the focus point stable while zooming.
        let newFocus = NSPoint(x: fx * bounds.width, y: fy * bounds.height)
        scroll(NSPoint(x: newFocus.x - (focus.x - visible.minX), y: newFocus.y - (focus.y - visible.minY)))
        onZoomChange?(zoom)
    }

    /// Zoom so the widest page fills the visible width.
    func fitWidth() {
        guard let widest = pages.map({ CGFloat($0.page.widthMM) }).max(),
              let clip = enclosingScrollView?.contentView.bounds.width else { return }
        setZoom((clip - 2 * margin) / (widest * Self.pointsPerMM))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layoutPageViews()
    }

    private func relayout() {
        let sizes = pages.map { pageSize($0) }
        let contentWidth = (sizes.map(\.width).max() ?? 0) + 2 * margin
        let contentHeight = sizes.reduce(margin) { $0 + $1.height + gap } - gap + margin
        let clip = enclosingScrollView?.contentView.bounds.size ?? .zero
        setFrameSize(NSSize(width: max(contentWidth, clip.width), height: max(contentHeight, clip.height)))
        layoutPageViews()
        placeWorkBadge()
    }

    private func layoutPageViews() {
        var y = margin
        for (v, p) in zip(pageViews, pages) {
            let size = pageSize(p)
            v.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: y, width: size.width, height: size.height)
            y += size.height + gap
        }
    }

    private func pageSize(_ p: RenderedPage) -> NSSize {
        NSSize(width: (CGFloat(p.page.widthMM) * Self.pointsPerMM * zoom).rounded(),
               height: (CGFloat(p.page.heightMM) * Self.pointsPerMM * zoom).rounded())
    }

    // MARK: Highlighting

    /// The first highlighted glyphs widened to their staff, in canvas
    /// coordinates: what a popover about the selection must not cover.
    private(set) var selectionAnchor: NSRect?

    /// The linked positions on the system around the selection: what "this
    /// system" means for an agent placing something "until the next system".
    func linksOnSelectedSystem() -> [PointAndClickLocation] {
        guard let anchor = selectionAnchor else { return [] }
        for v in pageViews {
            let r = v.convert(anchor, from: self)
            guard v.bounds.intersects(r), let page = v.rendered?.page else { continue }
            return page.links(onSystemAt: v.pagePoint(NSPoint(x: r.midX, y: r.midY)).y)
        }
        return []
    }

    /// Where the last click landed, so a large drawing highlights the shape
    /// under it rather than all of itself.
    private var clickFocus: (view: PageView, point: Point, link: PointAndClickLocation)?

    /// The shape a click selected inside a drawing of many parts, for the
    /// agent: its bounds and the broken spanner piece it belongs to, in
    /// page (staff-space) coordinates.
    struct LinkAnchor {
        var x: Double
        var link: PointAndClickLocation
    }
    struct GraphicPartSelection {
        var page: Int
        var part: Rect
        var piece: Rect
        var staffMiddle: Double
        var space: Double
        /// Other linked glyphs on the clicked system, for the bar/moment
        /// nearest the part.
        var anchors: [LinkAnchor]
    }
    private(set) var graphicPartSelection: GraphicPartSelection?

    /// Highlights every graphic produced by the given source positions.
    /// The highlight is an overlay; the music itself is never recoloured.
    func highlight(_ positions: Set<SourcePosition>, path: String?, reveal: Bool) {
        var firstRect: NSRect?
        selectionAnchor = nil
        graphicPartSelection = nil
        var sameFile: [String: Bool] = [:]
        // A drawing of many parts (a 20-bar texture, a spanner of separate
        // bursts) shows only the shape that was clicked, or its first one.
        var shownLarge = Set<PointAndClickLocation>()
        for (index, v) in pageViews.enumerated() {
            guard let page = v.rendered?.page else { continue }
            let matches = page.graphics.filter { g in
                guard !v.removed.contains(g) else { return false }
                guard let link = g.link, positions.contains(link.position) else { return false }
                guard let path else { return true }
                if let known = sameFile[link.path] { return known }
                let same = PathMatching.same(link.path, path)
                sameFile[link.path] = same
                return same
            }
            // A drawing of many parts is outlined by shape, not part by part.
            var parts: [PointAndClickLocation: [Graphic]] = [:]
            for g in matches { parts[g.link!, default: []].append(g) }
            let space = v.staves.first?.space ?? 1
            var rects: [Rect] = []
            for (link, group) in parts {
                guard group.count > 8 else { rects += group.map(\.bounds); continue }
                guard !shownLarge.contains(link) else { continue }
                let shapes = EngravedPage.clusters(of: group, gap: EngravedPage.clusterGap * space)
                // The shape on screen: the one clicked, else the first. Whichever
                // it is, the agent's context describes exactly it.
                let shown: Rect?
                if let focus = clickFocus, focus.link == link {
                    guard focus.view === v else { continue }
                    shown = shapes.min { $0.distance(to: focus.point) < $1.distance(to: focus.point) }
                } else {
                    shown = shapes.first
                }
                guard let near = shown else { continue }
                rects.append(near)
                shownLarge.insert(link)
                if graphicPartSelection == nil,
                   let staff = page.staff(at: Point(near.midX, near.midY), among: v.staves) {
                    let band = EngravedPage.systems(of: v.staves)
                        .first { ($0.lowerBound - 6)...($0.upperBound + 6) ~= near.midY }
                    let pieceParts = band.map { b in group.filter { b.contains($0.bounds.midY) } } ?? group
                    if let piece = EngravedPage.bounds(of: pieceParts) {
                        let middle = staff.lineYs.count > 2 ? staff.lineYs[staff.lineYs.count / 2] : staff.top
                        let anchors = page.graphics.compactMap { g -> LinkAnchor? in
                            guard let gl = g.link, gl != link, band.map({ $0.contains(g.bounds.midY) }) ?? true else { return nil }
                            return LinkAnchor(x: g.bounds.midX, link: gl)
                        }.sorted { abs($0.x - near.midX) < abs($1.x - near.midX) }.prefix(16)
                        graphicPartSelection = GraphicPartSelection(page: index + 1, part: near, piece: piece,
                                                                    staffMiddle: middle, space: staff.space,
                                                                    anchors: Array(anchors))
                    }
                }
            }
            v.highlights = rects
            let shown: Rect? = rects.dropFirst().reduce(rects.first) { acc, r in acc?.union(r) }
            if firstRect == nil, let r = shown {
                firstRect = convert(v.viewRect(for: r), from: v)
                var band = r
                if let staff = page.staff(at: Point(r.midX, r.midY), among: v.staves) {
                    let top = min(r.y, staff.top - staff.space), bottom = max(r.y + r.height, staff.bottom + staff.space)
                    band = Rect(x: r.x, y: top, width: r.width, height: bottom - top)
                }
                selectionAnchor = convert(v.viewRect(for: band), from: v)
            }
        }
        if reveal, let r = firstRect, !visibleRect.contains(r) {
            scrollToVisible(r.insetBy(dx: -80, dy: -80))
        }
    }

    // MARK: Agent at work

    /// The capsule above the region an agent is working on: a spinner and
    /// who is working. Chrome over content, so it sits beside the music
    /// (above it), never on it.
    private var workBadge: NSView?

    /// Marks the current selection as the agent's work in progress until
    /// `endWork`: its outline pulses, and the music inside it fades between
    /// blurred and sharp, so the region reads as "being redrawn" while
    /// staying readable every cycle. No spinner: the status bar says in
    /// words what the agent is doing.
    func beginWork(label: String) {
        for v in pageViews { v.working = v.highlights }
        guard pageViews.contains(where: { !$0.working.isEmpty }) else { return }
        workBadge?.removeFromSuperview()
        workBadge = nil
        NSAccessibility.post(element: NSApp.mainWindow as Any, notification: .announcementRequested,
                             userInfo: [.announcement: "\(label) on the selection", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// The work is over: the outline and the capsule fade out.
    func endWork() {
        for v in pageViews { v.working = [] }
        guard let badge = workBadge else { return }
        workBadge = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.2
            badge.animator().alphaValue = 0
        }, completionHandler: { badge.removeFromSuperview() })
    }

    /// On the top-right corner of the first page's work region, straddling
    /// its outline: it marks the region without covering the music around it
    /// (the status bar says in words what the agent is doing).
    private func placeWorkBadge() {
        guard let badge = workBadge else { return }
        guard let (v, r) = pageViews.lazy.compactMap({ v in v.workBounds.map { (v, $0) } }).first else {
            badge.isHidden = true
            return
        }
        badge.isHidden = false
        let region = convert(r, from: v)
        let size = badge.fittingSize
        var origin = NSPoint(x: region.maxX - size.width / 2, y: region.minY - size.height / 2)
        origin.x = min(max(origin.x, v.frame.minX + 2), v.frame.maxX - size.width - 2)
        origin.y = max(origin.y, v.frame.minY + 2)
        badge.frame = NSRect(origin: origin, size: size)
        // Pages added by a recompile must not cover it.
        addSubview(badge, positioned: .above, relativeTo: nil)
    }

    // MARK: Events

    fileprivate func pageView(_ v: PageView, clickedAt p: Point, event: NSEvent) {
        window?.makeFirstResponder(self)
        let tolerance = 0.3 / max(zoom, 0.5)
        // Between the parts of a drawing (a grain cloud's dots) still selects it.
        let link = v.rendered?.page.hitTest(p, tolerance: tolerance, excluding: v.removed)?.link
            ?? v.rendered?.page.regionHit(p, excluding: v.removed)?.link
        clickFocus = link.map { (v, p, $0) }
        if link == nil, let page = v.rendered?.page,
           page.graphics.contains(where: { $0.bounds.insetBy(-tolerance).contains(p) && $0.bounds.width < page.viewBox.width * 0.5 }) {
            // Something is there, but it can't lead back to the source.
            delegate?.canvasClickedUnlinkedMusic(self)
            return
        }
        delegate?.canvas(self, didClick: link, extending: event.modifierFlags.contains(.shift))
    }

    /// Provisional rendering: ghost noteheads where the given notes are
    /// moving, drawn until the next engraving replaces the pages. The music
    /// itself is never redrawn or recoloured.
    func provisionalShift(_ positions: Set<SourcePosition>, path: String, halfSpaces: Int) {
        guard halfSpaces != 0 else { return }
        for v in pageViews {
            guard let page = v.rendered?.page else { continue }
            var byPosition: [SourcePosition: [Graphic]] = [:]
            for g in page.graphics {
                guard let link = g.link, positions.contains(link.position), PathMatching.same(link.path, path) else { continue }
                byPosition[link.position, default: []].append(g)
            }
            var ghosts = v.provisional
            for (_, graphics) in byPosition {
                guard let first = graphics.first,
                      let staff = page.staff(at: Point(first.bounds.midX, first.bounds.midY), among: v.staves),
                      let glyph = EngravedPage.noteGlyph(among: graphics, space: staff.space) else { continue }
                // Accumulate: two quick ↑ before a recompile move the ghost twice.
                let base = ghosts.first { abs($0.head.midX - glyph.head.midX) < staff.space * 0.3 } ?? glyph
                ghosts.removeAll { abs($0.head.midX - glyph.head.midX) < staff.space * 0.3 }
                ghosts.append(base.translated(by: Point(0, -Double(halfSpaces) * staff.space / 2)))
            }
            v.provisional = ghosts
        }
    }

    /// The graphics linked to `positions` in `path`, per page view.
    private func linked(_ positions: Set<SourcePosition>, path: String) -> [(PageView, [SourcePosition: [Graphic]])] {
        pageViews.compactMap { v in
            guard let page = v.rendered?.page else { return nil }
            var byPosition: [SourcePosition: [Graphic]] = [:]
            for g in page.graphics {
                guard let link = g.link, positions.contains(link.position), PathMatching.same(link.path, path) else { continue }
                byPosition[link.position, default: []].append(g)
            }
            return byPosition.isEmpty ? nil : (v, byPosition)
        }
    }

    /// The last provisional note placed, so several quick insertions chain
    /// to the right of each other before LilyPond answers.
    private var lastInserted: (view: PageView, glyph: NoteGlyph, diatonic: Int)?

    /// Provisional rendering of an insertion: a ghost note after the anchor's
    /// notehead, at the new pitch's staff position.
    func provisionalInsert(after positions: Set<SourcePosition>, path: String, anchorDiatonic: Int?, diatonic: Int) {
        var base: (view: PageView, glyph: NoteGlyph, diatonic: Int)?
        if let anchorDiatonic {
            for (v, byPosition) in linked(positions, path: path) {
                guard let page = v.rendered?.page else { continue }
                for (_, graphics) in byPosition {
                    guard let first = graphics.first,
                          let staff = page.staff(at: Point(first.bounds.midX, first.bounds.midY), among: v.staves),
                          let glyph = EngravedPage.noteGlyph(among: graphics, space: staff.space) else { continue }
                    if base == nil || glyph.head.maxX > base!.glyph.head.maxX {
                        base = (v, glyph, anchorDiatonic)
                    }
                }
            }
        }
        if base == nil { base = lastInserted }
        guard let b = base else { return }
        let head = b.glyph.head
        let placed = b.glyph.placingHead(at: Point(
            head.maxX + b.glyph.space * 0.8 + head.width / 2,
            head.midY - Double(diatonic - b.diatonic) * b.glyph.space / 2))
        b.view.provisional.append(placed)
        lastInserted = (b.view, placed, diatonic)
    }

    /// Provisional deletion: take the event's glyphs out of the vector page at
    /// once, rather than crossing them out. The next engraving reflows the
    /// music; until then the rest of the page stays exactly where it was.
    func provisionalDelete(_ positions: Set<SourcePosition>, path: String) {
        for (v, byPosition) in linked(positions, path: path) {
            guard let page = v.rendered?.page else { continue }
            for graphics in byPosition.values {
                guard let first = graphics.first,
                      let staff = page.staff(at: Point(first.bounds.midX, first.bounds.midY),
                                             among: v.staves) else {
                    v.removed.formUnion(graphics)
                    continue
                }
                v.removed.formUnion(EngravedPage.removalSet(
                    for: graphics, among: page.graphics, space: staff.space))
            }
        }
    }

    /// Provisional rendering of a duration change: the new value as a badge.
    func provisionalBadge(_ positions: Set<SourcePosition>, path: String, text: String) {
        for (v, byPosition) in linked(positions, path: path) {
            for (_, graphics) in byPosition {
                guard let r = EngravedPage.bounds(of: graphics) else { continue }
                v.badges.removeAll { abs($0.0.midX - r.midX) < 0.3 }
                v.badges.append((r, text))
            }
        }
    }

    fileprivate func pageView(_ v: PageView, selected rect: Rect) {
        let links = v.rendered?.page.linkedGraphics(in: rect, excluding: v.removed).compactMap(\.link) ?? []
        delegate?.canvas(self, didSelect: links)
    }

    override func keyDown(with event: NSEvent) {
        if delegate?.canvas(self, handleKey: event) == true { return }
        super.keyDown(with: event)
    }

    // Re-centre pages when the viewport resizes.
    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        guard let clip = superview else { return }
        clip.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(viewportDidResize(_:)),
                                               name: NSView.frameDidChangeNotification, object: clip)
    }

    @objc private func viewportDidResize(_ notification: Notification) {
        relayout()
    }

    override func magnify(with event: NSEvent) {
        setZoom(zoom * (1 + event.magnification), anchor: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        delegate?.canvas(self, didClick: nil, extending: false)
    }
}

/// One sheet of paper. Opaque: nothing ever shows through the music.
@MainActor
private final class PageView: NSView {
    weak var owner: ScoreCanvasView?
    var rendered: RenderedPage? {
        didSet {
            staves = rendered?.page.staves ?? []
            provisional = []
            removed = []
            highlights = []
            badges = []
            legendDrag = nil
            legendCommitted = false
            needsDisplay = true
            updateWork()
        }
    }
    private(set) var staves: [Staff] = []
    /// Engraved note glyphs moved to provisional (not yet engraved) positions.
    var provisional: [NoteGlyph] = [] { didSet { if provisional != oldValue { needsDisplay = true } } }
    /// Glyphs the provisional deletion has taken out of the page.
    var removed: Set<Graphic> = [] { didSet { if removed != oldValue { needsDisplay = true } } }
    var badges: [(Rect, String)] = [] { didSet { needsDisplay = true } }
    var highlights: [Rect] = [] { didSet { if highlights != oldValue { needsDisplay = true } } }
    var lightsOut = false { didSet { needsDisplay = true } }
    /// The region an agent is working on (page coordinates): outlined on a
    /// layer of its own, so the pulse never redraws the music.
    var working: [Rect] = [] { didSet { if working != oldValue { updateWork() } } }
    private let workLayer = CAShapeLayer()
    /// A blurred copy of the music in the work region, faded in and out.
    private let blurLayer = CALayer()
    private var displayOptionsObserver: NSObjectProtocol?

    /// The work region in view coordinates, padded like the outline.
    var workBounds: NSRect? {
        guard let first = working.first else { return nil }
        return working.dropFirst().reduce(viewRect(for: first)) { $0.union(viewRect(for: $1)) }.insetBy(dx: -4, dy: -4)
    }
    private var dragStart: NSPoint?
    private var dragRect: NSRect? { didSet { needsDisplay = true } }
    var pageIndex: Int?
    /// A legend drag: its handle, where it began, and what it makes so far
    /// (kept, drawn, until the next engraving replaces the page).
    var legendDrag: (handle: LegendArrangement.Handle, start: Point, outcome: LegendArrangement.Outcome?)? {
        didSet { needsDisplay = true }
    }
    private var legendCommitted = false

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        workLayer.isHidden = true
        workLayer.zPosition = 1
        layer?.addSublayer(workLayer)
        layerUsesCoreImageFilters = true
        blurLayer.isHidden = true
        blurLayer.zPosition = 0.5
        blurLayer.masksToBounds = true
        layer?.addSublayer(blurLayer)
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWork() }
        }
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = NSSize(width: 0, height: -4)
        self.shadow = shadow
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// A zoom changes the page's size: redraw at the new size rather than
    /// leaving the layer to stretch (or misplace) the old drawing.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed {
            needsDisplay = true
            updateWork()
        }
    }

    /// The pulsing outline: the selection's own accent and shape, breathing
    /// slowly (1.1 s each way) between full and faint. Reduce Motion: no
    /// pulse, a dashed outline instead, so "working" still differs from
    /// "selected". Increase Contrast: a heavier line and fill.
    private func updateWork() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard !working.isEmpty else {
            workLayer.removeAllAnimations()
            workLayer.isHidden = true
            blurLayer.removeAllAnimations()
            blurLayer.isHidden = true
            blurLayer.contents = nil
            return
        }
        let path = CGMutablePath()
        for r in working {
            path.addRoundedRect(in: viewRect(for: r).insetBy(dx: -4, dy: -4), cornerWidth: 4, cornerHeight: 4)
        }
        let ws = NSWorkspace.shared
        let contrast = ws.accessibilityDisplayShouldIncreaseContrast
        let still = ws.accessibilityDisplayShouldReduceMotion
        workLayer.frame = bounds
        workLayer.path = path
        workLayer.fillColor = Theme.accent.withAlphaComponent(contrast ? 0.26 : 0.18).cgColor
        workLayer.strokeColor = Theme.accent.cgColor
        workLayer.lineWidth = contrast ? 3 : 2.25
        updateBlur(still: still)
        workLayer.lineDashPattern = still ? [5, 3] : nil
        workLayer.isHidden = false
        if still {
            workLayer.removeAnimation(forKey: "pondside.working")
            workLayer.opacity = 1
        } else if workLayer.animation(forKey: "pondside.working") == nil {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = contrast ? 0.35 : 0.08
            pulse.duration = 1.1
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            workLayer.add(pulse, forKey: "pondside.working")
        }
    }

    /// The blurred copy of the work region: the page's own drawing of it,
    /// through a Gaussian blur, its opacity breathing in step with the
    /// outline (blurred as the outline fades, sharp as it returns).
    private func updateBlur(still: Bool) {
        guard !still, let first = working.first else {
            blurLayer.removeAllAnimations()
            blurLayer.isHidden = true
            return
        }
        let region = working.dropFirst().reduce(viewRect(for: first)) { $0.union(viewRect(for: $1)) }
            .insetBy(dx: -6, dy: -6).intersection(bounds)
        guard region.width > 1, region.height > 1, let rep = bitmapImageRepForCachingDisplay(in: region) else { return }
        cacheDisplay(in: region, to: rep)
        blurLayer.frame = region
        blurLayer.contents = rep.cgImage
        blurLayer.contentsScale = window?.backingScaleFactor ?? 2
        blurLayer.filters = [CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 3.5])].compactMap { $0 }
        blurLayer.isHidden = false
        if blurLayer.animation(forKey: "pondside.blur") == nil {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0.0
            fade.toValue = 1.0
            fade.duration = 1.1
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            blurLayer.add(fade, forKey: "pondside.blur")
        }
    }

    func crossFade() {
        let fade = CATransition()
        fade.type = .fade
        fade.duration = 0.12
        layer?.add(fade, forKey: "pondside.recompile")
    }

    private var scale: CGFloat {
        guard let vb = rendered?.page.viewBox, vb.width > 0 else { return 1 }
        return bounds.width / vb.width
    }

    func pagePoint(_ p: NSPoint) -> Point {
        let vb = rendered?.page.viewBox ?? Rect(x: 0, y: 0, width: 1, height: 1)
        return Point(vb.x + p.x / scale, vb.y + p.y / scale)
    }

    func viewRect(for r: Rect) -> NSRect {
        let vb = rendered?.page.viewBox ?? Rect(x: 0, y: 0, width: 1, height: 1)
        return NSRect(x: (r.x - vb.x) * scale, y: (r.y - vb.y) * scale, width: r.width * scale, height: r.height * scale)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.setFillColor(Theme.paper.cgColor)
        ctx.fill(bounds)
        guard let rendered else { return }
        let vb = rendered.page.viewBox
        let s = scale

        ctx.saveGState()
        ctx.scaleBy(x: s, y: s)
        ctx.translateBy(x: -vb.x, y: -vb.y)
        let visible = Rect(x: vb.x + dirtyRect.minX / s, y: vb.y + dirtyRect.minY / s,
                           width: dirtyRect.width / s, height: dirtyRect.height / s)
        let moves = legendDrag?.outcome?.moves ?? []
        var moving: [(Graphic, PondsideEngrave.AffineTransform)] = []
        if !moves.isEmpty {
            for g in rendered.page.graphics {
                let c = Point(g.bounds.midX, g.bounds.midY)
                if let m = moves.first(where: { $0.region.contains(c) }) { moving.append((g, m.transform)) }
            }
        }
        rendered.draw(in: ctx, visible: visible, excluding: moving.isEmpty ? removed : removed.union(moving.map(\.0)))
        for (g, t) in moving {
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a: t.a, b: t.b, c: t.c, d: t.d, tx: t.e, ty: t.f))
            if let clip = g.clip { ctx.clip(to: CGRect(x: clip.x, y: clip.y, width: clip.width, height: clip.height)) }
            RenderedPage.draw(g, in: ctx)
            ctx.restoreGState()
        }
        ctx.restoreGState()
        if let sheet = owner?.legendSheet(self) { drawLegendOverlay(sheet, in: ctx) }

        if lightsOut {
            // Display filter only: dims paper and ink alike, never exported.
            ctx.setFillColor(NSColor.black.withAlphaComponent(Theme.lightsOutDim).cgColor)
            ctx.fill(bounds)
        }

        let accent = Theme.accent
        for r in highlights {
            let rect = viewRect(for: r).insetBy(dx: -3, dy: -3)
            let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
            ctx.addPath(path)
            ctx.setFillColor(accent.withAlphaComponent(0.16).cgColor)
            ctx.fillPath()
            ctx.addPath(path)
            ctx.setStrokeColor(accent.withAlphaComponent(0.9).cgColor)
            ctx.setLineWidth(1)
            ctx.strokePath()
        }

        // Provisional marks use ink, not the accent: the preview is meant to
        // look like the engraving that is about to land, not like a UI ghost.
        let ink = NSColor.black
        if !provisional.isEmpty {
            ctx.saveGState()
            ctx.scaleBy(x: s, y: s)
            ctx.translateBy(x: -vb.x, y: -vb.y)
            for glyph in provisional {
                for graphic in glyph.graphics {
                    RenderedPage.draw(graphic, in: ctx, tint: ink, alpha: 0.55)
                }
                drawLedgers(for: glyph, in: ctx, color: ink)
            }
            ctx.restoreGState()
        }
        for (r, text) in badges {
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: Theme.secondarySize, weight: .semibold),
                .foregroundColor: NSColor.white,
            ]
            let label = NSAttributedString(string: text, attributes: attrs)
            let size = label.size()
            let v = viewRect(for: r)
            let badge = NSRect(x: v.midX - size.width / 2 - 4, y: v.minY - size.height - 6, width: size.width + 8, height: size.height + 2)
            ctx.setFillColor(accent.withAlphaComponent(0.9).cgColor)
            ctx.addPath(CGPath(roundedRect: badge, cornerWidth: 4, cornerHeight: 4, transform: nil))
            ctx.fillPath()
            NSGraphicsContext.saveGraphicsState()
            label.draw(at: NSPoint(x: badge.minX + 4, y: badge.minY + 1))
            NSGraphicsContext.restoreGraphicsState()
        }

        if let dragRect {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(dragRect)
            ctx.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(dragRect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    /// The note a click would place, with any ledger lines it needs.
    /// Ledger lines at a provisional glyph's position. The page transform must
    /// already be in effect (page coordinates, y down).
    private func drawLedgers(for glyph: NoteGlyph, in ctx: CGContext, color: NSColor) {
        guard let staff = staves.min(by: {
            abs($0.y(ofPosition: 4) - glyph.head.midY) < abs($1.y(ofPosition: 4) - glyph.head.midY)
        }) else { return }
        let position = staff.position(ofY: glyph.head.midY)
        var ledgers: [Int] = []
        if position <= -2 { ledgers = Array(stride(from: -2, through: position, by: -2)) }
        if position >= 10 { ledgers = Array(stride(from: 10, through: position, by: 2)) }
        guard !ledgers.isEmpty else { return }
        ctx.setStrokeColor(color.withAlphaComponent(0.7).cgColor)
        ctx.setLineWidth(max(0.08, 0.12 * staff.space))
        for p in ledgers {
            let y = staff.y(ofPosition: p)
            ctx.move(to: CGPoint(x: glyph.head.midX - staff.space, y: y))
            ctx.addLine(to: CGPoint(x: glyph.head.midX + staff.space, y: y))
        }
        ctx.strokePath()
    }

    /// The table's outline and columns, each example's crop edges and
    /// scale corner, and while dragging the guides it snapped to and what
    /// the crop hides. Accent on the paper; the music is never recoloured.
    private func drawLegendOverlay(_ sheet: LegendArrangement.Sheet, in ctx: CGContext) {
        let accent = Theme.accent
        ctx.saveGState()
        defer { ctx.restoreGState() }
        let outcome = legendDrag?.outcome
        for r in outcome?.hidden ?? [] {
            ctx.setFillColor(Theme.paper.withAlphaComponent(0.82).cgColor)
            ctx.fill(viewRect(for: r))
        }
        // The frames and handles travel with what is being dragged.
        let overlay = LegendArrangement.overlay(of: sheet, outcome: outcome)
        ctx.setLineWidth(1)
        ctx.setStrokeColor(accent.withAlphaComponent(0.55).cgColor)
        ctx.setLineDash(phase: 0, lengths: [4, 3])
        ctx.stroke(viewRect(for: overlay.table).insetBy(dx: -3, dy: -3))
        if let w = overlay.words {
            let t = viewRect(for: overlay.table)
            let x = viewRect(for: w).minX
            ctx.move(to: CGPoint(x: x - 1, y: t.minY - 3))
            ctx.addLine(to: CGPoint(x: x - 1, y: t.maxY + 3))
            ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        for row in sheet.rows {
            guard let e = overlay.examples[row.index] else { continue }
            let r = viewRect(for: e)
            ctx.setStrokeColor(accent.withAlphaComponent(0.35).cgColor)
            ctx.stroke(r.insetBy(dx: -1, dy: -1))
            // Crop edges: short bars at mid-height; scale: a corner square.
            ctx.setFillColor(accent.cgColor)
            for x in [r.minX, r.maxX] { ctx.fill(CGRect(x: x - 1.5, y: r.midY - 7, width: 3, height: 14)) }
            ctx.fill(CGRect(x: r.maxX - 3.5, y: r.maxY - 3.5, width: 7, height: 7))
        }
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1)
        for g in outcome?.guides ?? [] {
            if g.axis == .vertical {
                let x = viewRect(for: Rect(x: g.at, y: 0, width: 0, height: 0)).minX
                ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height))
            } else {
                let y = viewRect(for: Rect(x: 0, y: g.at, width: 0, height: 0)).minY
                ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: bounds.width, y: y))
            }
        }
        ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [2, 2])
        let t = viewRect(for: sheet.table)
        for g in outcome?.marks ?? [] where g.axis == .vertical {
            let x = viewRect(for: Rect(x: g.at, y: 0, width: 0, height: 0)).minX
            ctx.move(to: CGPoint(x: x, y: t.minY - 6)); ctx.addLine(to: CGPoint(x: x, y: t.maxY + 6))
        }
        ctx.strokePath()
    }

    private func legendHandle(at p: NSPoint) -> LegendArrangement.Handle? {
        guard let owner, let sheet = owner.legendSheet(self), let legend = owner.legend else { return nil }
        return legend.handle(at: pagePoint(p), on: sheet, tolerance: owner.legendTolerance(self))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        guard owner?.legendArranging == true else { return }
        let p = convert(event.locationInWindow, from: nil)
        switch legendHandle(at: p) {
        case .some(let h) where h.isHorizontalResize: NSCursor.resizeLeftRight.set()
        case .some(.rowGap): NSCursor.resizeUpDown.set()
        case .some(.scale): NSCursor.crosshair.set()
        case .some(.table): NSCursor.openHand.set()
        default: NSCursor.arrow.set()
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if !legendCommitted, let handle = legendHandle(at: p) {
            if case .table = handle { NSCursor.closedHand.set() }
            legendDrag = (handle, pagePoint(p), nil)
            return
        }
        dragStart = p
    }

    override func mouseDragged(with event: NSEvent) {
        if let drag = legendDrag, let owner {
            let p = pagePoint(convert(event.locationInWindow, from: nil))
            legendDrag = (drag.handle, drag.start, owner.legendDrag(self, handle: drag.handle, from: drag.start, to: p, event: event))
            autoscroll(with: event)
            return
        }
        guard let start = dragStart else { return }
        let p = convert(event.locationInWindow, from: nil)
        dragRect = NSRect(x: min(start.x, p.x), y: min(start.y, p.y), width: abs(p.x - start.x), height: abs(p.y - start.y))
        autoscroll(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if let drag = legendDrag, let owner {
            if let outcome = drag.outcome {
                // The preview stays until the engraving replaces the page.
                legendCommitted = true
                owner.onLegendCommit(outcome)
            } else {
                legendDrag = nil
            }
            return
        }
        defer { dragStart = nil; dragRect = nil }
        guard let owner else { return }
        if let r = dragRect, r.width > 4 || r.height > 4 {
            let a = pagePoint(NSPoint(x: r.minX, y: r.minY)), b = pagePoint(NSPoint(x: r.maxX, y: r.maxY))
            owner.pageView(self, selected: Rect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y))
        } else {
            owner.pageView(self, clickedAt: pagePoint(convert(event.locationInWindow, from: nil)), event: event)
        }
    }
}

/// Compares the file paths LilyPond embeds with ours, through symlinks
/// (macOS's /tmp → /private/tmp is the classic trap).
enum PathMatching {
    static func same(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let ra = URL(fileURLWithPath: a).resolvingSymlinksInPath().standardizedFileURL.path
        let rb = URL(fileURLWithPath: b).resolvingSymlinksInPath().standardizedFileURL.path
        return ra == rb
    }
}

/// A small spinner on the work region's corner, on the app's chrome (solid,
/// so Reduce Transparency changes nothing). Its words are for VoiceOver and
/// the tooltip; the status bar shows them too.
@MainActor
private final class WorkBadge: NSView {
    init(label: String) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.cgColor
        layer?.cornerRadius = 10
        layer?.borderWidth = 1
        layer?.borderColor = Theme.accent.cgColor
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 20), heightAnchor.constraint(equalToConstant: 20),
            spinner.widthAnchor.constraint(equalToConstant: 14), spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel(label)
        toolTip = "\(label): the outlined music is being changed. ⌘⌥. stops it."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Clicks go through to the page: the badge is information, not a control.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

