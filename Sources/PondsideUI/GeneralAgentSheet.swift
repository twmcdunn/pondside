import AppKit

/// An explicit document sheet for requests about a file or the project.
/// The existing agents retain their own conversation, undo and contract checks.
@MainActor
final class GeneralAgentSheet: NSObject {
    enum Target: Int { case score, patch }
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 340), styleMask: [.titled], backing: .buffered, defer: false)
    private let target = NSSegmentedControl(labels: ["LilyPond", "SuperCollider"], trackingMode: .selectOne, target: nil, action: nil)
    private let files = NSPopUpButton()
    private let request = NSTextView()
    private var scoreFiles: [URL] = []
    private var patchFiles: [URL] = []
    private var root = URL(fileURLWithPath: "/")
    var onSubmit: ((String, Target, URL?) -> Void)?

    override init() {
        super.init()
        panel.title = "Ask Agent"
        panel.appearance = NSAppearance(named: .darkAqua)
        let content = panel.contentView!
        let scroll = NSScrollView()
        scroll.documentView = request
        scroll.hasVerticalScroller = true
        request.font = Theme.bodyFont
        request.backgroundColor = Theme.editorBackground
        request.textColor = Theme.text
        request.isRichText = false
        request.textContainerInset = NSSize(width: 8, height: 8)
        request.setAccessibilityLabel("Describe the requested project or file changes")
        let note = NSTextField(wrappingLabelWithString: "Describe any change to the selected file or the project. The agent preserves its .ly or SuperCollider performance contract.")
        note.font = Theme.secondaryFont
        note.textColor = Theme.secondaryText
        let send = NSButton(title: "Send Request", target: self, action: #selector(submit))
        send.bezelStyle = .rounded
        send.keyEquivalent = "\r"
        send.keyEquivalentModifierMask = .command
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(close))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        target.selectedSegment = 0
        target.target = self
        target.action = #selector(targetChanged)
        for view in [target, files, scroll, note, send, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            target.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            target.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            files.centerYAnchor.constraint(equalTo: target.centerYAnchor),
            files.leadingAnchor.constraint(equalTo: target.trailingAnchor, constant: 16),
            files.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.topAnchor.constraint(equalTo: target.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.heightAnchor.constraint(equalToConstant: 180),
            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
            send.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            send.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            cancel.trailingAnchor.constraint(equalTo: send.leadingAnchor, constant: -10),
            cancel.centerYAnchor.constraint(equalTo: send.centerYAnchor),
        ])
    }

    func present(on window: NSWindow, root: URL, scores: [URL], patches: [URL], target initial: Target) {
        self.root = root
        scoreFiles = scores
        patchFiles = patches
        target.selectedSegment = initial.rawValue
        request.string = ""
        targetChanged()
        window.beginSheet(panel)
        panel.makeFirstResponder(request)
    }
    @objc private func targetChanged() {
        files.removeAllItems()
        files.addItem(withTitle: "Whole project")
        for file in target.selectedSegment == 0 ? scoreFiles : patchFiles {
            let title = file.path.hasPrefix(root.path + "/") ? String(file.path.dropFirst(root.path.count + 1)) : file.lastPathComponent
            files.addItem(withTitle: title)
            files.lastItem?.representedObject = file
        }
    }
    @objc private func close() { panel.sheetParent?.endSheet(panel) }
    @objc private func submit() {
        let text = request.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let scope = Target(rawValue: target.selectedSegment) ?? .score
        let file = files.selectedItem?.representedObject as? URL
        close()
        onSubmit?(text, scope, file)
    }
}
