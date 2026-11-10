import AppKit
import PondsideCore
import PondsideEngrave

@MainActor
protocol ScoreCanvasDelegate: AnyObject {
    /// The user clicked a linked glyph (or empty paper: nil), at a page point.
    func canvas(_ canvas: ScoreCanvasView, didClick link: PointAndClickLocation?,
                at page: Int?, point: Point?, extending: Bool)
    /// The user clicked a graphic with ⌥ held (no drag): show its source.
    func canvas(_ canvas: ScoreCanvasView, didClickGraphic link: PointAndClickLocation)
    /// Whether a link is a graphic's `\\start…` command (for ⌥ selection).
    func canvas(_ canvas: ScoreCanvasView, isGraphicLink link: PointAndClickLocation) -> Bool
    /// Whether a link's graphics take a click only on their drawn shape
    /// (a slur), not anywhere in their bounding box.
    func canvas(_ canvas: ScoreCanvasView, hitsByOutline link: PointAndClickLocation) -> Bool
    /// The user dragged a selection rectangle over these links.
    func canvas(_ canvas: ScoreCanvasView, didSelect links: [PointAndClickLocation])
    /// The user marked a graphic section (⌥-drag), or cleared it (nil).
    func canvas(_ canvas: ScoreCanvasView, didSelectGraphicSection section: GraphicSection?)
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
    var onCopyNotation: (() -> Void)?
    var onCutNotation: (() -> Void)?
    var onPasteNotation: (() -> Void)?
    @objc func copy(_ sender: Any?) { onCopyNotation?() }
    @objc func cut(_ sender: Any?) { onCutNotation?() }
    @objc func paste(_ sender: Any?) { onPasteNotation?() }


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

    private var breakFeedback: NSImageView?

    func clearBreakFeedback() {
        breakFeedback?.layer?.removeAllAnimations()
        breakFeedback?.removeFromSuperview()
        breakFeedback = nil
    }

