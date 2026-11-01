import AppKit
import PondsideCore

/// The SuperCollider editor: a plain-text code view with sclang's keys
/// (⌘↩ evaluate, ⇧↩ evaluate line, ⌘D help), colouring from `SCLexer`,
/// auto-indent, bracket matching, and completion from the interpreter's
/// own class library.
@MainActor
final class SCCodeView: NSTextView {
    var onEvaluate: ((String, NSRange) -> Void)?
    var onHelp: ((SCCompletion.HelpTopic) -> Void)?
    /// The signature of the call around the caret, or nil.
    var onSignature: ((String?) -> Void)?
    var library: () -> SCClassLibrary = { SCClassLibrary() }

    private let popup = SCCompletionPopup()
    private var completion: SCCompletion.Result?

    static func make() -> SCCodeView {
        // TextKit 1: colouring and flashes use temporary attributes.
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        let v = SCCodeView(frame: .zero, textContainer: container)
        v.configure()
        return v
    }

    private func configure() {
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainerInset = NSSize(width: 14, height: 12)
        isRichText = false
        importsGraphics = false
        allowsUndo = true
        usesFindBar = true
        isIncrementalSearchingEnabled = true
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        font = Theme.monoFont
        textColor = Theme.text
        backgroundColor = Theme.editorBackground
        drawsBackground = true
        insertionPointColor = Theme.accent
        selectedTextAttributes = [.backgroundColor: Theme.accent.withAlphaComponent(0.28)]
        typingAttributes = [.font: Theme.monoFont, .foregroundColor: Theme.text]
        let tab = (" " as NSString).size(withAttributes: [.font: Theme.monoFont]).width * 4
        let paragraph = NSMutableParagraphStyle()
        paragraph.defaultTabInterval = tab
        paragraph.tabStops = []
        defaultParagraphStyle = paragraph
        typingAttributes[.paragraphStyle] = paragraph
        popup.onAccept = { [weak self] item in self?.accept(item) }
    }

    func load(_ text: String) {
        string = text
        textStorage?.setAttributes([.font: Theme.monoFont, .foregroundColor: Theme.text,
                                    .paragraphStyle: defaultParagraphStyle ?? NSParagraphStyle.default],
                                   range: NSRange(location: 0, length: (text as NSString).length))
        setSelectedRange(NSRange(location: 0, length: 0))
        recolor()
    }

    // MARK: Colour

    func recolor() {
        guard let lm = layoutManager else { return }
        let all = NSRange(location: 0, length: (string as NSString).length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: all)
        for t in SCLexer.tokenize(string) {
            let color: NSColor
            switch t.kind {
            case .comment: color = Theme.syntaxComment
            case .string, .character: color = Theme.syntaxString
            case .symbol: color = Theme.syntaxScheme
            case .number, .builtin: color = Theme.syntaxNumber
            case .className: color = Theme.syntaxCommand
            case .keyword, .primitive: color = Theme.syntaxScheme
            case .environment: color = Theme.warning
            case .openParen, .closeParen, .openBracket, .closeBracket, .openBrace, .closeBrace, .punctuation:
                color = Theme.syntaxPunctuation
            case .identifier, .whitespace: continue
            }
            lm.addTemporaryAttribute(.foregroundColor, value: color,
                                     forCharacterRange: NSRange(location: t.range.lowerBound, length: t.range.count))
        }
    }

