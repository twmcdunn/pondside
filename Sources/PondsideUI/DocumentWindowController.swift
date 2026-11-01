import AppKit
import UniformTypeIdentifiers
import AVFoundation
import PondsideCore
import PondsideEngrave
import PondsideTiming
import PondsideBridge
import PondsideLexicon

/// One window: source and score side by side, a one-line status bar, and
/// bidirectional point-and-click between them. The score is an editor too:
/// keyboard note input turns into minimal text edits on the same undo stack.
@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let score: ScoreDocument
    private let editor = SourceEditorView(frame: .zero)
    private let canvas = ScoreCanvasView(frame: .zero)
    private let canvasScroll = NSScrollView()
    private let firstEngraving = EngravingPlaceholderView()
    private var settingsPanel: EngravingSettingsPanel?
    var scoreSetupPanel: ScoreSetupPanel?
    private var player: AVAudioPlayer?
    private let editorPane = NSView()
    private let compilerOutput = CompilerOutputView(frame: .zero)
    private let cueInspector = CueInspectorView(frame: .zero)
    private lazy var lexiconBrowser: LexiconBrowserPane = {
        let pane = LexiconBrowserPane(frame: .zero)
        pane.model.project = score.url.deletingLastPathComponent()
        pane.model.onInsert = { [weak self] entry in self?.insertGraphic(entry) }
        return pane
    }()
    private var panes: PaneHost!
    private lazy var agentLogView = AgentLogView()
    /// The SuperCollider pane, once something has shown it.
    private var scPane: SuperColliderPane?
    private var help: HelpOverlay!
    private var chord = ChordRecognizer()
    /// The unattended agent finishing a patch migration, while it runs.
    private var agentHandle: AgentRun.Handle?
    private var agentNote: String?
    private var agentProgress: AgentProgress?
    private let requestPopover = AgentRequestPopover()
    /// The agent conversation for requests from the lens, kept between them.
    private var requestSession: AgentSession?
    private var requestRunning = false
    private var requestIdle: Task<Void, Never>?
    /// The patch agent's conversation (DESIGN.md §8): its own process and
    /// tools, so the score's agent stays lean. Its memory is the patch doc,
    /// so losing this conversation loses little.
    private var patchSession: AgentSession?
    private var patchIdle: Task<Void, Never>?
    /// Whether a legend page filled the view at the last scroll.
    private var legendWasInView = false
    /// After a request changed the score, the work badge and the pulsing dot
    /// stay until an engraving that started after the agent's last write has
    /// finished, so the user sees the change land, not the old pages.
    private var agentRender: (written: Date, done: () -> Void)?
    private var agentRenderTimeout: Task<Void, Never>?
    /// The score's files as they were before the agent's last request, and
    /// the files it actually changed, as it left them.
    private var agentUndo: [URL: String]?
    private var agentAfter: [URL: String] = [:]
    /// The files the agent changed, so their external reloads don't add
    /// their own undo step (the whole request is one ⌘Z).
    private var agentChanged: Set<URL> = []
    private var agentWritesInFlight: Set<URL> = []
    /// The single undo action that puts the agent's change back; it follows
    /// the active file so ⌘Z works from whichever file is showing.
    private final class AgentUndoCookie: @unchecked Sendable {
        weak var controller: DocumentWindowController?
        init(_ controller: DocumentWindowController) { self.controller = controller }
    }
    private var agentUndoCookie: AgentUndoCookie?
    private weak var agentUndoManager: UndoManager?
    private var keyMonitor: Any?
    private let statusBar = StatusBarView(frame: .zero)

    private var noteInput = NoteInput()
    private var lens: (any NotationLensSession)?
    private var lensClosesOnRender = false
    private var lensAwaitingGeneration = 0
    private var lensWasExplicit = false
    /// The last selection the page could show, canvas coordinates: a note
    /// typed since the engraving has no glyphs yet, so the lens keeps
    /// pointing at the one it follows.
    private var lastPageAnchor: NSRect?
    /// A lens that closes by itself stays at least this long after it last
    /// changed, so it never flickers past; ⎋ still closes it at once.
    private static let lensMinimumOpen: TimeInterval = 1.5
    private var lensChangedAt = Date.distantPast
    private var lensCloseTask: Task<Void, Never>?
    private var applyingScoreEdit = false
    /// Set while the score drives the editor, so the editor's selection
    /// callback does not scroll the score the user is looking at.
    private var scoreIsDriving = false
    private var pendingConflict: (file: SourceFile, disk: String)?
    /// The file shown in the source pane; score edits apply to it.
    private(set) var activeFile: SourceFile
    private let fileMenu = NSPopUpButton(frame: .zero, pullsDown: false)

    var lightsOut: Bool {
        get { canvas.lightsOut }
        set { canvas.lightsOut = newValue }
    }

    init(document: ScoreDocument) {
        self.score = document
        // Start where the music is: the root, unless it only includes parts.
        self.activeFile = document.root.hasNotes ? document.root : (document.files.first { $0.hasNotes } ?? document.root)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Theme.background
        window.title = document.url.lastPathComponent
        window.representedURL = document.url
        window.minSize = NSSize(width: 640, height: 400)
        _ = window.setFrameAutosaveName("Pondside.\(document.url.path)")
        super.init(window: window)
        window.delegate = self
        buildLayout()
        wire()
        installKeyMonitor()
        showFile(activeFile)
        score.delegate = self
        score.open()
        updateStatus()
        DispatchQueue.main.async { [weak self] in self?.offerToRestoreConvertedSettings() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.offerPatchMigration() }
        _ = Self.agent(UserDefaults.standard.string(forKey: Self.agentKey))   // found in the background, for the lens
        if !window.setFrameUsingName(window.frameAutosaveName) { window.center() }
        NotificationCenter.default.addObserver(self, selector: #selector(appWillTerminate(_:)),
                                               name: NSApplication.willTerminateNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoHistoryChanged(_:)),
                                               name: .NSUndoManagerDidUndoChange, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(undoHistoryChanged(_:)),
                                               name: .NSUndoManagerDidRedoChange, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Layout

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        canvasScroll.documentView = canvas
        canvasScroll.hasVerticalScroller = true
        canvasScroll.hasHorizontalScroller = true
        canvasScroll.autohidesScrollers = true
        canvasScroll.drawsBackground = true
        canvasScroll.backgroundColor = Theme.background
        canvasScroll.allowsMagnification = false
        canvasScroll.contentView.postsBoundsChangedNotifications = true
        // Scrolling a legend page into view offers ␣ f a in the hints.
        NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: canvasScroll.contentView,
                                               queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = self.canvas.legendInView
                if now != self.legendWasInView { self.legendWasInView = now; self.updateHints() }
            }
        }
        // The empty pane's "engraving" animation floats over the clip view.
        canvasScroll.addSubview(firstEngraving)

        // The source pane: a one-line file bar over the editor.
        let fileBar = NSView()
        fileBar.wantsLayer = true
        fileBar.layer?.backgroundColor = Theme.chrome.cgColor
        fileMenu.translatesAutoresizingMaskIntoConstraints = false
        fileMenu.isBordered = false
        fileMenu.font = Theme.secondaryFont
        fileMenu.target = self
        fileMenu.action = #selector(fileMenuChanged(_:))
        fileMenu.toolTip = "The file shown in the source pane — ⌘⇧] next, ⌘⇧[ previous. Clicking a note in the score opens its file."
        for v in [fileBar, editor] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            editorPane.addSubview(v)
        }
        fileBar.addSubview(fileMenu)
        NSLayoutConstraint.activate([
            fileBar.topAnchor.constraint(equalTo: editorPane.topAnchor),
            fileBar.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            fileBar.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            fileBar.heightAnchor.constraint(equalToConstant: 28),
            fileMenu.leadingAnchor.constraint(equalTo: fileBar.leadingAnchor, constant: 10),
            fileMenu.centerYAnchor.constraint(equalTo: fileBar.centerYAnchor),
            fileMenu.trailingAnchor.constraint(lessThanOrEqualTo: fileBar.trailingAnchor, constant: -10),
            editor.topAnchor.constraint(equalTo: fileBar.bottomAnchor),
            editor.leadingAnchor.constraint(equalTo: editorPane.leadingAnchor),
            editor.trailingAnchor.constraint(equalTo: editorPane.trailingAnchor),
            editor.bottomAnchor.constraint(equalTo: editorPane.bottomAnchor),
        ])

        // The overlay first: panes built now register their controls with it.
        help = HelpOverlay(window: window!)
        // Panes are frames, content is cargo (DESIGN.md, M3).
        panes = PaneHost(layout: Self.savedLayout()) { [unowned self] content in self.makeContent(content) }
        let split = panes.split
        split.translatesAutoresizingMaskIntoConstraints = false
        help.register(fileMenu, "go.file")
        help.register(statusBar, "help.context")

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        statusBar.onStopAgent = { [weak self] in self?.stopAgent() }
        content.addSubview(split)
        content.addSubview(statusBar)

        // Content starts below the transparent title bar, so neither code
        // nor music ever sits under the traffic lights.
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            split.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor),
            split.bottomAnchor.constraint(equalTo: statusBar.topAnchor),
            statusBar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            statusBar.heightAnchor.constraint(equalToConstant: 26),
        ])
        content.layoutSubtreeIfNeeded()
        panes.applyFractions()
    }

    private func wire() {
        canvas.delegate = self
        canvas.onZoomChange = { [weak self] _ in self?.updateStatus() }
        canvas.legendValues = { [weak self] in
            let fm = FrontMatter(self?.frontMatterFile?.text ?? "")
            return (fm.legendLayout ?? .init(), fm.legendItems.map(\.example))
        }
        canvas.onLegendStatus = { [weak self] in self?.statusBar.flash($0) }
        canvas.onLegendCommit = { [weak self] in self?.commitLegend($0) }
        // Show where keys go: a focus ring on the score (the one place glow
        // is allowed) and a word in the status line.
        canvasScroll.wantsLayer = true
        canvas.onFocusChange = { [weak self] focused in
            guard let self else { return }
            self.canvasScroll.layer?.borderWidth = focused ? 2 : 0
            self.canvasScroll.layer?.borderColor = Theme.accent.withAlphaComponent(0.7).cgColor
            self.statusBar.setKeyTarget(focused ? "score" : "source")
            self.updateHints()
        }
        editor.onUserEdit = { [weak self] text in
            guard let self else { return }
            self.score.userEdited(self.activeFile, text: text)
            AppRPC.shared.publish("score.changed", ["path": .string(self.activeFile.url.path), "by": "app"])
            self.rebuildEngravingMap()
            if !self.applyingScoreEdit {
                self.closeLens()
            }
        }
        editor.onSelectionChange = { [weak self] range in
            self?.editorSelectionChanged(range)
        }
    }

    // MARK: Selection model
    //
    // The text selection is the single source of truth. Selecting in the
    // score selects the characters of the chosen events; score operations
    // act on whatever events the text selection covers. Highlights are
    // derived from it, through the engraving map while the canvas still
    // shows the previous engraving.

    private var tree: SyntaxTree { activeFile.tree }

    // MARK: Files

    /// Shows `file` in the source pane. Selection, highlight and score
    /// edits all follow the visible file.
    private func showFile(_ file: SourceFile) {
        closeLens()
        lastPageAnchor = nil
        activeFile = file
        editor.show(file.url, text: file.text, undoManager: file.undoManager)
        moveAgentUndo(to: file.undoManager)
        rebuildFileMenu()
        rebuildEngravingMap()
        showDiagnostics()
        refreshHighlight(reveal: false)
        updateStatus()
    }

    private func rebuildFileMenu() {
        fileMenu.removeAllItems()
        for (i, f) in score.files.enumerated() {
            var title = f.displayName
            if i == 0 { title += "  (root)" }
            if !f.hasNotes { title += "  — no notes" }
            fileMenu.addItem(withTitle: title)
            fileMenu.lastItem?.representedObject = f.url
        }
        if let i = score.files.firstIndex(where: { $0 === activeFile }) { fileMenu.selectItem(at: i) }
    }

    @objc private func fileMenuChanged(_ sender: NSPopUpButton) {
        let i = sender.indexOfSelectedItem
        guard score.files.indices.contains(i) else { return }
        showFile(score.files[i])
    }

    @objc func nextFile(_ sender: Any?) { stepFile(1) }
    @objc func previousFile(_ sender: Any?) { stepFile(-1) }

    private func stepFile(_ step: Int) {
        let files = score.files
        guard let i = files.firstIndex(where: { $0 === activeFile }), files.count > 1 else { return }
        showFile(files[(i + step + files.count) % files.count])
        statusBar.flash("Editing \(activeFile.displayName)")
    }

    /// The selection as UTF-8 offsets into the current text.
    private func selectionUTF8() -> Range<Int> {
        let r = editor.textView.selectedRange()
        let text = editor.text
        let a = OffsetConversion.utf8(fromUTF16: r.location, in: text)
        let b = OffsetConversion.utf8(fromUTF16: r.location + r.length, in: text)
        return a..<max(a, b)
    }

    // MARK: Notation Lens

    /// `navigating`: ←→ in the lens moved the selection. The lens keeps its
    /// kind: an explicit one stays until ⎋, any other closes once the
    /// stepping stops (and any render it waits for has landed).
    private func showLens(closesOnRender: Bool, navigating: Bool = false) {
        let selection = selectionUTF8()
        guard let content = LensScoreBuilder.build(tree: tree, selection: selection) else {
            lensLog.debug("no lens for selection \(selection.lowerBound)..<\(selection.upperBound)")
            if closesOnRender {
                if !lensWasExplicit { closeLens() }
            } else if let r = ScoreGraphic.commandRange(at: selectionUTF8().lowerBound, in: editor.text),
                      String(decoding: Array(editor.text.utf8)[r], as: UTF8.self).hasPrefix("\\start") {
                // a graphic (its start command is the selection): its lens is the request line
                showRequest(fromLens: false)
            } else {
                statusBar.flash("Put the caret in a note or a graphic to open the Notation Lens")
            }
            return
        }
        if lens == nil {
            guard #available(macOS 15, *) else {
                lensLog.debug("needs macOS 15")
                if !closesOnRender { statusBar.flash("Notation Lens needs macOS 15") }
                return
            }
            let session = NotationLensController()
            session.onFailure = { [weak self] message in
                self?.statusBar.flash(message)
            }
            session.onClose = { [weak self] in
                self?.lensCloseTask?.cancel()
                self?.lensClosesOnRender = false
                self?.lensWasExplicit = false
            }
            lens = session
        }
        guard let lens else { return }
        let wasExplicit = lensWasExplicit && !lensClosesOnRender
        let explicit = navigating ? wasExplicit : (!closesOnRender || wasExplicit)
        let shown = lens.present(lens: content, fileLabel: activeFile.displayName, anchor: lensAnchor(), explicit: explicit)
        lensLog.debug("present \(shown ? "shown" : "failed"), bars \(content.bars.lowerBound)-\(content.bars.upperBound), edit: \(closesOnRender)")
        guard shown else {
            if !closesOnRender { statusBar.flash("Notation Lens is unavailable for this passage") }
            return
        }
        lensChangedAt = Date()
        if navigating {
            guard !wasExplicit else { return }
            // Nothing to wait for unless an edit's render is still due.
            if !lensClosesOnRender { lensAwaitingGeneration = score.completedRenderGeneration }
            lensWasExplicit = false
            lensClosesOnRender = true
            scheduleLensClose(after: Self.lensMinimumOpen)
            return
        }
        // An explicit lens stays until ⎋, even across edits made in it.
        if closesOnRender, !lensClosesOnRender, lensWasExplicit { return }
        lensWasExplicit = !closesOnRender
        lensClosesOnRender = closesOnRender
        lensAwaitingGeneration = score.renderGeneration + 1
        if closesOnRender { scheduleLensClose(after: Self.lensMinimumOpen) }
    }

    /// Where the lens points: the selection's staff when the page shows it,
    /// else the note it follows; nil keeps an open lens where it is. A
    /// first opening with neither points at the top of the score pane.
    private func lensAnchor() -> LensAnchor? {
        let visible = canvas.visibleRect
        if let rect = canvas.selectionAnchor ?? lastPageAnchor, visible.intersects(rect) {
            return LensAnchor(rect: rect, view: canvas)
        }
        if lens?.isOpen == true { return nil }
        if !visible.isEmpty {
            return LensAnchor(rect: NSRect(x: visible.midX, y: visible.minY, width: 1, height: 1), view: canvas)
        }
        guard let content = window?.contentView else { return nil }
        return LensAnchor(rect: NSRect(x: content.bounds.midX, y: content.bounds.maxY - 40, width: 1, height: 1), view: content)
    }

    /// ←→ while the lens is open: the next or previous event of the lens's
    /// voice, the lens following.
    private func stepLens(_ step: Int) {
        guard let content = LensScoreBuilder.build(tree: tree, selection: selectionUTF8()),
              let next = content.neighbor(step) else {
            NSSound.beep()
            return
        }
        setSelection(utf8: tree.events[next].range)
        showLens(closesOnRender: false, navigating: true)
    }

    private func closeLens(animated: Bool = false, _ why: StaticString = #function) {
        if lens?.isOpen == true { lensLog.debug("close (\(why)), animated: \(animated)") }
        lensCloseTask?.cancel()
        lensCloseTask = nil
        lens?.dismiss(animated: animated)
        lensClosesOnRender = false
    }

    /// An edit's lens has done its job once a render newer than the edit
    /// lands and it has been up for the minimum time; it fades out over the
    /// page's cross-fade.
    private func closeLensIfRendered() {
        guard lensClosesOnRender, lens?.isOpen == true,
              score.completedRenderGeneration >= lensAwaitingGeneration else { return }
        let remaining = Self.lensMinimumOpen - Date().timeIntervalSince(lensChangedAt)
        guard remaining <= 0 else {
            scheduleLensClose(after: remaining)
            return
        }
        closeLens(animated: true)
    }

    private func scheduleLensClose(after delay: TimeInterval) {
        lensCloseTask?.cancel()
        lensCloseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.closeLensIfRendered()
        }
    }

    /// What score operations act on: whole events, or a single chord
    /// member when the selection lies inside one.
    private func targets() -> (events: [Int], notes: [Int]) {
        let r = selectionUTF8()
        if !r.isEmpty, let n = tree.notes.firstIndex(where: { $0.role == .event && $0.spelledRange.lowerBound <= r.lowerBound && r.upperBound <= $0.spelledRange.upperBound }),
           let e = tree.notes[n].event, tree.events[e].kind == .chord {
            return ([], [n])
        }
        if r.isEmpty {
            if let e = tree.eventIndex(at: r.lowerBound), tree.events[e].range.upperBound > r.lowerBound || tree.events[e].range.isEmpty {
                return ([e], [])
            }
            return ([], [])
        }
        return (tree.eventIndices(overlapping: r), [])
    }

    private func setSelection(utf8 range: Range<Int>, scroll: Bool = true) {
        let text = editor.text
        let a = OffsetConversion.utf16(fromUTF8: range.lowerBound, in: text)
        let b = OffsetConversion.utf16(fromUTF8: range.upperBound, in: text)
        scoreIsDriving = true
        editor.select(NSRange(location: a, length: b - a), scroll: scroll)
        scoreIsDriving = false
        refreshHighlight(reveal: true)
    }

    private func selectEvents(_ indices: [Int]) {
        guard let first = indices.min(), let last = indices.max() else { return }
        setSelection(utf8: tree.events[first].range.lowerBound..<tree.events[last].range.upperBound)
    }

    private var engraving: EngravingMap?
    /// Linked positions of the current pages with their UTF-16 offsets in
    /// the engraved text, sorted by offset.
    private var linkOffsets: [(offset: Int, position: SourcePosition)] = []

    /// Source colouring from the parsed tree: one pass over the leaves, with a
    /// UTF-8 → UTF-16 table so it stays linear on large files.
    private func highlightSyntax() {
        let text = editor.text
        var utf16At = [Int](repeating: 0, count: text.utf8.count + 1)
        var u8 = 0, u16 = 0
        for scalar in text.unicodeScalars {
            let n8 = String(scalar).utf8.count, n16 = scalar.utf16.count
            for k in 0..<n8 { utf16At[u8 + k] = u16 }
            u8 += n8
            u16 += n16
        }
        if u8 < utf16At.count { utf16At[u8] = u16 }
        var runs: [(NSRange, NSColor)] = []
        tree.root.forEachLeaf { leaf in
            let color: NSColor?
            switch leaf.kind {
            case .lineComment, .blockComment: color = Theme.syntaxComment
            case .command, .escapedPunct: color = Theme.syntaxCommand
            case .string: color = Theme.syntaxString
            case .number, .dot: color = Theme.syntaxNumber
            case .hash, .schemeText, .embeddedOpen, .embeddedClose: color = Theme.syntaxScheme
            case .openBrace, .closeBrace, .openSimultaneous, .closeSimultaneous, .barCheck: color = Theme.syntaxPunctuation
            default: color = nil
            }
            guard let color, leaf.range.upperBound < utf16At.count else { return }
            let a = utf16At[leaf.range.lowerBound], b = utf16At[leaf.range.upperBound]
            runs.append((NSRange(location: a, length: b - a), color))
        }
        editor.showSyntax(runs)
    }

    private func rebuildEngravingMap() {
        highlightSyntax()
        guard let engraved = activeFile.engravedText else {
            engraving = nil
            linkOffsets = []
            return
        }
        let map = EngravingMap(engraved: engraved, current: editor.text)
        engraving = map
        linkOffsets = activeFile.linkedPositions
            .compactMap { p -> (offset: Int, position: SourcePosition)? in
                map.engravedOffset(of: p).map { (offset: $0, position: p) }
            }
            .sorted { $0.offset < $1.offset }
    }

    private func refreshHighlight(reveal: Bool) {
        guard let map = engraving else { return }
        let text = editor.text
        var r = selectionUTF8()
        if r.isEmpty {
            // A caret inside an event highlights that event.
            if let e = tree.eventIndex(at: r.lowerBound), tree.events[e].range.upperBound > r.lowerBound {
                r = tree.events[e].range
            }
        }
        var positions = Set<SourcePosition>()
        if !r.isEmpty {
            let a = map.engravedOffset(forCurrent: OffsetConversion.utf16(fromUTF8: r.lowerBound, in: text))
            let b = map.engravedOffset(forCurrent: OffsetConversion.utf16(fromUTF8: r.upperBound, in: text))
            for l in linkOffsets where l.offset >= a && l.offset < max(b, a + 1) { positions.insert(l.position) }
        }
        hasSelection = !positions.isEmpty
        highlighted = positions
        canvas.highlight(positions, path: activeFile.url.path, reveal: reveal)
        if let anchor = canvas.selectionAnchor { lastPageAnchor = anchor }
        updateHints()
    }

    private var hasSelection = false
    /// The engraved positions currently highlighted (the selection's glyphs).
    private var highlighted = Set<SourcePosition>()

    /// The current-text UTF-8 offset of a point-and-click link.
    private func currentOffset(of link: PointAndClickLocation) -> Int? {
        guard let map = engraving, let engraved = map.engravedOffset(of: link.position) else { return nil }
        let current16 = map.currentOffset(forEngraved: engraved)
        return OffsetConversion.utf8(fromUTF16: current16, in: editor.text)
    }

    private func editorSelectionChanged(_ range: NSRange) {
        AppRPC.shared.publish("selection.changed", rpcSelection)
        guard !scoreIsDriving else { return }
        refreshHighlight(reveal: true)
    }

    // MARK: Applying score edits

    /// Applies a score edit as one undoable change, then selects its result.
    private func apply(_ edit: ScoreEdit?) {
        guard let edit, !edit.isEmpty else { NSSound.beep(); return }
        let old = editor.text
        let oldBytes = Array(old.utf8)
        let newBytes = edit.edits.apply(to: oldBytes)
        // One replacement spanning the edits: the file result is identical,
        // and the text view gets a single undo step.
        let lo = edit.edits.map(\.range.lowerBound).min()!
        let hi = edit.edits.map(\.range.upperBound).max()!
        let newHi = hi + newBytes.count - oldBytes.count
        let replacement = String(decoding: newBytes[lo..<newHi], as: UTF8.self)
        let a = OffsetConversion.utf16(fromUTF8: lo, in: old)
        let b = OffsetConversion.utf16(fromUTF8: hi, in: old)
        applyingScoreEdit = true
        editor.replace(NSRange(location: a, length: b - a), with: replacement, actionName: edit.name)
        applyingScoreEdit = false

        // The document re-parsed synchronously; select what the edit produced.
        let new = tree
        let selected = edit.selectionAnchors.compactMap { anchor in
            new.events.firstIndex { $0.range.lowerBound == anchor } ?? new.eventIndex(at: anchor)
        }
        if selected.isEmpty {
            setSelection(utf8: lo..<lo, scroll: false)
        } else {
            selectEvents(selected)
        }
        showLens(closesOnRender: true)
    }

    // MARK: Keyboard note input

    private func keyInput(for event: NSEvent) -> KeyInput? {
        let flags = event.modifierFlags
        let shift = flags.contains(.shift), option = flags.contains(.option)
        let command = flags.contains(.command), control = flags.contains(.control)
        func k(_ key: KeyInput.Key) -> KeyInput {
            KeyInput(key, shift: shift, option: option, command: command, control: control)
        }
        switch event.specialKey {
        case .upArrow?: return k(.up)
        case .downArrow?: return k(.down)
        case .leftArrow?: return k(.left)
        case .rightArrow?: return k(.right)
        case .delete?, .deleteForward?, .backspace?: return k(.delete)
        case .carriageReturn?, .enter?, .newline?: return k(.enter)
        default: break
        }
        if event.keyCode == 53 { return k(.escape) }
        // Use the typed character (layout-aware), keeping shift for symbols.
        guard let c = event.characters?.first else { return nil }
        return KeyInput(.character(c), shift: false, option: false, command: command, control: control)
    }

    private func handleScoreKey(_ event: NSEvent) -> Bool {
        guard let input = keyInput(for: event) else { return false }
        let actions = noteInput.handle(input, now: event.timestamp)
        if actions.isEmpty { return false }
        for action in actions { perform(action) }
        return true
    }

    private func perform(_ action: InputAction) {
        let scoreEditor = ScoreEditor(tree)
        let (events, notes) = targets()
        switch action {
        case .move(let move):
            let moved = events.allSatisfy { isEngraved($0) } ? highlighted : []
            let edit = scoreEditor.move(events: events, extraNotes: notes, by: move)
            apply(edit)
            // Instant feedback: a ghost at the new staff position until
            // LilyPond's engraving lands (M4, provisional rendering).
            if edit != nil {
                switch move {
                case .step(let n): canvas.provisionalShift(moved, path: activeFile.url.path, halfSpaces: n)
                case .octave(let n): canvas.provisionalShift(moved, path: activeFile.url.path, halfSpaces: 7 * n)
                case .chromatic: break
                }
            }
        case .setDuration(let d):
            if !events.isEmpty { applyShowingDuration(scoreEditor.setDuration(events: events, to: d)) }
            updateInputStatus()
        case .toggleDot:
            if !events.isEmpty { applyShowingDuration(scoreEditor.toggleDot(events: events)) }
            updateInputStatus()
        case .insertNote(let step):
            insert(step: step)
        case .insertRest:
            insert(step: nil)
        case .delete:
            let gone = events.allSatisfy { isEngraved($0) } ? highlighted : []
            let edit = scoreEditor.delete(events: events)
            apply(edit)
            if edit != nil {
                canvas.provisionalDelete(gone, path: activeFile.url.path)
                refreshHighlight(reveal: false)
            }
        case .togglePostEvent(let text):
            let eligible = events.filter { tree.events[$0].acceptsNoteEntry }
            apply(scoreEditor.togglePostEvent(text, events: eligible))
        case .select(let step, let extend):
            moveSelection(by: step, extend: extend)
        case .clearSelection:
            // ⎋ with nothing selected disarms (ends mouse entry).
            if !hasSelection, noteInput.armedDuration != nil {
                noteInput.arm(nil)
                updateInputStatus()
                return
            }
            let r = selectionUTF8()
            let end = tree.eventIndex(at: r.upperBound).map { tree.events[$0].range.upperBound } ?? r.upperBound
            setSelection(utf8: end..<end, scroll: false)
        case .editSource:
            window?.makeFirstResponder(editor.textView)
        case .buffer:
            updateInputStatus()
        }
    }

    private func insert(step: Int?) {
        let r = selectionUTF8()
        // After the selected event, or after the event just before the caret.
        let anchor = targets().events.max()
            ?? tree.events.lastIndex { $0.range.upperBound <= r.lowerBound && $0.acceptsNoteEntry }
        guard let anchor, tree.events[anchor].acceptsNoteEntry else {
            statusBar.flash("Select a note to insert after (or type it in the source)")
            NSSound.beep()
            return
        }
        // Only an anchor the canvas already shows can place the ghost; a note
        // inserted since the last engraving chains from the previous ghost.
        let engraved = isEngraved(anchor)
        let anchorPositions = engraved ? highlighted : []
        let anchorDiatonic = engraved ? tree.events[anchor].notes.first.map { tree.notes[$0].absolute.diatonicIndex } : nil
        let edit = ScoreEditor(tree).insert(step: step, after: anchor, duration: noteInput.armedDuration)
        apply(edit)
        guard edit != nil else { return }
        // Instant feedback while LilyPond engraves: a ghost of the new note.
        if step != nil, let e = targets().events.first, let n = tree.events[e].notes.first {
            canvas.provisionalInsert(after: anchorPositions, path: activeFile.url.path,
                                     anchorDiatonic: anchorDiatonic, diatonic: tree.notes[n].absolute.diatonicIndex)
        }
    }

    /// Whether the event already existed at the last engraving (its start
    /// maps exactly), so the glyphs at its position on the canvas are its
    /// own. A note inserted since starts inside the changed span: it isn't.
    private func isEngraved(_ event: Int) -> Bool {
        guard let map = engraving else { return false }
        let start = OffsetConversion.utf16(fromUTF8: tree.events[event].range.lowerBound, in: editor.text)
        return map.currentOffset(forEngraved: map.engravedOffset(forCurrent: start)) == start
    }

    /// Applies a duration change and badges the notes with their new value
    /// until the engraving shows it.
    private func applyShowingDuration(_ edit: ScoreEdit?) {
        let changed = targets().events.allSatisfy { isEngraved($0) } ? highlighted : []
        apply(edit)
        guard edit != nil, let e = targets().events.first else { return }
        canvas.provisionalBadge(changed, path: activeFile.url.path, text: tree.events[e].effectiveDuration.text)
    }

    private func moveSelection(by step: Int, extend: Bool) {
        let all = tree.events.indices.filter { tree.events[$0].kind != .lyric }
        guard !all.isEmpty else { return }
        let current = targets().events
        let r = selectionUTF8()
        let events = tree.events
        let next: Int
        if step > 0 {
            if let c = current.max() {
                next = all.first { $0 > c } ?? all.last!
            } else {
                next = all.first { events[$0].range.lowerBound >= r.lowerBound } ?? all.last!
            }
        } else {
            if let c = current.min() {
                next = all.last { $0 < c } ?? all.first!
            } else {
                next = all.last { events[$0].range.upperBound <= r.lowerBound } ?? all.first!
            }
        }
        if extend, let lo = current.min(), let hi = current.max() {
            selectEvents([min(lo, next), max(hi, next)])
        } else {
            selectEvents([next])
        }
    }

    private func updateInputStatus() {
        statusBar.setInput(armed: noteInput.armedDuration?.text, buffer: noteInput.bufferText)
        updateHints()
    }

    // MARK: Status

    private func updateStatus() {
        let lily = score.installation.map { "LilyPond \($0.version)" } ?? "LilyPond —"
        var note: String?
        if let declared = score.declaredVersion, let v = score.installation?.version, declared != v {
            note = "Score declares \(declared); compiling with \(v)"
        }
        if let f = score.unlinkedFiles.first {
            // Never fail silently: say which music can't be clicked, and why.
            note = "\(f.displayName) has notes but no point-and-click links"
        }
        statusBar.setActivities(score.activities + (agentNote.map { [$0] } ?? []))
        statusBar.setAgentWorking(agentWorking)
        statusBar.set(status: score.status, detail: firstErrorText(), zoom: canvas.zoom, toolchain: lily, note: note,
                      stale: score.showingCachedRender)
        firstEngraving.setActive(canvas.pages.isEmpty && score.status == .compiling)
        updateHints()
    }

    private func firstErrorText() -> String? {
        guard let d = score.files.lazy.flatMap({ $0.diagnostics }).first(where: { $0.severity == .error || $0.severity == .fatal }) else { return nil }
        if let line = d.line { return "line \(line): \(d.message)" }
        return d.message
    }

    private func updateHints() {
        var hints: [String]
        if hasSelection {
            hints = ["↑↓ pitch  ⇧↑↓ octave  ⌥↑↓ sharp/flat", "1 2 4 8 16 duration  . dot", "a–g insert  ⌫ delete  ⌘L lens"]
        } else {
            hints = ["Click a note to select it", "←→ walk the score", "⌘J switch pane"]
        }
        if noteInput.armedDuration != nil { hints.insert("Type a–g to insert · ⎋ to disarm", at: 0) }
        if hasSelection, window?.firstResponder !== canvas {
            hints.insert("Keys type text here: click the score (or ⌘J) for note keys", at: 0)
        }
        if case .errors = score.status { hints.insert("Errors are underlined in the source", at: 0) }
        // The legend on screen, or its file in the source: how to arrange it.
        if canvas.legendArranging {
            hints = ["Drag edges, gaps and examples · ⌥ all examples · ⌘ no snapping", "⎋ done arranging"]
        } else if canvas.legendInView || activeFile.url.lastPathComponent == FrontMatter.fileName {
            hints.insert("␣ f a arrange legend", at: 0)
        }
        statusBar.setHints(Array(hints.prefix(3)) + ["⌘/ all actions"])
    }

    private func showDiagnostics() {
        let text = editor.text
        let source = SourceText(activeFile.compiledText ?? text)
        let map = EngravingMap(engraved: activeFile.compiledText ?? text, current: text)
        let current = SourceText(text)
        let ranges: [(NSRange, NSColor)] = activeFile.diagnostics.compactMap { d in
            guard let p = d.position(in: source), let i = source.index(of: p) else { return nil }
            let loc = map.currentOffset(forEngraved: source.utf16Offset(of: i))
            let start = current.index(utf16Offset: loc)
            let end = LilyLexing.tokenRange(in: current.string, at: start).upperBound
            let color = d.severity == .warning ? Theme.warning : Theme.error
            return (NSRange(location: loc, length: max(1, current.utf16Offset(of: end) - loc)), color)
        }
        editor.showDiagnostics(ranges)
    }

    // MARK: Actions (reached via the responder chain from menus)

    @objc func zoomIn(_ sender: Any?) { canvas.setZoom(canvas.zoom * 1.2) }
    @objc func zoomOut(_ sender: Any?) { canvas.setZoom(canvas.zoom / 1.2) }
    @objc func zoomToFitWidth(_ sender: Any?) { canvas.fitWidth() }
    @objc func actualSize(_ sender: Any?) { canvas.setZoom(1) }

    @objc func switchPane(_ sender: Any?) { run("pane.focusNext") }

    @objc func exportPDF(_ sender: Any?) {
        guard let window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = score.url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.directoryURL = score.url.deletingLastPathComponent()
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let dest = panel.url else { return }
            Task { @MainActor in await self.runExport(to: dest) }
        }
    }

    private func runExport(to dest: URL) async {
        statusBar.flash("Exporting PDF…")
        do {
            try await score.exportPDF(to: dest)
            statusBar.flash("Exported \(dest.lastPathComponent) — no local paths embedded")
        } catch {
            let alert = NSAlert(error: error)
            if let window { _ = await alert.beginSheetModal(for: window) }
        }
    }

    @objc func revealInFinder(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([score.url])
    }

    // MARK: NSWindowDelegate

    /// Agents started for this window don't outlive Pondside.
    @objc private func appWillTerminate(_ notification: Notification) {
        agentHandle?.stop()
        requestSession?.close()
        patchSession?.close()
    }

    func windowWillClose(_ notification: Notification) {
        agentHandle?.stop()
        requestIdle?.cancel()
        requestSession?.close()
        patchIdle?.cancel()
        patchSession?.close()
        closeLens()
        flushSuperCollider()
        NotificationCenter.default.removeObserver(self)
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        saveLayout()
        score.close()
        (NSApp.delegate as? PondsideAppDelegate)?.windowDidClose(self)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        score.revalidate()
    }

    /// ⌘Z from either pane undoes the visible file's edits, score and text alike.
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        activeFile.undoManager
    }

    @objc private func undoHistoryChanged(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager,
              manager === activeFile.undoManager else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let text = self.editor.text
            guard text != self.activeFile.text else { return }
            let fromSource = self.window?.firstResponder === self.editor.textView
            self.applyingScoreEdit = true
            self.editor.onUserEdit?(text)
            self.applyingScoreEdit = false
            self.refreshHighlight(reveal: false)
            if fromSource {
                self.closeLens()
            } else {
                self.showLens(closesOnRender: true)
            }
        }
    }
}

