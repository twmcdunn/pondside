import AppKit

/// The lens's request line: a popover beside the selection with one line to
/// describe a change ("grainy swell till m. 3"), which the agent carries
/// out in the background. For a graphic it is the lens (⌘L); for notes ⇥
/// switches to it from the lens and back. Opened explicitly, so its field
/// takes the keyboard; ↩ sends, ⎋ closes and returns focus to the score.
@MainActor
final class AgentRequestPopover: NSObject, NSPopoverDelegate, NSTextFieldDelegate {
    private var popover: NSPopover?
    private let field = NSTextField()
    private let caption = NSTextField(labelWithString: "")
    private weak var returnFocus: NSResponder?

    /// Called with the request when ↩ is pressed.
    var onSubmit: ((String) -> Void)?
    /// ⇥: back to the notation lens (nil for a graphic, which has none).
    var onTab: (() -> Void)?
    /// Where ⇥ goes, for the caption: "lens", "patch".
    var tabLabel = "lens"
    /// The field's prompt; nil for the score's.
    var placeholder: String?

    /// Which agent the line talks to, shown as an icon switch at its top so
    /// it is clear whether a request is about the graphics or the patch.
    enum Mode { case graphics, patch }
    var mode: Mode = .graphics
    /// Clicking the other side of the switch (nil: the score has no patch,
    /// and the patch side says so).
    var onSwitch: ((Mode) -> Void)?
    private let modes = NSSegmentedControl()

    static func icon(_ mode: Mode) -> NSImage? {
        NSImage(systemSymbolName: mode == .graphics ? "scribble.variable" : "waveform",
                accessibilityDescription: mode == .graphics ? "Graphics" : "SuperCollider patch")
    }

    var isOpen: Bool { popover?.isShown == true }

    /// `title`: what is selected ("\startGrains · bar 4"); `agent`: who
    /// will do it, or nil when no agent is set up (the field is disabled
    /// and the caption says where to choose one).
    func present(title: String, agent: String?, anchor: NSRect, in view: NSView) {
        popover?.close()
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Describe a change to \(title)")

        field.placeholderString = placeholder ?? "Describe what you want… e.g. grainy swell till m. 3"
        field.font = Theme.bodyFont
        field.stringValue = ""
        field.delegate = self
        field.isEnabled = agent != nil
        field.focusRingType = .default
        field.translatesAutoresizingMaskIntoConstraints = false
        caption.font = Theme.secondaryFont
        caption.textColor = Theme.glassSecondaryText
        caption.lineBreakMode = .byTruncatingMiddle
        let tab = onTab == nil ? "" : "  ⇥ \(tabLabel)"
        caption.stringValue = agent.map { "\(title)    \($0) · ↩ go\(tab)  ⎋ close" }
            ?? "\(title)    No agent is set up: choose one in Settings (⌘,)"
        caption.translatesAutoresizingMaskIntoConstraints = false
        modes.segmentCount = 2
        modes.segmentStyle = .rounded
        modes.trackingMode = .selectOne
        for (i, m) in [Mode.graphics, .patch].enumerated() {
            modes.setImage(Self.icon(m), forSegment: i)
            modes.setLabel(m == .graphics ? "Graphics" : "SuperCollider", forSegment: i)
            modes.setImageScaling(.scaleProportionallyDown, forSegment: i)
        }
        modes.setToolTip("Ask the score's agent about the graphics and notation", forSegment: 0)
        modes.setToolTip(onSwitch == nil && mode == .graphics ? "This score has no Pondside patch yet (File › Make Patch Pondside-Ready…)"
                            : "Ask the patch agent to change the SuperCollider patch at this point", forSegment: 1)
        modes.setEnabled(mode == .patch || onSwitch != nil, forSegment: 1)
        modes.setEnabled(mode == .graphics || onSwitch != nil, forSegment: 0)
        modes.selectedSegment = mode == .graphics ? 0 : 1
        modes.target = self
        modes.action = #selector(switchMode(_:))
        modes.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(modes)
        card.addSubview(field)
        card.addSubview(caption)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: 420),
            modes.topAnchor.constraint(equalTo: card.topAnchor, constant: 10),
            modes.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            field.topAnchor.constraint(equalTo: modes.bottomAnchor, constant: 8),
            field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            caption.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 6),
            caption.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        let controller = NSViewController()
        controller.view = card
        let p = NSPopover()
        p.contentViewController = controller
        p.behavior = .transient
        p.animates = false
        p.appearance = view.window?.appearance
        p.delegate = self
        returnFocus = view.window?.firstResponder
        p.show(relativeTo: anchor, of: view, preferredEdge: view.isFlipped ? .minY : .maxY)
        popover = p
        if agent != nil { p.contentViewController?.view.window?.makeFirstResponder(field) }
    }

    func close() {
        popover?.close()
    }

    @objc private func switchMode(_ sender: NSSegmentedControl) {
        let picked: Mode = sender.selectedSegment == 0 ? .graphics : .patch
        guard picked != mode, let onSwitch else { return }
        close()
        onSwitch(picked)
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
        if let view = returnFocus as? NSView { view.window?.makeFirstResponder(view) }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            let text = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return true }
            close()
            onSubmit?(text)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            close()
            return true
        case #selector(NSResponder.insertTab(_:)):
            guard let onTab else { return true }
            close()
            onTab()
            return true
        default:
            return false
        }
    }
}
