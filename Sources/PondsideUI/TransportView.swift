import AppKit

/// The score pane's transport: which recording plays (the mockup, or the mix
/// with the patch's electronics), play/pause, stop, where the selection or
/// the playing head is (bar, beat, clock time) and a slim timeline.
///
/// HIG pattern: a HUD-style floating control over content (chrome on glass,
/// like the lens card), not a toolbar: it belongs to the score pane and can
/// be dragged out of the way; where it sits is remembered. It never takes
/// key focus (its controls refuse first responder), so typing stays in the
/// score. Under Reduce Transparency the glass is solid (`GlassView`).
@MainActor
final class TransportView: NSView {
    enum Source: Int { case mockup = 0, mix = 1 }
    enum State { case stopped, playing, paused }

    var onPlayPause: (() -> Void)?
    var onStop: (() -> Void)?
    var onSource: ((Source) -> Void)?
    /// A click on the timeline: a fraction of the piece.
    var onSeek: ((Double) -> Void)?

    private let glass = GlassView(cornerRadius: 9)
    /// The two recordings, each an icon; the chosen one in the accent.
    private let mockupButton = TransportView.sourceButton("music.note", label: "Mockup")
    private let mixButton = TransportView.sourceButton("waveform", label: "With electronics")
    private let playButton = TransportView.button("play.fill", label: "Play")
    private let stopButton = TransportView.button("stop.fill", label: "Stop")
    private let time = NSTextField(labelWithString: "")
    private let timeline = TimelineView()
    private var stack = NSStackView()
    private lazy var timeWidth = time.widthAnchor.constraint(equalToConstant: 0)

    private(set) var source: Source = .mockup
    private(set) var state: State = .stopped

    private static let height: CGFloat = 30
    private static let offsetKey = "transport.offset"
    /// From the top-right corner of the pane, so a resize keeps it there.
    private var offset: NSPoint

    override init(frame frameRect: NSRect) {
        let stored = UserDefaults.standard.array(forKey: Self.offsetKey) as? [Double]
        offset = stored.map { NSPoint(x: $0.first ?? 14, y: $0.last ?? 12) } ?? NSPoint(x: 14, y: 12)
        super.init(frame: frameRect)
        wantsLayer = true
        // The shadow on this unclipped layer; the glass inside is clipped round.
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 7
        layer?.shadowOffset = CGSize(width: 0, height: -2)

        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)

        mockupButton.target = self
        mockupButton.action = #selector(chooseMockup)
        mixButton.target = self
        mixButton.action = #selector(chooseMix)
        mockupButton.setButtonType(.toggle)
        mixButton.setButtonType(.toggle)
        showSource()
        showState()

        playButton.target = self
        playButton.action = #selector(playPause)
        stopButton.target = self
        stopButton.action = #selector(stop)