extension DocumentWindowController: ScoreCanvasDelegate {
    func canvas(_ canvas: ScoreCanvasView, didClick link: PointAndClickLocation?, extending: Bool) {
        guard let link else {
            perform(.clearSelection)
            return
        }
        guard let file = score.file(for: link.path) else {
            statusBar.flash("That object comes from \((link.path as NSString).lastPathComponent), outside this score's files")
            return
        }
        if file !== activeFile {
            showFile(file)
            statusBar.flash("Editing \(file.displayName)")
        }
        guard let offset = currentOffset(of: link) else { return }
        // A chord member selects just that note, so ↑↓ move it alone.
        var range: Range<Int>
        if let n = tree.noteIndex(startingAt: offset), let e = tree.notes[n].event, tree.events[e].kind == .chord {
            range = tree.notes[n].spelledRange
        } else if let command = ScoreGraphic.commandRange(at: offset, in: editor.text) {
            // A graphic links to the command that starts it (`\startGrains`,
            // `\startGraphic`): selecting that word is the graphic's cursor.
            range = command
            statusBar.flash("⌘L: describe a change to this graphic")
        } else if let e = tree.eventIndex(at: offset) {
            range = tree.events[e].range
        } else {
            return
        }
        if extending {
            let current = selectionUTF8()
            range = min(current.lowerBound, range.lowerBound)..<max(current.upperBound, range.upperBound)
        }
        setSelection(utf8: range)
        // A click in the score means the next keys are score keys (a–g, 8,
        // ↑…), never text: make sure nothing on the way took the keyboard.
        window?.makeFirstResponder(canvas)
    }

