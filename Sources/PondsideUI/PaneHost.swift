import AppKit
import PondsideCore
import PondsideEngrave

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
    /// The collapse/expand buttons, in the title bar strip above the panes.
    let collapseBar = PaneCollapseBar()
    /// The pane the keyboard is in, for the ⌥C hint.
    var focusedPane: () -> Int? = { nil }
    /// A collapse button was clicked: the layout to apply.
    var onCollapseChange: ((PaneLayout) -> Void)?

    init(layout: PaneLayout, make: @escaping (PaneContent) -> NSView) {
        self.layout = layout
        self.make = make
        super.init()
        split.dividerStyle = .thin
        split.delegate = self
        collapseBar.host = self
        rebuildSlots()
        NotificationCenter.default.addObserver(forName: NSSplitView.didResizeSubviewsNotification, object: split,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapseBar.needsLayout = true }
        }
    }

    /// The slot frames in `view`'s coordinates, nil for collapsed panes.
    func slotFrames(in view: NSView) -> [NSRect?] {
        slots.map { $0.isHidden ? nil : $0.convert($0.bounds, to: view) }
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
        let collapseChanged = new.collapsed != layout.collapsed
        // Fractions record the open arrangement: capture them before folding.
        if collapseChanged, layout.collapsed.isEmpty, !geometryChanged, !fractionsChanged {
            captureFractions()
            var n = new
            n.fractions = layout.fractions
            layout = n
        } else {
            layout = new
        }
        if geometryChanged { rebuildSlots() } else { fill() }
        if collapseChanged, !geometryChanged { applyCollapsed() }
        if geometryChanged || fractionsChanged || (collapseChanged && layout.collapsed.isEmpty) { applyFractions() }
        collapseBar.refresh()
    }

    private func applyCollapsed() {
        for (i, slot) in slots.enumerated() { slot.isHidden = layout.collapsed.contains(i) }
        split.adjustSubviews()
        // Dividers beside folded panes hide: redraw so none is left behind.
        split.needsDisplay = true
        collapseBar.needsLayout = true
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
        guard total > 0, slots.count == layout.contents.count, layout.collapsed.isEmpty else { return }
        layout.fractions = slots.map { (split.isVertical ? $0.frame.width : $0.frame.height) / total }
    }

    func setFocused(_ i: Int) {
        layout.focused = min(max(i, 0), layout.contents.count - 1)
    }

    /// A click on a pane's collapse or expand button.
    fileprivate func clicked(_ action: PaneCollapseBar.Action) {
        var l = layout
        switch action {
        case .collapse(let i): l.collapse(i)
        case .expand(let panes): l.expand(panes)
        }
        onCollapseChange?(l)
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
        for (i, slot) in slots.enumerated() { slot.isHidden = layout.collapsed.contains(i) }
        collapseBar.refresh()
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
        guard total > 0, layout.collapsed.isEmpty else { return }
        var position: CGFloat = 0
        for (i, f) in layout.fractions.dropLast().enumerated() {
            position += (total * f).rounded()
            split.setPosition(position, ofDividerAt: i)
        }
    }

    /// One divider between each pair of open panes: the divider beside a
    /// folded pane goes with it, so no separator is left at the window edge.
    func splitView(_ splitView: NSSplitView, shouldHideDividerAt i: Int) -> Bool {
        let views = splitView.arrangedSubviews
        guard views.indices.contains(i) else { return false }
        return views[i].isHidden || !views[(i + 1)...].contains { !$0.isHidden }
    }

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        proposedMinimumPosition + 200
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt i: Int) -> CGFloat {
        proposedMaximumPosition - 200
    }
}

/// The strip under the transparent title bar, above the panes: one small
/// button per open pane at the corner on the side it folds toward (arrow to
/// the edge), and where panes are folded, one at that edge of the open
/// neighbour (arrow away from the edge). The button ⌥C would press shows
/// the key. Nothing here covers code or music (DESIGN.md, Pane collapse).
@MainActor
final class PaneCollapseBar: NSView {
    enum Action: Equatable { case collapse(Int), expand([Int]) }

