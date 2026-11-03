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
    private let scrollView = NSScrollView()
    private var document: LayoutDocument?
    private var target: VoiceElementID?
    private var targetMeasure = 0

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
        let score = try LensScoreAdapter.score(for: lens)
        var options = ScoreViewOptions()
        options.staffSize = 30
        options.wrapToViewWidth = false
        options.breakPolicy = .ignoreAll
        options.breakIndicatorVisibility = .none
        options.includeTitleFrame = false
        options.lyricsVisible = false
        let document = LayoutEngine.layout(
            score: score,
            options: options,
            availableWidth: 10_000
        )
        self.document = document

        targetMeasure = lens.target?.measureIndex ?? 0
        let selected = LensScoreAdapter.items(of: lens, in: score)
        let selection: ScoreSelection
        if let (id, item) = LensScoreAdapter.target(of: lens, in: score) {
            target = id
            selection = selected.count > 1 ? .multi(selected) : .single(item)
        } else {
            selection = selected.isEmpty ? .none : .multi(selected)
            target = nil
        }

        let hosting = NSHostingView(rootView: ScoreView(
            document: document,
            score: score,
            options: options,
            selection: selection,
            voiceColors: Dictionary(uniqueKeysWithValues: (0..<4).map { ($0, Color(nsColor: Theme.accent)) })
        ))
        hosting.frame = NSRect(origin: .zero, size: document.size)
        let clip = scrollView.contentView
        let previous = clip.bounds.origin
        scrollView.documentView = hosting
        clip.scroll(to: NSPoint(x: min(previous.x, max(0, document.size.width - clip.bounds.width)), y: previous.y))
        scrollView.reflectScrolledClipView(clip)
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
                context.duration = 0.35
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
