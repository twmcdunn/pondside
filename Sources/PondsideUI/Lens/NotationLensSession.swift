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

/// The kinds of mark a lens click can select, besides notes and slurs.
enum LensMarkKind: Sendable {
    case dynamic, hairpin, articulation, fermata

    func matches(_ kind: ScoreEditor.Mark.Kind) -> Bool {
        switch self {
        case .dynamic: kind == .dynamic
        case .hairpin: kind == .hairpin
        case .articulation: kind == .articulation
        case .fermata: kind == .fermata
        }
    }
}

/// An expression being typed after `\`: what is typed, and what ⇥ would add.
struct LensExpressionEntry: Equatable {
    var typed: String
    var completion: String?
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
    /// A slur in the lens was clicked: its opening event, and whether it is a phrasing slur.
    var onSelectSlur: ((Int, Bool) -> Void)? { get set }
    /// A dynamic, hairpin, articulation or fermata in the lens was clicked:
    /// the event it belongs to, and which kind of mark.
    var onSelectMark: ((Int, LensMarkKind) -> Void)? { get set }
    func showFeedback(_ message: String)
    /// An edit was refused or taken back: the red inline notice, in the lens.
    func showRejection(_ message: String)
    var onClose: (() -> Void)? { get set }
    /// The expression entry line; nil hides it.
    var expressionEntry: LensExpressionEntry? { get set }
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
