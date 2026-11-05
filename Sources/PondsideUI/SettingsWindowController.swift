import AppKit
import PondsideBridge

/// Pondside ▸ Settings… (⌘,): what belongs to the app rather than to a
/// score (a score's own settings live in its files and pondside.toml).
/// A standard settings window: changes apply at once, nothing to confirm.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    static let shared = SettingsWindowController()

    private let agentPopup = NSPopUpButton()
    private let agentDetail = NSTextField(wrappingLabelWithString: "")
    private let modelLabel = NSTextField(labelWithString: "Model:")
    /// A pull-down: its title shows the model, its menu groups them by provider.
    private let modelPopup = NSPopUpButton(frame: .zero, pullsDown: true)
    private let modelDetail = NSTextField(wrappingLabelWithString: "")
    private var models: [String]?
    private var loadingModels = false
    private let lightsOut = NSButton(checkboxWithTitle: "Lights Out: dim the paper for night work", target: nil, action: nil)
    private let followPlayback = NSButton(checkboxWithTitle: "Follow playback: glide each new system to the middle (⌥F)", target: nil, action: nil)
    private let hearNotes = NSButton(checkboxWithTitle: "Hear selected notes: play each new selection's pitch (⌥N)", target: nil, action: nil)
    private let cliStatus = NSTextField(wrappingLabelWithString: "")
    private var found: [(AgentHarness, String?)] = []
    private var modelRows: [NSGridRow] = []

    private init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: true)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show() {
        refresh()
        if window?.isVisible != true { window?.center() }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func build() {
        agentPopup.setAccessibilityLabel("Coding agent")
        agentPopup.target = self
        agentPopup.action = #selector(agentChanged)
        agentDetail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        agentDetail.textColor = .secondaryLabelColor
        agentDetail.preferredMaxLayoutWidth = 340
        let declined = NSButton(title: "Ask Again About Declined Patches", target: self, action: #selector(resetDeclined))
        lightsOut.target = self
        lightsOut.action = #selector(lightsOutChanged)
        followPlayback.target = self
        followPlayback.action = #selector(followPlaybackChanged)
        hearNotes.target = self
        hearNotes.action = #selector(hearNotesChanged)
        cliStatus.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        cliStatus.textColor = .secondaryLabelColor
        cliStatus.preferredMaxLayoutWidth = 340
        let install = NSButton(title: "Install in ~/.local/bin", target: self, action: #selector(installCLI))

        modelLabel.alignment = .right
        modelDetail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        modelDetail.textColor = .secondaryLabelColor
        modelDetail.preferredMaxLayoutWidth = 340
        modelPopup.setAccessibilityLabel("opencode model")
        let grid = NSGridView(views: [
            [label("Agent:"), agentPopup],
            [modelLabel, modelPopup],
            [NSGridCell.emptyContentView, modelDetail],
            [NSGridCell.emptyContentView, agentDetail],
            [NSGridCell.emptyContentView, declined],
            [label("Appearance:"), lightsOut],
            [label("Playback:"), followPlayback],
            [NSGridCell.emptyContentView, hearNotes],
            [label("Command-line tool:"), install],
            [NSGridCell.emptyContentView, cliStatus],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for row in [4, 5, 6, 8] { grid.row(at: row).topPadding = 10 }
        modelRows = [grid.row(at: 1), grid.row(at: 2)]
        grid.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
        window?.contentView = content
    }

    /// The agents installed, looked up off the main thread (it asks the
    /// login shell for its PATH).
    private func refresh() {
        lightsOut.state = UserDefaults.standard.bool(forKey: "Pondside.lightsOut") ? .on : .off
        followPlayback.state = (NSApp.delegate as? PondsideAppDelegate)?.followPlayback ?? true ? .on : .off
        hearNotes.state = NoteAudition.shared.isEnabled ? .on : .off
        let link = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/pondside")
        cliStatus.stringValue = (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)).map { "Installed: \(link.path) → \($0)" }
            ?? "Links pondside (the CLI, and the MCP server agents use) into ~/.local/bin. No admin rights needed."
        Task {
            let found = await Task.detached { AgentHarness.allCases.map { ($0, AgentRun.find($0)) } }.value
            self.found = found
            self.fillAgents()
        }
    }

    private func fillAgents() {
        let current = UserDefaults.standard.string(forKey: DocumentWindowController.agentKey)
        let firstInstalled = found.first { $0.1 != nil }?.0
        agentPopup.removeAllItems()
        agentPopup.addItem(withTitle: "Automatic" + (firstInstalled.map { " (\($0.title))" } ?? ""))
        for (h, path) in found { agentPopup.addItem(withTitle: h.title + (path == nil ? " (not installed)" : "")) }
        agentPopup.addItem(withTitle: "Off")
        let index = current == "off" ? found.count + 1 : current.flatMap { c in found.firstIndex { $0.0.rawValue == c }.map { $0 + 1 } } ?? 0
        agentPopup.selectItem(at: index)
        var detail = "Carries out requests from the lens (⌘L on a graphic, or ⇥ in the lens) and finishes SuperCollider patch migrations, in the background."
        for (h, path) in found {
            let missing = h == .codex ? "not installed — install the Codex CLI and run codex login" : "not installed — the Pondside installer can add it"
            detail += "\n\(h.title): " + (path ?? missing)
        }
        agentDetail.stringValue = detail
        fillModels()
    }

    @objc private func agentChanged() {
        let i = agentPopup.indexOfSelectedItem
        let value: String? = i == 0 ? nil : i <= found.count ? found[i - 1].0.rawValue : "off"
        UserDefaults.standard.set(value, forKey: DocumentWindowController.agentKey)
        _ = DocumentWindowController.agent(value)
        fillModels()
    }

    // MARK: opencode's model

    /// The agent the preference resolves to, as `AgentRun.choose` would pick it.
    private var chosenHarness: AgentHarness? {
        let pref = UserDefaults.standard.string(forKey: DocumentWindowController.agentKey)
        if pref == "off" { return nil }
        if let h = AgentHarness(rawValue: pref ?? ""), found.contains(where: { $0.0 == h && $0.1 != nil }) { return h }
        return found.first { $0.1 != nil }?.0
    }

    /// Shown only when opencode is the agent; the list comes from
    /// `opencode models`, read once in the background.
    private func fillModels() {
        let opencode = found.first { $0.0 == .opencode }?.1
        let shown = chosenHarness == .opencode && opencode != nil
        for row in modelRows { row.isHidden = !shown }
        guard shown, let opencode else { return }
        let current = UserDefaults.standard.string(forKey: DocumentWindowController.opencodeModelKey)
        let menu = NSMenu()
        menu.addItem(withTitle: current ?? "opencode’s default", action: nil, keyEquivalent: "")   // the pull-down's title
        let byDefault = NSMenuItem(title: "opencode’s Default", action: #selector(modelChosen(_:)), keyEquivalent: "")
        byDefault.target = self
        byDefault.state = current == nil ? .on : .off
        menu.addItem(byDefault)
        menu.addItem(.separator())
        if let models {
            if let current, !models.contains(current) {
                let missing = NSMenuItem(title: "\(current) (not available)", action: nil, keyEquivalent: "")
                missing.isEnabled = false
                menu.addItem(missing)
            }
            for item in Self.providerItems(models, current: current, target: self, action: #selector(modelChosen(_:))) { menu.addItem(item) }
            modelDetail.stringValue = models.isEmpty
                ? "opencode lists no models: set up a provider with `opencode auth login` in the terminal (⌃4)."
                : "\(models.count) models from the providers opencode is set up with. A new choice starts a new conversation."
        } else {
            let loading = NSMenuItem(title: "Loading models…", action: nil, keyEquivalent: "")
            loading.isEnabled = false
            menu.addItem(loading)
            modelDetail.stringValue = "Asking opencode which models it can use…"
            loadModels(opencode)
        }
        modelPopup.menu = menu
    }

    private func loadModels(_ executable: String) {
        guard !loadingModels else { return }
        loadingModels = true
        Task {
            let list = await Task.detached { AgentRun.models(opencode: executable) }.value
            self.models = list
            self.loadingModels = false
            self.fillModels()
        }
    }

    /// One submenu per provider; a provider whose ids hold a vendor too
    /// (`openrouter/anthropic/…`) gets one submenu per vendor inside it.
    static func providerItems(_ models: [String], current: String?, target: AnyObject, action: Selector) -> [NSMenuItem] {
        func leaf(_ title: String, _ id: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = id
            item.state = id == current ? .on : .off
            return item
        }
        func group(_ title: String, _ children: [NSMenuItem]) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let sub = NSMenu(title: title)
            for c in children { sub.addItem(c) }
            item.submenu = sub
            if children.contains(where: { $0.state == .on || $0.submenu?.items.contains { $0.state == .on } == true }) { item.state = .mixed }
            return item
        }
        var providers: [String] = []
        var byProvider: [String: [String]] = [:]
        for id in models {
            let provider = String(id.prefix { $0 != "/" })
            if byProvider[provider] == nil { providers.append(provider) }
            byProvider[provider, default: []].append(id)
        }
        return providers.map { provider in
            let ids = byProvider[provider] ?? []
            let rest = ids.map { String($0.dropFirst(provider.count + 1)) }
            let nested = rest.filter { $0.contains("/") }.count > rest.count / 2 && ids.count > 30
            guard nested else { return group(provider, zip(rest, ids).map { leaf($0, $1) }) }
            var vendors: [String] = []
            var byVendor: [String: [NSMenuItem]] = [:]
            for (r, id) in zip(rest, ids) {
                let vendor = r.contains("/") ? String(r.prefix { $0 != "/" }) : "other"
                if byVendor[vendor] == nil { vendors.append(vendor) }
                byVendor[vendor, default: []].append(leaf(r.contains("/") ? String(r.dropFirst(vendor.count + 1)) : r, id))
            }
            return group("\(provider) (\(ids.count))", vendors.sorted().map { group($0, byVendor[$0] ?? []) })
        }
    }

    @objc private func modelChosen(_ sender: NSMenuItem) {
        UserDefaults.standard.set(sender.representedObject as? String, forKey: DocumentWindowController.opencodeModelKey)
        fillModels()
    }

    @objc private func resetDeclined() {
        UserDefaults.standard.removeObject(forKey: "Pondside.patchMigrationDeclined")
    }

    @objc private func lightsOutChanged() {
        let want = lightsOut.state == .on
        if want != UserDefaults.standard.bool(forKey: "Pondside.lightsOut") {
            (NSApp.delegate as? PondsideAppDelegate)?.toggleLightsOut(nil)
        }
    }

    @objc private func followPlaybackChanged() {
        guard let app = NSApp.delegate as? PondsideAppDelegate else { return }
        if (followPlayback.state == .on) != app.followPlayback { app.toggleFollowPlayback(nil) }
    }

    /// Keeps the checkboxes true when a shortcut toggles them while open.
    func refreshToggles() {
        hearNotes.state = NoteAudition.shared.isEnabled ? .on : .off
        followPlayback.state = (NSApp.delegate as? PondsideAppDelegate)?.followPlayback ?? true ? .on : .off
    }

    @objc private func hearNotesChanged() {
        guard let app = NSApp.delegate as? PondsideAppDelegate else { return }
        if (hearNotes.state == .on) != app.hearNotes { app.toggleHearNotes(nil) }
    }

    @objc private func installCLI() {
        (NSApp.delegate as? PondsideAppDelegate)?.installCommandLineTool(nil)
        refresh()
    }

    // ⎋ closes, as in any settings window.
    override func cancelOperation(_ sender: Any?) { window?.close() }
}
