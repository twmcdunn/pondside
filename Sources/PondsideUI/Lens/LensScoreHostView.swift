import AppKit
import SwiftUI
import PondsideCore
import SheetMusicCore
import SheetMusicMusicXML
import SheetMusicLayout
import SheetMusicLayoutApple
import SheetMusicUI

@available(macOS 15.0, *)
@MainActor
final class LensScoreHostView: NSView {
    var enteringNotes = false
    var onSelectEvent: ((Int, Bool) -> Void)?
    private var displayedSelectionHandler: ((Int, Bool) -> Void)?
    /// A slur was clicked: its opening event and whether it is a phrasing slur.
    var onSelectSlur: ((Int, Bool) -> Void)?
    /// A mark other than a slur was clicked: its event and kind.
    var onSelectMark: ((Int, LensMarkKind) -> Void)?
    private var displayedMarkHandler: ((Int, LensMarkKind) -> Void)?
    private var displayedSlurHandler: ((Int, Bool) -> Void)?
    private let scrollView = NSScrollView()
    private var document: LayoutDocument?
    private var target: VoiceElementID?
    private var targetMeasure = 0
    private var lensWindow: LensScoreWindow?
    private var renderedScore: Score?
    private var hosting: NSHostingView<ScoreView>?
    private let cursorView = LensCursorView()
    private(set) var layoutCount = 0
    private(set) var lastLayoutWasOnMainThread: Bool?
    private let layoutWorker = LensLayoutWorker()
    private var loadTask: Task<Void, Never>?
    private var loadRevision = 0
    private(set) var isLoading = false
    var onLoad: (() -> Void)?
    var onFailure: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .none
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Lays out `lens`. The scroll position carries over, so a refresh
    /// glides from where the strip was rather than jumping back to its start.
    func load(_ lens: LensScoreWindow) throws {
        // Bravura metrics, not the stub: layout runs before any SheetMusicUI view would install them.
        _ = SheetMusicLayoutApple.install
        var options = ScoreViewOptions()
        options.staffSize = 30
        options.wrapToViewWidth = false
        options.breakPolicy = .ignoreAll
        options.breakIndicatorVisibility = .none
        options.includeTitleFrame = false
        options.lyricsVisible = false
        loadRevision += 1
        let revision = loadRevision
        let selectionHandler = onSelectEvent
        loadTask?.cancel()
        if let previous = lensWindow, LensLayoutWorker.sameMusic(previous, lens),
           let score = renderedScore, let document {
            isLoading = false
            install(lens, score: score, document: document, options: options, selectionHandler: selectionHandler)
            return
        }
        isLoading = true
        let worker = layoutWorker
        loadTask = Task { @MainActor [weak self] in
            do {
                let prepared = try await worker.prepare(lens, options: options)
                guard !Task.isCancelled, let self, self.loadRevision == revision else { return }
                self.isLoading = false
                self.loadTask = nil
                self.layoutCount = prepared.layoutCount
                self.lastLayoutWasOnMainThread = prepared.wasOnMainThread
                self.install(lens, score: prepared.score, document: prepared.document, options: options, selectionHandler: selectionHandler)
            } catch is CancellationError { }
            catch {
                guard let self, self.loadRevision == revision else { return }
                self.isLoading = false
                self.loadTask = nil
                self.onFailure?("Notation Lens could not display this passage: \(error)")
            }
        }
    }

