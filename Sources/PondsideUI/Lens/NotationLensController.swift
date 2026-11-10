import AppKit
import PondsideCore

/// Owns the lens's popover while it is open. It points at the passage on
/// the page, beside the staff rather than over it, and appears without
/// motion because edits open it keystroke after keystroke (HIG, Motion);
/// the render that makes it unnecessary fades it out. It never takes key
/// focus: ←→ and ⎋ reach it through the window's key monitor.
@available(macOS 15.0, *)
@MainActor
final class NotationLensController: NSObject, NotationLensSession, NSPopoverDelegate {
    private var popover: NSPopover?
    private var card: NotationLensOverlayView?
    private var host: LensScoreHostView?
    private weak var anchorView: NSView?

    var unmetered = false
    var enteringNotes = false
    var armedDuration = "4"
    var armedAccidental: Int?
    var onSelectEvent: ((Int, Bool) -> Void)?
    var onSelectSlur: ((Int, Bool) -> Void)?
    var onSelectMark: ((Int, LensMarkKind) -> Void)?
    func showFeedback(_ message: String) { card?.showFeedback(message) }
    func showRejection(_ message: String) { card?.showRejection(message) }
    var onClose: (() -> Void)?
    var expressionEntry: LensExpressionEntry? { didSet { card?.setExpressionEntry(expressionEntry) } }
    var onEscape: (() -> Bool)?
    private var handlingEscape = false
    var onFailure: ((String) -> Void)?
    var onSwitch: ((LensMode) -> Void)?
    var available: Set<LensMode> = []
    var unavailable: [LensMode: String] = [:]

    private func configure(_ card: NotationLensOverlayView) {
        card.enteringNotes = enteringNotes
        card.setUnmetered(unmetered)
        card.setDuration(armedDuration)
        card.setArmedAccidental(armedAccidental)
        card.tabTarget = LensMode.notation.next(among: available)?.title.lowercased()
        card.setExpressionEntry(expressionEntry)
        card.modes.configure(current: .notation, available: available, unavailable: unavailable)
        card.modes.onSelect = { [weak self] m in
            guard let self, m != .notation else { return }
            self.dismiss(animated: false)
            self.onSwitch?(m)
        }
    }

    var isOpen: Bool { popover?.isShown == true }

    private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    func present(lens: LensScoreWindow, fileLabel: String, anchor: LensAnchor?, explicit: Bool) -> Bool {
        if let popover, let host, let card, popover.isShown {
            do {
                host.enteringNotes = enteringNotes
                host.onSelectEvent = onSelectEvent
                host.onSelectSlur = onSelectSlur
                host.onSelectMark = onSelectMark
                try host.load(lens)
            } catch {
                lensLog.error("refresh failed: \(String(describing: error), privacy: .public)")
                dismiss(animated: false)
                onFailure?("Notation Lens could not display this passage")
                return false
            }
            configure(card)
            card.update(lens: lens, fileLabel: fileLabel, explicit: explicit)
            popover.animates = false
            // Following the cursor note by note is too much motion: the
            // arrow keeps pointing where the lens opened, and the strip's
            // highlight shows the cursor. Only a move to another staff
            // line, where the arrow would point at the wrong music, moves it,
            // and so does an anchor reaching higher (a collection's anchor
            // line over its whole system), which the lens would cover.
            if let anchor, anchor.view === anchorView,
               !Self.sameLine(anchor.rect, popover.positioningRect) || anchor.rect.minY < popover.positioningRect.minY - 1 {
                popover.positioningRect = anchor.rect
            }
            card.layoutSubtreeIfNeeded()
            host.centerTarget(animated: !enteringNotes && !Self.reduceMotion)
            return true
        }
        guard let anchor else { return false }

        let host = LensScoreHostView()
        host.onLoad = { [weak self, weak host] in
            guard let self, let host, self.host === host else { return }
            host.centerTarget(animated: !self.enteringNotes && !Self.reduceMotion)
        }
        host.onFailure = { [weak self] message in
            self?.dismiss(animated: false)
            self?.onFailure?(message)
        }
        do {
            host.enteringNotes = enteringNotes
            host.onSelectEvent = onSelectEvent
                host.onSelectSlur = onSelectSlur
                host.onSelectMark = onSelectMark
            try host.load(lens)
        } catch {
            lensLog.error("load failed: \(String(describing: error), privacy: .public)")
            onFailure?("Notation Lens could not display this passage")
            return false
        }
        let card = NotationLensOverlayView(host: host)
        configure(card)
        card.update(lens: lens, fileLabel: fileLabel, explicit: explicit)
        // Auto Layout sizes a popover to its content's fitting size, and the
        // strip has no intrinsic width: pin the card, or it collapses.
        let size = LensMode.size(for: anchor)
        card.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: size.width),
            card.heightAnchor.constraint(equalToConstant: size.height),
        ])
        let controller = NSViewController()
        controller.view = card
        controller.preferredContentSize = size

        let popover = NSPopover()
        popover.contentViewController = controller
        popover.contentSize = size
        // Clicking elsewhere in the window dismisses it, as a nonmodal popover should.
        popover.behavior = .semitransient
        popover.appearance = anchor.view.window?.appearance
        popover.animates = false
        popover.delegate = self
        // Above the staff, so the bars still to come stay in view; the
        // popover flips below when there's no room.
        popover.show(relativeTo: anchor.rect, of: anchor.view, preferredEdge: anchor.view.isFlipped ? .minY : .maxY)
        lensLog.debug("opening at \(Int(anchor.rect.midX)),\(Int(anchor.rect.minY)) in \(String(describing: type(of: anchor.view)))")
        card.layoutSubtreeIfNeeded()
        host.centerTarget(animated: false)
        self.popover = popover
        anchorView = anchor.view
        self.card = card
        self.host = host
        return true
    }

    private static func sameLine(_ a: NSRect, _ b: NSRect) -> Bool {
        a.minY < b.maxY && b.minY < a.maxY
    }

    func dismiss(animated: Bool) {
        guard let popover else { return }
        lensLog.debug("dismiss, animated: \(animated)")
        self.popover = nil
        card = nil
        host = nil
        popover.animates = animated && !Self.reduceMotion
        popover.close()
        onClose?()
    }

    // A click elsewhere closed it.
    func popoverShouldClose(_ popover: NSPopover) -> Bool {
        guard !handlingEscape, !enteringNotes,
              NSApp.currentEvent?.type == .keyDown, NSApp.currentEvent?.keyCode == 53 else { return true }
        handlingEscape = true
        defer { handlingEscape = false }
        let handled = onEscape?() ?? false
        return !(handled && enteringNotes)
    }

    func popoverDidClose(_ notification: Notification) {
        guard let closed = notification.object as? NSPopover, closed === popover else { return }
        popover = nil
        card = nil
        host = nil
        onClose?()
    }
}
