import AppKit
import PondsideCore

/// The single always-on line of help and state at the bottom of the window:
/// compile indicator, the 2–3 most relevant actions, zoom and toolchain.
@MainActor
final class StatusBarView: NSView {
    private let dot = NSView()
    private let statusLabel = StatusBarView.label(Theme.secondaryText)
    private let hintsLabel = StatusBarView.label(Theme.secondaryText.withAlphaComponent(0.8))
    private let rightLabel = StatusBarView.label(Theme.secondaryText)
    private var flashTask: Task<Void, Never>?
    private var baseStatus = ""
    private var rightText = ""
    private var inputText = ""
    private var engravingTask: Task<Void, Never>?
    private var isEngraving = false
    /// Background work besides engraving ("Rendering the mix..."), listed
    /// after the engraving status.
    private var activities: [String] = []
    /// Whether the dot pulses: engraving or any activity.
    private var isBusy = false
    /// Dots of each "..." drawn at full strength; 3 when not animating.
    private var ellipsisPhase = 3
    /// Shown while an agent works, next to what it is doing: cancels it.
    private let stopButton = NSButton()
    var onStopAgent: () -> Void = {}
    /// Collapses the button while hidden, so the hints don't leave a gap for it.
    private lazy var stopCollapsed = stopButton.widthAnchor.constraint(equalToConstant: 0)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.chrome.cgColor

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.toolTip = "Engraving status — clean, compiling, or errors — and, while it pulses, work running in the background."

        hintsLabel.lineBreakMode = .byTruncatingTail
        hintsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        statusLabel.lineBreakMode = .byTruncatingTail