    private func install(_ lens: LensScoreWindow, score: Score, document: LayoutDocument, options: ScoreViewOptions, selectionHandler: ((Int, Bool) -> Void)?) {
        displayedSelectionHandler = selectionHandler
        displayedSlurHandler = onSelectSlur
        displayedMarkHandler = onSelectMark
        self.document = document
        self.lensWindow = lens
        self.renderedScore = score

        targetMeasure = lens.target?.measureIndex ?? 0
        let selected = LensScoreAdapter.items(of: lens, in: score)
        var selection: ScoreSelection
        if let (id, item) = LensScoreAdapter.target(of: lens, in: score) {
            target = id
            selection = selected.count > 1 ? .multi(selected) : .single(item)
        } else {
            selection = selected.isEmpty ? .none : .multi(selected)
            target = nil
        }
        // A selected slur is outlined instead of its notes: the renderer
        // tints notes and text only, so the outline is drawn here.
        cursorView.slurRects = []
        if !enteringNotes, let index = lens.selectedSlur,
           let id = LensScoreAdapter.slurID(of: index, in: lens, score: score) {
            selection = .none
            cursorView.slurRects = ScoreHitTester(document: document).elementHitRects(for: .slur(id))
        }

        let view = ScoreView(document: document, score: score, options: options,
            selection: enteringNotes ? .none : selection,
            voiceColors: Dictionary(uniqueKeysWithValues: (0..<4).map { ($0, Color(nsColor: Theme.accent)) }))
        let hosting: NSHostingView<ScoreView>
        if let existing = self.hosting {
            hosting = existing
            hosting.rootView = view
        } else {
            hosting = NSHostingView(rootView: view)
            self.hosting = hosting
        }
        hosting.frame = NSRect(origin: .zero, size: document.size)
        cursorView.frame = hosting.bounds
        if enteringNotes {
            let point = target.flatMap { document.chordStemOrigin(at: $0) }
            let system = document.systems.first
            let measure = system?.measures.first { $0.measureIndex == targetMeasure }
            cursorView.cursor = point ?? CGPoint(x: (system?.origin.x ?? 0) + (measure?.origin.x ?? 0) + 24,
                                                y: (system?.origin.y ?? 0) + (measure?.origin.y ?? 0) + 30)
        } else { cursorView.cursor = nil }
        cursorView.needsDisplay = true
        hosting.addSubview(cursorView, positioned: .above, relativeTo: nil)
        let clip = scrollView.contentView
        let previous = clip.bounds.origin
        if scrollView.documentView !== hosting { scrollView.documentView = hosting }
        clip.scroll(to: NSPoint(x: min(previous.x, max(0, document.size.width - clip.bounds.width)), y: previous.y))
        scrollView.reflectScrolledClipView(clip)
        onLoad?()
    }

    // Keep AppKit event ownership outside NSHostingView: SwiftUI may replace
    // its internal subviews on layout, covering sibling click overlays.
    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .scrollWheel { return super.hitTest(point) }
        let local = superview.map { convert(point, from: $0) } ?? point
        return bounds.contains(local) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let document, let lensWindow, let renderedScore,
              let view = scrollView.documentView else { return }
        let point = view.convert(event.locationInWindow, from: nil)
        let hit = ScoreHitTester(document: document).hitTest(at: point)
        if case .slur(let id)? = hit,
           let slur = LensScoreAdapter.slur(for: id, in: lensWindow, score: renderedScore) {
            displayedSlurHandler?(lensWindow.events[slur.start].sourceEvent, slur.phrasing)
            return
        }
        if let (anchor, kind) = Self.mark(hit), let event = LensScoreAdapter.event(at: anchor, in: lensWindow, score: renderedScore) {
            displayedMarkHandler?(event.sourceEvent, kind)
            return
        }
        if case .graceNote(let grace)? = document.editingHitTest(at: point, activeVoice: 0, nearMissTolerance: 4),
           let source = LensScoreAdapter.event(at: grace, in: lensWindow, score: renderedScore) {
            displayedSelectionHandler?(source.sourceEvent, event.modifierFlags.contains(.shift))
        } else if let item = document.editingHitTest(at: point, activeVoice: 0, nearMissTolerance: 4),
           let source = lensWindow.events.first(where: { source in
               guard source.measureIndex == item.measureIndex,
                     let element = LensScoreAdapter.element(of: source, in: lensWindow, score: renderedScore) else { return false }
               return element.slot == item.voiceIndex && element.index == item.elementIndex
           }) {
            displayedSelectionHandler?(source.sourceEvent, event.modifierFlags.contains(.shift))
        } else if let measure = document.editingMeasureHit(at: point),
                  let source = lensWindow.events.first(where: { $0.measureIndex == measure.measureIndex && $0.notes.isEmpty }) {
            displayedSelectionHandler?(source.sourceEvent, event.modifierFlags.contains(.shift))
        }
    }

    /// The chord a clicked mark belongs to, and its kind.
    private static func mark(_ hit: ScoreHitTarget?) -> (VoiceElementID, LensMarkKind)? {
        switch hit {
        case .dynamic(let anchor)?: (anchor, .dynamic)
        case .articulation(let anchor, _)?: (anchor, .articulation)
        case .fermata(let anchor)?: (anchor, .fermata)
        case .spanner(let anchor, .hairpin)?: (anchor, .hairpin)
        default: nil
        }
    }

    func centerTarget(animated: Bool) {
        guard let document, let hosting = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let point: CGPoint
        if let target, let origin = document.chordStemOrigin(at: target) {
            point = origin
        } else {
            let system = document.systems.first
            let measure = system?.measures.first { $0.measureIndex == targetMeasure }
            point = CGPoint(
                x: (system?.origin.x ?? 0) + (measure?.origin.x ?? 0),
                y: (system?.origin.y ?? 0) + (measure?.origin.y ?? 0)
            )
        }
        let maxX = max(0, hosting.frame.width - clip.bounds.width)
        let maxY = max(0, hosting.frame.height - clip.bounds.height)
        let origin = NSPoint(
            x: min(max(0, point.x - clip.bounds.width / 2), maxX),
            y: min(max(0, point.y - clip.bounds.height / 2), maxY)
        )
        clip.wantsLayer = true
        clip.layer?.removeAllAnimations()
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                context.allowsImplicitAnimation = true
                clip.animator().setBoundsOrigin(origin)
            }
        } else {
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }
    }
}

