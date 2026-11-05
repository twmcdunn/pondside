import Foundation
import PondsideCore
import PondsideTiming

/// Where the audio is in the printed score: a vertical line over the system
/// playing at a given moment.
///
/// The track is built once for one engraving and its timing log. Each note
/// the playback reports (with the source position Pondside's timing dump
/// adds) is matched to the point-and-click glyphs of that engraving, so the
/// head follows repeats back through the printed bars, and the same track
/// serves the mockup and the mix.
public struct PlayheadTrack: Sendable {
    public struct Stop: Sendable, Hashable {
        public var seconds: Double
        public var position: PlayheadPosition
    }

    public var stops: [Stop]

    public init(log: TimingLog, pages: [EngravedPage]) {
        let map = TempoMap(log)
        let info = pages.map { page -> (staves: [Staff], systems: [ClosedRange<Double>]) in
            let staves = page.staves
            return (staves, EngravedPage.systems(of: staves))
        }
        var canonical: [String: String] = [:]
        func canon(_ path: String) -> String {
            if let known = canonical[path] { return known }
            let value = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            canonical[path] = value
            return value
        }
        var found: [(seconds: Double, x: Double, position: PlayheadPosition)] = []
        for row in log.rows {
            let anchored: Bool
            switch row.kind { case .note, .rest: anchored = true; default: anchored = false }
            guard anchored, let origin = row.origin,
                  let (_, position) = Self.locate(origin, in: pages, info: info, canon: canon)
            else { continue }
            found.append((map.seconds(at: row.moment), position.x, position))
        }
        // The same moment on several staves: one stop, at the leftmost of
        // the aligned notes (a small difference never shows).
        found.sort { ($0.seconds, $0.x) < ($1.seconds, $1.x) }
        var stops: [Stop] = []
        for hit in found {
            if let last = stops.last, abs(last.seconds - hit.seconds) < 1e-6 { continue }
            stops.append(Stop(seconds: hit.seconds, position: hit.position))
        }
        self.stops = stops
    }

    /// The head at `seconds`, playing from `start` (a bar the user chose):
    /// before the first stop of that pass it waits at the upcoming note,
    /// and between two stops on one system it glides along the notes.
    public func position(at seconds: Double, from start: Double = 0) -> PlayheadPosition? {
        guard !stops.isEmpty else { return nil }
        let first = stops.firstIndex { $0.seconds >= start - 1e-6 } ?? stops.startIndex
        guard first < stops.count else { return stops.last?.position }
        let anchor = stops[first]
        guard seconds >= anchor.seconds else { return anchor.position }
        var lo = first, hi = stops.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if stops[mid].seconds <= seconds { lo = mid } else { hi = mid - 1 }
        }
        let stop = stops[lo]
        guard lo + 1 < stops.count else { return stop.position }
        let next = stops[lo + 1]
        let sameSystem = next.position.page == stop.position.page
            && abs(next.position.top - stop.position.top) < 1
            && abs(next.position.bottom - stop.position.bottom) < 1
        guard sameSystem, next.seconds > stop.seconds else { return stop.position }
        let fraction = min(1, max(0, (seconds - stop.seconds) / (next.seconds - stop.seconds)))
        return PlayheadPosition(page: stop.position.page,
                                x: stop.position.x + (next.position.x - stop.position.x) * fraction,
                                top: stop.position.top, bottom: stop.position.bottom)
    }

    /// The note's glyph, staff and system on the engraved pages.
    private static func locate(
        _ origin: TimingLog.Row.Origin, in pages: [EngravedPage],
        info: [(staves: [Staff], systems: [ClosedRange<Double>])],
        canon: (String) -> String
    ) -> (Int, PlayheadPosition)? {
        let at = SourcePosition(line: origin.line, character: origin.character)
        for (index, page) in pages.enumerated() {
            let graphics = page.linkedGraphics(at: at).filter { graphic in
                guard let link = graphic.link else { return false }
                return samePath(link.path, origin.file, canon: canon)
            }
            guard let bounds = EngravedPage.bounds(of: graphics) else { continue }
            let centre = Point(bounds.midX, bounds.midY)
            let staves = info[index].staves
            let staff = page.staff(at: centre, among: staves)
            let space = staff?.space ?? staves.first?.space ?? 1
            let head = staff.flatMap { EngravedPage.notehead(among: graphics, space: $0.space) }
            let x = head?.bounds.midX ?? bounds.midX
            let y = head?.bounds.midY ?? centre.y
            let band = info[index].systems.first {
                ($0.lowerBound - 6 * space)...($0.upperBound + 6 * space) ~= y
            }
            let top = (band?.lowerBound ?? (staff?.top ?? y)) - 2 * space
            let bottom = (band?.upperBound ?? (staff?.bottom ?? y)) + 2 * space
            return (index, PlayheadPosition(page: index, x: x, top: top, bottom: bottom))
        }
        return nil
    }

    /// LilyPond may report a relative path in the timing and an absolute one
    /// in the SVG; compare both through symlinks when possible.
    private static func samePath(_ a: String, _ b: String, canon: (String) -> String) -> Bool {
        if a == b { return true }
        let ca = canon(a), cb = canon(b)
        if ca == cb { return true }
        if !a.hasPrefix("/") { return cb.hasSuffix("/" + a) }
        if !b.hasPrefix("/") { return ca.hasSuffix("/" + b) }
        return false
    }
}

/// The vertical line's place on a page, in page coordinates.
public struct PlayheadPosition: Sendable, Hashable {
    public var page: Int
    public var x: Double
    public var top: Double
    public var bottom: Double

    public init(page: Int, x: Double, top: Double, bottom: Double) {
        self.page = page
        self.x = x
        self.top = top
        self.bottom = bottom
    }
}
