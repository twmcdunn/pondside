import AppKit
import PondsideCore

/// The LilyPond source pane: a TextKit 2 `NSTextView`, configured as a code
/// editor (no smart quotes, no autocorrect), dark, with a legible mono font.
///
/// A score can span several files, so the pane holds one text view per
/// file and swaps them in place. Each keeps its own caret, scroll position
/// and undo stack (the file's), exactly like tabs in a code editor.
///
/// Highlighting and LSP-style services arrive in M5.
@MainActor
final class SourceEditorView: NSView, NSTextViewDelegate {
    let scrollView = NSScrollView()
    /// The visible file's text view.
    private(set) var textView: NSTextView
    private(set) var activeKey: URL?
    private var views: [URL: NSTextView] = [:]
    private var undoManagers: [ObjectIdentifier: UndoManager] = [:]
    private var scrollOrigins: [URL: NSPoint] = [:]

    /// Called after every user edit with the full new text.
    var onUserEdit: ((String) -> Void)?
    /// Called when the selection changes (UTF-16 range).
    var onSelectionChange: ((NSRange) -> Void)?

    private var applyingProgrammaticChange = false

    override init(frame frameRect: NSRect) {
        textView = NSTextView(usingTextLayoutManager: true)
        super.init(frame: frameRect)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.editorBackground
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        configure(textView)
        scrollView.documentView = textView
        scrollView.verticalRulerView = SourceLineRuler(scrollView: scrollView, textView: textView)
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
    }

