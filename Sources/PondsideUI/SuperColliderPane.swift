import AppKit
import UniformTypeIdentifiers
import PondsideCore
import PondsideEngrave
import PondsideLexicon
import PondsideTiming

/// The SuperCollider pane (DESIGN.md, M5): a .scd file beside the score,
/// run from the editor as in the SuperCollider IDE, with the post window
/// and help below it. The file on disk stays the truth: edits are written
/// as you type, and changes made elsewhere merge in.
@MainActor
final class SuperColliderPane: NSView, NSTextViewDelegate {
    let editor = SCCodeView.make()
    private let editorScroll = NSScrollView()
    private let fileMenu = NSPopUpButton(frame: .zero, pullsDown: false)
    private let status = NSTextField(labelWithString: "")
    private let statusDot = NSView()
    private let server = NSTextField(labelWithString: "")
    let bootButton = NSButton()
    let stopButton = NSButton()
    /// Opens the file in SuperCollider's own IDE (the window's command).
    let ideButton = NSButton()
    var openInIDE: (() -> Void)?
    private let signature = NSTextField(labelWithString: "")
    private let split = NSSplitView()
    private let bottomTabs = NSSegmentedControl(labels: ["Post", "Help"], trackingMode: .selectOne, target: nil, action: nil)
    private let post = NSTextView()
    private let postScroll = NSScrollView()
    let help = SCHelpView(frame: .zero)
    private let bottomContent = NSView()

    private let scoreURL: URL
    private(set) var fileURL: URL
    private var watcher: FileWatcher?
    private var undo = UndoManager()
    private var drafts: [URL: String] = [:]
    private var lastWritten: String?
    private var saveTask: Task<Void, Never>?
    private var loading = false
    /// Messages for the window's status bar.
    var flash: ((String) -> Void)?

