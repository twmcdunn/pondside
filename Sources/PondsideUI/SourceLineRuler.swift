import AppKit
import PondsideCore

/// Shared by the TextKit 2 LilyPond editor and TextKit 1 SC editor. Query
/// NSTextInputClient geometry rather than forcing either editor into the
/// other's layout system. Only visible logical line starts are drawn.
@MainActor
final class SourceLineRuler: NSRulerView {
    private weak var textView: NSTextView?
    private var source = SourceText("")

    init(scrollView: NSScrollView, textView: NSTextView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        bind(to: textView)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var wantsDefaultClipping: Bool { true }

    func bind(to view: NSTextView) {
        NotificationCenter.default.removeObserver(self)
        textView = view
        clientView = view
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(textChanged), name: NSTextStorage.didProcessEditingNotification, object: view.textStorage)
        if let clip = scrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            center.addObserver(self, selector: #selector(layoutChanged), name: NSView.boundsDidChangeNotification, object: clip)
        }
        view.postsFrameChangedNotifications = true
        center.addObserver(self, selector: #selector(layoutChanged), name: NSView.frameDidChangeNotification, object: view)
        textChanged()
    }

    @objc private func textChanged() {
        guard let textView else { return }
        source = SourceText(textView.string)
        let digits = String(max(999, source.lineCount)) as NSString
        let width = ceil(digits.size(withAttributes: [.font: Theme.monoFont]).width) + 20
        if ruleThickness != width { ruleThickness = width }
        needsDisplay = true
    }

    @objc private func layoutChanged() { needsDisplay = true }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        // AppKit can ask a ruler to draw a dirty rect larger than its
        // gutter. Clip explicitly so its background cannot cover the
        // document, find bar, or neighboring file selector.
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSBezierPath(rect: bounds).addClip()
        Theme.chrome.setFill()
        bounds.fill()
        Theme.separator.setFill()
        NSRect(x: bounds.maxX - 1, y: rect.minY, width: 1, height: rect.height).fill()
        guard let textView, let window, !textView.visibleRect.isEmpty else { return }
        let visible = textView.visibleRect
        // TextKit 2 treats a hit above the first fragment (in the text
        // inset) as the document's end. Keep hit tests inside the text.
        let origin = textView.textContainerOrigin
        let x = max(visible.minX, origin.x + (textView.textContainer?.lineFragmentPadding ?? 0)) + 1
        let top = textView.characterIndexForInsertion(at: NSPoint(x: x, y: max(visible.minY, origin.y) + 1))
        let bottom = textView.characterIndexForInsertion(at: NSPoint(x: x, y: max(visible.maxY - 1, origin.y + 1)))
        let first = source.position(of: source.index(utf16Offset: min(top, bottom))).line
        let last = min(source.lineCount, source.position(of: source.index(utf16Offset: max(top, bottom))).line + 1)
        let attributes: [NSAttributedString.Key: Any] = [.font: Theme.monoFont, .foregroundColor: Theme.secondaryText]
        for line in first...last {
            guard let range = source.lineRange(line) else { continue }
            let offset = source.utf16Offset(of: range.lowerBound)
            var actual = NSRange()
            let screen = textView.firstRect(forCharacterRange: NSRange(location: offset, length: 0), actualRange: &actual)
            let frame = convert(window.convertFromScreen(screen), from: nil)
            let label = String(line) as NSString
            let size = label.size(withAttributes: attributes)
            let y = frame.midY - size.height / 2
            if y + size.height >= rect.minY, y <= rect.maxY {
                label.draw(at: NSPoint(x: bounds.maxX - size.width - 10, y: y), withAttributes: attributes)
            }
        }
    }
}
