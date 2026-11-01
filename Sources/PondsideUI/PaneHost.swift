import AppKit
import PondsideCore

/// Lays a `PaneLayout` out in a split view. Slots are frames; content
/// views move between them, so swapping content never moves a divider.
@MainActor
final class PaneHost: NSObject, NSSplitViewDelegate {
    let split = NSSplitView()
    private(set) var layout: PaneLayout
    private var slots: [NSView] = []
    /// Builds (once) the view for a content type.
    private let make: (PaneContent) -> NSView
    private var views: [PaneContent: NSView] = [:]

    init(layout: PaneLayout, make: @escaping (PaneContent) -> NSView) {
        self.layout = layout
        self.make = make
        super.init()
        split.dividerStyle = .thin
        split.delegate = self
        rebuildSlots()
    }

    func view(for content: PaneContent) -> NSView {
        if let v = views[content] { return v }
        let v = make(content)
        views[content] = v
        return v
    }

    /// Applies a new layout: geometry only changes when the pane count or
    /// axis does (presets); content changes just move views.
    func apply(_ new: PaneLayout) {
        let geometryChanged = new.contents.count != layout.contents.count || new.axis != layout.axis
        let fractionsChanged = new.fractions != layout.fractions
        layout = new
        if geometryChanged { rebuildSlots() } else { fill() }
        if geometryChanged || fractionsChanged { applyFractions() }
    }

    /// The pane holding `view` (e.g. the first responder), if any.
    func paneIndex(containing view: NSView?) -> Int? {
        var v = view
        while let current = v {
            if let i = slots.firstIndex(where: { $0 === current }) { return i }
            v = current.superview
        }
        return nil
    }

    /// Records the dividers' positions in the layout (before saving it).
    func captureFractions() {
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        guard total > 0, slots.count == layout.contents.count else { return }
        layout.fractions = slots.map { (split.isVertical ? $0.frame.width : $0.frame.height) / total }
    }

    func setFocused(_ i: Int) {
        layout.focused = min(max(i, 0), layout.contents.count - 1)
    }

    private func rebuildSlots() {
        for s in slots { s.removeFromSuperview() }
        slots = layout.contents.map { _ in
            let slot = NSView()
            slot.translatesAutoresizingMaskIntoConstraints = false
            return slot
        }
        split.isVertical = layout.axis == .columns
        for s in slots { split.addArrangedSubview(s) }
        fill()
    }

    private func fill() {
        for (slot, content) in zip(slots, layout.contents) {
            let v = view(for: content)
            guard v.superview !== slot else { continue }
            v.removeFromSuperview()
            slot.subviews.forEach { $0.removeFromSuperview() }
            v.translatesAutoresizingMaskIntoConstraints = false
            slot.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: slot.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: slot.trailingAnchor),
                v.topAnchor.constraint(equalTo: slot.topAnchor),
                v.bottomAnchor.constraint(equalTo: slot.bottomAnchor),
            ])
        }
    }

    func applyFractions() {
        split.layoutSubtreeIfNeeded()
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        guard total > 0 else { return }
        var position: CGFloat = 0
        for (i, f) in layout.fractions.dropLast().enumerated() {
            position += (total * f).rounded()
            split.setPosition(position, ofDividerAt: i)
        }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        proposedMinimumPosition + 200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        proposedMaximumPosition - 200
    }
}

/// What a pane shows for content that hasn't been built yet: say which
/// milestone brings it, never a blank frame.
@MainActor
final class PanePlaceholder: NSView {
    init(_ content: PaneContent) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor
        let when: String
        switch content {
        case .python: when = "Arrives with the editor milestone (M5)."
        case .lexicon: when = "Arrives with the Lexicon (M7)."
        default: when = ""
        }
        let title = NSTextField(labelWithString: content.title)
        title.font = .systemFont(ofSize: Theme.bodySize + 2, weight: .semibold)
        title.textColor = Theme.secondaryText
        let detail = NSTextField(wrappingLabelWithString: when + "\n⌃⇥ shows the next content in this pane.")
        detail.font = Theme.bodyFont
        detail.textColor = Theme.secondaryText
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 320
        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// LilyPond's own words from the latest compile.
@MainActor
final class CompilerOutputView: NSScrollView {
    private let textView = NSTextView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        hasVerticalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = Theme.editorBackground
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.editorBackground
        textView.textColor = Theme.text
        textView.font = Theme.monoFont
        textView.textContainerInset = NSSize(width: 12, height: 10)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        documentView = textView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ log: String) {
        let text = log.isEmpty ? "No compile yet." : log
        guard textView.string != text else { return }
        textView.string = text
        textView.scrollToEndOfDocument(nil)
    }
}