    func canvasClickedUnlinkedMusic(_ canvas: ScoreCanvasView) {
        // DESIGN.md M2.1 B: explain, don't silently deselect.
        statusBar.flash("That object has no source link — it may come from Scheme, a music function, or LilyPond itself")
    }

    func canvas(_ canvas: ScoreCanvasView, didSelect links: [PointAndClickLocation]) {
        // A rectangle edits one file: the one most of its links come from.
        var counts: [ObjectIdentifier: (SourceFile, Int)] = [:]
        for l in links {
            guard let f = score.file(for: l.path) else { continue }
            counts[ObjectIdentifier(f), default: (f, 0)].1 += 1
        }
        guard let target = counts.values.max(by: { $0.1 < $1.1 })?.0 else { return }
        if target !== activeFile { showFile(target) }
        let offsets = links.filter { target.matches(path: $0.path) }.compactMap { currentOffset(of: $0) }
        let events = Set(offsets.compactMap { tree.eventIndex(at: $0) })
        guard !events.isEmpty else { return }
        // A rectangle selects the contiguous source span it covers.
        selectEvents(Array(events))
        window?.makeFirstResponder(canvas)
    }

    func canvas(_ canvas: ScoreCanvasView, handleKey event: NSEvent) -> Bool {
        if canvas.legendArranging, event.keyCode == 53 {      // ⎋ ends arranging
            arrangeLegend(false)
            return true
        }
        return handleScoreKey(event)
    }

}

extension DocumentWindowController: ScoreDocumentDelegate {
    func document(_ document: ScoreDocument, didReloadFromDisk file: SourceFile) {
        // An agent's write is part of its one request, undone with ⌘Z as a
        // whole; adopting it must not add a second step to this file.
        let fromAgent = requestRunning || agentChanged.contains(file.url)
        editor.mergeExternal(file.text, into: file.url, registeringUndo: !fromAgent)
        if requestRunning { agentWritesInFlight.insert(file.url) }
        agentChanged.remove(file.url)
        AppRPC.shared.publish("score.changed", ["path": .string(file.url.path), "by": "disk"])
        rebuildEngravingMap()
        refreshHighlight(reveal: false)
        statusBar.flash("Reloaded \(file.displayName) — it changed on disk")
    }

    func document(_ document: ScoreDocument, hasConflictIn file: SourceFile, diskText: String) {
        guard let window, pendingConflict == nil else {
            pendingConflict = (file, diskText)
            return
        }
        pendingConflict = (file, diskText)
        let alert = NSAlert()
        alert.messageText = "\(file.displayName) changed on disk while you were typing"
        alert.informativeText = "Another program edited the file. Whichever version you don't keep is saved to ~/Library/Application Support/Pondside/Recovery, so nothing is lost."
        alert.addButton(withTitle: "Use the File on Disk")
        alert.addButton(withTitle: "Keep My Edits")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, let pending = self.pendingConflict else { return }
            self.pendingConflict = nil
            self.score.resolveConflict(in: pending.file, keepMine: response == .alertSecondButtonReturn, diskText: pending.disk)
        }
    }

    func documentStatusDidChange(_ document: ScoreDocument) {
        updateStatus()
        // A compile that produced no pages never reaches documentDidEngrave.
        if case .failed = document.status { checkAgentRender() }
    }

    func documentFilesDidChange(_ document: ScoreDocument) {
        if !document.files.contains(where: { $0 === activeFile }) {
            showFile(document.root)
        } else {
            rebuildFileMenu()
        }
    }

    func documentDidUpdatePlayback(_ document: ScoreDocument) {
        cueInspector.show(score.cueSheet, scoreFolder: score.url.deletingLastPathComponent())
    }

    func documentDidLoadCachedRender(_ document: ScoreDocument) {
        canvas.setPages(score.pages)
        canvas.fitWidth()
        rebuildEngravingMap()
        refreshHighlight(reveal: false)
        updateStatus()
    }

    func documentDidEngrave(_ document: ScoreDocument) {
        let first = canvas.pages.isEmpty
        canvas.setPages(score.pages)
        if first { canvas.fitWidth() }
        compilerOutput.show(score.lastLog)
        AppRPC.shared.publish("compile.finished", rpcSummary)
        cueInspector.show(score.cueSheet, scoreFolder: score.url.deletingLastPathComponent())
        rebuildEngravingMap()
        refreshHighlight(reveal: false)
        showDiagnostics()
        updateStatus()
        checkAgentRender()
        closeLensIfRendered()
        refreshEngravingSettings()
        refreshScoreSetup()
    }
}

// MARK: - Commands, chords, palette and panes (M3)

/// A reference cell for palette providers, which recompute their rows on
/// each keystroke and must hand the chosen one back.
@MainActor
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}

extension DocumentWindowController: CommandResponder {
    @objc func performCommand(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.commandID else { return }
        run(id)
    }

    var commandContext: CommandContext {
        let responder = window?.firstResponder
        let focus: CommandContext.Focus = responder === canvas ? .score : responder === editor.textView ? .source
            : scPane.map { responder === $0.editor } == true ? .supercollider : .other
        var errors = false
        if case .errors = score.status { errors = true }
        return CommandContext(focus: focus, hasSelection: hasSelection, durationArmed: noteInput.armedDuration != nil,
                              hasErrors: errors, fileCount: score.files.count, agentWorking: agentWorking)
    }

