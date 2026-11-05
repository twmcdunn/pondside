import AppKit
import PondsideCore
import CoreText
import SheetMusicLayoutApple

/// The lens's content inside its popover: the engraved strip on softened
/// paper, and a line naming the passage. The popover supplies the chrome
/// (arrow, material, border) and adapts it to Reduce Transparency and
/// Increase Contrast; nothing here is translucent.
@available(macOS 15.0, *)
@MainActor
final class NotationLensOverlayView: NSView {
    private let meterIcon = NSImageView()
    private let duration = ArmedDurationView()
    private let accidentalHints = [
        AccidentalKeyHint(alteration: 0, symbol: "♮", key: "0", name: "Natural"),
        AccidentalKeyHint(alteration: -2, symbol: "♭", key: "-", name: "Flat"),
        AccidentalKeyHint(alteration: 2, symbol: "♯", key: "=", name: "Sharp"),
    ]
    private let inputGroup = NSStackView()
    private let meterGroup = NSView()
    private let meterKeys = NSTextField(labelWithString: "⌥U")
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
        badge.textColor = Theme.glassSecondaryText
        badge.alignment = .right
        badge.lineBreakMode = .byTruncatingTail
        badge.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        badge.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footer)
        addSubview(badge)
        modes.translatesAutoresizingMaskIntoConstraints = false
        addSubview(modes)
        meterIcon.translatesAutoresizingMaskIntoConstraints = false
        meterGroup.translatesAutoresizingMaskIntoConstraints = false
        meterGroup.wantsLayer = true
        meterGroup.layer?.cornerRadius = 6
        meterGroup.layer?.backgroundColor = Theme.glassSecondaryText.withAlphaComponent(0.12).cgColor
        addSubview(meterGroup)
        meterGroup.addSubview(meterIcon)
        meterKeys.font = Theme.secondaryFont
        meterKeys.textColor = Theme.glassSecondaryText
        meterKeys.translatesAutoresizingMaskIntoConstraints = false
        meterGroup.addSubview(meterKeys)
        duration.translatesAutoresizingMaskIntoConstraints = false
        inputGroup.orientation = .horizontal
        inputGroup.alignment = .centerY
        inputGroup.spacing = 4
        inputGroup.translatesAutoresizingMaskIntoConstraints = false
        inputGroup.addArrangedSubview(duration)
        for hint in accidentalHints { inputGroup.addArrangedSubview(hint) }
        addSubview(inputGroup)
        NSLayoutConstraint.activate([
            inputGroup.trailingAnchor.constraint(equalTo: meterGroup.leadingAnchor, constant: -10),
            duration.widthAnchor.constraint(equalToConstant: 44),
            duration.heightAnchor.constraint(equalToConstant: 28),
            meterGroup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            meterGroup.centerYAnchor.constraint(equalTo: topAnchor, constant: (LensMode.barHeight + 8) / 2),
            meterGroup.heightAnchor.constraint(equalToConstant: 26),
            meterIcon.leadingAnchor.constraint(equalTo: meterGroup.leadingAnchor, constant: 7),
            inputGroup.centerYAnchor.constraint(equalTo: meterIcon.centerYAnchor),
            meterKeys.trailingAnchor.constraint(equalTo: meterGroup.trailingAnchor, constant: -7),
            meterKeys.centerYAnchor.constraint(equalTo: meterIcon.centerYAnchor),
            meterIcon.trailingAnchor.constraint(equalTo: meterKeys.leadingAnchor, constant: -4),
            meterIcon.centerYAnchor.constraint(equalTo: meterGroup.centerYAnchor),
            meterIcon.widthAnchor.constraint(equalToConstant: 20),
            meterIcon.heightAnchor.constraint(equalToConstant: 20),
        ])

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

    override func layout() {
        // Keep every keyboard hint readable at the lens's minimum width.
        // Mode icons retain their tooltips; only their redundant labels shrink.
        modes.compact = bounds.width < 560
        super.layout()
    }

    func setDuration(_ value: String) { duration.value = DurationValue(text: value) ?? .quarter }

    func setArmedAccidental(_ alteration: Int?) {
        for hint in accidentalHints { hint.isArmed = hint.alteration == alteration }
    }

    func showFeedback(_ message: String) {
        footer.stringValue = message
        footer.toolTip = message
    }

    func setUnmetered(_ enabled: Bool) {
        meterIcon.image = NSImage(systemSymbolName: enabled ? "infinity" : "metronome", accessibilityDescription: enabled ? "Unmetered entry" : "Metered entry")
        meterIcon.contentTintColor = enabled ? Theme.warning : Theme.glassSecondaryText
        meterGroup.toolTip = enabled ? "Unmetered entry · ⌥U · | finishes the bar" : "Metered entry · ⌥U"
    }

    func update(lens: LensScoreWindow, fileLabel: String, explicit: Bool) {
        let staff = lens.label.map { " · \($0)" } ?? ""
        let bars = lens.bars.count == 1 ? "bar \(lens.bars.lowerBound)" : "bars \(lens.bars.lowerBound)–\(lens.bars.upperBound)"
        // An edit's lens closes on the next render; say how to keep it.
        let tab = tabTarget.map { "  ⇥ \($0)" } ?? ""
        let keys = (explicit ? "←→ step" : "⌘L keep open  ←→ step") + tab + "  ⎋ close"
        footer.stringValue = "\(fileLabel)\(staff) · \(bars)    \(keys)"
        let unsupported = lens.unsupported
        badge.stringValue = unsupported.isEmpty ? "" : "ⓘ"
        badge.toolTip = unsupported.isEmpty ? nil : "Not shown in the lens: " + unsupported.joined(separator: " · ")
        badge.isHidden = unsupported.isEmpty
        setAccessibilityLabel("Notation preview\(staff.isEmpty ? "" : ", \(lens.label!)"), \(bars)")
    }

    // The surrounding chrome leaves keyboard focus in the score.
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override var acceptsFirstResponder: Bool { false }
}

