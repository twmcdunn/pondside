import AppKit
import UniformTypeIdentifiers
import PondsideCore
import PondsideBridge
import PondsideLexicon
import os

/// Application entry point for the macOS front end.
@MainActor
public enum PondsideApplication {
    public static func run() {
        let app = NSApplication.shared
        let delegate = PondsideAppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.appearance = NSAppearance(named: .darkAqua)
        // NSApplication holds its delegate weakly; keep ours alive.
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class PondsideAppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var controllers: [DocumentWindowController] = []
    var documentControllers: [DocumentWindowController] { controllers }
    private var openedFromLaunch = false
    private let recentMenu = NSMenu(title: "Open Recent")
    private var lightsOut = UserDefaults.standard.bool(forKey: "Pondside.lightsOut")
    /// Playback following, on unless turned off.
    private(set) var followPlayback = UserDefaults.standard.object(forKey: "Pondside.followPlayback") as? Bool ?? true

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = buildMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ScoreDocument.detectCheckpointGit()
        // Scripts and agents follow the app over a socket (docs/API.md).
        AppRPC.shared.app = self
        AppRPC.shared.start()
        SettingsPanels.installEscape()
        if let cache = ScoreDocument.renderCache {
            Task.detached(priority: .background) { cache.prune() }
        }
        // `PondsideApp score.ly` from a terminal or agent.
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        for path in args { self.open(URL(fileURLWithPath: path)) }
        NSApp.activate(ignoringOtherApps: true)
        if controllers.isEmpty && !openedFromLaunch { openDocument(nil) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        openedFromLaunch = true
        urls.forEach { self.openFromFinder($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard controllers.contains(where: \.hasPendingNoteInput) else { return .terminateNow }
        Task { @MainActor in
            for controller in self.controllers { await controller.flushPendingNoteInput() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppRPC.shared.stop()
        controllers.forEach { $0.score.flushPendingSaves(); $0.flushSuperCollider() }
        SCLangHost.shared.shutdown()
        NoteAudition.shared.shutdown()
    }

    func windowDidClose(_ controller: DocumentWindowController) {
        controllers.removeAll { $0 === controller }
    }

    // MARK: Opening

    private func openFromFinder(_ url: URL) {
        guard url.pathExtension.lowercased() == "ly" else { open(url); return }
        let folder = url.standardizedFileURL.deletingLastPathComponent()
        if ProjectStructure.isProjectRoot(folder) {
            open(folder)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Make \(folder.lastPathComponent) a Pondside project?"
        alert.informativeText = "Pondside will use this folder as the project root, keep \(url.lastPathComponent) as its score, and add pondside.toml, patch/ and renders/."
        alert.addButton(withTitle: "Create Project")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try ProjectStructure.adopt(score: url.standardizedFileURL)
            open(folder)
        } catch { _ = NSAlert(error: error).runModal() }
    }

    /// Opens a project: its root folder, or a score in it. Every project
    /// gets the same structure (ProjectStructure) before its score opens.
    func open(_ url: URL) {
        var url = url.standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            guard let score = rootScore(in: url) else { return }
            url = score
        }
        if let existing = controllers.first(where: { $0.score.root.matches(path: url.path) }) {
            existing.showWindow(nil)
            return
        }
        for change in ProjectStructure.ensure(score: url) {
            if let why = change.error {
                Logger(subsystem: "app.pondside", category: "project").notice("\(change.path, privacy: .public) left alone: \(why, privacy: .public)")
            }
        }
        do {
            let document = try ScoreDocument(url: url)
            let controller = DocumentWindowController(document: document)
            controller.lightsOut = lightsOut
            controller.followsPlayback = followPlayback
            controllers.append(controller)
            controller.showWindow(nil)
            NSDocumentController.shared.noteNewRecentDocumentURL(url)
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }

    /// The score a project root opens. A folder with no score offers to
    /// start one; one with several asks which, and remembers the answer in
    /// its pondside.toml (`[project] score`).
    private func rootScore(in folder: URL) -> URL? {
        switch ProjectStructure.rootScore(in: folder) {
        case .score(let score):
            return score
        case .none:
            let alert = NSAlert()
            alert.messageText = "\(folder.lastPathComponent) has no score"
            alert.informativeText = "Start one in this project root? Pondside writes \(folder.lastPathComponent).ly "
                + "and the project's folders (patch/, renders/) beside it."
            alert.addButton(withTitle: "Create Score")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            do { return try ProjectStructure.create(at: folder) } catch {
                _ = NSAlert(error: error).runModal()
                return nil
            }
        case .ambiguous(let scores):
            let alert = NSAlert()
            alert.messageText = "Which score is \(folder.lastPathComponent)'s root?"
            alert.informativeText = "Pondside opens it whenever this project root is opened (pondside.toml, [project] score)."
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 260, height: 26), pullsDown: false)
            popup.addItems(withTitles: scores.map(\.lastPathComponent))
            alert.accessoryView = popup
            alert.addButton(withTitle: "Open")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            let score = scores[max(0, popup.indexOfSelectedItem)]
            let toml = folder.appendingPathComponent(ProjectConfig.fileName)
            let text = (try? String(contentsOf: toml, encoding: .utf8)) ?? ""
            try? Data(ProjectStructure.settingScore(score.lastPathComponent, in: text).utf8).write(to: toml, options: .atomic)
            return score
        }
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.title = "Open Project Root"
        panel.message = "Choose a project root: the folder that holds the score."
        panel.prompt = "Open"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach { self.open($0) }
    }

    @objc func newDocument(_ sender: Any?) {
        let panel = NSSavePanel()
        panel.title = "New Project"
        panel.message = "Name the project root. Pondside creates this folder with the score, patch/ and renders/ inside."
        panel.nameFieldLabel = "Project Root:"
        panel.nameFieldStringValue = "Untitled"
        panel.prompt = "Create"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        do {
            self.open(try ProjectStructure.create(at: folder))
        } catch {
            _ = NSAlert(error: error).runModal()
        }
    }

    @objc func toggleLightsOut(_ sender: Any?) {
        lightsOut.toggle()
        UserDefaults.standard.set(lightsOut, forKey: "Pondside.lightsOut")
        controllers.forEach { $0.lightsOut = lightsOut }
        lightsOutItem?.state = lightsOut ? .on : .off
    }

    @objc func toggleFollowPlayback(_ sender: Any?) {
        followPlayback.toggle()
        UserDefaults.standard.set(followPlayback, forKey: "Pondside.followPlayback")
        controllers.forEach { $0.followsPlayback = followPlayback }
        followPlaybackItem?.state = followPlayback ? .on : .off
        SettingsWindowController.shared.refreshToggles()
    }

    var hearNotes: Bool { NoteAudition.shared.isEnabled }

    @objc func toggleHearNotes(_ sender: Any?) {
        NoteAudition.shared.isEnabled.toggle()
        hearNotesItem?.state = hearNotes ? .on : .off
        let key = controllers.first { $0.window?.isKeyWindow == true } ?? controllers.first
        key?.flash(hearNotes ? "Hear Selected Notes on (⌥N)" : "Hear Selected Notes off (⌥N)")
        if hearNotes { key?.prepareNoteAudition() }
        SettingsWindowController.shared.refreshToggles()
    }

    @objc func showAbout(_ sender: Any?) {
        let credits = NSAttributedString(
            string: """
            Your scores are plain LilyPond files. Pondside never stores your music \
            anywhere else and adds nothing you can't take with you: stop using \
            Pondside tomorrow and you lose nothing.

            Engraving by GNU LilyPond.
            """,
            attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Pondside",
            .applicationVersion: "0.1 (M1)",
            .credits: credits,
        ])
    }

    /// Reached only when no score window answers: window commands that need
    /// a score stay greyed rather than beeping.
    func validateMenuItem(_ item: NSMenuItem) -> Bool { item.commandID != "file.revert" }

    /// The menu item's checkmark follows the setting wherever it changes.
    private weak var lightsOutItem: NSMenuItem?
    private weak var followPlaybackItem: NSMenuItem?
    private weak var hearNotesItem: NSMenuItem?

    // MARK: Commands

    /// Commands that need no window.
    func runAppCommand(_ id: CommandID) {
        switch id.rawValue {
        case "file.new": newDocument(nil)
        case "file.open": openDocument(nil)
        case "view.lightsOut": toggleLightsOut(nil)
        case "view.followPlayback": toggleFollowPlayback(nil)
        case "view.hearNotes": toggleHearNotes(nil)
        case "help.about": showAbout(nil)
        case "help.settings": SettingsWindowController.shared.show()
        default: NSSound.beep()
        }
    }

    // MARK: Menu

    /// Menus are built from the command catalog, so titles and shortcuts
    /// match the palette, the hints and the keyboard audit exactly.
    private func buildMenu() -> NSMenu {
        let main = NSMenu()
        let center = CommandCenter.shared

        func submenu(_ title: String, _ items: [NSMenuItem]) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title)
            for i in items { menu.addItem(i) }
            item.submenu = menu
            main.addItem(item)
        }
        func item(_ title: String, _ action: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            return i
        }
        func command(_ id: CommandID) -> NSMenuItem { center.menuItem(id) }
        func commands(category: String) -> [NSMenuItem] {
            center.keymap.specs.filter { $0.category == category && ($0.shortcut != nil || !$0.chords.isEmpty) }
                .map { center.menuItem($0.id) }
        }

        submenu("Pondside", [
            command("help.about"),
            .separator(),
            command("help.settings"),
            .separator(),
            item("Hide Pondside", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), ""),
            .separator(),
            item("Quit Pondside", #selector(NSApplication.terminate(_:)), "q"),
        ])
        submenu("File", [
            command("file.new"),
            command("file.open"),
            openRecentItem(),
            .separator(),
            command("file.scoreSetup"),
            command("file.engravingSettings"),
            command("file.lilypond"),
            command("file.migrateScore"),
            command("file.revert"),
            .separator(),
            command("file.exportPDF"),
            command("file.reveal"),
            .separator(),
            center.menuItem("file.close", action: #selector(NSWindow.performClose(_:))),
        ])
        submenu("Edit", [
            center.menuItem("edit.undo", action: Selector(("undo:"))),
            center.menuItem("edit.redo", action: Selector(("redo:"))),
            .separator(),
            center.menuItem("edit.cut", action: #selector(NSText.cut(_:))),
            center.menuItem("edit.copy", action: #selector(NSText.copy(_:))),
            center.menuItem("edit.paste", action: #selector(NSText.paste(_:))),
            center.menuItem("edit.selectAll", action: #selector(NSText.selectAll(_:))),
            .separator(),
            center.menuItem("edit.find", action: #selector(NSTextView.performFindPanelAction(_:)))
                .tagged(Int(NSFindPanelAction.showFindPanel.rawValue)),
            .separator(),
            command("edit.delete"),
            command("edit.source"),
            .separator(),
            command("edit.generalAgent"),
            command("edit.stopAgent"),
            command("edit.undoAgent"),
            command("edit.newAgentConversation"),
            command("edit.patchRequest"),
            command("edit.newPatchConversation"),
        ])
        submenu("Go", commands(category: "Go"))
        submenu("Add", commands(category: "Add"))
        submenu("SuperCollider", commands(category: "SuperCollider"))
        var view = commands(category: "View").filter { $0.commandID != "view.fullScreen" }
        view += [.separator()] + commands(category: "Pane")
        view += [.separator(), center.menuItem("view.fullScreen", action: #selector(NSWindow.toggleFullScreen(_:)))]
        lightsOutItem = view.first { $0.commandID == "view.lightsOut" }
        lightsOutItem?.state = lightsOut ? .on : .off
        followPlaybackItem = view.first { $0.commandID == "view.followPlayback" }
        followPlaybackItem?.state = followPlayback ? .on : .off
        hearNotesItem = view.first { $0.commandID == "view.hearNotes" }
        hearNotesItem?.state = hearNotes ? .on : .off
        submenu("View", view)
        submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:)), ""),
            .separator(),
        ] + commands(category: "Workspace"))
        submenu("Help", [command("help.palette"), command("help.context"), command("help.keys")])
        return main
    }
}

extension PondsideAppDelegate: CommandResponder {
    /// Reached when no window handles a command (e.g. none is open).
    // MARK: The command-line tool

    /// Links `pondside` into ~/.local/bin: no admin rights, nothing written
    /// outside the user's home (DESIGN.md, Appendix A.11).
    @objc func installCommandLineTool(_ sender: Any?) {
        let alert = NSAlert()
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("pondside"),
              FileManager.default.isExecutableFile(atPath: tool.path) else {
            alert.messageText = "The command-line tool isn't in this build"
            alert.runModal()
            return
        }
        let bin = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        let link = bin.appendingPathComponent("pondside")
        do {
            try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil || FileManager.default.fileExists(atPath: link.path) {
                try FileManager.default.removeItem(at: link)
            }
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: tool)
            let onPath = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").contains { $0 == bin.path }
            alert.messageText = "Installed pondside"
            alert.informativeText = "\(link.path) → \(tool.path)"
                + (onPath ? "" : "\n\n~/.local/bin isn't on your PATH yet. Add this to ~/.zshrc:\nexport PATH=\"$HOME/.local/bin:$PATH\"")
        } catch {
            alert.messageText = "Couldn't install pondside"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
    }

    // MARK: Open Recent
    //
    // macOS keeps the list (noteNewRecentDocumentURL on every open, shared
    // with the Dock menu); the submenu is rebuilt from it each time it opens.

    private func openRecentItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
        recentMenu.delegate = self
        recentMenu.autoenablesItems = false
        item.submenu = recentMenu
        return item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === recentMenu else { return }
        menu.removeAllItems()
        let fm = FileManager.default
        let urls = NSDocumentController.shared.recentDocumentURLs.filter { fm.fileExists(atPath: $0.path) }
        // Same-named scores in different folders get their folder too.
        let names = Dictionary(grouping: urls, by: \.lastPathComponent)
        for url in urls {
            var title = url.lastPathComponent
            if (names[title]?.count ?? 0) > 1 { title += " — " + url.deletingLastPathComponent().lastPathComponent }
            let item = NSMenuItem(title: title, action: #selector(openRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.toolTip = url.path
            item.image = NSWorkspace.shared.icon(forFile: url.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        if urls.isEmpty {
            let none = NSMenuItem(title: "No Recent Scores", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: "Clear Menu", action: #selector(clearRecent(_:)), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !urls.isEmpty
        menu.addItem(clear)
    }

    @objc private func openRecent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        open(url)
    }

    @objc private func clearRecent(_ sender: Any?) {
        NSDocumentController.shared.clearRecentDocuments(sender)
    }

    @objc func performCommand(_ sender: Any?) {
        guard let id = (sender as? NSMenuItem)?.commandID else { return }
        runAppCommand(id)
    }
}

private extension NSMenuItem {
    func tagged(_ tag: Int) -> NSMenuItem {
        self.tag = tag
        return self
    }
}

/// ⎋ closes any settings panel: Settings, Engraving Settings, Score Setup.
/// The score panels float without taking the keyboard, so ⎋ in the score
/// window closes them too (DocumentWindowController.intercept), after it
/// stops playback.
@MainActor
enum SettingsPanels {
    private static var monitor: Any?

    static func isSettingsPanel(_ window: NSWindow) -> Bool {
        window.windowController is SettingsWindowController || window is EngravingSettingsPanel || window is ScoreSetupPanel
    }

    /// For a panel that has the keyboard (its text field, list or button).
    static func installEscape() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function, .capsLock])
            guard event.keyCode == 53, flags.isEmpty else { return event }
            let closed = MainActor.assumeIsolated { () -> Bool in
                guard let window = event.window, window.attachedSheet == nil, isSettingsPanel(window) else { return false }
                close(window)
                return true
            }
            return closed ? nil : event
        }
    }

    /// Closes the frontmost visible score panel; false when none is open.
    static func closeFloating() -> Bool {
        guard let panel = NSApp.orderedWindows.first(where: { ($0 is EngravingSettingsPanel || $0 is ScoreSetupPanel) && $0.isVisible })
        else { return false }
        close(panel)
        return true
    }

    private static func close(_ window: NSWindow) {
        if window is NSPanel { window.orderOut(nil) } else { window.close() }
    }
}