        time.font = .monospacedDigitSystemFont(ofSize: Theme.secondarySize, weight: .regular)
        time.textColor = Theme.glassSecondaryText
        time.lineBreakMode = .byClipping
        time.setContentHuggingPriority(.required, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setAccessibilityLabel("Position")
        time.isHidden = true

        timeline.onSeek = { [weak self] f in self?.onSeek?(f) }

        let divider = NSBox()
        divider.boxType = .separator
        stack = NSStackView(views: [mockupButton, mixButton, divider, playButton, stopButton, time, timeline])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setCustomSpacing(4, after: mockupButton)
        stack.setCustomSpacing(8, after: mixButton)
        stack.setCustomSpacing(2, after: playButton)
        stack.setCustomSpacing(10, after: stopButton)
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 10)
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            divider.heightAnchor.constraint(equalToConstant: 16),
            timeline.widthAnchor.constraint(equalToConstant: 84),
            timeline.heightAnchor.constraint(equalToConstant: Self.height),
            timeWidth,
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Playback")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private static func button(_ symbol: String, label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imageScaling = .scaleProportionallyDown
        b.contentTintColor = Theme.text
        b.refusesFirstResponder = true
        b.setAccessibilityLabel(label)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return b
    }

    /// An icon on a faint rounded ground when chosen. Its shortcut shows
    /// in the tooltip and, under ⌥, on the window's key reveal.
    private static func sourceButton(_ symbol: String, label: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: nil, action: nil)
        b.isBordered = false
        b.bezelStyle = .regularSquare
        b.imagePosition = .imageOnly
        b.imageScaling = .scaleNone
        b.refusesFirstResponder = true
        b.setAccessibilityLabel(label)
        b.translatesAutoresizingMaskIntoConstraints = false
        b.widthAnchor.constraint(equalToConstant: 22).isActive = true
        b.heightAnchor.constraint(equalToConstant: 22).isActive = true
        b.wantsLayer = true
        b.layer?.cornerRadius = 6
        return b
    }

    /// The source buttons, for the ⌥ key reveal.
    var mockupControl: NSView { mockupButton }
    var mixControl: NSView { mixButton }

    // MARK: State

    /// The shortcuts as the keymap has them, for the hints.
    func setHints(play: String?, playMix: String?, stop: String) {
        let p = play.map { " (\($0))" } ?? "", m = playMix.map { " (\($0))" } ?? ""
        mockupButton.toolTip = "Mockup" + p + ": the instruments alone"
        mixButton.toolTip = "With electronics" + m + ": the score and the patch's mix"
        mockupButton.setAccessibilityHelp(mockupButton.toolTip)
        mixButton.setAccessibilityHelp(mixButton.toolTip)
        playHints = (p, m)
        stopButton.toolTip = "Stop (\(stop))"
        updatePlayButton()
    }
    private var playHints = ("", "")
    private var stamp = ""

    /// A recording that isn't there yet: its segment dims, and says why.
    func setAvailable(mockup: String?, mix: String?) {
        unavailable = [mockup, mix]
        updatePlayButton()
    }
    private var unavailable: [String?] = [nil, nil]

    func setSource(_ s: Source) {
        source = s
        showSource()
        updatePlayButton()
    }

    private func showSource() {
        for (button, s) in [(mockupButton, Source.mockup), (mixButton, Source.mix)] {
            let on = s == source
            button.state = on ? .on : .off
            button.contentTintColor = on ? Theme.accent : Theme.secondaryText
            button.layer?.backgroundColor = on ? Theme.glassSecondaryText.withAlphaComponent(0.12).cgColor : nil
            button.setAccessibilityValue(on ? "Selected" : nil)
        }
    }

    func setState(_ s: State) {
        guard s != state else { return }
        state = s
        showState()
    }

    private func showState() {
        let s = state
        updatePlayButton()
        stopButton.isEnabled = s != .stopped
        stopButton.contentTintColor = s == .stopped ? Theme.secondaryText.withAlphaComponent(0.6) : Theme.text
    }

    /// The stamp and the timeline's mark (nil: nothing to show).
    func setPosition(_ label: String?, fraction: Double?) {
        stamp = label ?? ""
        showTime()
        timeline.fraction = fraction
    }

    private func showTime() {
        let text = stamp
        guard time.stringValue != text else { return }
        time.stringValue = text
        time.isHidden = text.isEmpty
        // Playing or paused, the stamp only widens (a new digit), never
        // narrows, so the bar doesn't flicker as it ticks; stopped, it fits.
        let width = ceil(time.intrinsicContentSize.width)
        let floor = state == .stopped ? width : max(width, timeWidth.constant)
        if floor != timeWidth.constant || state == .stopped {
            timeWidth.constant = floor
            place()
        }
    }

    private func updatePlayButton() {
        let playing = state == .playing
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
                                   accessibilityDescription: playing ? "Pause" : "Play")
        playButton.setAccessibilityLabel(playing ? "Pause" : "Play")
        let hint = source == .mockup ? playHints.0 : playHints.1
        let what = source == .mockup ? "the mockup" : "with electronics"
        switch state {
        case .playing: playButton.toolTip = "Pause"
        case .paused: playButton.toolTip = "Resume " + what
        case .stopped:
            playButton.toolTip = (unavailable[source.rawValue].map { "Play \(what): \($0)" } ?? "Play \(what) from the selection") + hint
        }
        let missing = unavailable[source.rawValue] != nil && state == .stopped
        playButton.contentTintColor = missing ? Theme.secondaryText.withAlphaComponent(0.6) : Theme.text
    }

    @objc private func chooseMockup() { choose(.mockup) }
    @objc private func chooseMix() { choose(.mix) }

    private func choose(_ s: Source) {
        source = s
        showSource()
        updatePlayButton()
        onSource?(s)
    }

    @objc private func playPause() { onPlayPause?() }
    @objc private func stop() { onStop?() }

    // MARK: Placement (frames: its superview is a scroll view)

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        NotificationCenter.default.removeObserver(self)
        guard let superview else { return }
        superview.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(place), name: NSView.frameDidChangeNotification, object: superview)
        place()
    }

    @objc func place() {
        guard let superview else { return }
        let size = NSSize(width: stack.fittingSize.width, height: Self.height)
        let bounds = superview.bounds
        var x = bounds.maxX - offset.x - size.width
        var y = superview.isFlipped ? bounds.minY + offset.y : bounds.maxY - offset.y - size.height
        x = min(max(x, bounds.minX + 4), max(bounds.minX + 4, bounds.maxX - size.width - 4))
        y = min(max(y, bounds.minY + 4), max(bounds.minY + 4, bounds.maxY - size.height - 4))
        frame = NSRect(x: x, y: y, width: size.width, height: Self.height)
    }

    // Dragged by its background (the controls keep their clicks).
    private var dragStart: (mouse: NSPoint, offset: NSPoint)?

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        dragStart = (event.locationInWindow, offset)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart, let superview else { return }
        let dx = event.locationInWindow.x - start.mouse.x
        let dy = event.locationInWindow.y - start.mouse.y
        // Window coordinates go up; the offset is from the top-right.
        offset = NSPoint(x: start.offset.x - dx, y: start.offset.y - dy)
        let size = frame.size, bounds = superview.bounds
        offset.x = min(max(offset.x, 4), max(4, bounds.width - size.width - 4))
        offset.y = min(max(offset.y, 4), max(4, bounds.height - size.height - 4))
        place()
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStart != nil else { return }
        dragStart = nil
        NSCursor.pop()
        UserDefaults.standard.set([Double(offset.x), Double(offset.y)], forKey: Self.offsetKey)
    }
}

/// The timeline: a hairline track, the elapsed part in the accent, a small
/// knob at the position. A click seeks (while there is something to seek).
@MainActor
private final class TimelineView: NSView {
    var onSeek: ((Double) -> Void)?
    var fraction: Double? { didSet { if fraction != oldValue { needsDisplay = true } } }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let track = NSRect(x: bounds.minX + 4, y: bounds.midY - 1.5, width: bounds.width - 8, height: 3)
        NSColor(white: 1, alpha: contrast ? 0.45 : 0.22).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        guard let f = fraction.map({ min(1, max(0, $0)) }) else { return }
        let x = track.minX + track.width * f
        Theme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: track.minX, y: track.minY, width: x - track.minX, height: track.height),
                     xRadius: 1.5, yRadius: 1.5).fill()
        let r: CGFloat = 4
        NSColor.white.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - r, y: bounds.midY - r, width: 2 * r, height: 2 * r)).fill()
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        onSeek?(Double((p.x - 4) / max(1, bounds.width - 8)))
    }
}