/// A passive keyboard hint, styled and aligned with the adjacent meter hint.
@MainActor
private final class AccidentalKeyHint: NSView {
    let alteration: Int
    private let glyph: NSTextField
    private let keyLabel: NSTextField
    var isArmed = false { didSet { refreshAppearance() } }

    init(alteration: Int, symbol: String, key: String, name: String) {
        self.alteration = alteration
        glyph = NSTextField(labelWithString: symbol)
        keyLabel = NSTextField(labelWithString: key)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6
        glyph.font = .systemFont(ofSize: 20)
        glyph.alignment = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        keyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)
        addSubview(keyLabel)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 36),
            heightAnchor.constraint(equalToConstant: 26),
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 5),
            glyph.widthAnchor.constraint(equalToConstant: 12),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            keyLabel.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: 3),
            keyLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        toolTip = "\(name) · \(key) · toggle selected accidental or arm next note"
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(name) accidental, \(key)")
        NotificationCenter.default.addObserver(self, selector: #selector(refreshAppearance),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        refreshAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func refreshAppearance() {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let color = isArmed ? Theme.accent : Theme.glassSecondaryText
        layer?.backgroundColor = color.withAlphaComponent(isArmed ? 0.20 : 0.12).cgColor
        layer?.borderWidth = isArmed ? 2 : (contrast ? 1 : 0)
        layer?.borderColor = color.cgColor
        glyph.textColor = color
        keyLabel.textColor = color
        keyLabel.font = .systemFont(ofSize: Theme.secondarySize, weight: isArmed ? .semibold : .regular)
        setAccessibilityValue(isArmed ? "Armed" : "Not armed")
    }
}

@available(macOS 15.0, *)
@MainActor
private final class ArmedDurationView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Armed duration: 4")
        toolTip = "Armed duration: 4"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var value = DurationValue.quarter {
        didSet {
            toolTip = "Armed duration: " + value.text
            setAccessibilityLabel(toolTip)
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        _ = BravuraFont.register
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let scalar: UInt32
        switch value.log {
        case ...(-1): scalar = 0xE1D0 // breve
        case 0: scalar = 0xE1D2
        case 1: scalar = 0xE1D3
        default: scalar = 0xE1D5 + UInt32(min(7, value.log) - 2) * 2
        }
        let font = CTFontCreateWithName("Bravura" as CFString, 30, nil)
        var character = UniChar(scalar)
        var glyph = CGGlyph()
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1),
              let path = CTFontCreatePathForGlyph(font, glyph, nil) else { return }
        let box = path.boundingBoxOfPath
        let tuplet = value.factorNumerator != 1 || value.factorDenominator != 1
        let height: CGFloat = tuplet ? 18 : 23
        let scale = min(1, height / max(1, box.height))
        context.saveGState()
        context.setFillColor(Theme.glassSecondaryText.cgColor)
        context.translateBy(x: 5 - box.minX * scale, y: 2 - box.minY * scale)
        context.scaleBy(x: scale, y: scale)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
        Theme.glassSecondaryText.setFill()
        for dot in 0..<min(3, value.dots) {
            NSBezierPath(ovalIn: NSRect(x: 8 + box.width * scale + CGFloat(dot) * 4, y: 5, width: 2.5, height: 2.5)).fill()
        }
        if tuplet {
            let label = value.factorNumerator == 2 && value.factorDenominator == 3 ? "3" : "\(value.factorNumerator):\(value.factorDenominator)"
            (label as NSString).draw(at: NSPoint(x: 8, y: 18), withAttributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: Theme.glassSecondaryText])
        }
    }
}