@available(macOS 15.0, *)
@MainActor
private final class LensCursorView: NSView {
    var cursor: CGPoint?
    /// The selected slur's pieces, outlined like a selection on the page.
    var slurRects: [CGRect] = []
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        for rect in slurRects {
            let outline = NSBezierPath(roundedRect: rect.insetBy(dx: -3, dy: -3), xRadius: 3, yRadius: 3)
            outline.lineWidth = 1.5
            Theme.accent.withAlphaComponent(0.15).setFill()
            outline.fill()
            Theme.accent.setStroke()
            outline.stroke()
        }
        guard let cursor else { return }
        Theme.accent.setStroke()
        let line = NSBezierPath()
        line.lineWidth = 2
        line.move(to: CGPoint(x: cursor.x + 16, y: cursor.y - 32))
        line.line(to: CGPoint(x: cursor.x + 16, y: cursor.y + 24))
        line.stroke()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Owns the mutable measure cache, so two layout calls can never race it.
/// Score and LayoutDocument are Sendable; AppKit/SwiftUI stay on the main actor.
@available(macOS 15.0, *)
private actor LensLayoutWorker {
    struct Prepared: Sendable {
        var lens: LensScoreWindow
        var score: Score
        var document: LayoutDocument
        var layoutCount: Int
        var wasOnMainThread: Bool
    }
    private let cache = LayoutCache()
    private var recent: [Prepared] = []
    private var count = 0

    nonisolated static func sameMusic(_ a: LensScoreWindow, _ b: LensScoreWindow) -> Bool {
        a.xml == b.xml && a.slurs == b.slurs && a.tuplets == b.tuplets
            && a.dynamics == b.dynamics && a.hairpins == b.hairpins
            && a.tremolos == b.tremolos && a.reachesEnd == b.reachesEnd
            && a.events.map { $0.notes.map(\.forcesAccidental) } == b.events.map { $0.notes.map(\.forcesAccidental) }
    }
    func prepare(_ lens: LensScoreWindow, options: ScoreViewOptions) throws -> Prepared {
        try Task.checkCancellation()
        if var found = recent.first(where: { Self.sameMusic($0.lens, lens) }) {
            found.layoutCount = count
            return found
        }
        let score = try LensScoreAdapter.score(for: lens)
        try Task.checkCancellation()
        let document = LayoutEngine.layout(score: score, options: options, availableWidth: 10_000, cache: cache)
        count += 1
        let prepared = Prepared(lens: lens, score: score, document: document, layoutCount: count, wasOnMainThread: Thread.isMainThread)
        recent.insert(prepared, at: 0)
        if recent.count > 6 { recent.removeLast() }
        return prepared
    }
}
