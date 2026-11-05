import AppKit
import PondsideCore
import PondsideEngrave
import PondsideTiming
import PondsideBridge

/// Export vector system cards once, using the same renderer as the score.
@MainActor enum PerformanceScoreExport {
    static func systems(pages: [EngravedPage], log: TimingLog) throws -> ([PerformanceDeployment.System], [String: Data]) {
        let timeline = PerformanceTimeline(log: log, pages: pages)
        var data: [String: Data] = [:]
        for (index, card) in timeline.cards.enumerated() {
            let page = pages[card.page], band = card.band
            let bands = EngravedPage.systems(of: page.staves)
            let ordinal = bands.firstIndex(of: band)!
            let lower = ordinal == 0 ? max(page.viewBox.y, band.lowerBound - 12) : (bands[ordinal - 1].upperBound + band.lowerBound) / 2
            let upper = ordinal + 1 == bands.count ? min(page.viewBox.maxY, band.upperBound + 12) : (band.upperBound + bands[ordinal + 1].lowerBound) / 2
            let crop = Rect(x: page.viewBox.x, y: lower, width: page.viewBox.width, height: upper - lower)
            let view = SystemPDFView(page: page, crop: crop)
            data["systems/\(index + 1).pdf"] = view.dataWithPDF(inside: view.bounds)
        }
        guard Set(timeline.entries.map(\.card)).count == timeline.cards.count else {
            throw PatchContract.Failure("Some score systems have no source timing. Re-engrave the score before deploying.")
        }
        let systems = timeline.entries.map { PerformanceDeployment.System(file: "systems/\($0.card + 1).pdf", seconds: $0.seconds) }

        return (systems, data)
    }
}
@MainActor private final class SystemPDFView: NSView {
    let rendered: RenderedPage
    let crop: Rect
    override var isFlipped: Bool { true }
    init(page: EngravedPage, crop: Rect) {
        rendered = RenderedPage(page); self.crop = crop
        super.init(frame: NSRect(x: 0, y: 0, width: crop.width * 4, height: crop.height * 4))
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.white.setFill(); bounds.fill()
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.scaleBy(x: 4, y: 4)
        context.translateBy(x: -crop.x, y: -crop.y)
        rendered.draw(in: context, visible: crop)
        context.restoreGState()
    }
}