    /// `cues`: the score's latest cue sheet, for the stubs of a new patch.
    init(score: URL, cues: CueSheet? = nil) {
        scoreURL = score
        fileURL = Self.initialFile(for: score)
        // No patch yet: start one (patch/<name>.scd, and its engine in patch/dependencies/).
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            let sheet = cues ?? CueSheet(log: TimingLog(rows: []), score: score.lastPathComponent)
            let name = score.deletingPathExtension().lastPathComponent
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? Data(HandlerSync.patchStarter(sheet, name: name).utf8).write(to: fileURL, options: .atomic)
            try? PatchMigration.ensureEngine(patch: fileURL, name: name)
        }
        super.init(frame: .zero)
        build()
        open(fileURL)
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(postChanged(_:)), name: SCLangHost.postDidChange, object: nil)
        nc.addObserver(self, selector: #selector(stateChanged), name: SCLangHost.stateDidChange, object: nil)
        nc.addObserver(self, selector: #selector(stateChanged), name: SCLangHost.serverDidChange, object: nil)
        post.string = SCLangHost.shared.log
        colorPost(from: 0)
        SCLangHost.shared.start(near: score)
        stateChanged()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var responder: NSView { editor }

    // MARK: Files

    private var folder: URL { scoreURL.deletingLastPathComponent() }

    /// The score's patch (`patch/<name>.scd`, or pondside.toml's), else any
    /// .scd beside the score (a patch not migrated yet), else the patch's
    /// place (created as a Pondside patch).
    static func initialFile(for score: URL) -> URL {
        let patch = PatchMigration.patchURL(score: score, configured: (try? ProjectConfig.find(from: score))?.handlers)
        if FileManager.default.fileExists(atPath: patch.path) { return patch }
        return scdFiles(near: score).first { !$0.lastPathComponent.hasSuffix(".before-pondside.scd") } ?? patch
    }

    /// Every project .scd file, with packages and hidden tooling excluded.
    static func scdFiles(near score: URL) -> [URL] {
        let fm = FileManager.default
        guard let entries = fm.enumerator(at: score.deletingLastPathComponent(),
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        return entries.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension.lowercased() == "scd",
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
            return url
        }.sorted { $0.path < $1.path }
    }

    func open(_ url: URL) {
        flushSave()
        watcher?.stop()
        fileURL = url.standardizedFileURL
        undo = UndoManager()
        let text = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        lastWritten = FileManager.default.fileExists(atPath: fileURL.path) ? text : nil
        loading = true
        editor.load(drafts[fileURL] ?? text)
        loading = false
        let w = FileWatcher(url: fileURL) { [weak self] change in
            Task { @MainActor in self?.diskChanged(change.text) }
        }
        w.start()
        watcher = w
        rebuildFileMenu()
    }

    private func rebuildFileMenu() {
        fileMenu.removeAllItems()
        var files = Self.scdFiles(near: scoreURL)
        if !files.contains(fileURL) { files.insert(fileURL, at: 0) }
        for f in files {
            let rel = f.path.hasPrefix(folder.path + "/") ? String(f.path.dropFirst(folder.path.count + 1)) : f.path
            let exists = FileManager.default.fileExists(atPath: f.path)
            fileMenu.addItem(withTitle: exists ? rel : rel + " (new)")
            fileMenu.lastItem?.representedObject = f
        }
        fileMenu.menu?.addItem(.separator())
        fileMenu.addItem(withTitle: "New File…")
        fileMenu.lastItem?.representedObject = "new"
        fileMenu.addItem(withTitle: "Open Other…")
        fileMenu.lastItem?.representedObject = "open"
        fileMenu.selectItem(at: files.firstIndex(of: fileURL) ?? 0)
    }

    @objc private func fileChosen(_ sender: NSPopUpButton) {
        switch sender.selectedItem?.representedObject {
        case let url as URL: if url != fileURL { open(url) }
        case "new" as String: chooseFile(creating: true)
        case "open" as String: chooseFile(creating: false)
        default: break
        }
        rebuildFileMenu()
    }

    /// Picks a .scd to edit, or names a new one.
    func chooseFile(creating: Bool) {
        guard let window else { return }
        if creating {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "scd") ?? .plainText]
            panel.directoryURL = folder
            panel.nameFieldStringValue = "patch.scd"
            panel.beginSheetModal(for: window) { [weak self] r in
                guard r == .OK, let url = panel.url else { return }
                if !FileManager.default.fileExists(atPath: url.path) { try? Data().write(to: url) }
                self?.open(url)
            }
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "scd") ?? .plainText]
            panel.directoryURL = folder
            panel.beginSheetModal(for: window) { [weak self] r in
                guard r == .OK, let url = panel.url else { return }
                self?.open(url)
            }
        }
    }

    /// Quick pick for ␣ s o.
    var files: [URL] { Self.scdFiles(near: scoreURL) }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    func flushSave() {
        saveTask?.cancel()
        saveTask = nil
        let text = editor.string
        guard text != lastWritten, !(lastWritten == nil && text.isEmpty) else { return }
        do {
            let main = Self.initialFile(for: scoreURL)
            if let existing = try? String(contentsOf: main, encoding: .utf8), existing.contains(PatchContract.marker) {
                try PatchContract.validateProject(patch: main, overrides: [fileURL.standardizedFileURL: text])
            }
            watcher?.noteOwnWrite(text)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            if lastWritten == nil { rebuildFileMenu() }
            lastWritten = text
            drafts.removeValue(forKey: fileURL)
        } catch {
            drafts[fileURL] = text
            flash?("Patch draft retained in editor: \(error)")
        }
    }

    /// Another program (an agent, `pondside handlers`) changed the file:
    /// merge it as one undoable minimal edit.
    private func diskChanged(_ text: String) {
        guard text != lastWritten, text != editor.string else { return }
        lastWritten = text
        guard let r = TextDiff.minimalReplacement(from: editor.string, to: text) else { return }
        let range = NSRange(location: r.location, length: r.length)
        loading = true
        if editor.shouldChangeText(in: range, replacementString: r.replacement) {
            editor.textStorage?.replaceCharacters(in: range, with: r.replacement)
            editor.didChangeText()
        }
        loading = false
        editor.recolor()
    }

    // MARK: Interpreter

    func evaluate(line: Bool) { editor.evaluate(line: line) }

    func lookUpHelp() { editor.lookUpHelp() }

    func showHelp(_ topic: SCCompletion.HelpTopic) {
        Task {
            guard let url = await SCLangHost.shared.helpURL(for: topic) else {
                flash?("No help found for \(topic.word)")
                return
            }
            help.show(url)
            showBottom(1)
        }
    }

    private func showBottom(_ i: Int) {
        bottomTabs.selectedSegment = i
        postScroll.isHidden = i != 0
        help.isHidden = i != 1
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) { showBottom(sender.selectedSegment) }

    @objc private func postChanged(_ note: Notification) {
        if note.userInfo?["cleared"] != nil {
            post.string = ""
            return
        }
        guard let text = note.userInfo?["text"] as? String, let storage = post.textStorage else { return }
        let atEnd = postScroll.verticalScroller.map { $0.floatValue > 0.98 || $0.isHidden } ?? true
            || (postScroll.documentView?.frame.height ?? 0) <= postScroll.contentSize.height + 4
        let start = storage.length
        storage.append(NSAttributedString(string: text, attributes: [.font: Theme.monoFont, .foregroundColor: Theme.text]))
        if storage.length > 220_000 { storage.deleteCharacters(in: NSRange(location: 0, length: storage.length - 160_000)) }
        colorPost(from: max(0, min(start, storage.length) - 200))
        if atEnd { post.scrollToEndOfDocument(nil) }
        if postScroll.isHidden, text.contains("ERROR") { showBottom(0) }
    }

    /// Errors and warnings stand out in the post window.
    private func colorPost(from start: Int) {
        guard let storage = post.textStorage else { return }
        let ns = storage.string as NSString
        var loc = ns.lineRange(for: NSRange(location: min(start, ns.length), length: 0)).location
        while loc < ns.length {
            let line = ns.lineRange(for: NSRange(location: loc, length: 0))
            let s = ns.substring(with: line)
            let color: NSColor = s.hasPrefix("ERROR") || s.hasPrefix("^^") ? Theme.error
                : s.hasPrefix("WARNING") || s.hasPrefix("Warning") ? Theme.warning
                : s.hasPrefix("-> ") ? Theme.syntaxCommand : Theme.text
            storage.addAttribute(.foregroundColor, value: color, range: line)
            loc = NSMaxRange(line)
        }
    }

    @objc private func stateChanged() {
        let host = SCLangHost.shared
        status.stringValue = host.statusText
        status.toolTip = host.missing
        let color: NSColor
        if host.missing != nil { color = Theme.error }
        else {
            switch host.state {
            case .ready: color = Theme.accent
            case .starting: color = Theme.warning
            case .libraryFailed, .exited: color = Theme.error
            case .stopped: color = Theme.secondaryText
            }
        }
        statusDot.layer?.backgroundColor = color.cgColor
        server.stringValue = host.serverStatus
        server.textColor = host.serverRunning ? Theme.text : Theme.secondaryText
        bootButton.image = NSImage(systemSymbolName: "power", accessibilityDescription: host.serverRunning ? "Quit Server" : "Boot Server")
        bootButton.contentTintColor = host.serverRunning ? Theme.accent : Theme.secondaryText
        bootButton.isEnabled = host.ready
    }

    @objc private func bootPressed() { SCLangHost.shared.toggleServer() }
    @objc private func stopPressed() { SCLangHost.shared.stopSound() }
    @objc private func ideButtonPressed() { openInIDE?() }
    @objc private func clearPressed() { SCLangHost.shared.clearLog() }

    // MARK: NSTextViewDelegate

    func undoManager(for view: NSTextView) -> UndoManager? { undo }

    private var lastTyped: String?

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        lastTyped = replacementString
        return true
    }

    func textDidChange(_ notification: Notification) {
        guard !loading else { return }
        editor.textChanged(typed: lastTyped)
        lastTyped = nil
        scheduleSave()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        editor.selectionChanged()
    }

    // MARK: Layout

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor

        let bar = NSView()
        bar.wantsLayer = true
        bar.layer?.backgroundColor = Theme.chrome.cgColor
        fileMenu.isBordered = false
        fileMenu.font = Theme.secondaryFont
        fileMenu.target = self
        fileMenu.action = #selector(fileChosen(_:))
        fileMenu.toolTip = "The SuperCollider file in this pane: saved as you type"
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 4
        status.font = Theme.secondaryFont
        status.textColor = Theme.secondaryText
        status.lineBreakMode = .byTruncatingTail
        server.font = Theme.secondaryFont
        server.lineBreakMode = .byTruncatingTail
        server.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for (b, symbol, label, action) in [(bootButton, "power", "Boot Server", #selector(bootPressed)),
                                           (stopButton, "stop.fill", "Stop Sound", #selector(stopPressed))] {
            b.isBordered = false
            b.bezelStyle = .regularSquare
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            b.imagePosition = .imageOnly
            b.contentTintColor = Theme.secondaryText
            b.target = self
            b.action = action
            b.toolTip = label
        }
        stopButton.toolTip = "Stop Sound — ⌘."
        bootButton.toolTip = "Boot or quit the server — ⌘B"
        let right = NSStackView(views: [statusDot, status, server, bootButton, stopButton])
        right.spacing = 8
        right.setCustomSpacing(5, after: statusDot)
        right.setCustomSpacing(14, after: status)
        ideButton.isBordered = false
        ideButton.bezelStyle = .regularSquare
        ideButton.title = "Open in IDE"
        ideButton.font = Theme.secondaryFont
        ideButton.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        ideButton.imagePosition = .imageLeading
        ideButton.contentTintColor = Theme.secondaryText
        ideButton.target = self
        ideButton.action = #selector(ideButtonPressed)
        ideButton.toolTip = "Open this file in the SuperCollider IDE — ␣ s v"
        for v in [fileMenu, ideButton, right] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bar.addSubview(v)
        }

        editorScroll.documentView = editor
        editorScroll.verticalRulerView = SourceLineRuler(scrollView: editorScroll, textView: editor)
        editorScroll.hasVerticalRuler = true
        editorScroll.rulersVisible = true
        editorScroll.hasVerticalScroller = true
        editorScroll.autohidesScrollers = true
        editorScroll.drawsBackground = true
        editorScroll.backgroundColor = Theme.editorBackground
        editor.delegate = self
        editor.library = { SCLangHost.shared.library }
        editor.onEvaluate = { [weak self] code, _ in SCLangHost.shared.evaluate(code, path: self?.fileURL.path) }
        editor.onHelp = { [weak self] topic in self?.showHelp(topic) }
        editor.onSignature = { [weak self] s in
            self?.signature.stringValue = s ?? ""
            self?.signature.isHidden = s == nil
        }
        signature.font = .monospacedSystemFont(ofSize: Theme.secondarySize, weight: .regular)
        signature.textColor = Theme.text
        signature.backgroundColor = Theme.chrome
        signature.drawsBackground = true
        signature.lineBreakMode = .byTruncatingTail
        signature.isHidden = true

        let top = NSView()
        for v in [editorScroll, signature] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            top.addSubview(v)
        }

        // The post window and help, under a small tab bar.
        let tabsBar = NSView()
        tabsBar.wantsLayer = true
        tabsBar.layer?.backgroundColor = Theme.chrome.cgColor
        bottomTabs.target = self
        bottomTabs.action = #selector(tabChanged(_:))
        bottomTabs.selectedSegment = 0
        bottomTabs.controlSize = .small
        bottomTabs.font = Theme.secondaryFont
        let clear = NSButton(image: NSImage(systemSymbolName: "trash", accessibilityDescription: "Clear Post Window")!,
                             target: self, action: #selector(clearPressed))
        clear.isBordered = false
        clear.contentTintColor = Theme.secondaryText
        clear.toolTip = "Clear the post window — ␣ s x"
        for v in [bottomTabs, clear] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            tabsBar.addSubview(v)
        }
        post.isEditable = false
        post.isSelectable = true
        post.drawsBackground = true
        post.backgroundColor = Theme.editorBackground
        post.font = Theme.monoFont
        post.textColor = Theme.text
        post.textContainerInset = NSSize(width: 10, height: 6)
        post.isVerticallyResizable = true
        post.autoresizingMask = [.width]
        post.textContainer?.widthTracksTextView = true
        postScroll.documentView = post
        postScroll.hasVerticalScroller = true
        postScroll.autohidesScrollers = true
        postScroll.drawsBackground = true
        postScroll.backgroundColor = Theme.editorBackground
        help.isHidden = true
        help.onEvaluate = { code in SCLangHost.shared.evaluate(code) }
        for v in [tabsBar, postScroll, help] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            bottomContent.addSubview(v)
        }

        split.isVertical = false
        split.dividerStyle = .thin
        split.addArrangedSubview(top)
        split.addArrangedSubview(bottomContent)
        for v in [bar, split] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 28),
            fileMenu.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: 10),
            fileMenu.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            ideButton.leadingAnchor.constraint(equalTo: fileMenu.trailingAnchor, constant: 12),
            ideButton.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            right.leadingAnchor.constraint(greaterThanOrEqualTo: ideButton.trailingAnchor, constant: 10),
            right.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -10),
            right.centerYAnchor.constraint(equalTo: bar.centerYAnchor),
            statusDot.widthAnchor.constraint(equalToConstant: 8),
            statusDot.heightAnchor.constraint(equalToConstant: 8),
            split.topAnchor.constraint(equalTo: bar.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: leadingAnchor),
            split.trailingAnchor.constraint(equalTo: trailingAnchor),
            split.bottomAnchor.constraint(equalTo: bottomAnchor),

            editorScroll.topAnchor.constraint(equalTo: top.topAnchor),
            editorScroll.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            editorScroll.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            editorScroll.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            signature.leadingAnchor.constraint(equalTo: top.leadingAnchor),
            signature.trailingAnchor.constraint(equalTo: top.trailingAnchor),
            signature.bottomAnchor.constraint(equalTo: top.bottomAnchor),
            top.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            tabsBar.topAnchor.constraint(equalTo: bottomContent.topAnchor),
            tabsBar.leadingAnchor.constraint(equalTo: bottomContent.leadingAnchor),
            tabsBar.trailingAnchor.constraint(equalTo: bottomContent.trailingAnchor),
            tabsBar.heightAnchor.constraint(equalToConstant: 26),
            bottomTabs.leadingAnchor.constraint(equalTo: tabsBar.leadingAnchor, constant: 10),
            bottomTabs.centerYAnchor.constraint(equalTo: tabsBar.centerYAnchor),
            clear.trailingAnchor.constraint(equalTo: tabsBar.trailingAnchor, constant: -10),
            clear.centerYAnchor.constraint(equalTo: tabsBar.centerYAnchor),
            bottomContent.heightAnchor.constraint(greaterThanOrEqualToConstant: 60),
        ])
        for v in [postScroll, help] as [NSView] {
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: tabsBar.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: bottomContent.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: bottomContent.trailingAnchor),
                v.bottomAnchor.constraint(equalTo: bottomContent.bottomAnchor),
            ])
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.split.setPosition(max(120, self.split.bounds.height * 0.64), ofDividerAt: 0)
        }
    }
}
