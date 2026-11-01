import AppKit
import WebKit

/// SuperCollider's own help (SCDoc), rendered by the interpreter and shown
/// here. Links are rendered before they are followed, as in the
/// SuperCollider IDE; web links open in the browser. ⌘↩ runs code
/// selected in a page's examples.
@MainActor
final class SCHelpView: NSView, WKNavigationDelegate {
    private let web: SCHelpWebView
    /// Runs code selected in the page.
    var onEvaluate: ((String) -> Void)? {
        get { web.onEvaluate }
        set { web.onEvaluate = newValue }
    }
    private let empty = NSTextField(wrappingLabelWithString: "⌘D on a class or method shows its help here.")

    override init(frame frameRect: NSRect) {
        let config = WKWebViewConfiguration()
        web = SCHelpWebView(frame: .zero, configuration: config)
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor
        web.navigationDelegate = self
        web.translatesAutoresizingMaskIntoConstraints = false
        web.isHidden = true
        addSubview(web)
        empty.font = Theme.bodyFont
        empty.textColor = Theme.secondaryText
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        addSubview(empty)
        NSLayoutConstraint.activate([
            web.leadingAnchor.constraint(equalTo: leadingAnchor),
            web.trailingAnchor.constraint(equalTo: trailingAnchor),
            web.topAnchor.constraint(equalTo: topAnchor),
            web.bottomAnchor.constraint(equalTo: bottomAnchor),
            empty.centerXAnchor.constraint(equalTo: centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -32),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var responder: NSView { web }

    func show(_ url: URL) {
        empty.isHidden = true
        web.isHidden = false
        // Pages link across the whole help tree, and to its scripts.
        let root = SCLangHost.shared.helpDirectory ?? url.deletingLastPathComponent().deletingLastPathComponent()
        web.loadFileURL(url, allowingReadAccessTo: root)
    }

    func goBack() { web.goBack() }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard action.navigationType == .linkActivated, let url = action.request.url else { return decisionHandler(.allow) }
        if url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return decisionHandler(.cancel)
        }
        // An anchor on the same page needs no rendering.
        if url.scheme == "file", let current = webView.url, url.path == current.path { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        Task {
            if let ready = await SCLangHost.shared.prepareHelp(url) { show(ready) } else { NSSound.beep() }
        }
    }
}

private final class SCHelpWebView: WKWebView {
    var onEvaluate: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if flags == .command, event.keyCode == 36 || event.keyCode == 76, window?.firstResponder === self || isDescendantFirstResponder {
            evaluateJavaScript("window.getSelection().toString()") { [weak self] result, _ in
                guard let code = result as? String, !code.isEmpty else { NSSound.beep(); return }
                MainActor.assumeIsolated { self?.onEvaluate?(code) }
            }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private var isDescendantFirstResponder: Bool {
        (window?.firstResponder as? NSView)?.isDescendant(of: self) ?? false
    }
}