    /// Lights up the code just sent, briefly, as the SuperCollider IDE does.
    func flash(_ range: NSRange) {
        guard let lm = layoutManager else { return }
        lm.addTemporaryAttribute(.backgroundColor, value: Theme.accent.withAlphaComponent(0.35), forCharacterRange: range)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            self?.showMatchingBracket()
        }
    }

    private var bracketMarks: [NSRange] = []

    /// Outlines the bracket matching the one beside the caret.
    func showMatchingBracket() {
        guard let lm = layoutManager else { return }
        for r in bracketMarks where NSMaxRange(r) <= (string as NSString).length {
            lm.removeTemporaryAttribute(.backgroundColor, forCharacterRange: r)
        }
        bracketMarks = []
        let sel = selectedRange()
        guard sel.length == 0 else { return }
        let ns = string as NSString
        for offset in [sel.location - 1, sel.location] where offset >= 0 && offset < ns.length {
            let c = ns.character(at: offset)
            guard "()[]{}".utf16.contains(c), let match = SCRegion.matchingBracket(in: string, at: offset) else { continue }
            bracketMarks = [NSRange(location: offset, length: 1), NSRange(location: match, length: 1)]
            for r in bracketMarks {
                lm.addTemporaryAttribute(.backgroundColor, value: NSColor(white: 1, alpha: 0.14), forCharacterRange: r)
            }
            return
        }
    }

    // MARK: Keys

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if popup.isVisible {
            switch event.specialKey {
            case .upArrow?: popup.move(-1); return
            case .downArrow?: popup.move(1); return
            case .pageUp?: popup.move(-8); return
            case .pageDown?: popup.move(8); return
            case .carriageReturn?, .enter?, .tab?:
                if flags.isEmpty, let item = popup.selected { accept(item); return }
            default:
                if event.keyCode == 53 { hideCompletion(); return }
            }
        }
        if event.keyCode == 36 || event.keyCode == 76 { // return
            if flags == .shift { evaluate(line: true); return }
            if flags == .command { evaluate(line: false); return }
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.keyCode == 36 || event.keyCode == 76 { evaluate(line: false); return true }
        if flags == .command, event.charactersIgnoringModifiers == "d" { lookUpHelp(); return true }
        return super.performKeyEquivalent(with: event)
    }

    /// ⌘↩ sends the selection or the block around the caret; ⇧↩ the line.
    func evaluate(line: Bool) {
        hideCompletion()
        let sel = selectedRange()
        let r: Range<Int> = line && sel.length == 0
            ? SCRegion.line(in: string, caret: sel.location)
            : SCRegion.evaluationRange(in: string, selection: sel.location..<NSMaxRange(sel))
        let range = NSRange(location: r.lowerBound, length: r.count)
        let code = (string as NSString).substring(with: range)
        guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        flash(range)
        onEvaluate?(code, range)
    }

    func lookUpHelp() {
        hideCompletion()
        let sel = selectedRange()
        guard let topic = SCCompletion.helpTopic(string, caret: sel.location + (sel.length > 0 ? 1 : 0), library: library()) else {
            NSSound.beep()
            return
        }
        onHelp?(topic)
    }

    /// Return keeps the line's indent, and one more after an open bracket.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange().location
        let line = ns.lineRange(for: NSRange(location: caret, length: 0))
        let head = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
        var indent = String(head.prefix { $0 == " " || $0 == "\t" })
        let unit = indent.hasPrefix(" ") ? "    " : "\t"
        if let last = head.trimmingCharacters(in: .whitespaces).last, "([{".contains(last) { indent += unit }
        super.insertNewline(sender)
        insertText(indent, replacementRange: selectedRange())
    }

    /// A closing bracket typed on an empty line steps back one indent.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let s = string as? String, s.count == 1, ")]}".contains(s), replacementRange.location == NSNotFound {
            let ns = self.string as NSString
            let caret = selectedRange().location
            let line = ns.lineRange(for: NSRange(location: caret, length: 0))
            let head = ns.substring(with: NSRange(location: line.location, length: caret - line.location))
            if !head.isEmpty, head.allSatisfy({ $0 == " " || $0 == "\t" }) {
                let drop = head.hasSuffix("\t") ? 1 : min(4, head.count)
                super.insertText(s, replacementRange: NSRange(location: caret - drop, length: drop))
                return
            }
        }
        super.insertText(string, replacementRange: replacementRange)
    }

    // MARK: Completion

    /// ⎋ (and F5) ask for completion explicitly.
    override func complete(_ sender: Any?) {
        updateCompletion(explicit: true)
    }

    /// Called after every user edit.
    func textChanged(typed: String?) {
        recolor()
        if let typed, let c = typed.unicodeScalars.last,
           CharacterSet.alphanumerics.contains(c) || c == "." || c == "~" || c == "_" {
            updateCompletion(explicit: false)
        } else {
            hideCompletion()
        }
        updateSignature()
    }

    func selectionChanged() {
        showMatchingBracket()
        updateSignature()
        // Typing moves the caret one past the old prefix (and then
        // recomputes); anything else means the caret left the word.
        if popup.isVisible, let c = completion {
            let sel = selectedRange()
            if sel.length > 0 || sel.location < c.replacing.lowerBound || sel.location > c.replacing.upperBound + 1 {
                hideCompletion()
            }
        }
    }

    private func updateSignature() {
        let caret = selectedRange().location
        onSignature?(SCCompletion.signature(string, caret: caret, library: library())?.display)
    }

    private func updateCompletion(explicit: Bool) {
        let lib = library()
        guard let result = SCCompletion.complete(string, caret: selectedRange().location, library: lib, explicit: explicit),
              !result.items.isEmpty else {
            hideCompletion()
            if explicit { NSSound.beep() }
            return
        }
        completion = result
        let anchor = NSRange(location: result.replacing.lowerBound, length: 0)
        var actual = NSRange()
        let rect = firstRect(forCharacterRange: anchor, actualRange: &actual)
        popup.show(result.items, below: rect, parent: window)
    }

    func hideCompletion() {
        completion = nil
        popup.hide()
    }

    private func accept(_ item: SCCompletion.Item) {
        guard let c = completion else { return }
        hideCompletion()
        let range = NSRange(location: c.replacing.lowerBound, length: c.replacing.count)
        guard shouldChangeText(in: range, replacementString: item.label) else { return }
        super.insertText(item.label, replacementRange: range)
        updateSignature()
    }

    override func resignFirstResponder() -> Bool {
        hideCompletion()
        return super.resignFirstResponder()
    }
}