    /// Runs a catalog command. Menus, chords and the palette all end here.
    func run(_ id: CommandID) {
        let center = CommandCenter.shared
        if let spec = center.spec(id), !spec.isAvailable(in: commandContext) {
            statusBar.flash(Self.unavailableMessage(spec))
            NSSound.beep()
            return
        }
        center.palette.noteUsed(id)
        let selected = targets().events
        let pitched = selected.filter { tree.events[$0].isPitched }
        let editor = ScoreEditor(tree)
        switch id.rawValue {
        case "file.exportPDF": exportPDF(nil)
        case "file.reveal": revealInFinder(nil)
        case "file.migratePatch": offerPatchMigration(asked: true)
        case "file.close": window?.performClose(nil)

        case "go.file": showFilePicker()
        case "go.nextFile": nextFile(nil)
        case "go.previousFile": previousFile(nil)
        case "go.error": goToError()
        case "go.cue": showCuePicker()
        case "go.first":
            if let i = tree.events.firstIndex(where: { $0.acceptsNoteEntry }) { selectEvents([i]) }
        case "go.last":
            if let i = tree.events.lastIndex(where: { $0.acceptsNoteEntry }) { selectEvents([i]) }
        case "go.next": perform(.select(step: 1, extend: false))
        case "go.previous": perform(.select(step: -1, extend: false))

        case "add.slur": apply(editor.toggleSpan(open: "(", close: ")", events: pitched, name: "Slur"))
        case "add.beam": apply(editor.toggleSpan(open: "[", close: "]", events: pitched, name: "Beam"))
        case "add.crescendo": apply(editor.toggleSpan(open: "\\<", close: "\\!", events: selected, name: "Crescendo"))
        case "add.decrescendo": apply(editor.toggleSpan(open: "\\>", close: "\\!", events: selected, name: "Decrescendo"))
        case "add.tie": apply(editor.togglePostEvent("~", events: pitched))
        case "add.staccato": apply(editor.togglePostEvent("-.", events: pitched))
        case "add.accent": apply(editor.togglePostEvent("->", events: pitched))
        case "add.tenuto": apply(editor.togglePostEvent("--", events: pitched))
        case "add.fermata": apply(editor.togglePostEvent("\\fermata", events: selected))
        case "add.dynamic": showDynamicPicker(events: selected)
        case "add.tuplet": showTupletPicker(events: selected)
        case "add.clef": showClefPicker(events: selected)
        case "add.time": showTimePicker(events: selected)
        case "add.key": showKeyPicker(events: selected)
        case "add.tempo": showTempoPicker(events: selected)
        case "add.text": showTextPicker(events: selected)
        case "add.cue": addCue(events: selected)
        case "add.note": statusBar.flash("Type a–g with the score focused: the note goes after the selection")
        case "add.rest": insert(step: nil)

        case "edit.undo": activeFile.undoManager.undo()
        case "edit.redo": activeFile.undoManager.redo()
        case "edit.delete": perform(.delete)
        case "edit.source": perform(.editSource)
        case "edit.find":
            let item = NSMenuItem()
            item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
            window?.makeFirstResponder(self.editor.textView)
            self.editor.textView.performFindPanelAction(item)
        case "edit.selectAll": NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: self)
        case "edit.up": perform(.move(.step(1)))
        case "edit.down": perform(.move(.step(-1)))
        case "edit.duration": statusBar.flash("Type 1 2 4 8 16 32 in the score: it changes the selection, or arms the next note")
        case "edit.dot": perform(.toggleDot)
        case "edit.disarm":
            noteInput.arm(nil)
            updateInputStatus()

        case "file.engravingSettings": showEngravingSettings()
        case "file.scoreSetup": showScoreSetup()
        case "file.arrangeLegend": arrangeLegend(!canvas.legendArranging)
        case "file.lilypond": showLilyPondPicker()
        case "view.play": togglePlayback()
        case "view.playMix": togglePlayback(electronics: true)
        case "view.lens": showLens(closesOnRender: false)
        case "view.zoomIn": zoomIn(nil)
        case "view.zoomOut": zoomOut(nil)
        case "view.actualSize": actualSize(nil)
        case "view.fitWidth": zoomToFitWidth(nil)
        case "view.fullScreen": window?.toggleFullScreen(nil)
        case "view.agentLog": toggleAgentLog()

        case "pane.focusNext":
            syncFocusedPane()
            var l = panes.layout
            l.focusNext()
            focusPane(l.focused)
        case "pane.cycleNext": cyclePane(forward: true)
        case "pane.cyclePrevious": cyclePane(forward: false)
        case "workspace.save": saveWorkspace()
        case "workspace.open": showWorkspacePicker()

        case "sc.evaluate": scPane?.evaluate(line: false)
        case "sc.evaluateLine": scPane?.evaluate(line: true)
        case "sc.help": scPane?.lookUpHelp()
        case "sc.complete": scPane?.editor.complete(nil)
        case "sc.stop":
            SCLangHost.shared.stopSound()
            statusBar.flash("Stopped all sound (CmdPeriod)")
        case "sc.boot":
            ensureSuperCollider()
            SCLangHost.shared.toggleServer()
        case "sc.openFile": showSuperColliderFilePicker()
        case "edit.undoAgent": undoAgentChange()
        case "edit.stopAgent": stopAgent()
        case "edit.newAgentConversation": newAgentConversation()
        case "edit.patchRequest": showPatchRequest(fromLens: false)
        case "edit.newPatchConversation": newPatchConversation()
        case "sc.openInIDE": openInSuperColliderIDE()
        case "sc.clearPost": SCLangHost.shared.clearLog()
        case "sc.recompile":
            ensureSuperCollider()
            SCLangHost.shared.recompile()
        case "sc.restart":
            ensureSuperCollider()
            SCLangHost.shared.restart()

        case "help.palette": showCommandPalette(onlyAvailable: false, placeholder: "Type a command — two letters are usually enough")
        case "help.context": showCommandPalette(onlyAvailable: true, placeholder: "What can I do here?")
        case "help.keys": showCommandPalette(onlyAvailable: false, placeholder: "Every command and its keys")

        default:
            let raw = id.rawValue
            if raw.hasPrefix("pane.show."), let c = PaneContent(rawValue: String(raw.dropFirst("pane.show.".count))) {
                showInFocusedPane(c)
            } else if raw.hasPrefix("workspace.preset"), let n = Int(raw.dropFirst("workspace.preset".count)),
                      PaneLayout.presets.indices.contains(n - 1) {
                applyLayout(PaneLayout.presets[n - 1])
            } else {
                (NSApp.delegate as? PondsideAppDelegate)?.runAppCommand(id)
            }
        }
    }

    private static func unavailableMessage(_ spec: CommandSpec) -> String {
        switch spec.requires {
        case .selection: return "\(spec.title) needs a selection: click a note, or walk with ←→"
        case .errors: return "No errors: the score compiles cleanly"
        case .severalFiles: return "This score is a single file"
        case .scoreFocus: return "\(spec.title) works in the score: ⌘J to focus it"
        case .supercollider: return "\(spec.title) works in the SuperCollider pane: ␣ p c shows it"
        case .agentWorking: return "No agent is working"
        case .always: return spec.title
        }
    }

    // MARK: Leader chords

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            let consumed = MainActor.assumeIsolated { self?.intercept(event) ?? false }
            return consumed ? nil : event
        }
    }

    /// Window-wide keys: the leader (Space in the score, ⌥Space anywhere —
    /// ⌃Space belongs to macOS input-source switching),
    /// the keys of a chord in progress, and ⌥ for the key reveal.
    private func intercept(_ event: NSEvent) -> Bool {
        guard let window, event.window === window else { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if event.type == .flagsChanged {
            help.optionChanged(isDown: flags == .option)
            return false
        }
        help.optionChanged(isDown: false)
        if event.keyCode == 53, lens?.isOpen == true {
            closeLens()
            return true
        }
        // ⇥ in the lens: the request line for this passage.
        if event.keyCode == 48, lens?.isOpen == true, flags.subtracting([.numericPad, .function]).isEmpty {
            closeLens()
            showRequest(fromLens: true)
            return true
        }
        // Plain ←→ step through the lens's voice; with modifiers they keep
        // their usual meaning.
        if lens?.isOpen == true, event.type == .keyDown, !noteInput.isBuffering,
           flags.subtracting([.numericPad, .function]).isEmpty,
           let key = event.specialKey, key == .leftArrow || key == .rightArrow {
            stepLens(key == .rightArrow ? 1 : -1)
            return true
        }
        let keymap = CommandCenter.shared.keymap
        if chord.isActive {
            if event.keyCode == 53 {
                chord.cancel()
                statusBar.endChord()
                return true
            }
            guard let c = event.characters?.first else { return true }
            handle(chord.feed(c, keymap))
            return true
        }
        let isSpace = event.keyCode == 49
        let leader = isSpace && (flags == .option || (flags.isEmpty && window.firstResponder === canvas && !noteInput.isBuffering))
        guard leader else { return false }
        handle(chord.begin(keymap))
        return true
    }

    private func handle(_ outcome: ChordRecognizer.Outcome) {
        switch outcome {
        case .pending(let next):
            let typed = (["␣"] + (chord.typed ?? []).map { String($0) }).joined(separator: " ")
            statusBar.showChord(typed: typed, continuations: next)
        case .command(let id):
            statusBar.endChord()
            run(id)
        case .unbound(let keys):
            statusBar.endChord()
            statusBar.flash("\(keys) isn't bound. ⌘K finds any command")
            NSSound.beep()
        }
    }

    // MARK: Palette

    private func showCommandPalette(onlyAvailable: Bool, placeholder: String) {
        guard let window else { return }
        let context = commandContext
        let items = Box<[CommandPalette.Item]>([])
        let panel = PalettePanel(placeholder: placeholder, provider: { query in
            items.value = CommandCenter.shared.palette.items(for: query, in: context, onlyAvailable: onlyAvailable)
            return items.value.map {
                PaletteRow(title: $0.spec.title, detail: $0.spec.gloss, hint: $0.hint, enabled: $0.available, matched: $0.matched)
            }
        }, onChoose: { [weak self] i in
            guard items.value.indices.contains(i) else { return }
            self?.run(items.value[i].spec.id)
        })
        panel.present(over: window)
    }

    /// A palette over plain choices, fuzzy-matched by title.
    private func showPicker(placeholder: String, choices: [(title: String, detail: String?)], choose: @escaping (Int) -> Void) {
        guard let window else { return }
        let order = Box<[Int]>([])
        let panel = PalettePanel(placeholder: placeholder, provider: { query in
            let scored = choices.enumerated().compactMap { i, c -> (Int, FuzzyMatch.Result)? in
                FuzzyMatch.match(query, in: c.title).map { (i, $0) }
            }.sorted { $0.1.score > $1.1.score || ($0.1.score == $1.1.score && $0.0 < $1.0) }
            order.value = scored.map(\.0)
            return scored.map { PaletteRow(title: choices[$0.0].title, detail: choices[$0.0].detail, matched: $0.1.positions) }
        }, onChoose: { i in
            guard order.value.indices.contains(i) else { return }
            choose(order.value[i])
        })
        panel.present(over: window)
    }

    private func showFilePicker() {
        let rootDir = score.url.deletingLastPathComponent().path + "/"
        let files = score.files
        showPicker(placeholder: "Go to file", choices: files.map { f in
            let path = f.url.path.hasPrefix(rootDir) ? String(f.url.path.dropFirst(rootDir.count)) : f.url.path
            return (title: f.displayName, detail: (f.hasNotes ? path : path + " · no notes") as String?)
        }) { [weak self] i in
            guard let self, files.indices.contains(i) else { return }
            self.showFile(files[i])
        }
    }

    private func showCuePicker() {
        let cues = score.cueSheet?.cues ?? []
        guard !cues.isEmpty else {
            statusBar.flash("No cues in the score yet: \\ecue \"1\" on a note places one")
            return
        }
        showPicker(placeholder: "Go to cue", choices: cues.map { c in
            (title: "cue \(c.name)", detail: "bar \(c.position.measure) · \(CueInspectorView.timecode(c.seconds))" as String?)
        }) { [weak self] i in
            guard cues.indices.contains(i) else { return }
            self?.reveal(cues[i])
        }
    }

    /// Selects a cue's \ecue in the source, which highlights its note.
    private func reveal(_ cue: CueSheet.Cue) {
        guard let origin = cue.source else {
            statusBar.flash("cue \(cue.name) is generated (a Lexicon sound), so it has no line of its own")
            return
        }
        guard revealSource(path: origin.file, line: origin.line, character: origin.character) else {
            statusBar.flash("cue \(cue.name) is in \(origin.file), outside this score's files")
            return
        }
        statusBar.flash("cue \(cue.name) · bar \(cue.position.measure) · \(CueInspectorView.timecode(cue.seconds))")
    }

    /// Puts the caret at a source position (point-and-click coordinates),
    /// switching files if needed; the score highlights what is there.
    func revealSource(path: String, line: Int, character: Int) -> Bool {
        guard let file = score.file(for: path) else { return false }
        if file !== activeFile { showFile(file) }
        let text = editor.text
        guard let i = SourceText(text).index(of: SourcePosition(line: line, character: character)) else { return false }
        let offset = text.utf8.distance(from: text.startIndex, to: i)
        setSelection(utf8: offset..<offset)
        return true
    }

    /// The selection in point-and-click coordinates, for scripts.
    var rpcSelection: JSONValue {
        let text = editor.text
        let r = selectionUTF8()
        let source = SourceText(text)
        func position(_ o: Int) -> JSONValue {
            let p = source.position(of: text.utf8.index(text.utf8.startIndex, offsetBy: min(o, text.utf8.count)))
            return ["line": .number(Double(p.line)), "character": .number(Double(p.character))]
        }
        let selected = String(decoding: Array(text.utf8)[r], as: UTF8.self)
        return ["path": .string(activeFile.url.path), "start": position(r.lowerBound), "end": position(r.upperBound),
                "text": .string(selected), "events": .array(targets().events.map { .string(tree.string(tree.events[$0].range)) })]
    }

    private static let dynamics = ["ppp", "pp", "p", "mp", "mf", "f", "ff", "fff", "fp", "sf", "sfz", "rfz"]

    /// `score_context` for the selection (DESIGN.md §8): what the files say
    /// (ScoreContext), plus what only the engraving knows, the system the
    /// selection is on: its first and last events in this staff's music,
    /// and the first event of the next system.
    var rpcContext: JSONValue {
        let text = editor.text
        let r = selectionUTF8()
        let start = SourceText(text).position(of: text.utf8.index(text.utf8.startIndex, offsetBy: min(r.lowerBound, text.utf8.count)))
        let files = score.files.map { (path: $0.url.path, text: $0 === activeFile ? text : $0.text) }
        var context = ScoreContext.describe(text: text, file: activeFile.url.path, line: start.line, character: start.character,
                                            files: files, cues: score.cueSheet)
        guard case var .object(o) = context else { return context }
        if let part = canvas.graphicPartSelection, o["graphic"] != nil {
            let scale = part.space > 0 ? part.space : 1
            let width = max(part.piece.width, 0.001)
            func y(_ pageY: Double) -> Double { (part.staffMiddle - pageY) / scale }
            var selection: [String: JSONValue] = [
                "kind": .string("graphic-part"),
                "page": .number(Double(part.page)),
                // Fractions of the broken piece's width, so they do not depend on the
                // system's page offset. The drawing code's x runs from (car (g-span grob)).
                "x": .array([.number((part.part.minX - part.piece.minX) / width),
                             .number((part.part.maxX - part.piece.minX) / width)]),
                // Staff spaces above the middle line, as the drawing code's y.
                "y": .array([.number(y(part.part.maxY)), .number(y(part.part.minY))]),
                // The clicked system's piece, so the same x on another system is not changed too.
                "spanner_x": .array([.number(part.piece.minX), .number(part.piece.maxX)]),
                "units": .string("x is a fraction of the piece's width (from (car (g-span grob)) to its right edge); y is in staff spaces above the middle line; spanner_x is that piece's page x"),
            ]
            // The exact test for "inside the highlight", ready to paste into the
            // drawing loop: the agent changes this and no wider.
            let f0 = (part.part.minX - part.piece.minX) / width, f1 = (part.part.maxX - part.piece.minX) / width
            let y0 = y(part.part.maxY), y1 = y(part.part.minY)
            func r(_ v: Double) -> String { String(format: "%.3f", v) }
            selection["scope"] = .string("(let ((f (/ (- x x0) (- x1 x0)))) (and (>= f \(r(f0))) (<= f \(r(f1))) (>= y \(r(y0))) (<= y \(r(y1)))))"
                + "   ; x0 x1 = (car/cdr (g-span grob)); only on the piece at page x \(r(part.piece.minX))–\(r(part.piece.maxX))")
            if let musical = clickedMusicalContext(for: part) {
                for (key, value) in musical { selection[key] = value }
            }
            o["selection"] = .object(selection)
        }
        if let system = systemOfSelection(text: text) { o["system"] = system }
        context = .object(o)
        return context
    }

    /// The bar/moment nearest the click and, when the system's other
    /// linked glyphs bracket it, the musical range of the clicked part
    /// (the graphic itself only links to the spanner's start).
    private func clickedMusicalContext(for part: ScoreCanvasView.GraphicPartSelection) -> [String: JSONValue]? {
        struct Hit { var x: Double; var bar: Int; var moment: String; var event: String? }
        var hits: [Hit] = []
        for anchor in part.anchors {
            guard let file = score.file(for: anchor.link.path), let engraved = file.engravedText else { continue }
            let text = file.text
            let map = EngravingMap(engraved: engraved, current: text)
            guard let engravedOffset = map.engravedOffset(of: anchor.link.position) else { continue }
            let source = SourceText(text)
            let p = source.position(of: source.index(utf16Offset: map.currentOffset(forEngraved: engravedOffset)))
            let files = score.files.map { (path: $0.url.path, text: $0 === file ? text : $0.text) }
            let context = ScoreContext.describe(text: text, file: file.url.path, line: p.line, character: p.character,
                                                files: files, cues: score.cueSheet)
            guard let bar = context["bar"]?.int, let moment = context["moment"]?.string else { continue }
            hits.append(Hit(x: anchor.x, bar: bar, moment: moment, event: context["event"]?["text"]?.string))
        }
        guard !hits.isEmpty else { return nil }
        func json(_ hit: Hit) -> JSONValue {
            var out: [String: JSONValue] = ["bar": .number(Double(hit.bar)), "moment": .string(hit.moment)]
            if let event = hit.event { out["event"] = .string(event) }
            return .object(out)
        }
        let target = part.part.midX
        let nearest = hits.min { abs($0.x - target) < abs($1.x - target) }!
        var out: [String: JSONValue] = ["at": json(nearest)]
        let left = hits.filter { $0.x <= part.part.minX }.max { $0.x < $1.x }
        let right = hits.filter { $0.x >= part.part.maxX }.min { $0.x < $1.x }
        if let left, let right, left.bar != right.bar || left.moment != right.moment {
            // The music on either side: wider than the highlight, for "from here", never for scoping.
            out["music_around"] = .object(["from": json(left), "to": json(right)])
        }
        return out
    }

    private func systemOfSelection(text: String) -> JSONValue? {
        let links = canvas.linksOnSelectedSystem().filter { PathMatching.same($0.path, activeFile.url.path) }
        guard let anchor = targets().events.first,
              let block = LensBlockFinder.block(in: tree, at: tree.events[anchor].range.lowerBound) else { return nil }
        let staffEvents = Set(block.events)
        let onSystem = Set(links.compactMap { currentOffset(of: $0) }.compactMap { tree.eventIndex(at: $0) })
            .intersection(staffEvents).sorted()
        guard let first = onSystem.first, let last = onSystem.last else { return nil }
        func describe(_ e: Int) -> JSONValue {
            let p = SourceText(text).position(of: text.utf8.index(text.utf8.startIndex, offsetBy: tree.events[e].range.lowerBound))
            return ["text": .string(tree.string(tree.events[e].range)), "line": .number(Double(p.line)),
                    "character": .number(Double(p.character))]
        }
        var out: [String: JSONValue] = ["first": describe(first), "last": describe(last)]
        if let next = block.events.sorted().first(where: { $0 > last }) { out["next"] = describe(next) }
        return .object(out)
    }

    // MARK: Toolchains

    /// Every LilyPond found, the one in use marked; choosing one pins it in
    /// the project's pondside.toml (a file, like everything else).
    private func showLilyPondPicker() {
        Task {
            let installs = await ToolchainStore.shared.installs()
            guard !installs.isEmpty else {
                self.statusBar.flash("No LilyPond found — run the Pondside installer, or brew install lilypond")
                return
            }
            let current = self.score.installation
            let choices = installs.map { i -> (title: String, detail: String?) in
                let mark = i == current ? " — in use" : ""
                return ("LilyPond \(i.version)\(mark)", "\(i.origin.rawValue): \(i.resolvedPath)")
            }
            self.showPicker(placeholder: "LilyPond version for this score", choices: choices) { [weak self] index in
                guard let self else { return }
                let install = installs[index]
                let dir = (try? ProjectConfig.find(from: self.score.url))?.root ?? self.score.url.deletingLastPathComponent()
                let file = dir.appendingPathComponent(ProjectConfig.fileName)
                let old = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
                do {
                    try ProjectConfig.settingLilyPond(version: "\(install.version)", in: old).write(to: file, atomically: true, encoding: .utf8)
                    self.score.use(install)
                    self.statusBar.flash("LilyPond \(install.version) for this score (\(file.lastPathComponent))")
                } catch {
                    self.statusBar.flash("Couldn't write \(file.path): \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Audition

    /// The mockup, `renders/<name>.wav` (⌘⇧P plays it).
    private var mockupURL: URL? {
        let url = HandlerSync.Layout.mockup(score: score.url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The score with its electronics (`pondside mix`), after each mockup.
    private var mixURL: URL? {
        let url = PatchRender.output(for: score.url)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Plays the mockup, or with `electronics` the mix, from the selection's
    /// bar; either command stops whatever is playing.
    private func togglePlayback(electronics: Bool = false) {
        if let player, player.isPlaying {
            player.stop()
            self.player = nil
            statusBar.flash("Stopped")
            return
        }
        let found = electronics ? mixURL : mockupURL
        guard let url = found else {
            if !electronics {
                statusBar.flash("No mockup yet: it renders after each engraving (MuseScore or fluidsynth needed)")
            } else if score.patchURL == nil {
                let scd = PatchMigration.patchURL(score: score.url)
                statusBar.flash(FileManager.default.fileExists(atPath: scd.path)
                    ? "\(scd.lastPathComponent) isn't a Pondside patch: move it aside and open the SuperCollider pane to start one"
                    : "No patch yet: open the SuperCollider pane to start \(scd.lastPathComponent)")
            } else {
                statusBar.flash("No mix yet" + (score.mixProblem.map { ": \($0)" } ?? ": it renders after each mockup (SuperCollider needed)"))
            }
            NSSound.beep()
            return
        }
        // Start at the selected bar, timed as the MIDI the mockup came from.
        var start = 0.0
        if let log = score.timingLog, let first = targets().events.first,
           let window = LensScoreBuilder.build(tree: tree, selection: tree.events[first].range), let target = window.target {
            let bar = window.bars.lowerBound + target.measureIndex
            if let row = log.rows.first(where: { $0.bar >= bar }) { start = TempoMap(log).seconds(at: row.moment) }
        }
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.currentTime = min(start, max(0, p.duration - 0.1))
            p.play()
            player = p
            statusBar.flash("Playing \(url.lastPathComponent) from \(String(format: "%.1f", start)) s — \(electronics ? "⌘⌥P" : "⌘⇧P") stops")
        } catch {
            statusBar.flash("Can't play \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    // MARK: Engraving settings

    private var settingsDocument: EngravingSettingsDocument {
        EngravingSettingsDocument(root: score.root.text,
                                  others: score.files.dropFirst().map { (file: $0.displayName, text: $0.text) })
    }

    private func showEngravingSettings() {
        let panel = settingsPanel ?? {
            let panel = EngravingSettingsPanel()
            panel.model.onChange = { [weak self] setting, value in
                guard let self else { return }
                self.applyText(self.settingsDocument.edits(setting: setting, to: value), to: self.score.root,
                               name: setting.title)
                self.refreshEngravingSettings()
            }
            panel.model.onRestoreAll = { [weak self] in self?.restoreEngravingDefaults() }
            panel.model.onShowSource = { [weak self] in
                guard let self else { return }
                if self.activeFile !== self.score.root { self.showFile(self.score.root) }
                self.window?.makeKeyAndOrderFront(nil)
                self.window?.makeFirstResponder(self.editor.textView)
            }
            if let frame = window?.frame, !panel.setFrameUsingName("Pondside.engravingSettings") {
                panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 64))
            }
            settingsPanel = panel
            return panel
        }()
        refreshEngravingSettings(force: true)
        panel.orderFront(nil)
    }

    private func refreshEngravingSettings(force: Bool = false) {
        guard let panel = settingsPanel, force || panel.isVisible else { return }
        panel.model.rootName = score.root.displayName
        panel.model.values = settingsDocument.values
    }

    private func restoreEngravingDefaults() {
        guard let window = settingsPanel ?? window else { return }
        let alert = NSAlert()
        alert.messageText = "Restore LilyPond's defaults?"
        alert.informativeText = "Every engraving setting goes back to LilyPond's default: Pondside removes the settings from \(score.root.displayName), or writes the default where another file sets something else. You can undo it in the source."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let doc = self.settingsDocument
            let changes = EngravingSetting.all.filter { doc.value(of: $0).value != $0.defaultValue }.map { ($0, $0.defaultValue) }
            self.applyText(doc.edits(for: changes), to: self.score.root, name: "Restore Engraving Defaults")
            self.refreshEngravingSettings()
        }
    }

    /// Applies `edits` to `file` as one undoable change in that file's
    /// history, showing it in the source pane while it happens.
    private func applyText(_ edits: [TextEdit], to file: SourceFile, name: String) {
        guard !edits.isEmpty else { return }
        let previous = activeFile
        if file !== activeFile { showFile(file) }
        let old = editor.text
        let oldBytes = Array(old.utf8)
        let newBytes = edits.apply(to: oldBytes)
        let lo = edits.map(\.range.lowerBound).min()!
        let hi = edits.map(\.range.upperBound).max()!
        let newHi = hi + newBytes.count - oldBytes.count
        let replacement = String(decoding: newBytes[lo..<newHi], as: UTF8.self)
        let a = OffsetConversion.utf16(fromUTF8: lo, in: old)
        let b = OffsetConversion.utf16(fromUTF8: hi, in: old)
        applyingScoreEdit = true
        editor.replace(NSRange(location: a, length: b - a), with: replacement, actionName: name)
        applyingScoreEdit = false
        if previous !== file { showFile(previous) }
    }

    /// Once per score: a file musicxml2ly made turns LilyPond's defaults off
    /// (beaming, key cancellation). Offer to put them back.
    private func offerToRestoreConvertedSettings() {
        let key = "Pondside.convertedScoresChecked"
        var checked = Set(UserDefaults.standard.stringArray(forKey: key) ?? [])
        guard !checked.contains(score.url.path), let window else { return }
        let findings = ConvertedScoreCheck.findings(in: score.files.map { (file: $0.displayName, text: $0.text) })
        guard !findings.isEmpty else { return }
        checked.insert(score.url.path)
        UserDefaults.standard.set(Array(checked), forKey: key)

        let files = Array(Set(findings.map(\.file))).sorted().joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "\(files) looks converted from MusicXML"
        alert.informativeText = "musicxml2ly turned some of LilyPond's defaults off:\n"
            + findings.map { "• \($0.description) (\($0.file), line \($0.line))" }.joined(separator: "\n")
            + "\n\nPondside can restore them: it writes the defaults in \(score.root.displayName)'s settings. "
            + "Beams written with [ ] stay as they are. You can undo it in the source."
        alert.addButton(withTitle: "Restore Defaults")
        alert.addButton(withTitle: "Keep As Is")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let settings = findings.compactMap { f in EngravingSetting.named(f.setting).map { ($0, f.value) } }
            self.applyText(self.settingsDocument.edits(for: settings), to: self.score.root, name: "Restore Defaults")
            self.statusBar.flash("Restored LilyPond's defaults")
        }
    }

    /// A SuperCollider patch beside the score that doesn't follow Pondside's
    /// layout (PatchMigration): offered once per version of the file, or
    /// whenever the command asks. Pondside does what it can, then the
    /// chosen agent (Settings, ⌘,) finishes the marked lines unattended; without
    /// one, the dialog says how to finish them in the terminal.
    private func offerPatchMigration(asked: Bool = false) {
        if let run = agentHandle {
            if asked { confirmStopAgent(run) }
            return
        }
        let scoreURL = score.url
        let configured = (try? ProjectConfig.find(from: scoreURL))?.handlers
        let preference = UserDefaults.standard.string(forKey: Self.agentKey)
        let model = Self.opencodeModel
        Task { [weak self] in
            let (found, agent) = await Task.detached {
                (PatchMigration.candidate(score: scoreURL, configured: configured), AgentRun.choose(preference: preference, model: model))
            }.value
            guard let self, let window = self.window else { return }
            guard let c = found else {
                if asked { self.statusBar.flash("The SuperCollider patch is ready for Pondside") }
                return
            }
            let text = (try? String(contentsOf: c.source, encoding: .utf8)) ?? ""
            let key = "Pondside.patchMigrationDeclined"
            var declined = UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
            let version = text.utf8.reduce(5381) { ($0 &* 33) &+ Int($1) }
            guard asked || declined[c.source.path] != version else { return }

            let auto = c.findings.filter(\.automatic), manual = c.findings.filter { !$0.automatic }
            let useAgent = manual.isEmpty ? nil : agent
            func list(_ fs: [PatchMigration.Finding]) -> String {
                fs.prefix(6).map { "• " + ($0.line.map { "line \($0): " } ?? "") + $0.message }.joined(separator: "\n")
                    + (fs.count > 6 ? "\n• … and \(fs.count - 6) more" : "")
            }
            let alert = NSAlert()
            alert.messageText = "\(c.source.lastPathComponent) isn't fully a Pondside patch"
            var info = ""
            if !auto.isEmpty { info += "Pondside does this itself:\n" + list(auto) + "\n\n" }
            if !manual.isEmpty {
                info += "Needs an agent (each line gets a // pondside: comment):\n" + list(manual) + "\n\n"
                if let a = useAgent {
                    info += "\(a.harness.title) then fixes them in the background, unattended: a few minutes, on your "
                        + "\(a.harness.title) plan or credits. "
                        + (a.harness == .claude ? "It may only read and edit files in this folder and use Pondside's tools. "
                           : "opencode auto-approves its file edits (it can't be limited to this folder); Pondside turns off its shell. ")
                        + "Choose the agent in Settings (⌘,).\n\n"
                } else {
                    info += "No agent is set up (Settings, ⌘,), so finish them in the terminal (⌃4): run claude, then type "
                        + "\(Self.agentCommand). Refactor copies that command.\n\n"
                }
            }
            info += c.source == c.target ? "The original is kept as \(c.target.deletingPathExtension().lastPathComponent).before-pondside.scd."
                : "The patch goes in \(c.target.lastPathComponent); \(c.source.lastPathComponent) stays as it is."
            alert.informativeText = info
            if let a = useAgent {
                alert.addButton(withTitle: "Refactor with \(a.harness.title)")
                alert.addButton(withTitle: "Refactor Only")
            } else {
                alert.addButton(withTitle: "Refactor")
            }
            alert.addButton(withTitle: "Not Now")
            alert.beginSheetModal(for: window) { [weak self] response in
                guard let self else { return }
                let withAgent = useAgent != nil && response == .alertFirstButtonReturn
                let refactor = response == .alertFirstButtonReturn || (useAgent != nil && response == .alertSecondButtonReturn)
                guard refactor else {
                    declined[c.source.path] = version
                    UserDefaults.standard.set(declined, forKey: key)
                    return
                }
                let before = try? String(contentsOf: c.target, encoding: .utf8)
                let log = AgentLog.Run(kind: .refactor)
                log.log("start", "Refactor \(c.source.lastPathComponent) → \(c.target.lastPathComponent)"
                            + (withAgent ? " with \(useAgent?.harness.title ?? "the agent")" : ", Pondside's part only"),
                        detail: "score \(scoreURL.path)\nsource \(c.source.path)\ntarget \(c.target.path)\n\nautomatic:\n"
                            + auto.map { "line \($0.line.map(String.init) ?? "-"): \($0.message)" }.joined(separator: "\n")
                            + "\n\nfor the agent:\n" + manual.map { "line \($0.line.map(String.init) ?? "-"): \($0.message)" }.joined(separator: "\n"))
                do {
                    let (result, _, _) = try PatchMigration.write(score: scoreURL, source: c.source, target: c.target, sheet: self.score.cueSheet)
                    log.log("migrate", "Pondside wrote \(c.target.lastPathComponent): \(result.manual.count) lines marked for an agent")
                    self.score.renderMix()
                    self.scPane?.open(c.target)   // the patch now lives in patch/
                    if result.manual.isEmpty {
                        self.statusBar.flash("\(c.target.lastPathComponent) is a Pondside patch")
                    } else if withAgent, let a = useAgent {
                        self.runAgent(a, score: scoreURL, patch: c.target, before: before, log: log)
                    } else {
                        log.log("outcome", "\(result.manual.count) marked lines left; the agent command was copied")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Self.agentCommand, forType: .string)
                        self.statusBar.flash("\(c.target.lastPathComponent): \(result.manual.count) lines for an agent; \(Self.agentCommand) copied")
                    }
                } catch {
                    log.log("outcome", "Couldn't write \(c.target.lastPathComponent): \(error.localizedDescription)", level: .error)
                    self.statusBar.flash("Couldn't write \(c.target.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
    }

    static let agentKey = "Pondside.patchAgent"
    /// opencode's model (`provider/model`), chosen in Settings; absent: opencode's default.
    static let opencodeModelKey = "Pondside.opencodeModel"
    static var opencodeModel: String? { UserDefaults.standard.string(forKey: opencodeModelKey) }
    static let agentCommand = "/mcp__pondside__sc-patch-migration"

    private func runAgent(_ agent: AgentRun, score scoreURL: URL, patch: URL, before: String?, log: AgentLog.Run) {
        guard let pondside = Bundle.main.resourceURL?.appendingPathComponent("pondside").path,
              FileManager.default.isExecutableFile(atPath: pondside) else {
            log.log("refused", "The bundled pondside CLI is missing", level: .error)
            statusBar.flash("Pondside's command-line tool is missing from the app bundle")
            return
        }
        let handle = AgentRun.Handle()
        agentHandle = handle
        // n/total marked lines fixed (read from the patch), then what the
        // agent is doing (from its event stream).
        let total = PatchMigration.allMarks(patch: patch).count
        agentProgress = AgentProgress(label: "\(agent.harness.title) fixing \(patch.lastPathComponent)", total: total)
        showAgentProgress()
        let poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, self.agentHandle === handle else { return }
                let left = PatchMigration.allMarks(patch: patch).count
                if let was = self.agentProgress?.fixed, max(0, total - left) != was {
                    log.log("progress", "\(max(0, total - left))/\(total) marked lines fixed")
                }
                self.agentProgress?.fixed = max(0, total - left)
                self.showAgentProgress()
            }
        }
        let started = Date()
        Task { [weak self] in
            let outcome: AgentRun.Outcome
            let prompt = AgentRun.migrationPrompt(score: scoreURL, patch: patch)
            log.log("prompt", "Migration prompt, \(prompt.count) characters, \(total) marked lines", detail: prompt, limit: AgentLog.promptLimit)
            do {
                outcome = try await agent.run(prompt: prompt, folder: scoreURL.deletingLastPathComponent(), pondside: pondside,
                                              handle: handle, log: log) { words in
                    Task { @MainActor in
                        guard let self, self.agentHandle === handle else { return }
                        self.agentProgress?.doing = words
                        self.showAgentProgress()
                    }
                }
            } catch {
                outcome = AgentRun.Outcome(summary: error.localizedDescription, failed: true, costUSD: nil)
            }
            poll.cancel()
            let left = PatchMigration.allMarks(patch: patch).count
            log.log("outcome", (outcome.failed ? "Failed: " : "") + (outcome.summary.split(separator: "\n").first.map(String.init) ?? "(no reply)")
                        + " · \(left) marked lines left" + String(format: " · %.0f s", log.elapsed)
                        + (outcome.costUSD.map { String(format: " · $%.3f", $0) } ?? ""),
                    level: outcome.failed ? .error : left > 0 ? .warning : .info, detail: outcome.summary)
            guard let self else { return }
            self.agentHandle = nil
            self.agentProgress = nil
            self.agentNote = nil
            self.updateStatus()
            self.score.renderMix()
            self.showAgentResult(agent, outcome, patch: patch, before: before, minutes: Date().timeIntervalSince(started) / 60)
        }
    }

    struct AgentProgress {
        var label: String
        var total: Int
        var fixed = 0
        var doing = "starting"
    }

    /// "Claude Code fixing score.scd: 3/7 · editing...", in the status bar;
    /// without a count for a request ("Claude Code: “taller” · editing...").
    private func showAgentProgress() {
        guard let p = agentProgress else { return }
        let note = p.total > 0 ? "\(p.label): \(p.fixed)/\(p.total) · \(p.doing)..." : "\(p.label) · \(p.doing)..."
        guard note != agentNote else { return }
        agentNote = note
        updateStatus()
    }

    private func showAgentResult(_ agent: AgentRun, _ outcome: AgentRun.Outcome, patch: URL, before: String?, minutes: Double) {
        let marks = PatchMigration.allMarks(patch: patch).count
        let alert = NSAlert()
        alert.messageText = outcome.failed ? "\(agent.harness.title) didn't finish \(patch.lastPathComponent)"
            : marks == 0 ? "\(patch.lastPathComponent) is a Pondside patch" : "\(agent.harness.title) left \(marks) marked lines"
        var info = String(outcome.summary.prefix(1500))
        info += "\n\n" + String(format: "%.0f min", max(1, minutes.rounded()))
        if let cost = outcome.costUSD { info += String(format: " · $%.2f", cost) }
        if marks > 0 { info += " · the rest: \(Self.agentCommand) in the terminal (⌃4)" }
        info += ". The mix is rendering; ⌘⌥P plays it."
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Undo Refactor")
        guard let window else { return }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertSecondButtonReturn else { return }
            do {
                if let before { try Data(before.utf8).write(to: patch, options: .atomic) }
                else { try FileManager.default.removeItem(at: patch) }
                self.score.renderMix()
                self.statusBar.flash("\(patch.lastPathComponent) is back as it was")
            } catch {
                self.statusBar.flash("Couldn't restore \(patch.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    private func confirmStopAgent(_ handle: AgentRun.Handle) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Stop the agent?"
        alert.informativeText = "It is still finishing the patch. What it has changed so far stays; Undo Refactor in the next dialog restores the patch."
        alert.addButton(withTitle: "Stop")
        alert.addButton(withTitle: "Keep Going")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { handle.stop() }
        }
    }

    // MARK: Requests

    /// The request line for the selection: a graphic's own lens, or the
    /// notation lens's other side (⇥ from the lens, ⇥ back).
    private func showRequest(fromLens: Bool) {
        guard let anchor = lensAnchor() else { return }
        // Shown at once: the title is the selected command word, the agent the
        // one found in the background; the full context is built on ↩.
        let text = editor.text
        let sel = selectionUTF8()
        let word = sel.upperBound <= text.utf8.count
            ? String(decoding: Array(text.utf8)[sel.lowerBound..<min(sel.upperBound, sel.lowerBound + 40)], as: UTF8.self) : ""
        let title = word.hasPrefix("\\") ? word : "the selection"
        let agent = Self.agent(UserDefaults.standard.string(forKey: Self.agentKey))
        // ⇥ goes on to the patch agent when the score has a patch, then back to the lens.
        let hasPatch = score.patchURL != nil
        requestPopover.tabLabel = hasPatch ? "patch" : "lens"
        requestPopover.onTab = hasPatch ? { [weak self] in self?.showPatchRequest(fromLens: fromLens) }
            : fromLens ? { [weak self] in self?.showLens(closesOnRender: false) } : nil
        requestPopover.placeholder = nil
        requestPopover.mode = .graphics
        requestPopover.onSwitch = hasPatch ? { [weak self] _ in self?.showPatchRequest(fromLens: fromLens) } : nil
        requestPopover.onSubmit = { [weak self] request in
            guard let self else { return }
            guard let agent = agent ?? AgentRun.choose(preference: UserDefaults.standard.string(forKey: Self.agentKey)) else {
                self.statusBar.flash("No agent: choose one in Settings (⌘,)")
                return
            }
            self.runRequest(request, agent: agent, context: self.rpcContext)
        }
        let turns = requestSession.map { $0.agent.harness == agent?.harness ? $0.turns : 0 } ?? 0
        let who = agent.map { $0.harness.title + (turns > 0 ? " (continuing, ␣ e n new)" : "") } ?? "the agent"
        requestPopover.present(title: title, agent: who, anchor: anchor.rect, in: anchor.view)
    }

    /// The request line for the patch agent: a change to the SuperCollider
    /// patch at the selection's point in the score (its cue).
    private func showPatchRequest(fromLens: Bool) {
        guard let anchor = lensAnchor() else { return }
        guard let patch = score.patchURL else {
            statusBar.flash("This score has no Pondside patch: File › Make Patch Pondside-Ready… (␣ f m)")
            return
        }
        let agent = Self.agent(UserDefaults.standard.string(forKey: Self.agentKey))
        let context = rpcPatchContext(cue: nil)
        let cue = context["cue"]?["name"]?.string
        let title = cue.map { "cue \($0) in \(patch.lastPathComponent)" } ?? patch.lastPathComponent
        requestPopover.tabLabel = "lens"
        requestPopover.onTab = { [weak self] in self?.showLens(closesOnRender: false) }
        requestPopover.mode = .patch
        requestPopover.onSwitch = { [weak self] _ in self?.showRequest(fromLens: fromLens) }
        requestPopover.placeholder = "Describe the electronics here… e.g. more reverb, a grain cloud on this chord"
        requestPopover.onSubmit = { [weak self] request in
            guard let self else { return }
            guard let agent = agent ?? AgentRun.choose(preference: UserDefaults.standard.string(forKey: Self.agentKey)) else {
                self.statusBar.flash("No agent: choose one in Settings (⌘,)")
                return
            }
            self.runPatchRequest(request, agent: agent, patch: patch, context: self.rpcPatchContext(cue: nil))
        }
        let turns = patchSession.map { $0.agent.harness == agent?.harness ? $0.turns : 0 } ?? 0
        let who = agent.map { "patch agent (\($0.harness.title)" + (turns > 0 ? ", continuing, ␣ e N new" : "") + ")" } ?? "the patch agent"
        requestPopover.present(title: title, agent: who, anchor: anchor.rect, in: anchor.view)
    }

    /// `patch_context` at the selection (DESIGN.md §8): the cue there, its
    /// handler, what it touches, the collections, the patch doc.
    func rpcPatchContext(cue: String?) -> JSONValue {
        guard let patch = score.patchURL else { return ["error": "no Pondside patch"] }
        let here = rpcContext
        // The clicked part of a large drawing has its own time; else the event's.
        let moment = (here["selection"]?["at"]?["moment"] ?? here["moment"])?.string.flatMap(Rational.init(parsing:))
        let bar = here["selection"]?["at"]?["bar"]?.int ?? here["bar"]?.int
        let seconds = moment.flatMap { m in score.timingLog.map { TempoMap($0).seconds(at: m) } }
        let point = PatchContext.Point(bar: bar, moment: moment, cue: cue, seconds: seconds)
        return PatchContext.describe(score: score.url, patch: patch, sheet: score.cueSheet, at: point,
                                     collections: score.timingLog.map(PatchContext.collections(in:)) ?? [], scoreContext: here,
                                     lexicon: SCLexicon.load(project: score.url.deletingLastPathComponent()))
    }

    /// The patch's files: what a patch request may change and ⌘Z restores.
    private func patchFiles(_ patch: URL) -> [URL: String] {
        var out: [URL: String] = [:]
        for url in [patch] + PatchMigration.dependencies(of: patch) + [PatchDoc.url(patch: patch)] {
            if let t = try? String(contentsOf: url, encoding: .utf8) { out[url.standardizedFileURL] = t }
        }
        return out
    }

    /// The patch agent carries out a request in the background; the mix
    /// re-renders when it is done, and ⌘Z puts the patch back.
    private func runPatchRequest(_ request: String, agent: AgentRun, patch: URL, context: JSONValue) {
        var agent = agent
        agent.model = agent.harness == .opencode ? Self.opencodeModel : nil
        let log = AgentLog.Run(kind: .patch)
        log.log("request", "“\(request)” · patch agent (\(agent.harness.title)\(agent.model.map { ", \($0)" } ?? "")) · \(patch.lastPathComponent)",
                detail: "score \(score.url.path)\npatch \(patch.path)\nagent \(agent.executable)")
        guard agentHandle == nil, !requestRunning else {
            // One request at a time per score: the two agents never edit at once.
            log.log("refused", "Another agent is still working", level: .warning)
            statusBar.flash("An agent is still working (␣ e k stops it)")
            return
        }
        guard let pondside = Bundle.main.resourceURL?.appendingPathComponent("pondside").path,
              FileManager.default.isExecutableFile(atPath: pondside) else {
            log.log("refused", "The bundled pondside CLI is missing", level: .error)
            statusBar.flash("Pondside's command-line tool is missing from the app bundle")
            return
        }
        if let s = patchSession, s.agent.harness != agent.harness || s.agent.executable != agent.executable || s.agent.model != agent.model {
            s.reset()
            patchSession = nil
        }
        let session = patchSession ?? AgentSession(agent: agent, folder: score.url.deletingLastPathComponent(), pondside: pondside, role: .patch)
        patchSession = session
        patchIdle?.cancel()
        let snapshot = patchFiles(patch)
        let scoreBefore = Dictionary(score.files.map { ($0.url.standardizedFileURL, $0.text) }, uniquingKeysWith: { a, _ in a })
        requestRunning = true
        canvas.beginWork(label: "Patch agent working…")
        let short = request.count > 28 ? String(request.prefix(27)) + "…" : request
        agentProgress = AgentProgress(label: "Patch: “\(short)”", total: 0)
        showAgentProgress()
        let contextText = context.jsonString(pretty: true)
        let prompt = AgentRun.patchPrompt(request: request, context: contextText, score: score.url, patch: patch,
                                          followUp: session.turns > 0)
        log.log("context", "Cue \(context["cue"]?["name"]?.string ?? "none") · \(context["cue"]?["touches"]?.array?.count ?? 0) items it touches",
                detail: contextText)
        log.log("prompt", "\(session.turns > 0 ? "Follow-up" : "First") request, \(prompt.count) characters", detail: prompt, limit: AgentLog.promptLimit)
        Task { [weak self] in
            let outcome = await session.send(prompt, log: log) { words in
                Task { @MainActor in
                    guard let self, self.patchSession === session, self.requestRunning else { return }
                    self.agentProgress?.doing = words
                    self.showAgentProgress()
                }
            }
            guard let self else { return }
            self.requestRunning = false
            self.agentProgress = nil
            self.patchIdle = Task { [weak session] in
                try? await Task.sleep(for: .seconds(30 * 60))
                if !Task.isCancelled { session?.close() }
            }
            let now = self.patchFiles(patch)
            let changed = Set(now.keys.filter { now[$0] != snapshot[$0] && snapshot[$0] != nil })
            // The score is the other agent's: say so if this one touched it.
            let strays = scoreBefore.filter { url, text in (try? String(contentsOf: url, encoding: .utf8)) != text }.keys
            if !strays.isEmpty {
                log.log("files", "The patch agent changed score files too: " + strays.map(\.lastPathComponent).sorted().joined(separator: ", "), level: .warning)
            }
            if !changed.isEmpty {
                self.agentUndo = snapshot.filter { changed.contains($0.key) }
                self.agentAfter = now.filter { changed.contains($0.key) }
                self.registerAgentUndo(on: self.activeFile.undoManager)
            }
            let line = outcome.summary.split(separator: "\n").first.map(String.init) ?? ""
            let cost = outcome.costUSD.map { String(format: "   $%.2f", $0) } ?? ""
            log.log("files", changed.isEmpty ? "No patch file changed" : "Changed " + changed.map(\.lastPathComponent).sorted().joined(separator: ", "),
                    level: changed.isEmpty && !outcome.failed ? .warning : .info)
            log.log("outcome", (outcome.failed ? "Failed: " : "") + (line.isEmpty ? "(no reply)" : line)
                        + String(format: " · %.1f s", log.elapsed) + (outcome.costUSD.map { String(format: " · $%.3f", $0) } ?? ""),
                    level: outcome.failed ? .error : .info, detail: outcome.summary)
            self.canvas.endWork()
            self.updateStatus()
            // The agent's patch_check rendered the mix; render again in case it didn't.
            if !changed.isEmpty { self.score.renderMix() }
            if outcome.providerProblem {
                self.showProviderProblem(agent, outcome.summary, changed: !changed.isEmpty)
                return
            }
            self.statusBar.flash(outcome.failed
                ? "The patch agent didn't finish: \(line.isEmpty ? "no reply" : line)" + (changed.isEmpty ? "" : "   ⌘Z undo") + "   ⌘⌥A log"
                : line + cost + (changed.isEmpty ? "" : "   ⌘Z undo   ⌘⌥P play the mix"))
        }
    }

    /// ␣ e N: the patch agent's next request starts a new conversation (the
    /// patch doc keeps what it knew).
    private func newPatchConversation() {
        AgentLog.Run(kind: .patch).log("reset", "New conversation: the next patch request starts a new session")
        patchSession?.reset()
        patchSession = nil
        statusBar.flash("The patch agent's next request starts a new conversation; its notes are in the patch doc")
    }

    /// The installed agent for `preference`, found once in the background
    /// (it asks the login shell for its PATH) and remembered.
    private static var agentCache: [String: AgentRun?] = [:]
    static func agent(_ preference: String?) -> AgentRun? {
        let key = preference ?? "auto"
        if let known = agentCache[key] { return known }
        Task.detached {
            let found = AgentRun.choose(preference: preference)
            await MainActor.run { agentCache[key] = .some(found) }
        }
        return nil
    }

    /// The agent carries out a request about the selection in the
    /// background; the status bar shows what it is doing, and ␣ e z undoes
    /// its change.
    private func runRequest(_ request: String, agent: AgentRun, context: JSONValue) {
        var agent = agent
        agent.model = agent.harness == .opencode ? Self.opencodeModel : nil
        let log = AgentLog.Run(kind: .graphics)
        log.log("request", "“\(request)” · \(agent.harness.title)\(agent.model.map { " (\($0))" } ?? "") · \(score.url.lastPathComponent)",
                detail: "score \(score.url.path)\nagent \(agent.executable)")
        guard agentHandle == nil, !requestRunning else {
            log.log("refused", "Another agent is still working", level: .warning)
            statusBar.flash("An agent is still working (␣ e k stops it)")
            return
        }
        guard let pondside = Bundle.main.resourceURL?.appendingPathComponent("pondside").path,
              FileManager.default.isExecutableFile(atPath: pondside) else {
            log.log("refused", "The bundled pondside CLI is missing (\(Bundle.main.resourceURL?.path ?? "?"))", level: .error)
            statusBar.flash("Pondside's command-line tool is missing from the app bundle")
            return
        }
        // One conversation per window, kept between requests (the agent
        // compacts it when it grows long); a new one when the agent or
        // opencode's model changed in Settings, or on ␣ e n.
        if let s = requestSession, s.agent.harness != agent.harness || s.agent.executable != agent.executable
            || s.agent.model != agent.model {
            s.reset()
            requestSession = nil
        }
        let session = requestSession ?? AgentSession(agent: agent, folder: score.url.deletingLastPathComponent(), pondside: pondside)
        requestSession = session
        requestIdle?.cancel()
        let snapshot = Dictionary(score.files.map { ($0.url, $0.text) }, uniquingKeysWith: { a, _ in a })
        finishAgentRender()
        requestRunning = true
        canvas.beginWork(label: "\(agent.harness.title) working…")
        let short = request.count > 28 ? String(request.prefix(27)) + "…" : request
        agentProgress = AgentProgress(label: "\(agent.harness.title): “\(short)”", total: 0)
        showAgentProgress()
        let contextText = context.jsonString(pretty: true)
        let prompt = AgentRun.graphicsPrompt(request: request, context: contextText, score: score.url,
                                             followUp: session.turns > 0)
        let graphic = context["graphic"]
        log.log("context", graphic == nil ? "No graphic at the selection: the agent gets the event and staff only"
                    : "Selection: \(graphic?["command"]?.string ?? graphic?["entry"]?.string ?? "a graphic")"
                      + (graphic?["drawing"] == nil ? "" : " with its drawing code"),
                level: graphic == nil ? .warning : .info, detail: contextText)
        log.log("prompt", "\(session.turns > 0 ? "Follow-up" : "First") request, \(prompt.count) characters"
                    + (session.turns > 0 ? " (turn \(session.turns + 1))" : ""), detail: prompt, limit: AgentLog.promptLimit)
        Task { [weak self] in
            let outcome = await session.send(prompt, log: log) { words in
                Task { @MainActor in
                    guard let self, self.requestSession === session, self.requestRunning else { return }
                    self.agentProgress?.doing = words
                    self.showAgentProgress()
                }
            }
            guard let self else { return }
            self.requestRunning = false
            self.agentProgress = nil
            // An idle conversation's process ends after a while; the next request resumes it.
            self.requestIdle = Task { [weak session] in
                try? await Task.sleep(for: .seconds(30 * 60))
                if !Task.isCancelled { session?.close() }
            }
            let changedFiles = Set(snapshot.filter { url, text in (try? String(contentsOf: url, encoding: .utf8)) != text }.keys)
            let changed = !changedFiles.isEmpty
            if changed {
                self.agentUndo = snapshot
                self.agentAfter = changedFiles.reduce(into: [:]) { after, url in
                    if let text = try? String(contentsOf: url, encoding: .utf8) { after[url] = text }
                }
                self.agentChanged = changedFiles.subtracting(self.agentWritesInFlight)
                self.registerAgentUndo(on: self.activeFile.undoManager)
            }
            self.agentWritesInFlight.removeAll()
            let line = outcome.summary.split(separator: "\n").first.map(String.init) ?? ""
            let cost = outcome.costUSD.map { String(format: "   $%.2f", $0) } ?? ""
            log.log("files", changed ? "Changed " + changedFiles.map(\.lastPathComponent).sorted().joined(separator: ", ") : "No file changed",
                    level: changed || outcome.failed ? .info : .warning)
            log.log("outcome", (outcome.failed ? "Failed: " : "") + (line.isEmpty ? "(no reply)" : line)
                        + String(format: " · %.1f s", log.elapsed) + (outcome.costUSD.map { String(format: " · $%.3f", $0) } ?? ""),
                    level: outcome.failed ? .error : .info, detail: outcome.summary)
            // The reply shows once the score shows the change.
            let report: () -> Void = { [weak self] in
                guard let self else { return }
                if outcome.providerProblem {
                    self.showProviderProblem(agent, outcome.summary, changed: changed)
                    return
                }
                // A run that edited the score and then failed (a dropped
                // connection on its last reply) still changed the music.
                self.statusBar.flash(outcome.failed
                    ? "\(agent.harness.title) didn't finish: \(line.isEmpty ? "no reply" : line)" + (changed ? "   it changed files: ⌘Z undo" : "") + "   ⌘⌥A log"
                    : line + cost + (changed ? "   ⌘Z undo" : ""))
            }
            let scoreFiles = Set(self.score.files.map { $0.url.standardizedFileURL })
            let written = changedFiles.filter { scoreFiles.contains($0.standardizedFileURL) }
                .compactMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }.max()
            if let written {
                log.log("render", "Waiting for the app to engrave the change")
                self.awaitAgentRender(written: written, log: log, then: report)
            } else {
                self.canvas.endWork()
                self.agentNote = nil
                self.updateStatus()
                report()
            }
        }
    }

    private func awaitAgentRender(written: Date, log: AgentLog.Run, then done: @escaping () -> Void) {
        agentRender = (written, { [weak self] in
            if let self { log.log("render", String(format: "Engraved · %.1f s", log.elapsed), detail: "\(self.score.status)") }
            done()
        })
        agentNote = "Engraving the change..."
        updateStatus()
        // The watcher polls; don't wait for its next tick.
        score.revalidate()
        agentRenderTimeout?.cancel()
        agentRenderTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, let wait = self.agentRender else { return }
            // Nothing picked the change up: engrave it now.
            if (self.score.compileStarted ?? .distantPast) < wait.written, self.score.status != .compiling {
                self.score.engrave()
            }
            try? await Task.sleep(for: .seconds(115))
            guard !Task.isCancelled else { return }
            log.log("render", "No engraving of the change within 2 minutes", level: .warning)
            self.finishAgentRender()
        }
        checkAgentRender()
    }

    /// Ends the wait once the pages on screen come from the agent's files.
    private func checkAgentRender() {
        guard let wait = agentRender, let started = score.compileStarted,
              started >= wait.written, score.status != .compiling else { return }
        finishAgentRender()
    }

    private func finishAgentRender() {
        guard let wait = agentRender else { return }
        agentRender = nil
        agentRenderTimeout?.cancel()
        agentRenderTimeout = nil
        canvas.endWork()
        agentNote = nil
        updateStatus()
        wait.done()
    }

    /// ␣ e n: the next request starts a new conversation.
    private func newAgentConversation() {
        AgentLog.Run(kind: .graphics).log("reset", "New conversation: the next request starts a new session")
        requestSession?.reset()
        requestSession = nil
        statusBar.flash("The next request starts a new conversation")
    }

    /// One undo step for the agent's whole request, on the active file's
    /// stack, so ⌘Z works like any other edit even when the agent changed
    /// another file. Switching files moves it along.
    private func registerAgentUndo(on manager: UndoManager) {
        guard agentUndo != nil else { return }
        if let old = agentUndoCookie { agentUndoManager?.removeAllActions(withTarget: old) }
        let cookie = AgentUndoCookie(self)
        agentUndoCookie = cookie
        agentUndoManager = manager
        manager.registerUndo(withTarget: cookie) { cookie in
            MainActor.assumeIsolated { cookie.controller?.undoAgentChange(fromUndoManager: true) }
        }
        manager.setActionName("Agent Change")
    }

    private func moveAgentUndo(to manager: UndoManager) {
        guard agentUndo != nil, agentUndoManager !== manager else { return }
        registerAgentUndo(on: manager)
    }

    /// Puts back the files the agent's last request changed. Files changed
    /// since (by the user or another program) are left alone.
    private func undoAgentChange(fromUndoManager: Bool = false) {
        guard let snapshot = agentUndo else { statusBar.flash("No agent change to undo"); return }
        let after = agentAfter
        var restored = 0
        var kept = 0
        var restoredURLs = Set<URL>()
        for (url, text) in snapshot where after[url] != nil {
            let current = try? String(contentsOf: url, encoding: .utf8)
            guard current != text else { continue }
            if let current, let expected = after[url], current != expected {
                // Someone edited it after the agent: don't overwrite that.
                kept += 1
                continue
            }
            if (try? Data(text.utf8).write(to: url, options: .atomic)) != nil {
                restored += 1
                restoredURLs.insert(url)
            }
        }
        // The reloads these writes cause are part of this undo, not new edits.
        agentChanged = restoredURLs
        if !fromUndoManager, let cookie = agentUndoCookie {
            agentUndoManager?.removeAllActions(withTarget: cookie)
        }
        agentUndoCookie = nil
        agentUndoManager = nil
        agentUndo = nil
        agentAfter = [:]
        AgentLog.Run(kind: .graphics, id: "user").log("undo",
            "Undid the agent's last change: \(restored) file\(restored == 1 ? "" : "s") restored"
            + (kept > 0 ? ", \(kept) changed since and kept" : ""))
        statusBar.flash(restored == 0
            ? (kept > 0 ? "The agent's files changed since; left as they are" : "Nothing to undo")
            : "Undid the agent's change (\(restored) file\(restored == 1 ? "" : "s")"
              + (kept > 0 ? "; \(kept) changed since, kept" : "") + ")")
    }

    /// The Lexicon pane's "Insert over Selection": the graphic from the
    /// first selected event to the last, its include wired into the root.
    private func insertGraphic(_ entry: LexiconEntry) {
        let events = targets().events
        guard let first = events.min(), let last = events.max(), last > first else {
            statusBar.flash("Select the notes or skips the graphic should span (at least two)")
            NSSound.beep()
            return
        }
        let text = editor.text
        let start = ScoreContext.lineAndCharacter(of: tree.events[first].range.lowerBound, in: text)
        let stop = ScoreContext.lineAndCharacter(of: tree.events[last].range.lowerBound, in: text)
        do {
            let new = try GraphicEdit.insert(into: text, id: entry.id, params: "()", start: start, stop: stop)
            applyText(EngravingSettingsDocument.span(from: Array(text.utf8), to: Array(new.utf8)), to: activeFile,
                      name: "Insert \(entry.id)")
            let lex = Lexicon.load(Lexicon.standardScopes(project: score.url.deletingLastPathComponent()))
            let used = Set(score.files.flatMap { LexiconUse.find(in: $0.text).map(\.id) })
            try Data(lex.includeFile(for: used).utf8).write(to: score.url.deletingLastPathComponent().appendingPathComponent("lexicon.ily"), options: .atomic)
            let root = score.root.text
            if !root.contains("\\include \"lexicon.ily\"") {
                let withInclude = GraphicEdit.withLexiconInclude(root)
                applyText(EngravingSettingsDocument.span(from: Array(root.utf8), to: Array(withInclude.utf8)), to: score.root,
                          name: "Include the Lexicon")
            }
            statusBar.flash("Inserted \(entry.id); its params are in the source")
        } catch {
            statusBar.flash("\(error)")
            NSSound.beep()
        }
    }

    // MARK: Add… pickers

    /// A picker of presets that also takes what was typed, when `custom`
    /// can make a value of it ("7/8", "4 = 96", any words).
    private func showEntryPicker(placeholder: String, presets: [(title: String, value: String, detail: String?)],
                                 custom: @escaping (String) -> String?, choose: @escaping (String) -> Void) {
        guard let window else { return }
        let values = Box<[String]>([])
        let panel = PalettePanel(placeholder: placeholder, provider: { query in
            var rows: [PaletteRow] = []
            var chosen: [String] = []
            let typed = query.trimmingCharacters(in: .whitespaces)
            if !typed.isEmpty, let value = custom(typed), !presets.contains(where: { $0.value == value }) {
                rows.append(PaletteRow(title: "Use “\(typed)”", detail: value, matched: []))
                chosen.append(value)
            }
            let scored = presets.enumerated().compactMap { i, p -> (index: Int, score: Int, positions: [Int])? in
                if typed.isEmpty { return (i, 0, []) }
                return FuzzyMatch.match(typed, in: p.title).map { (i, $0.score, $0.positions) }
            }.sorted { $0.score > $1.score || ($0.score == $1.score && $0.index < $1.index) }
            for (i, _, positions) in scored {
                rows.append(PaletteRow(title: presets[i].title, detail: presets[i].detail, matched: positions))
                chosen.append(presets[i].value)
            }
            values.value = chosen
            return rows
        }, onChoose: { i in
            guard values.value.indices.contains(i) else { return }
            choose(values.value[i])
        })
        panel.present(over: window)
    }

    private func applyCommand(_ command: String, events: [Int], name: String) {
        guard let first = events.min(), let edit = ScoreEditor(tree).insertCommand(command, before: first, name: name) else {
            NSSound.beep()
            return
        }
        apply(edit)
    }

    private func showTupletPicker(events: [Int]) {
        let presets: [(String, String, String?)] = [
            ("Triplet", "3/2", "3 in the time of 2"), ("Quintuplet", "5/4", "5 in the time of 4"),
            ("Sextuplet", "6/4", "6 in the time of 4"), ("Septuplet", "7/8", "7 in the time of 8"),
            ("Septuplet in 4", "7/4", "7 in the time of 4"), ("Duplet", "2/3", "2 in the time of 3"),
            ("Quadruplet", "4/3", "4 in the time of 3"),
        ]
        showEntryPicker(placeholder: "Tuplet — or type a ratio, e.g. 9/8", presets: presets.map { ($0.0, $0.1, $0.2) },
                        custom: Self.ratio) { [weak self] value in
            guard let self else { return }
            let parts = value.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 2, let edit = ScoreEditor(self.tree).wrapTuplet(events: events, numerator: parts[0], denominator: parts[1]) else {
                self.statusBar.flash("A tuplet needs a selection inside one { } block")
                NSSound.beep()
                return
            }
            self.apply(edit)
        }
    }

    private static func ratio(_ text: String) -> String? {
        let parts = text.replacingOccurrences(of: ":", with: "/").split(separator: "/")
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let a = Int(parts[0]), let b = Int(parts[1]), a > 0, b > 0, a < 100, b < 100 else { return nil }
        return "\(a)/\(b)"
    }

    private func showClefPicker(events: [Int]) {
        let clefs: [(String, String)] = [
            ("treble", "Treble"), ("bass", "Bass"), ("alto", "Alto"), ("tenor", "Tenor"),
            ("treble_8", "Treble 8vb (tenor voice, guitar)"), ("treble^8", "Treble 8va (piccolo)"),
            ("bass_8", "Bass 8vb (double bass)"), ("soprano", "Soprano"), ("mezzosoprano", "Mezzo-soprano"),
            ("baritone", "Baritone"), ("percussion", "Percussion"),
        ]
        showEntryPicker(placeholder: "Clef", presets: clefs.map { ($0.1, $0.0, "\\clef \($0.0)") },
                        custom: { LensClef.named($0) != nil ? $0 : nil }) { [weak self] name in
            let spelled = name.contains("_") || name.contains("^") ? "\"\(name)\"" : name
            self?.applyCommand("\\clef \(spelled)", events: events, name: "Clef")
        }
    }

    private func showTimePicker(events: [Int]) {
        let meters = ["4/4", "3/4", "2/4", "2/2", "6/8", "9/8", "12/8", "3/8", "5/4", "5/8", "7/8", "6/4"]
        showEntryPicker(placeholder: "Time signature — or type one, e.g. 11/8", presets: meters.map { ($0, $0, nil) },
                        custom: Self.ratio) { [weak self] meter in
            self?.applyCommand("\\time \(meter)", events: events, name: "Time Signature")
        }
    }

    private func showKeyPicker(events: [Int]) {
        let language = activeFile.entryLanguage
        // Circle of fifths: tonic step and alteration (quarter tones), major then minor.
        let majors: [(Int, Int)] = [(0, 0), (4, 0), (1, 0), (5, 0), (2, 0), (6, 0), (3, 2), (0, 2),
                                    (3, 0), (6, -2), (2, -2), (5, -2), (1, -2), (4, -2), (0, -2)]
        let minors: [(Int, Int)] = [(5, 0), (2, 0), (6, 0), (3, 2), (0, 2), (4, 2), (1, 2), (5, 2),
                                    (1, 0), (4, 0), (0, 0), (3, 0), (6, -2), (2, -2), (5, -2)]
        func label(_ step: Int, _ alteration: Int, _ mode: String) -> String {
            let letter = ["C", "D", "E", "F", "G", "A", "B"][step]
            return letter + (alteration > 0 ? "♯" : alteration < 0 ? "♭" : "") + " " + mode
        }
        let presets = majors.map { (label($0.0, $0.1, "major"), language.spell(step: $0.0, alteration: $0.1) + " \\major", nil as String?) }
            + minors.map { (label($0.0, $0.1, "minor"), language.spell(step: $0.0, alteration: $0.1) + " \\minor", nil as String?) }
        showEntryPicker(placeholder: "Key signature", presets: presets, custom: { _ in nil }) { [weak self] key in
            self?.applyCommand("\\key \(key)", events: events, name: "Key Signature")
        }
    }

    private func showTempoPicker(events: [Int]) {
        let presets: [(String, String, String?)] = [
            "Adagio", "Andante", "Moderato", "Allegro", "Presto",
        ].map { ($0, "\"\($0)\"", nil) } + ["4 = 60", "4 = 90", "4 = 120", "4. = 60", "2 = 60"].map { ($0, $0, nil) }
        showEntryPicker(placeholder: "Tempo — words, 4 = 96, or both: Allegro 4 = 132", presets: presets,
                        custom: Self.tempo) { [weak self] tempo in
            self?.applyCommand("\\tempo \(tempo)", events: events, name: "Tempo")
        }
    }

    /// "Allegro 4 = 132" → `"Allegro" 4 = 132`; "4. = 60" and "Allegro" alone too.
    private static func tempo(_ text: String) -> String? {
        let words = text.split(separator: " ").map(String.init)
        if let eq = words.firstIndex(of: "="), eq > 0, eq + 1 < words.count,
           let unit = words[eq - 1].first, unit.isNumber, Int(words[eq + 1]) != nil {
            let mark = words[(eq - 1)...].joined(separator: " ")
            let label = words[..<(eq - 1)].joined(separator: " ")
            return label.isEmpty ? mark : "\"\(escaped(label))\" \(mark)"
        }
        return "\"\(escaped(text))\""
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private func showTextPicker(events: [Int]) {
        let words = ["dolce", "espressivo", "cantabile", "legato", "leggiero", "sul pont.", "sul tasto", "pizz.", "arco",
                     "rit.", "accel.", "a tempo", "poco a poco"]
        showEntryPicker(placeholder: "Text above the note — or type any words", presets: words.map { ($0, $0, nil) },
                        custom: { $0 }) { [weak self] text in
            guard let self else { return }
            let pitched = events.filter { self.tree.events[$0].acceptsNoteEntry }
            self.apply(ScoreEditor(self.tree).togglePostEvent("^\\markup \\italic \"\(Self.escaped(text))\"", events: Array(pitched.prefix(1))))
        }
    }

    /// The next cue number on the selection, if the score defines `\ecue`.
    private func addCue(events: [Int]) {
        let texts = score.files.map(\.text)
        guard texts.contains(where: { $0.contains("ecue =") || $0.contains("ecue=") }) else {
            statusBar.flash("Cues need \\ecue, from the electronics staff library (lilypond-electronics-staff)")
            NSSound.beep()
            return
        }
        var highest = 0
        for text in texts {
            var rest = Substring(text)
            while let r = rest.range(of: "\\ecue \"") {
                rest = rest[r.upperBound...]
                if let n = Int(rest.prefix { $0.isNumber }) { highest = max(highest, n) }
            }
        }
        guard let first = events.min() else { return }
        apply(ScoreEditor(tree).togglePostEvent("\\ecue \"\(highest + 1)\"", events: [first]))
        statusBar.flash("Cue \(highest + 1)")
    }

    private func showDynamicPicker(events: [Int]) {
        showPicker(placeholder: "Dynamic", choices: Self.dynamics.map { (title: "\\" + $0, detail: nil as String?) }) { [weak self] i in
            guard let self else { return }
            self.apply(ScoreEditor(self.tree).togglePostEvent("\\" + Self.dynamics[i], events: events))
        }
    }

    private func goToError() {
        let errors = score.files.flatMap { f in
            f.diagnostics.filter { $0.severity == .error || $0.severity == .fatal }.map { (file: f, diagnostic: $0) }
        }
        guard !errors.isEmpty else { return }
        let caret = editor.textView.selectedRange().location
        // The next error after the caret in this file, else the first elsewhere.
        let here = errors.filter { $0.file === activeFile }
            .compactMap { e in Self.location(of: e.diagnostic, in: e.file).map { (e, $0) } }
            .sorted { $0.1 < $1.1 }
        let target = here.first { $0.1 > caret }?.0 ?? errors.first { $0.file !== activeFile } ?? here.first?.0 ?? errors[0]
        if target.file !== activeFile { showFile(target.file) }
        guard let loc = Self.location(of: target.diagnostic, in: target.file) else { return }
        window?.makeFirstResponder(editor.textView)
        editor.select(NSRange(location: loc, length: 0))
        statusBar.flash(target.diagnostic.message)
    }

    /// Where a diagnostic points in the file's current text (UTF-16).
    private static func location(of d: Diagnostic, in f: SourceFile) -> Int? {
        let engraved = f.compiledText ?? f.text
        let source = SourceText(engraved)
        guard let p = d.position(in: source), let i = source.index(of: p) else { return nil }
        return EngravingMap(engraved: engraved, current: f.text).currentOffset(forEngraved: source.utf16Offset(of: i))
    }

    // MARK: Panes

    private static let layoutKey = "Pondside.layout"
    private static let workspacesKey = "Pondside.workspaces"
    /// Content that exists today; the rest shows a placeholder naming its milestone.
    private static let builtContent: [PaneContent] = [.score, .lilypond, .compilerOutput, .terminal, .supercollider, .cues, .lexicon, .agentLog]

    private static func savedLayout() -> PaneLayout {
        if let data = UserDefaults.standard.data(forKey: layoutKey),
           let layout = try? JSONDecoder().decode(PaneLayout.self, from: data), !layout.contents.isEmpty {
            return layout
        }
        return PaneLayout.presets[0]
    }

    private func saveLayout() {
        panes.captureFractions()
        if let data = try? JSONEncoder().encode(panes.layout) { UserDefaults.standard.set(data, forKey: Self.layoutKey) }
    }

    private func makeContent(_ content: PaneContent) -> NSView {
        switch content {
        case .score: return canvasScroll
        case .lilypond: return editorPane
        case .compilerOutput:
            compilerOutput.show(score.lastLog)
            return compilerOutput
        case .terminal: return TerminalPane(directory: score.url.deletingLastPathComponent())
        case .supercollider: return makeSuperColliderPane()
        case .lexicon:
            lexiconBrowser.model.installation = score.installation
            lexiconBrowser.model.reload()
            return lexiconBrowser
        case .agentLog: return agentLogView
        case .cues:
            cueInspector.onJump = { [weak self] cue in self?.reveal(cue) }
            cueInspector.show(score.cueSheet, scoreFolder: score.url.deletingLastPathComponent())
            return cueInspector
        default: return PanePlaceholder(content)
        }
    }

    private func responder(for content: PaneContent) -> NSView {
        switch content {
        case .score: return canvas
        case .lilypond: return editor.textView
        case .cues: return cueInspector.responder
        case .agentLog: return agentLogView.responder
        case .supercollider: return (panes.view(for: .supercollider) as? SuperColliderPane)?.responder ?? panes.view(for: content)
        case .terminal: return (panes.view(for: .terminal) as? TerminalPane)?.responder ?? panes.view(for: .terminal)
        default: return panes.view(for: content)
        }
    }

    private func syncFocusedPane() {
        if let i = panes.paneIndex(containing: window?.firstResponder as? NSView) { panes.setFocused(i) }
    }

    private func focusPane(_ i: Int) {
        panes.setFocused(i)
        if let c = panes.layout.focusedContent { window?.makeFirstResponder(responder(for: c)) }
    }

    private func applyLayout(_ layout: PaneLayout) {
        panes.apply(layout)
        focusPane(layout.focused)
        saveLayout()
    }

    private func cyclePane(forward: Bool) {
        syncFocusedPane()
        var l = panes.layout
        l.cycle(forward: forward, available: Self.builtContent)
        applyLayout(l)
        if let c = l.focusedContent { statusBar.flash("\(c.title) · ⌃⇥ next, ⌃1–⌃0 jump") }
    }

    /// ⌘⌥A: the Agent Log in a pane of its own beside the others, or closes
    /// it. The keyboard stays where it was (HIG: don't move focus without
    /// the user's interaction); ⌘J reaches the log.
    private func toggleAgentLog() {
        syncFocusedPane()
        var l = panes.layout
        let showing = l.contents.contains(.agentLog)
        if showing, l.contents.count == 1 {
            statusBar.flash("The Agent Log is the only pane: ⌃⇥ shows something else")
            return
        }
        l.toggle(.agentLog)
        panes.apply(l)
        saveLayout()
        if !showing { statusBar.flash("Agent Log · ⌘⌥A hides it · in the log: d details, v verbose, f filter") }
    }

    private func showInFocusedPane(_ content: PaneContent) {
        syncFocusedPane()
        var l = panes.layout
        l.show(content)
        applyLayout(l)
    }

    private func loadWorkspaces() -> Workspaces {
        guard let data = UserDefaults.standard.data(forKey: Self.workspacesKey),
              let w = try? JSONDecoder().decode(Workspaces.self, from: data) else { return Workspaces() }
        return w
    }

    private func saveWorkspace() {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Save Workspace"
        alert.informativeText = "Name this arrangement of panes. Open it again with ␣ w o."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "Orchestration"
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .alertFirstButtonReturn else { return }
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return }
            self.panes.captureFractions()
            var w = self.loadWorkspaces()
            w.save(self.panes.layout, as: name)
            if let data = try? JSONEncoder().encode(w) { UserDefaults.standard.set(data, forKey: Self.workspacesKey) }
            self.statusBar.flash("Saved workspace “\(name)”")
        }
    }

    private func showWorkspacePicker() {
        let saved = loadWorkspaces().saved
        let all = PaneLayout.presets + saved
        showPicker(placeholder: "Open workspace", choices: all.map { l in
            (title: l.name, detail: l.contents.map(\.title).joined(separator: " · ") as String?)
        }) { [weak self] i in
            guard all.indices.contains(i) else { return }
            self?.applyLayout(all[i])
        }
    }

    // MARK: SuperCollider

    private func makeSuperColliderPane() -> SuperColliderPane {
        let pane = SuperColliderPane(score: score.url, cues: score.cueSheet)
        pane.flash = { [weak self] message in self?.statusBar.flash(message) }
        help.register(pane.bootButton, "sc.boot")
        help.register(pane.stopButton, "sc.stop")
        help.register(pane.ideButton, "sc.openInIDE")
        pane.openInIDE = { [weak self] in self?.openInSuperColliderIDE() }
        scPane = pane
        return pane
    }

    /// Starts the interpreter for commands run before the pane is shown.
    private func ensureSuperCollider() {
        if scPane == nil { SCLangHost.shared.start(near: score.url) }
    }

    func flushSuperCollider() { scPane?.flushSave() }

    /// The SuperCollider file in the pane (else the patch) in the SuperCollider
    /// IDE, by launching the IDE itself: while Pondside's own sclang runs,
    /// macOS takes it for SuperCollider.app and a double-clicked .scd fails
    /// ("cannot open files in the Plain Text format").
    private func openInSuperColliderIDE() {
        flushSuperCollider()
        let config = try? ProjectConfig.find(from: score.url)
        guard let file = scPane?.fileURL ?? score.patchURL ?? config?.handlers
                ?? Optional(PatchMigration.patchURL(score: score.url)),
              FileManager.default.fileExists(atPath: file.path) else {
            statusBar.flash("No SuperCollider file to open")
            return
        }
        guard let sclang = SuperColliderToolchain.findSclang(configured: config?.sclang?.path),
              let ide = SuperColliderToolchain.ide(forSclang: sclang) else {
            statusBar.flash("SuperCollider's IDE isn't installed")
            return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: ide)
        p.arguments = [file.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            statusBar.flash("Opening \(file.lastPathComponent) in the SuperCollider IDE")
        } catch {
            statusBar.flash("Couldn't start the SuperCollider IDE: \(error.localizedDescription)")
        }
    }

    private func showSuperColliderFilePicker() {
        let files = SuperColliderPane.scdFiles(near: score.url)
        let folder = score.url.deletingLastPathComponent().path + "/"
        var choices = files.map { (title: $0.path.hasPrefix(folder) ? String($0.path.dropFirst(folder.count)) : $0.lastPathComponent,
                                   detail: nil as String?) }
        choices.append((title: "New File…", detail: "Name a new .scd beside the score"))
        showPicker(placeholder: "Open SuperCollider file", choices: choices) { [weak self] i in
            guard let self else { return }
            self.showInFocusedPane(.supercollider)
            guard let pane = self.scPane else { return }
            if files.indices.contains(i) { pane.open(files[i]) } else { pane.chooseFile(creating: true) }
        }
    }
}

// MARK: - Score Setup

extension DocumentWindowController {
    /// The included `front-matter.ily` beside the root, once the score has one.
    private var frontMatterFile: SourceFile? {
        let url = score.url.deletingLastPathComponent().appendingPathComponent(FrontMatter.fileName).standardizedFileURL
        return score.files.first { $0.url.standardizedFileURL == url }
    }

    private var frontMatterURL: URL {
        score.url.deletingLastPathComponent().appendingPathComponent(FrontMatter.fileName)
    }

    private var staffSetup: StaffSetup { StaffSetup(files: score.files.map(\.text)) }

    func showScoreSetup() {
        let panel = scoreSetupPanel ?? makeScoreSetupPanel()
        scoreSetupPanel = panel
        refreshScoreSetup(force: true)
        panel.orderFront(nil)
    }

    private func makeScoreSetupPanel() -> ScoreSetupPanel {
        let panel = ScoreSetupPanel()
        let model = panel.model
        model.onStaffChange = { [weak self] index, change in
            guard let self else { return }
            let setup = self.staffSetup
            let label = setup.staves.indices.contains(index) ? setup.staves[index].label : "Staff"
            for (file, edits) in setup.edits(staff: index, change).sorted(by: { $0.key < $1.key }) where self.score.files.indices.contains(file) {
                self.applyText(edits, to: self.score.files[file], name: "Set Up \(label)")
            }
            self.refreshScoreSetup()
        }
        model.onShowStaff = { [weak self] index in
            guard let self else { return }
            let staves = self.staffSetup.staves
            guard staves.indices.contains(index), self.score.files.indices.contains(staves[index].file) else { return }
            let staff = staves[index]
            let file = self.score.files[staff.file]
            if file !== self.activeFile { self.showFile(file) }
            self.setSelection(utf8: staff.offset..<staff.offset)
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.makeFirstResponder(self.editor.textView)
        }
        model.onHeader = { [weak self] key, value in
            guard let self else { return }
            let doc = EngravingSettingsDocument(root: self.score.root.text,
                                                others: self.score.files.dropFirst().map { (file: $0.displayName, text: $0.text) })
            let label = FrontMatter.headerFields.first { $0.key == key }?.label ?? key
            self.applyText(doc.edits(headerField: key, to: value), to: self.score.root, name: "Set \(label)")
            self.refreshScoreSetup()
        }
        model.onSection = { [weak self] section, on in
            self?.editFrontMatter(name: on ? "Add \(section.title)" : "Remove \(section.title)", creating: on ? [section] : nil) {
                $0.edits(section: section, enabled: on)
            }
        }
        model.onHeading = { [weak self] section, text in
            self?.editFrontMatter(name: "Set \(section.title) Heading") { $0.edits(heading: section, to: text) }
        }
        model.onParagraphs = { [weak self] paragraphs in
            self?.editFrontMatter(name: "Edit Notes") { $0.edits(paragraphs: paragraphs) }
        }
        model.onAddLegend = { [weak self] items in
            self?.editFrontMatter(name: "Add to Legend", creating: [.legend]) { fm in
                let present = Set(fm.legendItems.map(\.id))
                return fm.edits(adding: items.filter { !present.contains($0.id) })
            }
        }
        model.onAddSymbol = { [weak self] in
            guard let self else { return }
            let taken = Set(FrontMatter(self.frontMatterFile?.text ?? "").legendItems.map(\.id))
            let id = (1...).lazy.map { "symbol-\($0)" }.first { !taken.contains($0) }!
            let item = FrontMatter.NewLegendItem(id: id, title: "New symbol", text: "What it asks of the performer.",
                                                 example: "\\null % notation: \\score { \\new Staff { c''1 } \\layout { indent = 0 line-width = 40\\mm } }")
            self.editFrontMatter(name: "Add to Legend", creating: [.legend]) { $0.edits(adding: [item]) }
        }
        model.onRemoveLegend = { [weak self] id in
            self?.editFrontMatter(name: "Remove from Legend") { $0.edits(removingLegend: id) }
        }
        model.onEditLegend = { [weak self] id, title, text in
            self?.editFrontMatter(name: "Edit Legend") { $0.edits(legend: id, title: title, text: text) }
        }
        model.onArrangeLegend = { [weak self] on in self?.arrangeLegend(on) }
        model.onShowFrontMatter = { [weak self] section in
            guard let self else { return }
            if section == .cover {
                // The cover's words are the root's \header.
                let root = self.score.root.text
                let offset = root.range(of: "\\header").map { root.utf8.distance(from: root.startIndex, to: $0.lowerBound) } ?? 0
                if self.activeFile !== self.score.root { self.showFile(self.score.root) }
                self.setSelection(utf8: offset..<offset)
            } else if let file = self.frontMatterFile {
                if file !== self.activeFile { self.showFile(file) }
                let offset = section.flatMap { FrontMatter(file.text).range(of: $0)?.lowerBound } ?? 0
                self.setSelection(utf8: offset..<offset)
            }
            self.window?.makeKeyAndOrderFront(nil)
            self.window?.makeFirstResponder(self.editor.textView)
        }
        if let frame = window?.frame, !panel.setFrameUsingName("Pondside.scoreSetup") {
            panel.setFrameTopLeftPoint(NSPoint(x: frame.maxX - panel.frame.width - 24, y: frame.maxY - 64))
        }
        return panel
    }

    /// Edits `front-matter.ily` as one undoable change in that file. A score
    /// without one gets it (with `creating`'s sections) and the include
    /// before its first `\score`; nothing happens if `creating` is nil.
    private func editFrontMatter(name: String, creating: Set<FrontMatter.Section>? = nil,
                                 _ change: (FrontMatter) -> [TextEdit]) {
        if let file = frontMatterFile {
            applyText(change(FrontMatter(file.text)), to: file, name: name)
        } else if let creating {
            // A file of that name the score doesn't include yet is the user's: build on it.
            let existing = (try? String(contentsOf: frontMatterURL, encoding: .utf8)).map(FrontMatter.init)
            var fm = existing ?? FrontMatter(FrontMatter.template(creating))
            for section in creating where !fm.sections.contains(section) {
                fm = FrontMatter(fm.edits(section: section, enabled: true).apply(to: fm.text))
            }
            fm = FrontMatter(change(fm).apply(to: fm.text))
            do {
                try Data(fm.text.utf8).write(to: frontMatterURL, options: .atomic)
            } catch {
                statusBar.flash("Can't write \(FrontMatter.fileName): \(error.localizedDescription)")
                NSSound.beep()
                return
            }
            if let include = FrontMatter.includeEdit(root: score.root.text) {
                applyText([include], to: score.root, name: "Include \(FrontMatter.fileName)")
            }
            statusBar.flash("Wrote \(FrontMatter.fileName); \(score.root.displayName) includes it before the score")
        }
        refreshScoreSetup()
    }

    /// Arrange mode for the legend (␣ f a, Score Setup › Legend). A file
    /// written before the legend could be arranged gets its layout and
    /// current definitions first, so the engraving carries the markers.
    func arrangeLegend(_ on: Bool) {
        guard on else {
            canvas.legendArranging = false
            scoreSetupPanel?.model.arrangingLegend = false
            updateHints()
            statusBar.flash("Done arranging the legend")
            return
        }
        guard let file = frontMatterFile, FrontMatter(file.text).sections.contains(.legend) else {
            statusBar.flash("No legend yet: Score Setup (⌘⇧U) › Legend adds one")
            return
        }
        let fm = FrontMatter(file.text)
        if fm.legendLayout == nil || !fm.upgradeEdits.isEmpty {
            editFrontMatter(name: "Arrange Legend") { fm in
                fm.legendLayout == nil ? fm.edits(legendLayout: .init()) : fm.upgradeEdits
            }
        }
        canvas.legendArranging = true
        scoreSetupPanel?.model.arrangingLegend = true
        canvas.revealLegend()
        updateHints()
        window?.makeFirstResponder(canvas)
        statusBar.flash("Arranging the legend: drag the table, a column edge or a row gap; an example's edges crop it, "
                        + "its corner scales it (⌥ all). ⌘ while dragging: no snapping. ⎋ done")
    }

    /// Writes a finished legend drag as one undoable edit.
    private func commitLegend(_ outcome: LegendArrangement.Outcome) {
        editFrontMatter(name: "Arrange Legend") { fm in
            var text = fm.edits(legendLayout: outcome.layout).apply(to: fm.text)
            if let (row, layout) = outcome.example {
                let next = FrontMatter(text)
                let items = next.legendItems
                if items.indices.contains(row) {
                    text = next.edits(legend: items[row].id, example: layout).apply(to: text)
                }
            }
            return EngravingSettingsDocument.span(from: Array(fm.text.utf8), to: Array(text.utf8))
        }
    }

    func refreshScoreSetup(force: Bool = false) {
        guard let panel = scoreSetupPanel, force || panel.isVisible else { return }
        let model = panel.model
        let setup = staffSetup
        model.staves = setup.staves
        model.fileNames = score.files.map(\.displayName)
        model.rootName = score.root.displayName
        let doc = EngravingSettingsDocument(root: score.root.text,
                                            others: score.files.dropFirst().map { (file: $0.displayName, text: $0.text) })
        model.header = Dictionary(uniqueKeysWithValues: FrontMatter.headerFields.map { ($0.key, doc.headerField($0.key)) })
        let fm = FrontMatter(frontMatterFile?.text ?? "")
        model.sections = fm.sections
        model.notesHeading = fm.heading(.notes)?.value ?? ""
        model.paragraphs = fm.sections.contains(.notes) ? fm.paragraphs?.values : []
        model.legendHeading = fm.heading(.legend)?.value ?? ""
        model.legendItems = fm.legendItems
        // What the instrumental music uses: Lexicon entries, then the score's own symbols.
        let front = frontMatterFile
        let music = score.files.filter { $0 !== front }
        let lex = Lexicon.load(Lexicon.standardScopes(project: score.url.deletingLastPathComponent()))
        var seen = Set<String>()
        var candidates: [ScoreSetupModel.Candidate] = []
        for use in music.flatMap({ LexiconUse.find(in: $0.text) }) where seen.insert(use.id).inserted {
            guard let entry = lex.entries[use.id]?.entry else { continue }
            let item = entry.legendItem
            candidates.append(.init(id: use.id, title: item.title, detail: "Lexicon entry \(use.id)", printed: true, item: item))
        }
        let names = music.map(\.displayName)
        for c in LegendScan.candidates(files: music.map(\.text)) where seen.insert(c.id).inserted {
            let place = names.indices.contains(c.file) ? "\(names[c.file]):\(c.line)" : ""
            candidates.append(.init(id: c.id, title: c.title, detail: "\(c.invocation) · \(c.staff) · \(place) · \(c.uses)×",
                                    printed: c.printed, item: c.legendItem))
        }
        model.candidates = candidates
    }
}

// MARK: - Stopping the agent

extension DocumentWindowController {
    /// An agent is carrying out a lens request or finishing a patch migration.
    var agentWorking: Bool { agentHandle != nil || requestRunning }

    /// Cancels whatever the agent is doing (⌘⌥., ␣ e k, the status bar's
    /// Stop). A lens request is interrupted and its conversation kept, so
    /// the next request resumes it; a patch migration's process is ended.
    /// Files it already changed stay changed: ␣ e z puts them back.
    func stopAgent() {
        if let h = agentHandle {
            AgentLog.Run(kind: .refactor, id: "user").log("stop", "Stopped by the user", level: .warning)
            h.stop()
            statusBar.flash("Stopping the agent… (␣ e z undoes what it changed)")
        } else if requestRunning {
            AgentLog.Run(kind: .graphics, id: "user").log("stop", "Stopped by the user", level: .warning)
            requestSession?.interrupt()
            patchSession?.interrupt()
            statusBar.flash("Stopping the agent… (␣ e z undoes what it changed)")
        } else {
            statusBar.flash("No agent is working")
        }
    }
}

// MARK: - Provider problems

extension DocumentWindowController {
    /// The model's provider refused the request (a usage limit, no credit,
    /// a bad key) or went quiet. HIG Alerts: the user must act, so it is an
    /// alert on the window, not a flash in the status bar, with the action
    /// that fixes it most often: choosing another model.
    func showProviderProblem(_ agent: AgentRun, _ message: String, changed: Bool) {
        statusBar.flash("\(agent.harness.title) couldn't finish: see the alert")
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(agent.harness.title) couldn't carry out the request"
        alert.informativeText = message + (changed ? "\n\nIt changed files before it stopped: ␣ e z puts them back." : "")
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { SettingsWindowController.shared.show() }
        }
    }
}

