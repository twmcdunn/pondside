import AppKit
import PondsideCore

/// Discoverability in place (product law 2):
/// - hover a control for ~400 ms: a tip with its name, one line, and keys;
/// - hold ⌥ for ~500 ms: every registered control shows its keys at once.
///
/// Both are floating overlays that ignore the mouse, so they never block
/// what's underneath, and both vanish the moment the cause goes away.
@MainActor
final class HelpOverlay {
    private struct Target {
        weak var view: NSView?
        let id: CommandID
        let tracker: HoverTracker?
    }

    private weak var window: NSWindow?
    private var targets: [Target] = []
    private var tip: NSPanel?
    private var tipTask: Task<Void, Never>?
    private var reveal: NSPanel?
    private var revealTask: Task<Void, Never>?

    init(window: NSWindow) {
        self.window = window
    }

    /// Makes `view` explain `id` on hover and under ⌥.
    func register(_ view: NSView, _ id: CommandID) {
        let tracker = HoverTracker()
        tracker.onEnter = { [weak self, weak view] in
            guard let view else { return }
            self?.scheduleTip(for: view, id)
        }
        tracker.onExit = { [weak self] in self?.hideTip() }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: tracker, userInfo: nil)
        view.addTrackingArea(area)
        view.toolTip = nil
        targets.append(Target(view: view, id: id, tracker: tracker))
    }

    /// Shows `id`'s keys on `view` under ⌥ only; the view keeps its own
    /// tooltip (for controls whose hover help says more than the command).
    func registerReveal(_ view: NSView, _ id: CommandID) {
        targets.append(Target(view: view, id: id, tracker: nil))
    }

    // MARK: Hover

    private func scheduleTip(for view: NSView, _ id: CommandID) {
        tipTask?.cancel()
        tipTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.showTip(for: view, id)
        }
    }

    private func hideTip() {
        tipTask?.cancel()
        tip?.orderOut(nil)
    }

    private func showTip(for view: NSView, _ id: CommandID) {
        guard let window, let spec = CommandCenter.shared.spec(id), view.window === window else { return }
        let panel = tip ?? Self.floatingPanel()
        tip = panel
        let keys = CommandCenter.shared.keymap.keyHint(for: id) ?? ""
        let content = TipView(title: spec.title, gloss: spec.gloss, keys: keys)
        panel.contentView = content
        let size = content.fittingSize
        let rect = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 6)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
            if origin.y < screen.minY { origin.y = rect.maxY + 6 }
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
    }

    // MARK: ⌥ reveal

    /// Call from the window's flagsChanged: ⌥ alone held reveals keys.
    func optionChanged(isDown: Bool) {
        revealTask?.cancel()
        guard isDown else {
            reveal?.orderOut(nil)
            return
        }
        revealTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.showReveal()
        }
    }

    private func showReveal() {
        guard let window, let contentView = window.contentView else { return }
        let panel = reveal ?? Self.floatingPanel()
        reveal = panel
        let badges: [(NSRect, String)] = targets.compactMap { t in
            guard let v = t.view, v.window === window, !v.isHiddenOrHasHiddenAncestor,
                  let keys = CommandCenter.shared.keymap.keyHint(for: t.id) else { return nil }
            return (contentView.convert(v.bounds, from: v), keys)
        }
        let view = RevealView(frame: contentView.bounds, badges: badges)
        panel.contentView = view
        panel.setFrame(window.convertToScreen(contentView.convert(contentView.bounds, to: nil)), display: true)
        panel.alphaValue = 0
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 1
        }
    }

    private static func floatingPanel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.ignoresMouseEvents = true
        p.appearance = NSAppearance(named: .darkAqua)
        return p
    }
}

/// Receives tracking-area events for one control.
@MainActor
private final class HoverTracker: NSResponder {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
}

@MainActor
private final class TipView: GlassView {
    init(title: String, gloss: String, keys: String) {
        super.init(cornerRadius: 8)

        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: Theme.bodySize, weight: .semibold)
        t.textColor = Theme.text
        let k = NSTextField(labelWithString: keys)
        k.font = .monospacedSystemFont(ofSize: Theme.bodySize, weight: .medium)
        k.textColor = Theme.accent
        let g = NSTextField(wrappingLabelWithString: gloss)
        g.font = Theme.secondaryFont
        g.textColor = Theme.glassSecondaryText
        g.preferredMaxLayoutWidth = 280
        let top = NSStackView(views: [t, k])
        top.spacing = 12
        let stack = NSStackView(views: [top, g])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 9, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

/// Key badges drawn over their controls.
@MainActor
private final class RevealView: NSView {
    private let badges: [(NSRect, String)]

    init(frame: NSRect, badges: [(NSRect, String)]) {
        self.badges = badges
        super.init(frame: frame)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: Theme.secondarySize, weight: .semibold),
            .foregroundColor: Theme.background,
        ]
        for (rect, keys) in badges {
            let text = NSAttributedString(string: keys, attributes: attrs)
            let size = text.size()
            let badge = NSRect(x: rect.midX - size.width / 2 - 6, y: rect.midY - size.height / 2 - 2,
                               width: size.width + 12, height: size.height + 4)
            let path = NSBezierPath(roundedRect: badge, xRadius: 5, yRadius: 5)
            Theme.accent.withAlphaComponent(0.95).setFill()
            path.fill()
            text.draw(at: NSPoint(x: badge.minX + 6, y: badge.minY + 2))
        }
    }
}
