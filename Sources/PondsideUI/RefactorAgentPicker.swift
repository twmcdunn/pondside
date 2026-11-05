import AppKit
import PondsideBridge

/// A per-refactor override. Native controls stay inside the explicit sheet;
/// changing this choice never rewrites the user's Settings preference.
@MainActor final class RefactorAgentPicker: NSView {
    let popup = NSPopUpButton()
    var onChange: ((AgentRun?) -> Void)?
    var selectedAgent: AgentRun? { popup.selectedItem?.representedObject as? AgentRun }

    init(found: [(AgentHarness, String?)], preference: String?, model: String?) {
        super.init(frame: NSRect(x: 0, y: 0, width: 380, height: 66))
        let label = NSTextField(labelWithString: "Agent:")
        label.font = Theme.bodyFont
        let hint = NSTextField(wrappingLabelWithString: "Applies to this refactor. Your Settings preference stays unchanged.")
        hint.font = Theme.secondaryFont
        hint.textColor = Theme.secondaryText
        func run(_ item: (AgentHarness, String?)) -> AgentRun? {
            item.1.map { AgentRun(harness: item.0, executable: $0, model: item.0 == .opencode ? model : nil) }
        }
        let preferred = found.first { $0.0.rawValue == preference && $0.1 != nil } ?? found.first { $0.1 != nil }
        let chosen = preference == "off" ? nil : preferred.flatMap(run)
        popup.autoenablesItems = false
        popup.addItem(withTitle: "Use Settings (\(chosen?.harness.title ?? "No Agent"))")
        popup.lastItem?.representedObject = chosen
        popup.menu?.addItem(.separator())
        for item in found {
            popup.addItem(withTitle: item.0.title + (item.1 == nil ? " (not installed)" : ""))
            popup.lastItem?.representedObject = run(item)
            popup.lastItem?.isEnabled = item.1 != nil
        }
        popup.menu?.addItem(.separator())
        popup.addItem(withTitle: "No Agent — Refactor Only")
        popup.target = self
        popup.action = #selector(changed)
        popup.setAccessibilityLabel("Agent for this patch refactor")
        for view in [label, popup, hint] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor), label.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            popup.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10), popup.topAnchor.constraint(equalTo: topAnchor),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.leadingAnchor.constraint(equalTo: leadingAnchor), hint.trailingAnchor.constraint(equalTo: trailingAnchor),
            hint.topAnchor.constraint(equalTo: popup.bottomAnchor, constant: 8), hint.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc private func changed() { onChange?(selectedAgent) }
}
