import AppKit
import PondsideBridge

/// The Agent Log pane: what every agent run did, read back from
/// `AgentLog`'s file (the app's own entries and those of the `pondside mcp`
/// server each agent starts), newest at the bottom.
///
/// HIG pattern: a content view in a pane, like Compiler Output (a console):
/// selectable text, no alerts, nothing that takes focus by itself. Errors
/// and warnings are marked by a symbol as well as colour. While the pane is
/// on screen it follows the file twice a second; off screen it doesn't poll.
@MainActor
final class AgentLogView: NSView {
    private let header = NSStackView()
    private let filter = NSSegmentedControl()
    private let detailsBox = NSButton(checkboxWithTitle: "Details", target: nil, action: nil)
    private let verboseBox = NSButton(checkboxWithTitle: "Verbose", target: nil, action: nil)
    private let scroll = NSScrollView()
    private let textView = LogTextView()
    private var presenter = AgentLogPresenter()
    private let log: AgentLog
    private var offset: UInt64 = 0
    private var shownEntries: [AgentLog.Entry] = []
    private var timer: Timer?
    private var showsPlaceholder = false
    /// Wrapped lines hang under the message: past the time (8), mark (2),
    /// event (9) and a space, 22 columns of the monospaced font.
    private var paragraph: NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byWordWrapping
        let column = ("M" as NSString).size(withAttributes: [.font: Self.mono]).width
        p.headIndent = (column * 22).rounded()
        return p
    }

    init(log: AgentLog = .shared) {
        self.log = log
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Agent Log")

        filter.segmentCount = AgentLogPresenter.Filter.allCases.count
        for (i, f) in AgentLogPresenter.Filter.allCases.enumerated() { filter.setLabel(f.title, forSegment: i) }
        filter.selectedSegment = 0
        filter.controlSize = .small
        filter.font = Theme.secondaryFont
        filter.target = self
        filter.action = #selector(changeFilter)
        filter.setAccessibilityLabel("Show runs of")
        for box in [detailsBox, verboseBox] {
            box.controlSize = .small
            box.font = Theme.secondaryFont
            box.target = self
            box.action = #selector(toggleOptions)
        }
        detailsBox.toolTip = "Show each entry's prompt, tool input or output (d)"
        verboseBox.toolTip = "Show thinking, model steps and raw tool results (v)"
        let reveal = NSButton(title: "Show in Finder", target: self, action: #selector(revealFile))
        reveal.controlSize = .small
        reveal.font = Theme.secondaryFont
        reveal.bezelStyle = .rounded
        reveal.toolTip = log.url.path
        let clear = NSButton(title: "Clear", target: self, action: #selector(clearView))
        clear.controlSize = .small
        clear.font = Theme.secondaryFont
        clear.bezelStyle = .rounded
        clear.toolTip = "Clear the pane; the log file keeps everything"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        for v in [filter, detailsBox, verboseBox, spacer, reveal, clear] as [NSView] { header.addArrangedSubview(v) }
        // A narrow pane drops the buttons first (the log file keeps everything;
        // d, v and f work from the keyboard), then the checkboxes.
        header.setVisibilityPriority(.detachOnlyIfNecessary, for: filter)
        for v in [detailsBox, verboseBox] { header.setVisibilityPriority(.init(600), for: v) }
        for v in [reveal, clear] { header.setVisibilityPriority(.init(400), for: v) }
        header.setClippingResistancePriority(.defaultLow, for: .horizontal)
        header.orientation = .horizontal
        header.spacing = 10
        header.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        header.translatesAutoresizingMaskIntoConstraints = false

        let rule = NSBox()
        rule.boxType = .custom
        rule.borderWidth = 0
        rule.fillColor = Theme.separator
        rule.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = Theme.editorBackground
        textView.textColor = Theme.text
        textView.font = Self.mono
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityLabel("Agent log entries")
        textView.onKey = { [weak self] key in self?.key(key) ?? false }
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.editorBackground
        scroll.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(rule)
        addSubview(scroll)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: header.bottomAnchor),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.heightAnchor.constraint(equalToConstant: 1),
            scroll.topAnchor.constraint(equalTo: rule.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(displayOptionsChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The view that takes the keyboard.
    var responder: NSView { textView }

    static var mono: NSFont { .monospacedSystemFont(ofSize: Theme.secondarySize, weight: .regular) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        if shownEntries.isEmpty, offset == 0 { load() } else { poll() }
        let t = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Reading

    private func load() {
        let (entries, next) = log.tail(3000)
        offset = next
        shownEntries = entries
        rebuild()
    }

    private func poll() {
        let (entries, next) = log.read(from: offset)
        if next < offset { load(); return }   // rotated
        offset = next
        guard !entries.isEmpty else { return }
        shownEntries.append(contentsOf: entries)
        if shownEntries.count > 6000 { shownEntries.removeFirst(shownEntries.count - 4000); rebuild(); return }
        append(presenter.spans(for: entries))
    }

    private func rebuild() {
        // A fresh presenter learns the runs' kinds again from the entries.
        var p = AgentLogPresenter()
        p.filter = presenter.filter
        p.details = presenter.details
        p.verbose = presenter.verbose
        presenter = p
        textView.textStorage?.setAttributedString(NSAttributedString())
        let spans = presenter.spans(for: shownEntries)
        if spans.isEmpty {
            textView.textStorage?.setAttributedString(NSAttributedString(
                string: "No agent runs yet. Requests from the lens (⇥ in the lens, then ↩) and patch refactors are logged here "
                    + "and in \(log.url.path).\n",
                attributes: [.font: Theme.secondaryFont, .foregroundColor: Theme.secondaryText]))
            showsPlaceholder = true
            return
        }
        append(spans, forceScroll: true)
    }

    private func append(_ spans: [AgentLogPresenter.Span], forceScroll: Bool = false) {
        guard !spans.isEmpty, let storage = textView.textStorage else { return }
        let clip = scroll.contentView
        let atEnd = forceScroll || clip.bounds.maxY >= textView.frame.height - 24
        let out = NSMutableAttributedString()
        for s in spans { out.append(NSAttributedString(string: s.text, attributes: attributes(s.style))) }
        if showsPlaceholder { storage.setAttributedString(out) } else { storage.append(out) }
        showsPlaceholder = false
        if atEnd { textView.scrollToEndOfDocument(nil) }
    }

    private func attributes(_ style: AgentLogPresenter.Style) -> [NSAttributedString.Key: Any] {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let quiet = contrast ? Theme.text : Theme.secondaryText
        var a: [NSAttributedString.Key: Any] = [.font: Self.mono, .paragraphStyle: paragraph]
        switch style {
        case .heading:
            a[.font] = NSFont.systemFont(ofSize: Theme.secondarySize, weight: .semibold)
            a[.foregroundColor] = Theme.accent
            a[.paragraphStyle] = NSParagraphStyle.default
        case .time: a[.foregroundColor] = quiet
        case .normal: a[.foregroundColor] = Theme.text
        case .quiet: a[.foregroundColor] = quiet
        case .warning: a[.foregroundColor] = Theme.warning
        case .error: a[.foregroundColor] = Theme.error
        case .detail: a[.foregroundColor] = quiet
        }
        return a
    }

    // MARK: Controls

    @objc private func changeFilter() {
        presenter.filter = AgentLogPresenter.Filter.allCases[max(0, filter.selectedSegment)]
        rebuild()
    }

    @objc private func toggleOptions() {
        presenter.details = detailsBox.state == .on
        presenter.verbose = verboseBox.state == .on
        rebuild()
    }

    @objc private func revealFile() {
        if FileManager.default.fileExists(atPath: log.url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([log.url])
        } else {
            NSWorkspace.shared.open(log.url.deletingLastPathComponent())
        }
    }

    @objc private func clearView() {
        shownEntries = []
        rebuild()
    }

    @objc private func displayOptionsChanged() { rebuild() }

    /// Plain keys in the log: d details, v verbose, f the next filter.
    private func key(_ key: String) -> Bool {
        switch key {
        case "d": detailsBox.state = detailsBox.state == .on ? .off : .on; toggleOptions()
        case "v": verboseBox.state = verboseBox.state == .on ? .off : .on; toggleOptions()
        case "f":
            filter.selectedSegment = (filter.selectedSegment + 1) % filter.segmentCount
            changeFilter()
        default: return false
        }
        return true
    }
}

/// A read-only text view that hands plain letter keys to its pane.
@MainActor
private final class LogTextView: NSTextView {
    var onKey: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        if mods.isEmpty, let c = event.charactersIgnoringModifiers, onKey?(c) == true { return }
        super.keyDown(with: event)
    }
}
