import AppKit
import os
import PondsideCore

/// `log stream --predicate 'subsystem == "app.pondside" && category == "lens"'`
let lensLog = Logger(subsystem: "app.pondside", category: "lens")

/// Where the lens points: a rect in `view`'s coordinates (the selection's
/// staff on the page, or a fallback spot in the score pane).
struct LensAnchor {
    var rect: NSRect
    var view: NSView
}

/// The Notation Lens as the window controller sees it. Available on every
/// macOS the app runs on; the implementation needs macOS 15.
@MainActor
protocol NotationLensSession: AnyObject {
    var isOpen: Bool { get }
    var unmetered: Bool { get set }
    var enteringNotes: Bool { get set }
    var armedDuration: String { get set }
    var armedAccidental: Int? { get set }
    var onSelectEvent: ((Int, Bool) -> Void)? { get set }
    func showFeedback(_ message: String)
    var onClose: (() -> Void)? { get set }
    var onFailure: ((String) -> Void)? { get set }
    /// The mode bar was clicked: open that lens instead.
    var onSwitch: ((LensMode) -> Void)? { get set }
    /// The other lenses the bar offers, and why the rest aren't.
    var available: Set<LensMode> { get set }
    var unavailable: [LensMode: String] { get set }

    /// Shows `lens` pointing at `anchor`, or updates the lens already
    /// showing. An open lens stays put; it moves only when `anchor` is on
    /// another staff line of the page. `explicit`: it stays until ⎋, which
    /// the footer says. False if it could not.
    func present(lens: LensScoreWindow, fileLabel: String, anchor: LensAnchor?, explicit: Bool) -> Bool
    /// Closes the lens; `animated` fades it out as the new engraving fades in.
    func dismiss(animated: Bool)
}