    private func configure(_ tv: NSTextView) {
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainerInset = NSSize(width: 14, height: 14)

        tv.isRichText = false
        tv.importsGraphics = false
        tv.allowsUndo = true
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.smartInsertDeleteEnabled = false

        tv.font = Theme.monoFont
        tv.textColor = Theme.text
        tv.backgroundColor = Theme.editorBackground
        tv.drawsBackground = true
        tv.insertionPointColor = Theme.accent
        tv.selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.28)]
        tv.typingAttributes = baseAttributes
        tv.delegate = self
    }

    /// Shows `key`'s text view, creating it from `text` the first time.
    func show(_ key: URL, text: String, undoManager: UndoManager) {
        if let current = activeKey { scrollOrigins[current] = scrollView.contentView.bounds.origin }
        let view: NSTextView
        if let existing = views[key] {
            view = existing
        } else if activeKey == nil && views.isEmpty {
            // Reuse the initial view for the first file.
            view = textView
            views[key] = view
            load(text, into: view)
        } else {
            view = NSTextView(usingTextLayoutManager: true)
            configure(view)
            view.frame = NSRect(origin: .zero, size: scrollView.contentSize)
            views[key] = view
            load(text, into: view)
        }
        undoManagers[ObjectIdentifier(view)] = undoManager
        textView = view
        activeKey = key
        scrollView.documentView = view
        (scrollView.verticalRulerView as? SourceLineRuler)?.bind(to: view)
        view.textContainer?.containerSize = NSSize(width: scrollView.contentSize.width, height: .greatestFiniteMagnitude)
        if let origin = scrollOrigins[key] {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    /// Forgets a file that left the include graph.
    func forget(_ key: URL) {
        guard key != activeKey, let view = views.removeValue(forKey: key) else { return }
        undoManagers.removeValue(forKey: ObjectIdentifier(view))
        scrollOrigins.removeValue(forKey: key)
    }

    func hasView(for key: URL) -> Bool { views[key] != nil }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: Theme.monoFont, .foregroundColor: Theme.text]
    }

    var text: String { textView.string }

    private func load(_ string: String, into view: NSTextView) {
        applyingProgrammaticChange = true
        view.textStorage?.setAttributedString(NSAttributedString(string: string, attributes: baseAttributes))
        view.setSelectedRange(NSRange(location: 0, length: 0))
        applyingProgrammaticChange = false
    }

    /// Merges an external edit as a single minimal replacement, so the caret,
    /// selection and scroll position of untouched text stay exactly where
    /// they were. The change is undoable like any other edit unless
    /// `registeringUndo` is false (an agent change keeps its own single
    /// cross-file undo step instead).
    func mergeExternal(_ newText: String, into key: URL, registeringUndo: Bool = true) {
        guard let view = views[key] else { return }
        let manager = view.undoManager
        if !registeringUndo { manager?.disableUndoRegistration() }
        defer { if !registeringUndo { manager?.enableUndoRegistration() } }
        if view !== textView {
            applyingProgrammaticChange = true
            if let r = TextDiff.minimalReplacement(from: view.string, to: newText) {
                let range = NSRange(location: r.location, length: r.length)
                if view.shouldChangeText(in: range, replacementString: r.replacement) {
                    view.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: r.replacement, attributes: baseAttributes))
                    view.didChangeText()
                }
            }
            applyingProgrammaticChange = false
            return
        }
        guard let r = TextDiff.minimalReplacement(from: textView.string, to: newText) else { return }
        let range = NSRange(location: r.location, length: r.length)
        let oldSelections = textView.selectedRanges.map(\.rangeValue)
        let visibleOrigin = scrollView.contentView.bounds.origin

        applyingProgrammaticChange = true
        if textView.shouldChangeText(in: range, replacementString: r.replacement) {
            textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: r.replacement, attributes: baseAttributes))
            textView.didChangeText()
        }
        let mapped = oldSelections.map { sel -> NSValue in
            let start = r.mapOffset(sel.location)
            let end = r.mapOffset(sel.location + sel.length)
            return NSValue(range: NSRange(location: start, length: max(0, end - start)))
        }
        textView.selectedRanges = mapped
        applyingProgrammaticChange = false
        scrollView.contentView.scroll(to: visibleOrigin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Applies an edit made in the score as an ordinary, undoable text
    /// change on the file's own undo stack, which the window also uses, so
    /// ⌘Z in either pane undoes both kinds of edit in order.
    func replace(_ range: NSRange, with string: String, actionName: String) {
        guard textView.shouldChangeText(in: range, replacementString: string) else { return }
        textView.textStorage?.replaceCharacters(in: range, with: NSAttributedString(string: string, attributes: baseAttributes))
        textView.didChangeText()
        textView.undoManager?.setActionName(actionName)
    }

    func select(_ range: NSRange, scroll: Bool = true) {
        let length = (textView.string as NSString).length
        let clamped = NSRange(location: min(range.location, length), length: min(range.length, max(0, length - range.location)))
        textView.setSelectedRange(clamped)
        if scroll { textView.scrollRangeToVisible(clamped) }
    }

    /// Colours the source by token kind with rendering attributes, which
    /// decorate the text without editing it (and without touching undo).
    func showSyntax(_ runs: [(NSRange, NSColor)]) {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return }
        let doc = tlm.documentRange
        tlm.removeRenderingAttribute(.foregroundColor, for: doc)
        for (r, color) in runs where r.length > 0 {
            guard let start = tcm.location(doc.location, offsetBy: r.location),
                  let end = tcm.location(start, offsetBy: r.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            tlm.addRenderingAttribute(.foregroundColor, value: color, for: textRange)
        }
    }

    /// Underlines diagnostic ranges using TextKit 2 rendering attributes, which
    /// decorate the text without editing it (and without touching undo).
    func showDiagnostics(_ ranges: [(NSRange, NSColor)]) {
        guard let tlm = textView.textLayoutManager, let tcm = tlm.textContentManager else { return }
        let doc = tlm.documentRange
        tlm.removeRenderingAttribute(.underlineStyle, for: doc)
        tlm.removeRenderingAttribute(.underlineColor, for: doc)
        for (r, color) in ranges {
            guard let start = tcm.location(doc.location, offsetBy: r.location),
                  let end = tcm.location(start, offsetBy: max(1, r.length)),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            tlm.addRenderingAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, for: textRange)
            tlm.addRenderingAttribute(.underlineColor, value: color, for: textRange)
        }
    }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? {
        undoManagers[ObjectIdentifier(view)]
    }

    func textDidChange(_ notification: Notification) {
        guard !applyingProgrammaticChange, (notification.object as? NSTextView) === textView else { return }
        onUserEdit?(textView.string)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !applyingProgrammaticChange, (notification.object as? NSTextView) === textView else { return }
        onSelectionChange?(textView.selectedRange())
    }
}