        let separator = NSBox()
        separator.boxType = .custom
        separator.borderWidth = 0
        separator.fillColor = Theme.separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // HIG: a small, plain control beside the status it acts on, labelled in words.
        stopButton.title = "Stop Agent"
        stopButton.image = NSImage(systemSymbolName: "stop.circle", accessibilityDescription: nil)
        stopButton.imagePosition = .imageLeading
        stopButton.isBordered = false
        stopButton.font = Theme.secondaryFont
        stopButton.contentTintColor = Theme.text
        stopButton.attributedTitle = NSAttributedString(string: "Stop Agent", attributes: [.font: Theme.secondaryFont, .foregroundColor: Theme.text])
        stopButton.toolTip = "Cancel the agent's work (⌘⌥.). What it already changed stays; ␣ e z undoes it."
        stopButton.setAccessibilityLabel("Stop the agent")
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isHidden = true
        stopCollapsed.isActive = true
        stopButton.refusesFirstResponder = true
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        for v in [separator, dot, statusLabel, stopButton, hintsLabel, rightLabel] as [NSView] { addSubview(v) }
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),

            statusLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.55),

            stopButton.leadingAnchor.constraint(equalTo: statusLabel.trailingAnchor, constant: 10),
            stopButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            hintsLabel.leadingAnchor.constraint(equalTo: stopButton.trailingAnchor, constant: 18),
            hintsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintsLabel.trailingAnchor.constraint(lessThanOrEqualTo: rightLabel.leadingAnchor, constant: -16),

            rightLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Shows or hides Stop Agent; no motion, it just appears (HIG: frequent, passive).
    func setAgentWorking(_ working: Bool) {
        guard stopButton.isHidden == working else { return }
        stopButton.isHidden = !working
        stopCollapsed.isActive = !working
    }

    @objc private func stopClicked() { onStopAgent() }

    private static func label(_ color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: "")
        l.font = Theme.secondaryFont
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    /// `stale`: the pages are the last session's engraving, from the cache.
    func set(status: CompileStatus, detail: String?, zoom: CGFloat, toolchain: String, note: String?, stale: Bool = false) {
        let color: NSColor
        switch status {
        case .idle: baseStatus = "Ready"; color = Theme.secondaryText
        case .noLilyPond: baseStatus = "LilyPond not found — run the Pondside installer, or brew install lilypond"; color = Theme.warning
        case .compiling: baseStatus = stale ? "Engraving fresh..." : "Engraving..."; color = Theme.accent
        case .clean(let ms): baseStatus = "Clean · \(ms) ms"; color = Theme.accent.withAlphaComponent(0.55)
        case .errors(let n): baseStatus = "\(n) error\(n == 1 ? "" : "s")" + (detail.map { " — \($0)" } ?? ""); color = Theme.error
        case .failed(let why): baseStatus = why; color = Theme.error
        }
        dot.layer?.backgroundColor = color.cgColor
        dot.setAccessibilityLabel(baseStatus)
        isEngraving = status == .compiling
        setBusy(isEngraving || !activities.isEmpty)
        renderStatus()
        statusLabel.toolTip = detail
        var right = "\(Int((zoom * 100).rounded()))%   \(toolchain)"
        if let note { right = note + "   " + right }
        rightText = right
        renderRight()
        rightLabel.toolTip = "Zoom: ⌘= / ⌘- / ⌘0 fit width. Toolchain: the LilyPond this score compiles with."
    }

    /// Background work besides engraving, each ending in "...": the
    /// mockup and mix renders, an agent finishing a patch.
    func setActivities(_ list: [String]) {
        guard list != activities else { return }
        activities = list
        setBusy(isEngraving || !activities.isEmpty)
        renderStatus()
    }

    /// While anything works the one dot pulses and every ellipsis fills in,
    /// as an indeterminate progress indicator (HIG Loading). Most renders
    /// take a few hundred milliseconds and come keystroke after keystroke,
    /// so the motion starts only once work runs past 300 ms (HIG Motion:
    /// little motion for frequent events); Reduce Motion keeps both still.
    private func setBusy(_ on: Bool) {
        guard on != isBusy else { return }
        isBusy = on
        engravingTask?.cancel()
        engravingTask = nil
        dot.layer?.removeAnimation(forKey: "pondside.engraving")
        ellipsisPhase = 3
        guard on, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        engravingTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled, let self else { return }
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.3
            pulse.duration = 0.6
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.dot.layer?.add(pulse, forKey: "pondside.engraving")
            var phase = 0
            while !Task.isCancelled {
                self.ellipsisPhase = phase
                self.renderStatus()
                phase = (phase + 1) % 4
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
    }

    /// The status, then each activity. Every "..." keeps all three dots and
    /// only dims the ones not yet reached, so the width never changes.
    private func renderStatus() {
        guard flashTask == nil else { return }
        let items = [baseStatus] + activities
        let font = Theme.secondaryFont
        let text = NSMutableAttributedString()
        for (i, item) in items.enumerated() {
            if i > 0 { text.append(NSAttributedString(string: "   ", attributes: [.font: font])) }
            let animated = isBusy && item.hasSuffix("...")
            text.append(NSAttributedString(string: animated ? String(item.dropLast(3)) : item,
                                           attributes: [.font: font, .foregroundColor: Theme.secondaryText]))
            guard animated else { continue }
            for d in 0..<3 {
                let color = d < ellipsisPhase ? Theme.secondaryText : Theme.secondaryText.withAlphaComponent(0.25)
                text.append(NSAttributedString(string: ".", attributes: [.font: font, .foregroundColor: color]))
            }
        }
        statusLabel.attributedStringValue = text
    }

    /// Note-input state: the armed duration and any half-typed input.
    func setInput(armed: String?, buffer: String, completion: String? = nil) {
        var parts: [String] = []
        if let armed { parts.append("Next: \(armed)") }
        if !buffer.isEmpty { parts.append(buffer + "▏" + (completion.map { "\($0)  ⇥" } ?? "")) }
        inputText = parts.joined(separator: "   ")
        renderRight()
    }

    private var keyTarget = ""

    /// Where typed keys go: "score" (note entry) or "source" (text).
    func setKeyTarget(_ target: String) {
        keyTarget = target
        renderRight()
    }

    private func renderRight() {
        var parts = [String]()
        if !keyTarget.isEmpty { parts.append("Keys → \(keyTarget)") }
        if !inputText.isEmpty { parts.append(inputText) }
        parts.append(rightText)
        rightLabel.stringValue = parts.joined(separator: "      ")
    }

    private var hints: [String] = []
    private var chordShowing = false

    func setHints(_ hints: [String]) {
        self.hints = hints
        if !chordShowing { hintsLabel.stringValue = hints.joined(separator: "   ·   ") }
    }

    /// The chord hint bar: what was typed, and every key that can follow
    /// with its meaning. Learning is a side effect of use.
    func showChord(typed: String, continuations: [Keymap.Continuation]) {
        chordShowing = true
        let keyAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: Theme.secondarySize, weight: .semibold), .foregroundColor: Theme.accent,
        ]
        let labelAttrs: [NSAttributedString.Key: Any] = [.font: Theme.secondaryFont, .foregroundColor: Theme.text]
        let groupAttrs: [NSAttributedString.Key: Any] = [.font: Theme.secondaryFont, .foregroundColor: Theme.secondaryText]
        let s = NSMutableAttributedString(string: typed + "   ", attributes: keyAttrs)
        for c in continuations {
            s.append(NSAttributedString(string: c.key == " " ? "␣" : String(c.key), attributes: keyAttrs))
            s.append(NSAttributedString(string: " " + (c.command == nil ? c.label + "…" : c.label) + "    ",
                                        attributes: c.command == nil ? groupAttrs : labelAttrs))
        }
        hintsLabel.attributedStringValue = s
    }

    func endChord() {
        chordShowing = false
        hintsLabel.stringValue = hints.joined(separator: "   ·   ")
    }

    /// Shows a transient message in place of the status for a few seconds.
    func flash(_ message: String) {
        flashTask?.cancel()
        statusLabel.stringValue = message
        flashTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self else { return }
            self.flashTask = nil
            self.renderStatus()
        }
    }
}
