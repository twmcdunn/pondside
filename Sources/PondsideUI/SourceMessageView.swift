import AppKit
import PondsideEngrave

/// Read-only compiler prose whose source links stay inside Pondside.
@MainActor
final class SourceMessageView: NSTextView, NSTextViewDelegate {
    var onOpenSource: ((SourceDiagnosticLink) -> Void)?
    private var locations: [SourceDiagnosticLink] = []

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isRichText = true
        drawsBackground = true
        backgroundColor = Theme.editorBackground
        textColor = Theme.text
        font = Theme.monoFont
        textContainerInset = NSSize(width: 12, height: 10)
        minSize = .zero
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        linkTextAttributes = [.foregroundColor: Theme.accent, .underlineStyle: NSUnderlineStyle.single.rawValue]
        delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func show(_ message: String) {
        locations = SourceDiagnosticLink.links(in: message)
        let text = NSMutableAttributedString(string: message, attributes: [
            .font: font ?? Theme.monoFont, .foregroundColor: textColor ?? Theme.text,
        ])
        for (index, location) in locations.enumerated() {
            let url = URL(string: "pondside-source://location/\(index)")!
            text.addAttribute(.link, value: url, range: NSRange(location: location.range.lowerBound, length: location.range.count))
        }
        textStorage?.setAttributedString(text)
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL, url.scheme == "pondside-source",
              let index = Int(url.lastPathComponent), locations.indices.contains(index) else { return true }
        onOpenSource?(locations[index])
        return true
    }
}
