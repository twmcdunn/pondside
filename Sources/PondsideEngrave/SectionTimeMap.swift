import Foundation
import PondsideCore
import PondsideTiming

/// The musical time at any x in a marked section: each note LilyPond timed
/// is matched to the notehead it engraved, and the edge's x is interpolated
/// between the neighbouring notes on that staff and system. It is the
/// section's version of `PlayheadTrack`, computed before an agent runs.
public struct SectionTimeMap: Sendable {
    public struct Edge: Sendable, Hashable {
        public var bar: Int
        public var moment: Rational
        /// The note whose position anchored this edge, when known.
        public var source: TimingLog.Row.Origin?
    }

    private struct Hit: Sendable {
        var page: Int
        var system: ClosedRange<Double>
        var x: Double
        var staffTop: Double
        var staffBottom: Double
        var staffName: String
        var moment: Rational
        var bar: Int
        var source: TimingLog.Row.Origin
    }

    private var hits: [Hit]

    public init(log: TimingLog, pages: [EngravedPage]) {
        var found: [Hit] = []
        var canonical: [String: String] = [:]
        func canon(_ path: String) -> String {
            if let known = canonical[path] { return known }
            let value = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
            canonical[path] = value
            return value
        }
        func samePath(_ a: String, _ b: String) -> Bool {
            if a == b { return true }
            let ca = canon(a), cb = canon(b)
            if ca == cb { return true }
            if !a.hasPrefix("/") { return cb.hasSuffix("/" + a) }
            if !b.hasPrefix("/") { return ca.hasSuffix("/" + b) }
            return false
        }
        for row in log.rows {
            let staff: String
            switch row.kind { case .note(let name, _), .rest(let name): staff = name; default: continue }
            guard let origin = row.origin else { continue }
            let position = SourcePosition(line: origin.line, character: origin.character)
            for (pageIndex, page) in pages.enumerated() {
                let graphics = page.linkedGraphics(at: position).filter { g in
                    guard let link = g.link else { return false }
                    return samePath(link.path, origin.file)
                }
                guard let bounds = EngravedPage.bounds(of: graphics) else { continue }
                let centre = Point(bounds.midX, bounds.midY)
                guard let staffGeometry = page.staff(at: centre) else { continue }
                let systems = EngravedPage.systems(of: page.staves)
                let middle = (staffGeometry.top + staffGeometry.bottom) / 2
                guard let system = systems.min(by: { Self.distance($0, to: middle) < Self.distance($1, to: middle) }) else { continue }
                let head = EngravedPage.notehead(among: graphics, space: staffGeometry.space)
                found.append(Hit(page: pageIndex, system: system,
                                 x: head?.bounds.midX ?? bounds.midX,
                                 staffTop: staffGeometry.top, staffBottom: staffGeometry.bottom,
                                 staffName: staff, moment: row.moment, bar: row.bar, source: origin))
            }
        }
        hits = found
    }

    private static func distance(_ range: ClosedRange<Double>, to y: Double) -> Double {
        range.contains(y) ? 0 : min(abs(y - range.lowerBound), abs(y - range.upperBound))
    }

    private func sameSystem(_ hit: Hit, page: Int, system: ClosedRange<Double>) -> Bool {
        hit.page == page && abs(hit.system.lowerBound - system.lowerBound) < 0.001
            && abs(hit.system.upperBound - system.upperBound) < 0.001
    }

    /// The canonical first and last timed moments on a system. Unlike an
    /// interpolated edge, these identify the system even when its graphics
    /// staff is hidden and has no noteheads of its own.
    public func systemMoments(page: Int, system: ClosedRange<Double>) -> (first: Rational, last: Rational)? {
        let moments = hits.filter { sameSystem($0, page: page, system: system) }.map(\.moment)
        guard let first = moments.min(), let last = moments.max() else { return nil }
        return (first, last)
    }

    /// The interpolated bar and moment at one edge. Always interpolate on
    /// the edge's own system: a hidden graphics staff has no matching
    /// noteheads, so falling back to every staff on the page can otherwise
    /// mix systems and even produce a backwards range.
    public func edge(at endpoint: GraphicSection.Endpoint, staffName: String? = nil) -> Edge? {
        var candidates = hits.filter { sameSystem($0, page: endpoint.page, system: endpoint.system) }
        let sameStaff = candidates.filter {
            abs($0.staffTop - endpoint.staff.top) < 0.5 && abs($0.staffBottom - endpoint.staff.bottom) < 0.5
        }
        if !sameStaff.isEmpty { candidates = sameStaff }
        if let staffName, !staffName.isEmpty {
            let name = staffName.lowercased()
            let named = candidates.filter { $0.staffName.lowercased() == name }
            if !named.isEmpty { candidates = named }
        }
        let sorted = candidates.sorted { $0.x < $1.x }
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let x = endpoint.pageX
        if x <= first.x { return Edge(bar: first.bar, moment: first.moment, source: first.source) }
        if x >= last.x { return Edge(bar: last.bar, moment: last.moment, source: last.source) }
        guard let upper = sorted.firstIndex(where: { $0.x >= x }), upper > 0 else {
            return Edge(bar: last.bar, moment: last.moment, source: last.source)
        }
        let a = sorted[upper - 1], b = sorted[upper]
        let dx = b.x - a.x
        guard dx > 1e-9 else { return Edge(bar: b.bar, moment: b.moment, source: b.source) }
        let t = max(0, min(1, (x - a.x) / dx))
        let value = a.moment.doubleValue + (b.moment.doubleValue - a.moment.doubleValue) * t
        // A microsecond is far finer than any engraved x; the moment stays a
        // rational, as LilyPond and the skill expect.
        let moment = Rational(Int((value * 1_000_000).rounded()), 1_000_000)
        let nearest = t < 0.5 ? a : b
        return Edge(bar: nearest.bar, moment: moment, source: nearest.source)
    }
}
