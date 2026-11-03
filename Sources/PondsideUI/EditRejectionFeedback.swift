import AppKit

/// Brief inline status, never a popover/sheet or keyboard target. A separate
/// caret layer pulses without redrawing or recoloring the engraved music.
@MainActor
final class EditRejectionFeedback: NSView {
    private let caret = CALayer()
    private var dismissal: Task<Void, Never>?

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    init(message: String, anchor: NSRect, in parent: NSView, reduceMotion: Bool? = nil, increaseContrast: Bool? = nil) {
        let reduceMotion = reduceMotion ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let increaseContrast = increaseContrast ?? NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let visible = parent.visibleRect.insetBy(dx: 8, dy: 8)
        let width = min(340, max(120, visible.width))
        let textWidth = width - 42
        let textHeight = ceil((message as NSString).boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: Theme.bodyFont]).height)
        let height = max(36, textHeight + 18)
        let x = min(max(anchor.minX, visible.minX), visible.maxX - width)
        let above = anchor.minY - height - 8
        let y = above >= visible.minY ? above : min(anchor.maxY + 8, visible.maxY - height)
        let bubble = NSRect(x: x, y: max(visible.minY, y), width: width, height: height)
        let caretHeight = min(36, max(18, anchor.height))
        let mark = NSRect(x: min(max(anchor.maxX + 3, visible.minX), visible.maxX - 3),
                          y: min(max(anchor.midY - caretHeight / 2, visible.minY), visible.maxY - caretHeight),
                          width: 3, height: caretHeight)
        let frame = bubble.union(mark)
        super.init(frame: frame)
        wantsLayer = true
        layer?.zPosition = 20
        let color = increaseContrast ? NSColor.systemRed : Theme.error
        let card = NSView(frame: bubble.offsetBy(dx: -frame.minX, dy: -frame.minY))
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.chrome.cgColor
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = increaseContrast ? 2 : 1
        card.layer?.borderColor = color.cgColor
        let icon = NSImageView(frame: NSRect(x: 10, y: (height - 16) / 2, width: 16, height: 16))
        icon.image = NSImage(systemSymbolName: "exclamationmark.circle.fill", accessibilityDescription: "Edit blocked")
        icon.contentTintColor = color
        let label = NSTextField(wrappingLabelWithString: message)
        label.font = Theme.bodyFont
        label.textColor = Theme.text
        label.frame = NSRect(x: 33, y: 8, width: textWidth, height: height - 16)
        card.addSubview(icon)
        card.addSubview(label)
        addSubview(card)
        caret.frame = mark.offsetBy(dx: -frame.minX, dy: -frame.minY)
        caret.backgroundColor = color.cgColor
        caret.cornerRadius = 1.5
        layer?.addSublayer(caret)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(message)
        parent.addSubview(self)
        if !reduceMotion {
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.09
            pulse.autoreverses = true
            pulse.repeatCount = 2
            caret.add(pulse, forKey: "pondside.rejectedEdit")
        }
        NSAccessibility.post(element: parent, notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.removeFromSuperview()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func dismiss() {
        dismissal?.cancel()
        removeFromSuperview()
    }
}