/// The list of completions under the caret: a borderless child window, so
/// the text view keeps the keyboard while ↑↓ ↩ ⇥ ⎋ steer the list.
@MainActor
final class SCCompletionPopup: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    var onAccept: ((SCCompletion.Item) -> Void)?
    private var items: [SCCompletion.Item] = []
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private lazy var panel: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 200),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isFloatingPanel = true
        p.hasShadow = true
        p.backgroundColor = Theme.chrome
        p.appearance = NSAppearance(named: .darkAqua)
        let column = NSTableColumn(identifier: .init("item"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 20
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = Theme.chrome
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(doubleClicked)
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.cornerRadius = 6
        scroll.layer?.borderWidth = 1
        scroll.layer?.borderColor = Theme.separator.cgColor
        p.contentView = scroll
        return p
    }()

    var isVisible: Bool { panel.isVisible }
    var selected: SCCompletion.Item? { items.indices.contains(table.selectedRow) ? items[table.selectedRow] : nil }

    func show(_ items: [SCCompletion.Item], below rect: NSRect, parent: NSWindow?) {
        self.items = items
        _ = panel
        table.reloadData()
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        table.scrollRowToVisible(0)
        let height = CGFloat(min(items.count, 9)) * table.rowHeight + 2
        let frame = NSRect(x: rect.minX - 6, y: rect.minY - height - 2, width: 460, height: height)
        panel.setFrame(frame, display: true)
        if panel.parent == nil, let parent { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    func move(_ step: Int) {
        guard !items.isEmpty else { return }
        let row = min(max(table.selectedRow + step, 0), items.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    @objc private func doubleClicked() { if let s = selected { onAccept?(s) } }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let field = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField) ?? {
            let f = NSTextField(labelWithString: "")
            f.identifier = id
            f.lineBreakMode = .byTruncatingTail
            return f
        }()
        let item = items[row]
        let s = NSMutableAttributedString(string: " " + item.label, attributes: [
            .font: Theme.monoFont, .foregroundColor: Self.color(item.kind),
        ])
        if !item.detail.isEmpty {
            s.append(NSAttributedString(string: "  " + item.detail, attributes: [
                .font: Theme.secondaryFont, .foregroundColor: Theme.secondaryText,
            ]))
        }
        field.attributedStringValue = s
        return field
    }

    static func color(_ kind: SCCompletion.Kind) -> NSColor {
        switch kind {
        case .className: return Theme.syntaxCommand
        case .method: return Theme.text
        case .variable: return Theme.text
        case .keyword: return Theme.syntaxScheme
        case .environment: return Theme.warning
        }
    }
}
