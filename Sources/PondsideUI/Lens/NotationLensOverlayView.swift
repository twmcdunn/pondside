import AppKit
import PondsideCore

/// The lens's content inside its popover: the engraved strip on softened
/// paper, and a line naming the passage. The popover supplies the chrome
/// (arrow, material, border) and adapts it to Reduce Transparency and
/// Increase Contrast; nothing here is translucent.
@available(macOS 15.0, *)
@MainActor
final class NotationLensOverlayView: NSView {
    private let host: LensScoreHostView
    private let footer = NSTextField(labelWithString: "")
    private let badge = NSTextField(labelWithString: "")
    /// The same switch as the request lines', so ⇥ between them only
    /// changes what is below it.
    let modes = LensModeBar()
    /// Where ⇥ goes, for the footer ("graphics"); nil when nowhere.
    var tabTarget: String?

    static let musicHeight: CGFloat = 136

    init(host: LensScoreHostView) {
        self.host = host
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        // The popover's material lets a white page through; darken it so
        // the footer keeps its contrast (HIG Materials).
        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.withAlphaComponent(0.72).cgColor

        let paper = NSView()
        paper.wantsLayer = true
        paper.layer?.backgroundColor = Theme.lensPaper.cgColor
        paper.layer?.cornerRadius = 6
        paper.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paper)
        paper.addSubview(host)

        footer.font = Theme.secondaryFont
        footer.textColor = Theme.glassSecondaryText
        footer.lineBreakMode = .byTruncatingMiddle
        footer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        footer.translatesAutoresizingMaskIntoConstraints = false
        badge.font = Theme.secondaryFont
        badge.textColor = Theme.warning
        badge.alignment = .right
        badge.lineBreakMode = .byTruncatingTail
        badge.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        addSubview(badge)
        modes.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modes)

        NSLayoutConstraint.activate([
            paper.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            paper.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            modes.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            modes.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            paper.topAnchor.constraint(equalTo: topAnchor, constant: LensMode.barHeight + 8),
            paper.heightAnchor.constraint(equalToConstant: Self.musicHeight),
            host.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 10),
            host.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -10),
            host.topAnchor.constraint(equalTo: paper.topAnchor, constant: 4),
            host.bottomAnchor.constraint(equalTo: paper.bottomAnchor, constant: -4),
            footer.leadingAnchor.constraint(equalTo: paper.leadingAnchor, constant: 2),
            footer.topAnchor.constraint(equalTo: paper.bottomAnchor, constant: 6),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            badge.trailingAnchor.constraint(equalTo: paper.trailingAnchor, constant: -2),
            badge.firstBaselineAnchor.constraint(equalTo: footer.firstBaselineAnchor),
            badge.leadingAnchor.constraint(greaterThanOrEqualTo: footer.trailingAnchor, constant: 12),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func update(lens: LensScoreWindow, fileLabel: String, explicit: Bool) {
        let staff = lens.label.map { " · \($0)" } ?? ""
        let bars = lens.bars.count == 1 ? "bar \(lens.bars.lowerBound)" : "bars \(lens.bars.lowerBound)–\(lens.bars.upperBound)"
        // An edit's lens closes on the next render; say how to keep it.
        let tab = tabTarget.map { "  ⇥ \($0)" } ?? ""
        let keys = (explicit ? "←→ step" : "⌘L keep open  ←→ step") + tab + "  ⎋ close"
        footer.stringValue = "\(fileLabel)\(staff) · \(bars)    \(keys)"
        let unsupported = lens.unsupported
        badge.stringValue = unsupported.isEmpty ? "" : unsupported.joined(separator: " · ")
        badge.toolTip = unsupported.isEmpty ? nil : "Not shown in the lens: " + badge.stringValue
        badge.isHidden = unsupported.isEmpty
        setAccessibilityLabel("Notation preview\(staff.isEmpty ? "" : ", \(lens.label!)"), \(bars)")
    }

    // The lens is a preview: clicks must not reach the music or take focus.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { false }
}
