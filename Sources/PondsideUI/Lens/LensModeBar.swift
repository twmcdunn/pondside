import AppKit

/// What a lens popover is about, shown the same way at the top of every
/// one, so tabbing between them only changes what is below the bar: the
/// Notation Lens (the passage's music), the score agent's request line
/// (graphics and notation), the patch agent's (the SuperCollider patch).
enum LensMode: Int, CaseIterable {
    case notation, graphics, patch

    var title: String {
        switch self {
        case .notation: return "Notation"
        case .graphics: return "Graphics"
        case .patch: return "SuperCollider"
        }
    }

    var icon: NSImage? {
        let name: String
        switch self {
        case .notation: name = "music.note"
        case .graphics: name = "scribble.variable"
        case .patch: name = "waveform"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: title)
    }

    var help: String {
        switch self {
        case .notation: return "The passage's notes, to step through and edit"
        case .graphics: return "Ask the score's agent to change the graphics or notation here"
        case .patch: return "Ask the patch agent to change the SuperCollider patch at this point"
        }
    }

    /// The order ⇥ goes in.
    func next(among available: Set<LensMode>) -> LensMode? {
        let all = LensMode.allCases
        let i = all.firstIndex(of: self)!
        return (1..<all.count).map { all[(i + $0) % all.count] }.first { available.contains($0) }
    }

    /// One size for every lens popover, so ⇥ never resizes it: wide enough
    /// for a few bars, never wider than the score pane.
    static func size(for anchor: LensAnchor) -> NSSize {
        let room = anchor.view.enclosingScrollView?.contentView.bounds.width ?? anchor.view.bounds.width
        return NSSize(width: min(640, max(380, room - 48)), height: barHeight + 136 + 42)
    }

    static let barHeight: CGFloat = 30
}

/// The icon switch itself.
@MainActor
final class LensModeBar: NSSegmentedControl {
    var onSelect: ((LensMode) -> Void)?

    /// `current` selected; the others enabled when `available`; `unavailable`
    /// tooltips say why one isn't.
    func configure(current: LensMode, available: Set<LensMode>, unavailable: [LensMode: String] = [:]) {
        segmentCount = LensMode.allCases.count
        segmentStyle = .rounded
        trackingMode = .selectOne
        controlSize = .small
        for m in LensMode.allCases {
            setImage(m.icon, forSegment: m.rawValue)
            setLabel(m.title, forSegment: m.rawValue)
            setImageScaling(.scaleProportionallyDown, forSegment: m.rawValue)
            setEnabled(m == current || available.contains(m), forSegment: m.rawValue)
            setToolTip(available.contains(m) || m == current ? m.help : (unavailable[m] ?? m.help), forSegment: m.rawValue)
        }
        selectedSegment = current.rawValue
        target = self
        action = #selector(picked(_:))
    }

    @objc private func picked(_ sender: NSSegmentedControl) {
        guard let m = LensMode(rawValue: sender.selectedSegment) else { return }
        onSelect?(m)
    }
}
