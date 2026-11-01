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
    /// The field's prompt; nil for the score's.
    var placeholder: String?
    /// What it shows below the field: the selection, and a few examples.
    var detail = ""

    /// Which agent the line talks to (graphics or patch), and which other
    /// lenses ⇥ and the bar can switch to.
    var mode: LensMode = .graphics
    var available: Set<LensMode> = []
    var unavailable: [LensMode: String] = [:]
    /// The bar was clicked, or ⇥ pressed: open that lens instead.
    var onSwitch: ((LensMode) -> Void)?
    private let modes = LensModeBar()
    private let detailLabel = NSTextField(wrappingLabelWithString: "")

    var isOpen: Bool { popover?.isShown == true }

    /// `title`: what is selected ("\startGrains · bar 4"); `agent`: who
    /// will do it, or nil when no agent is set up (the field is disabled
    /// and the caption says where to choose one). The same size as the
    /// Notation Lens, so ⇥ between them doesn't resize anything.
    func present(title: String, agent: String?, anchor: NSRect, in view: NSView) {
        popover?.close()
        let size = LensMode.size(for: LensAnchor(rect: anchor, view: view))
        let card = NSView()
        card.translatesAutoresizingMaskIntoConstraints = false
        card.setAccessibilityElement(true)
        card.setAccessibilityRole(.group)
        card.setAccessibilityLabel("Describe a change to \(title)")
        card.wantsLayer = true
        card.layer?.backgroundColor = Theme.chrome.withAlphaComponent(0.72).cgColor

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
        let tab = mode.next(among: available).map { "  ⇥ \($0.title.lowercased())" } ?? ""
        caption.stringValue = agent.map { "\(title)    \($0) · ↩ go\(tab)  ⎋ close" }
            ?? "\(title)    No agent is set up: choose one in Settings (⌘,)"
        caption.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = Theme.secondaryFont
        detailLabel.textColor = Theme.glassSecondaryText
        detailLabel.stringValue = detail
        detailLabel.maximumNumberOfLines = 5
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        modes.configure(current: mode, available: available, unavailable: unavailable)
        modes.onSelect = { [weak self] m in
            guard let self, m != self.mode else { return }
            self.close()
            self.onSwitch?(m)
        }
        modes.translatesAutoresizingMaskIntoConstraints = false
        for v in [modes, field, caption, detailLabel] as [NSView] { card.addSubview(v) }
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: size.width),
            card.heightAnchor.constraint(equalToConstant: size.height),
            modes.topAnchor.constraint(equalTo: card.topAnchor, constant: 6),
            modes.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            field.topAnchor.constraint(equalTo: card.topAnchor, constant: LensMode.barHeight + 8),
            field.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: field.bottomAnchor, constant: 10),
            detailLabel.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            detailLabel.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            caption.leadingAnchor.constraint(equalTo: field.leadingAnchor, constant: 2),
            caption.trailingAnchor.constraint(equalTo: field.trailingAnchor),
            caption.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8),
        ])
        let controller = NSViewController()
        controller.view = card
        controller.preferredContentSize = size
        let p = NSPopover()
        p.contentViewController = controller
        p.contentSize = size
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
            guard let next = mode.next(among: available) else { return true }
            close()
            onSwitch?(next)
            return true
        default:
            return false
        }
    }
}