    func showBreakFeedback(kind: StructuralEditing.BreakKind, removing: Bool = false) {
        guard breakFeedback == nil else { return }
        let badge = BreakProgressIcon()
        let label = "\(removing ? "Removing" : "Adding") \(kind == .page ? "page" : "system") break · engraving…"
        badge.image = NSImage(systemSymbolName: kind == .page ? "doc" : "arrow.turn.down.left", accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .medium))
        badge.contentTintColor = Theme.accent
        badge.imageScaling = .scaleProportionallyDown
        badge.toolTip = label
        badge.setAccessibilityElement(true)
        badge.setAccessibilityRole(.image)
        badge.setAccessibilityLabel(label)
        badge.wantsLayer = true
        badge.layer?.backgroundColor = Theme.chrome.withAlphaComponent(0.94).cgColor
        badge.layer?.cornerRadius = 6
        let rect = selectionAnchor ?? NSRect(x: visibleRect.midX, y: visibleRect.minY + 40, width: 2, height: 20)
        badge.frame = NSRect(x: min(max(visibleRect.minX + 8, rect.minX), max(visibleRect.minX + 8, visibleRect.maxX - 32)),
                             y: max(visibleRect.minY + 8, rect.minY - 30), width: 24, height: 24)
        addSubview(badge, positioned: .above, relativeTo: nil)
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.65
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            badge.layer?.add(pulse, forKey: "waitingForBreakRender")
        }
        breakFeedback = badge
        displayIfNeeded()
        CATransaction.flush()
    }

    // MARK: Content

    /// Replaces the pages, cross-fading so a recompile never flickers.
    func setPages(_ newPages: [EngravedPage]) {
        lastInserted = nil
        playhead = nil
        graphicSectionSelection = nil
        sectionDrag = nil
        pendingLegend = [:]
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

    /// Marks systems that run into the right margin (automatic line breaks
    /// off): the overrun tinted red past a rule at the justified edge. Passive
    /// feedback; it never moves the music or takes focus.
    func setOverflows(_ list: [SystemOverflow]) {
        for (n, v) in pageViews.enumerated() { v.overflows = list.filter { $0.page == n } }
    }

    // MARK: Playback head

    /// The audio's place in the score: one line over the system playing now,
    /// in page coordinates. A display-only cursor; it never takes focus.
    private(set) var playhead: PlayheadPosition? {
        didSet {
            guard playhead != oldValue else { return }
            for (n, v) in pageViews.enumerated() { v.playhead = playhead?.page == n ? playhead : nil }
        }
    }

    func setPlayhead(_ position: PlayheadPosition?) {
        playhead = position
    }

    /// Brings a new system into view. Called when the head moves to another
    /// system, not on every tick, so the page doesn't creep while it plays.
    /// Following playback: glide so the playhead's whole system sits in the
    /// middle of the view (horizontally only when the head is off screen).
    /// Reduce Motion jumps instead.
    func centerPlayheadSystem() {
        guard let p = playhead, pageViews.indices.contains(p.page),
              let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let v = pageViews[p.page]
        let rect = convert(v.viewRect(for: Rect(x: p.x, y: p.top, width: 0, height: p.bottom - p.top)), from: v)
        let view = clip.bounds
        var origin = view.origin
        origin.y = rect.midY - view.height / 2
        if rect.midX < view.minX + 24 || rect.midX > view.maxX - 24 { origin.x = rect.midX - view.width / 2 }
        origin.x = min(max(origin.x, 0), max(0, bounds.width - view.width))
        origin.y = min(max(origin.y, 0), max(0, bounds.height - view.height))
        guard abs(origin.x - view.minX) > 1 || abs(origin.y - view.minY) > 1 else { return }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.45
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            context.allowsImplicitAnimation = true
            clip.animator().setBoundsOrigin(origin)
        }, completionHandler: { scrollView.reflectScrolledClipView(clip) })
    }

    // MARK: Collection anchor

    /// Where the selection starts in time (a collection: where it is
    /// anchored): a dashed line in the accent over its system, drawn on the
    /// latest engraving, so a move shows before the engraving that prints it
    /// lands. Its time stamp is in the transport (`TransportView`).
    private(set) var collectionAnchor: PlayheadPosition?
    /// A click's moment, given as soon as the line is placed from it.
    var onAnchorMoment: ((LensFraction) -> Void)?

    /// Moments of the shown engraving's glyphs and its clock, for placing
    /// the line at a click before the source is looked up.
    var momentMap: MomentMap?

    func setCollectionAnchor(_ position: PlayheadPosition?, reveal: Bool) {
        if position != collectionAnchor {
            collectionAnchor = position
            for (n, v) in pageViews.enumerated() { v.collectionAnchor = position?.page == n ? position : nil }
        }
        if reveal, let r = collectionAnchorRect, !visibleRect.insetBy(dx: 24, dy: 0).intersects(r) {
            scrollToVisible(r.insetBy(dx: -120, dy: -24))
        }
    }

    /// The line's system, in canvas coordinates.
    var collectionAnchorRect: NSRect? {
        guard let p = collectionAnchor, pageViews.indices.contains(p.page) else { return nil }
        let v = pageViews[p.page]
        return convert(v.viewRect(for: Rect(x: p.x, y: p.top, width: 0, height: p.bottom - p.top)), from: v)
            .insetBy(dx: -1, dy: 0)
    }

    func revealPlayhead() {
        guard let p = playhead, pageViews.indices.contains(p.page) else { return }
        let v = pageViews[p.page]
        let rect = convert(v.viewRect(for: Rect(x: p.x, y: p.top, width: 0, height: p.bottom - p.top)), from: v)
        guard !visibleRect.insetBy(dx: -24, dy: -24).contains(rect) else { return }
        scrollToVisible(rect.insetBy(dx: -80, dy: -40))
    }

    // MARK: Graphic section (⌥-drag)

    /// The section marked with ⌥-drag; what a graphics request may change.
    private(set) var graphicSectionSelection: GraphicSection?

    /// The section's boxes in canvas coordinates, for the request popover.
    var graphicSectionAnchor: NSRect? {
        guard let section = graphicSectionSelection else { return nil }
        var union: NSRect?
        for s in section.systems where pageViews.indices.contains(s.page) {
            let v = pageViews[s.page]
            let r = convert(v.viewRect(for: Rect(x: s.pageX.lowerBound, y: s.staff.top,
                                                 width: s.pageX.upperBound - s.pageX.lowerBound,
                                                 height: s.staff.bottom - s.staff.top)), from: v)
            union = union.map { $0.union(r) } ?? r
        }
        return union
    }

    private struct SectionDrag {
        var startPage: Int
        var start: Point
        var link: PointAndClickLocation?
    }
    private var sectionDrag: SectionDrag?

    fileprivate func beginGraphicSection(page: Int, point: Point, link: PointAndClickLocation?) {
        guard !legendArranging else { return }
        sectionDrag = SectionDrag(startPage: page, start: point, link: link)
        graphicSectionSelection = nil
        pageViews.forEach { $0.sectionBoxes = []; $0.highlights = [] }
    }

    fileprivate func updateGraphicSection(windowPoint: NSPoint) {
        guard let drag = sectionDrag else { return }
        let end = sectionEnd(windowPoint: windowPoint, startPage: drag.startPage)
        guard let section = GraphicSection.make(pages: pages.map(\.page),
                                               from: (drag.startPage, drag.start),
                                               to: end, link: drag.link) else {
            pageViews.forEach { $0.sectionBoxes = [] }
            return
        }
        showGraphicSection(section)
    }

    fileprivate func endGraphicSection(windowPoint: NSPoint) {
        guard let drag = sectionDrag else { return }
        let end = sectionEnd(windowPoint: windowPoint, startPage: drag.startPage)
        sectionDrag = nil
        let section = GraphicSection.make(pages: pages.map(\.page),
                                         from: (drag.startPage, drag.start),
                                         to: end, link: drag.link)
        graphicSectionSelection = section
        if let section {
            showGraphicSection(section)
            delegate?.canvas(self, didSelectGraphicSection: section)
        } else {
            pageViews.forEach { $0.sectionBoxes = [] }
            // An ⌥-click with no drag is the graphic's source navigation;
            // a drag is the section request.
            if let link = drag.link { delegate?.canvas(self, didClickGraphic: link) }
            delegate?.canvas(self, didSelectGraphicSection: nil)
        }
    }

    /// Clears the section; a normal click or ⎋ does this.
    func clearGraphicSection(notify: Bool = true) {
        guard graphicSectionSelection != nil || sectionDrag != nil else { return }
        sectionDrag = nil
        graphicSectionSelection = nil
        pageViews.forEach { $0.sectionBoxes = [] }
        if notify { delegate?.canvas(self, didSelectGraphicSection: nil) }
    }

    private func showGraphicSection(_ section: GraphicSection) {
        pageViews.forEach { $0.sectionBoxes = [] }
        for s in section.systems where pageViews.indices.contains(s.page) {
            let r = Rect(x: s.pageX.lowerBound, y: s.staff.top,
                         width: s.pageX.upperBound - s.pageX.lowerBound,
                         height: s.staff.bottom - s.staff.top)
            pageViews[s.page].sectionBoxes.append(r)
        }
    }

    /// The release's page and page point. Over a page, its nearest system is
    /// the end system; outside the sheets, the nearest system by vertical
    /// distance over every page is used, so a drag off the paper still ends
    /// on a system (and the x is taken on that page).
    private func sectionEnd(windowPoint: NSPoint, startPage: Int) -> (page: Int, point: Point) {
        let p = convert(windowPoint, from: nil)
        if let page = pageViews.indices.first(where: { pageViews[$0].frame.contains(p) }) {
            let v = pageViews[page]
            return (page, v.pagePoint(v.convert(p, from: self)))
        }
        var best: (page: Int, distance: CGFloat, point: Point)?
        for (i, v) in pageViews.enumerated() {
            guard let rendered = v.rendered else { continue }
            let pagePoint = v.pagePoint(v.convert(p, from: self))
            for band in EngravedPage.systems(of: rendered.page.staves) {
                let r = convert(v.viewRect(for: Rect(x: 0, y: band.lowerBound, width: 0,
                                                     height: band.upperBound - band.lowerBound)), from: v)
                let distance: CGFloat = p.y < r.minY ? r.minY - p.y : (p.y > r.maxY ? p.y - r.maxY : 0)
                if best == nil || distance < best!.distance { best = (i, distance, pagePoint) }
            }
        }
        if let best { return (best.page, best.point) }
        let page = pageViews.indices.min {
            pageDistance(pageViews[$0].frame, p) < pageDistance(pageViews[$1].frame, p)
        } ?? startPage
        let v = pageViews[page]
        return (page, v.pagePoint(v.convert(p, from: self)))
    }

    private func pageDistance(_ rect: NSRect, _ p: NSPoint) -> CGFloat {
        let dx = max(max(rect.minX - p.x, 0), p.x - rect.maxX)
        let dy = max(max(rect.minY - p.y, 0), p.y - rect.maxY)
        return (dx * dx + dy * dy).squareRoot()
    }

    // MARK: Arranging the legend

    /// Arrange mode: the legend's handles show, and drags on a legend page
    /// move its table, columns and rows, or crop and scale an example.
    var legendArranging = false {
        didSet {
            guard legendArranging != oldValue else { return }
            legend = legendArranging ? LegendArrangement(pages: pages.map(\.page)) : nil
            pendingLegend = [:]
            clearGraphicSection(notify: false)
            pageViews.forEach { $0.legendDrag = nil; $0.needsDisplay = true; $0.window?.invalidateCursorRects(for: $0) }
        }
    }
    private(set) var legend: LegendArrangement?
    /// The pages that hold the legend's table.
    private(set) var legendPages: Set<Int> = []

    /// Drags committed since the pages were last engraved, by page. A drag
    /// made before the next engraving lands starts from these, so the page
    /// and the handles stay where the last drop left them.
    private var pendingLegend: [Int: [LegendArrangement.Outcome]] = [:]

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
        guard legendArranging, let n = v.pageIndex, var sheet = legend?.sheet(page: n) else { return nil }
        for outcome in pendingLegend[n] ?? [] { sheet = sheet.applying(outcome) }
        return sheet
    }

    /// A drag's starting point: the sheet and the file's values as the last
    /// committed drag left them.
    fileprivate func legendBaseline(_ v: PageView)
        -> (sheet: LegendArrangement.Sheet, layout: FrontMatter.LegendLayout, examples: [FrontMatter.ExampleLayout])? {
        guard let sheet = legendSheet(v) else { return nil }
        let (layout, examples) = legendValues()
        return (sheet, layout, examples)
    }

    /// Keeps a finished drag as the preview the next drag starts from, until
    /// the engraving replaces the page, and writes it.
    fileprivate func commitLegend(_ v: PageView, _ outcome: LegendArrangement.Outcome) {
        guard let n = v.pageIndex else { return }
        pendingLegend[n, default: []].append(outcome)
        onLegendCommit(outcome)
    }

    fileprivate func pendingLegendOutcomes(for page: Int?) -> [LegendArrangement.Outcome] {
        guard let page else { return [] }
        return pendingLegend[page] ?? []
    }

    /// Handle tolerance: 5 points on screen, in page units.
    fileprivate func legendTolerance(_ v: PageView) -> Double {
        guard let vb = v.rendered?.page.viewBox, v.bounds.width > 0 else { return 1 }
        return 5 * vb.width / v.bounds.width
    }

    fileprivate func legendDrag(_ v: PageView, handle: LegendArrangement.Handle, from start: Point, to p: Point,
                                event: NSEvent) -> LegendArrangement.Outcome? {
        guard let legend, let baseline = legendBaseline(v) else { return nil }
        let outcome = legend.drag(handle, on: baseline.sheet, from: start, to: p,
                                  layout: baseline.layout, examples: baseline.examples,
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

    /// Highlights every graphic produced by the given source positions.
    /// The highlight is an overlay; the music itself is never recoloured.
    func highlight(_ positions: Set<SourcePosition>, path: String?, reveal: Bool) {
        var firstRect: NSRect?
        selectionAnchor = nil
        var sameFile: [String: Bool] = [:]
        for v in pageViews {
            guard let page = v.rendered?.page else { continue }
            let matches = positions.flatMap { page.linkedGraphics(at: $0) }.filter { g in
                guard !v.removed.contains(g) else { return false }
                guard let link = g.link else { return false }
                guard let path else { return true }
                if let known = sameFile[link.path] { return known }
                let same = PathMatching.same(link.path, path)
                sameFile[link.path] = same
                return same
            }
            v.highlights = matches.map(\.bounds)
            let shown = matches.dropFirst().reduce(matches.first?.bounds) { acc, g in acc?.union(g.bounds) }
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
        // A graphics request's region is its marked section, not the note
        // highlight: the request starts from the section's `\start…` link,
        // where there is no event to highlight.
        for v in pageViews { v.working = v.sectionBoxes.isEmpty ? v.highlights : v.sectionBoxes }
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
        var outline: [PointAndClickLocation: Bool] = [:]
        let byOutline: (PointAndClickLocation) -> Bool = { [unowned self] link in
            if let known = outline[link] { return known }
            let answer = delegate?.canvas(self, hitsByOutline: link) ?? false
            outline[link] = answer
            return answer
        }
        let link = v.rendered?.page.hitTest(p, tolerance: tolerance, excluding: v.removed, byOutline: byOutline)?.link
            ?? v.rendered?.page.regionHit(p, excluding: v.removed, byOutline: byOutline)?.link
        let extending = event.modifierFlags.contains(.shift)
        if let link, let page = v.rendered?.page, delegate?.canvas(self, isGraphicLink: link) != true {
            // Outline what was clicked now, from its own glyphs, and put it on
            // screen before the source is looked up; the selection's own
            // highlight replaces it a moment later.
            let glyphs = page.linkedGraphics(at: link.position).filter { $0.link?.path == link.path && !v.removed.contains($0) }
            if !glyphs.isEmpty {
                if !extending { for other in pageViews where other !== v { other.highlights = [] } }
                v.highlights = (extending ? v.highlights : []) + glyphs.map(\.bounds)
                if !extending, let m = momentMap?.moment(of: link) {
                    setCollectionAnchor(momentMap?.position(at: m), reveal: false)
                    onAnchorMoment?(m)
                }
                CATransaction.flush()
            }
        }
        delegate?.canvas(self, didClick: link, at: pageViews.firstIndex { $0 === v }, point: p, extending: extending)
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

    var editFeedbackAnchor: NSRect? {
        if let lastInserted { return convert(lastInserted.view.viewRect(for: lastInserted.glyph.head), from: lastInserted.view) }
        return selectionAnchor
    }

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
        clearGraphicSection()
        delegate?.canvas(self, didClick: nil, at: nil, point: nil, extending: false)
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
            playhead = nil
            sectionBoxes = []
            needsDisplay = true
            updateWork()
        }
    }
    private(set) var staves: [Staff] = []
    /// The audio's place on this page, when it is the page playing.
    var playhead: PlayheadPosition? { didSet { if playhead != oldValue { updatePlayhead() } } }
    var collectionAnchor: PlayheadPosition? { didSet { if collectionAnchor != oldValue { updateCollectionAnchor() } } }
    private let anchorLine = CAShapeLayer()
    /// The ⌥-drag section's boxes on this page, in page coordinates.
    var sectionBoxes: [Rect] = [] { didSet { if sectionBoxes != oldValue { needsDisplay = true } } }
    /// Engraved note glyphs moved to provisional (not yet engraved) positions.
    var provisional: [NoteGlyph] = [] { didSet { if provisional != oldValue { needsDisplay = true } } }
    /// Glyphs the provisional deletion has taken out of the page.
    var removed: Set<Graphic> = [] { didSet { if removed != oldValue { needsDisplay = true } } }
    var badges: [(Rect, String)] = [] { didSet { needsDisplay = true } }
    /// The selection's outline, on its own layer: selecting never redraws the music.
    var highlights: [Rect] = [] { didSet { if highlights != oldValue { updateHighlights() } } }
    private let highlightLayer = CAShapeLayer()
    var overflows: [SystemOverflow] = [] { didSet { if overflows != oldValue { needsDisplay = true } } }
    var lightsOut = false { didSet { needsDisplay = true } }
    /// The region an agent is working on (page coordinates): outlined on a
    /// layer of its own, so the pulse never redraws the music.
    var working: [Rect] = [] { didSet { if working != oldValue { updateWork() } } }
    private let workLayer = CAShapeLayer()
    /// A blurred copy of the music in the work region, faded in and out.
    private let blurLayer = CALayer()
    /// Blurs the snapshot itself: a layer filter is not reliable on a
    /// sublayer, and the copy must really be blurred to read as work.
    private lazy var blurContext = CIContext(options: nil)
    /// The playback head, on layers of its own so following the audio never
    /// redraws the music.
    private let playheadLine = CAShapeLayer()
    private let playheadCap = CAShapeLayer()
    private var displayOptionsObserver: NSObjectProtocol?

    /// The work region in view coordinates, padded like the outline.
    var workBounds: NSRect? {
        guard let first = working.first else { return nil }
        return working.dropFirst().reduce(viewRect(for: first)) { $0.union(viewRect(for: $1)) }.insetBy(dx: -4, dy: -4)
    }
    private var dragStart: NSPoint?
    private var dragRect: NSRect? { didSet { needsDisplay = true } }
    var pageIndex: Int?
    /// This page received the ⌥-mouse-down of a graphic-section drag; the
    /// events go to the owner because the release may be on another page.
    private var sectionDragging = false
    /// A legend drag: its handle, where it began, and what it makes so far
    /// (kept, drawn, until the next engraving replaces the page).
    var legendDrag: (handle: LegendArrangement.Handle, start: Point, outcome: LegendArrangement.Outcome?)? {
        didSet { needsDisplay = true }
    }

    /// The committed drags still waiting for an engraving, plus the one in
    /// progress, in the order they applied.
    private var legendOutcomes: [LegendArrangement.Outcome] {
        (owner?.pendingLegendOutcomes(for: pageIndex) ?? []) + [legendDrag?.outcome].compactMap { $0 }
    }

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
        for head in [playheadLine, playheadCap] {
            head.isHidden = true
            head.zPosition = 2
            layer?.addSublayer(head)
        }
        playheadLine.fillColor = nil
        playheadLine.lineCap = .round
        highlightLayer.zPosition = 1.2
        highlightLayer.fillColor = Theme.accent.withAlphaComponent(0.16).cgColor
        highlightLayer.strokeColor = Theme.accent.withAlphaComponent(0.9).cgColor
        highlightLayer.lineWidth = 1
        layer?.addSublayer(highlightLayer)
        anchorLine.isHidden = true
        anchorLine.zPosition = 1.5
        anchorLine.fillColor = nil
        layer?.addSublayer(anchorLine)
        playheadCap.fillColor = Theme.accent.cgColor
        displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateWork(); self?.updatePlayhead(); self?.updateCollectionAnchor() }
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
            updatePlayhead()
            updateCollectionAnchor()
            updateHighlights()
        }
    }

    private func updateHighlights() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let path = CGMutablePath()
        for r in highlights {
            path.addRoundedRect(in: viewRect(for: r).insetBy(dx: -3, dy: -3), cornerWidth: 3, cornerHeight: 3)
        }
        highlightLayer.frame = bounds
        highlightLayer.path = path
    }

    /// The anchor line on its own layer, like the playhead: moving it never
    /// redraws the music. Dashed, so it never reads as a barline.
    private func updateCollectionAnchor() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let p = collectionAnchor, rendered != nil else {
            anchorLine.isHidden = true
            return
        }
        let r = viewRect(for: Rect(x: p.x, y: p.top, width: 0, height: p.bottom - p.top))
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let line = CGMutablePath()
        line.move(to: CGPoint(x: r.midX, y: r.minY))
        line.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        anchorLine.frame = bounds
        anchorLine.path = line
        anchorLine.strokeColor = Theme.accent.withAlphaComponent(contrast ? 1 : 0.85).cgColor
        anchorLine.lineWidth = contrast ? 2 : 1.25
        anchorLine.lineDashPattern = [5, 3]
        anchorLine.isHidden = false
    }

    /// Places the head on its own layers: following the audio never redraws
    /// the music, and it stays above the page under Lights Out.
    private func updatePlayhead() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let p = playhead, rendered != nil else {
            playheadLine.isHidden = true
            playheadCap.isHidden = true
            return
        }
        let r = viewRect(for: Rect(x: p.x, y: p.top, width: 0, height: p.bottom - p.top))
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let line = CGMutablePath()
        line.move(to: CGPoint(x: r.midX, y: r.minY))
        line.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        playheadLine.frame = bounds
        playheadLine.path = line
        playheadLine.strokeColor = Theme.accent.withAlphaComponent(contrast ? 1 : 0.85).cgColor
        playheadLine.lineWidth = contrast ? 2.5 : 1.75
        playheadLine.isHidden = false
        let radius: CGFloat = contrast ? 4.5 : 3.5
        playheadCap.frame = bounds
        playheadCap.path = CGPath(ellipseIn: CGRect(x: r.midX - radius, y: r.minY - radius,
                                                     width: radius * 2, height: radius * 2), transform: nil)
        playheadCap.fillColor = Theme.accent.cgColor
        playheadCap.isHidden = false
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
        let image = rep.cgImage
        if let image {
            let source = CIImage(cgImage: image)
            let blurred = source.clampedToExtent()
                .applyingGaussianBlur(sigma: 3.5)
                .cropped(to: source.extent)
            blurLayer.contents = blurContext.createCGImage(blurred, from: source.extent) ?? image
        } else {
            blurLayer.contents = nil
        }
        blurLayer.contentsScale = window?.backingScaleFactor ?? 2
        blurLayer.filters = []
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
        let outcomes = legendOutcomes
        var moving: [(Graphic, PondsideEngrave.AffineTransform)] = []
        if !outcomes.isEmpty {
            for g in rendered.page.graphics {
                var point = Point(g.bounds.midX, g.bounds.midY)
                var transform = PondsideEngrave.AffineTransform.identity
                for outcome in outcomes {
                    guard let t = outcome.moves.first(where: { $0.region.contains(point) })?.transform else { continue }
                    transform = transform.then(t)
                    point = t.apply(point)
                }
                if !transform.isIdentity { moving.append((g, transform)) }
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

        drawOverflows(in: ctx)

        let accent = Theme.accent

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

        // The ⌥-drag section: one box per system, the whole staff tall.
        if !sectionBoxes.isEmpty {
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            for r in sectionBoxes {
                let rect = viewRect(for: r).insetBy(dx: -2, dy: -2)
                let path = CGPath(roundedRect: rect, cornerWidth: 3, cornerHeight: 3, transform: nil)
                ctx.addPath(path)
                ctx.setFillColor(accent.withAlphaComponent(contrast ? 0.2 : 0.12).cgColor)
                ctx.fillPath()
                ctx.addPath(path)
                ctx.setStrokeColor(accent.withAlphaComponent(contrast ? 1 : 0.85).cgColor)
                ctx.setLineWidth(contrast ? 2.5 : 1.5)
                ctx.strokePath()
            }
        }

        if let dragRect {
            ctx.setFillColor(accent.withAlphaComponent(0.08).cgColor)
            ctx.fill(dragRect)
            ctx.setStrokeColor(accent.withAlphaComponent(0.7).cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(dragRect.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private func drawOverflows(in ctx: CGContext) {
        guard !overflows.isEmpty else { return }
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let red = Theme.error
        for o in overflows {
            let top = o.band.lowerBound - 1, bottom = o.band.upperBound + 1
            let over = viewRect(for: Rect(x: o.edge, y: top, width: o.right - o.edge, height: bottom - top))
            ctx.setFillColor(red.withAlphaComponent(contrast ? 0.28 : 0.16).cgColor)
            ctx.fill(over)
            ctx.setStrokeColor(red.withAlphaComponent(contrast ? 1 : 0.85).cgColor)
            ctx.setLineWidth(contrast ? 2.5 : 1.5)
            ctx.move(to: CGPoint(x: over.minX, y: over.minY))
            ctx.addLine(to: CGPoint(x: over.minX, y: over.maxY))
            ctx.strokePath()
            let label = NSAttributedString(string: String(format: "+%.1f mm", o.amountMM), attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: red])
            let size = label.size()
            label.draw(at: NSPoint(x: max(over.minX + 3, min(over.maxX - size.width, bounds.maxX - size.width - 2)),
                                   y: over.minY - size.height - 1))
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
        // What a crop hides, carried along by drags that came after it.
        let outcomes = legendOutcomes
        for (i, dragged) in outcomes.enumerated() {
            for hidden in dragged.hidden {
                var r = hidden
                for later in outcomes.dropFirst(i + 1) {
                    if let t = later.moves.first(where: { $0.region.contains(Point(r.midX, r.midY)) })?.transform {
                        r = r.transformed(by: t)
                    }
                }
                ctx.setFillColor(Theme.paper.withAlphaComponent(0.82).cgColor)
                ctx.fill(viewRect(for: r))
            }
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
        if event.modifierFlags.contains(.option), owner?.legendArranging != true {
            NSCursor.crosshair.set()
            return
        }
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
        let pageP = pagePoint(p)
        if let owner, !owner.legendArranging, event.modifierFlags.contains(.option) {
            owner.beginGraphicSection(page: pageIndex ?? 0, point: pageP, link: graphicLink(at: pageP))
            sectionDragging = true
            return
        }
        owner?.clearGraphicSection()
        // A committed drag still previewing is not a drag in progress: this
        // press may take another handle where the last drop left it.
        legendDrag = nil
        if let handle = legendHandle(at: p) {
            if case .table = handle { NSCursor.closedHand.set() }
            legendDrag = (handle, pageP, nil)
            return
        }
        dragStart = p
    }

    /// The graphic under the ⌥-press: directly, its region, or the one that
    /// spans this staff at the same x (a drawing above the staff). A note
    /// link is not a graphic, even when the press lands on one.
    private func graphicLink(at p: Point) -> PointAndClickLocation? {
        guard let page = rendered?.page, let owner else { return nil }
        func graphic(_ link: PointAndClickLocation?) -> PointAndClickLocation? {
            guard let link, owner.delegate?.canvas(owner, isGraphicLink: link) == true else { return nil }
            return link
        }
        let tolerance = 0.3 / max(owner.zoom, 0.5)
        if let link = graphic(page.hitTest(p, tolerance: tolerance, excluding: removed)?.link) { return link }
        if let link = graphic(page.regionHit(p, excluding: removed)?.link) { return link }
        let staffs = page.staves.sorted {
            abs(($0.top + $0.bottom) / 2 - p.y) < abs(($1.top + $1.bottom) / 2 - p.y)
        }
        for staff in staffs where p.x >= staff.minX - 6 && p.x <= staff.maxX + 6 {
            let mid = Point(p.x, (staff.top + staff.bottom) / 2)
            if let link = graphic(page.regionHit(mid, excluding: removed)?.link) { return link }
        }
        return nil
    }

    override func mouseDragged(with event: NSEvent) {
        if sectionDragging, let owner {
            owner.updateGraphicSection(windowPoint: event.locationInWindow)
            autoscroll(with: event)
            return
        }
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
        if sectionDragging, let owner {
            sectionDragging = false
            owner.endGraphicSection(windowPoint: event.locationInWindow)
            return
        }
        if let drag = legendDrag, let owner {
            if let outcome = drag.outcome {
                // The preview stays until the engraving replaces the page,
                // and the next drag starts from it.
                owner.commitLegend(self, outcome)
            }
            legendDrag = nil
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


@MainActor
private final class BreakProgressIcon: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
