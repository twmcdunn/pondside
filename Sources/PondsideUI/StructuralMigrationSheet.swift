import AppKit

/// A standard, indeterminate progress sheet for the explicit migration job.
@MainActor
final class StructuralMigrationSheet: NSObject {
    private let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 450, height: 155),
                                styleMask: [.titled], backing: .buffered, defer: false)
    private let label = NSTextField(wrappingLabelWithString: "Checking LilyPond source…")
    private let spinner = NSProgressIndicator()
    private let cancel = NSButton(title: "Cancel", target: nil, action: nil)
    private weak var parent: NSWindow?
    private var cancelling = false
    var onCancel: () -> Void = {}

    override init() {
        super.init()
        panel.title = "Preparing Score"
        panel.isReleasedWhenClosed = false
        label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        label.preferredMaxLayoutWidth = 350
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.controlSize = .regular
        cancel.target = self
        cancel.action = #selector(cancelWork)
        cancel.keyEquivalent = "\u{1b}"
        let row = NSStackView(views: [spinner, label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 14
        let controls = NSStackView(views: [NSView(), cancel])
        controls.orientation = .horizontal
        controls.distribution = .fill
        let stack = NSStackView(views: [row, controls])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: panel.contentView!.centerYAnchor),
            controls.widthAnchor.constraint(equalTo: stack.widthAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 20), spinner.heightAnchor.constraint(equalToConstant: 20),
        ])
    }

    func begin(on window: NSWindow) {
        parent = window
        spinner.startAnimation(nil)
        window.beginSheet(panel)
    }

    func update(_ message: String) { if !cancelling { label.stringValue = message } }

    func finish() {
        spinner.stopAnimation(nil)
        parent?.endSheet(panel)
        parent = nil
        panel.orderOut(nil)
    }

    @objc private func cancelWork() {
        cancelling = true
        label.stringValue = "Cancelling…"
        cancel.isEnabled = false
        onCancel()
    }
}