    weak var host: PaneHost?
    private var buttons: [PaneCollapseButton] = []
    /// Room the traffic lights take at the window's leading corner.
    private static let trafficLights: CGFloat = 78

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// Rebuilds the buttons for the host's layout and focus.
    func refresh() {
        guard let host else { return }
        let l = host.layout
        var wanted: [(Action, PaneLayout.Edge, Int, PaneContent)] = []
        for i in l.contents.indices where l.canCollapse(i) {
            wanted.append((.collapse(i), l.collapseEdge(of: i), i, l.contents[i]))
        }
        for run in l.collapsedRuns {
            wanted.append((.expand(run.panes), run.side, run.host, l.contents[run.panes[0]]))
        }
        // ⌥C opens what is folded, else folds the focused pane.
        let keyed: Action? = l.collapsed.isEmpty ? host.focusedPane().map { .collapse($0) } : wanted.first {
            if case .expand = $0.0 { return true } else { return false }
        }?.0
        while buttons.count > wanted.count { buttons.removeLast().removeFromSuperview() }
        while buttons.count < wanted.count {
            let b = PaneCollapseButton()
            b.onClick = { [weak self, weak b] in
                guard let self, let b, let action = b.action else { return }
                self.host?.clicked(action)
            }
            addSubview(b)
            buttons.append(b)
        }
        for (b, w) in zip(buttons, wanted) {
            let expandPanes: [Int]
            if case .expand(let p) = w.0 { expandPanes = p } else { expandPanes = [] }
            b.configure(action: w.0, edge: w.1, host: w.2, rows: l.axis == .rows,
                        title: expandPanes.count > 1 ? "\(expandPanes.count) panes" : w.3.title,
                        showsKey: w.0 == keyed)
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        guard let host else { return }
        let frames = host.slotFrames(in: self)
        let rows = host.layout.axis == .rows
        var trailingX = bounds.maxX - 8
        for b in buttons {
            let size = b.fittingSize
            let y = ((bounds.height - size.height) / 2).rounded()
            if rows {
                // Stacked panes: their buttons line up at the trailing end.
                b.frame = NSRect(x: trailingX - size.width, y: y, width: size.width, height: size.height)
                trailingX -= size.width + 4
                continue
            }
            guard frames.indices.contains(b.hostPane), let f = frames[b.hostPane] else { b.isHidden = true; continue }
            b.isHidden = false
            let x: CGFloat
            if b.edge == .leading {
                // A pane at the window's leading edge (its folded neighbour's
                // divider may leave it a point in) keeps clear of the lights.
                x = max(f.minX + 6, Self.trafficLights)
            } else {
                x = f.maxX - 6 - size.width
            }
            b.frame = NSRect(x: x.rounded(), y: y, width: size.width, height: size.height)
        }
    }
}

/// A borderless icon button with an optional key hint.
@MainActor
final class PaneCollapseButton: NSView {
    private(set) var action: PaneCollapseBar.Action?
    private(set) var edge: PaneLayout.Edge = .leading
    private(set) var hostPane = 0
    var onClick: (() -> Void)?
    private let icon = NSImageView()
    private let key = NSTextField(labelWithString: "⌥C")
    private let stack = NSStackView()
    private var hovering = false { didSet { restyle() } }
    private var pressed = false { didSet { restyle() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 5
        key.font = .systemFont(ofSize: 10, weight: .medium)
        icon.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        stack.orientation = .horizontal
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 5, bottom: 2, right: 5)
        stack.addArrangedSubview(icon)
        stack.addArrangedSubview(key)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                                                          object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restyle() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(action: PaneCollapseBar.Action, edge: PaneLayout.Edge, host: Int, rows: Bool, title: String, showsKey: Bool) {
        self.action = action
        self.edge = edge
        self.hostPane = host
        let symbol: String
        let label: String
        switch action {
        case .collapse:
            // Arrow to the edge the pane folds into.
            symbol = rows ? (edge == .leading ? "arrow.up.to.line.compact" : "arrow.down.to.line.compact")
                          : (edge == .leading ? "arrow.left.to.line.compact" : "arrow.right.to.line.compact")
            label = "Collapse \(title)"
        case .expand:
            // Arrow away from the edge the pane comes back from.
            symbol = rows ? (edge == .leading ? "arrow.down" : "arrow.up")
                          : (edge == .leading ? "arrow.right" : "arrow.left")
            label = "Expand \(title)"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        key.isHidden = !showsKey
        toolTip = label + (showsKey ? "  ⌥C" : "")
        setAccessibilityLabel(label)
        restyle()
    }

    private func restyle() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let tint = hovering || contrast ? Theme.text : Theme.secondaryText
        icon.contentTintColor = tint
        key.textColor = contrast ? Theme.text : Theme.secondaryText
        let fill: CGFloat = pressed ? 0.14 : hovering ? 0.08 : 0
        layer?.backgroundColor = NSColor(white: 1, alpha: fill).cgColor
        layer?.borderWidth = contrast ? 1 : 0
        layer?.borderColor = Theme.secondaryText.cgColor
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
    override func mouseDown(with event: NSEvent) { pressed = true }
    override func mouseUp(with event: NSEvent) {
        pressed = false
        if bounds.contains(convert(event.locationInWindow, from: nil)) { onClick?() }
    }
    override func accessibilityPerformPress() -> Bool { onClick?(); return true }
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
    private let textView = SourceMessageView()
    var onOpenSource: ((SourceDiagnosticLink) -> Void)? {
        didSet { textView.onOpenSource = onOpenSource }
    }

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
        textView.show(text)
        textView.scrollToEndOfDocument(nil)
    }

    func clear() {
        textView.show("")
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        contentView.scroll(to: .zero)
        reflectScrolledClipView(contentView)
    }
}
