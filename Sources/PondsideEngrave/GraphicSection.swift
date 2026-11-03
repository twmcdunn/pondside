import Foundation
import PondsideCore

/// A section of a staff, marked by dragging across the engraved pages: from
/// an x on the system where the drag began to an x on the system nearest the
/// release. It is the range a graphics agent may change, in the drawing
/// code's coordinates (DESIGN.md §8, "A marked section").
///
/// A section is one staff across one or more systems. On the first system it
/// runs from the click to the end of the staff; on the systems between, all
/// of it; on the last, from the start of the staff to the release. A drag
/// upwards gives the same range, ordered from the top system down.
public struct GraphicSection: Sendable, Hashable {
    /// One edge of the section, on its system.
    public struct Endpoint: Sendable, Hashable {
        /// 0-based page index.
        public var page: Int
        /// The edge in page coordinates.
        public var pageX: Double
        /// Its fraction of the broken graphic piece's width (0…1), as the
        /// drawing's x runs from `(car (g-span grob))`.
        public var fraction: Double
        /// The graphic's broken piece on this system, or the staff's line
        /// when the drag started outside a graphic.
        public var piece: Rect
        /// The system's vertical band.
        public var system: ClosedRange<Double>
        /// The selected staff on this system.
        public var staff: Staff
    }

    /// One system the section covers, with the x range selected there.
    public struct System: Sendable, Hashable {
        public var page: Int
        /// 0-based system order across the score (pages top to bottom).
        /// A staff's systems are counted in the same order; the recipe that
        /// clips staff lines uses `ordinal + 1`.
        public var ordinal: Int
        public var pageX: ClosedRange<Double>
        public var fraction: ClosedRange<Double>
        public var piece: Rect
        public var system: ClosedRange<Double>
        public var staff: Staff
    }

    public var from: Endpoint
    public var to: Endpoint
    /// Systems top to bottom; the first and last carry the two edges.
    public var systems: [System]
    /// Which staff of its system was clicked (0 is the top staff).
    public var staffOrdinal: Int
    /// The graphic under the click, when the drag began on one.
    public var link: PointAndClickLocation?

    /// The whole staff's height in staff spaces above its middle line
    /// (`[-2, 2]` for five lines) — the box always covers the staff.
    public var staffSpaceRange: ClosedRange<Double> {
        let mid = (from.staff.top + from.staff.bottom) / 2
        let space = from.staff.space
        guard space > 0 else { return -2...2 }
        return ((mid - from.staff.bottom) / space)...((mid - from.staff.top) / space)
    }

    /// Marks a section from `from` to `to` on the clicked graphic (`link`,
    /// when the drag began on one). Returns nil if the drag is a point.
    public static func make(pages: [EngravedPage],
                            from: (page: Int, point: Point),
                            to: (page: Int, point: Point),
                            link: PointAndClickLocation?) -> GraphicSection? {
        guard pages.indices.contains(from.page), pages.indices.contains(to.page) else { return nil }
        let stavesByPage = pages.map(\.staves)
        let allSystems = stavesByPage.map { EngravedPage.systems(of: $0) }
        guard let fromSystem = nearest(allSystems[from.page], to: from.point.y) else { return nil }
        guard let toSystem = nearest(allSystems[to.page], to: to.point.y) else { return nil }

        // The staff is the one that was clicked; on other systems use the
        // same position from the top. The release's y only says which system
        // ends the section.
        let fromStaves = staves(in: allSystems[from.page][fromSystem], of: stavesByPage[from.page])
        guard !fromStaves.isEmpty else { return nil }
        let ordinal = fromStaves.indices.min {
            abs(middle(fromStaves[$0]) - from.point.y) < abs(middle(fromStaves[$1]) - from.point.y)
        } ?? 0

        // A graphic on a hidden staff has no lines to click: the drawing
        // itself marks that staff's place, and there may be no full staff
        // anywhere near the click. The section then takes its height from
        // the drawing on each system, not from the nearest visible staff.
        let representative = stavesByPage.map { EngravedPage.systemStaves(of: $0) }
        let graphicsOnly = link != nil && !representative[from.page].contains(where: {
            $0.band().contains(from.point)
        })

        var startPage = from.page, startSystem = fromSystem, startX = from.point.x, startY = from.point.y
        var endPage = to.page, endSystem = toSystem, endX = to.point.x, endY = to.point.y
        // A drag upwards means the same section: order it top to bottom.
        if (endPage, endSystem) < (startPage, startSystem) {
            swap(&startPage, &endPage); swap(&startSystem, &endSystem)
            swap(&startX, &endX); swap(&startY, &endY)
        }
        // On one system a marquee may be dragged either way.
        if startPage == endPage, startSystem == endSystem, startX > endX { swap(&startX, &endX) }
        guard startX != endX || startPage != endPage || startSystem != endSystem else { return nil }

        var coords: [(page: Int, system: Int)] = []
        if startPage == endPage {
            for i in startSystem...endSystem { coords.append((startPage, i)) }
        } else {
            for i in startSystem..<allSystems[startPage].count { coords.append((startPage, i)) }
            if startPage + 1 < endPage {
                for p in (startPage + 1)..<endPage {
                    for i in allSystems[p].indices { coords.append((p, i)) }
                }
            }
            for i in 0...endSystem { coords.append((endPage, i)) }
        }
        guard !coords.isEmpty else { return nil }

        var systemBase: [Int] = []
        var running = 0
        for bands in allSystems { systemBase.append(running); running += bands.count }
        var systems: [System] = []
        for (index, coord) in coords.enumerated() {
            let page = pages[coord.page]
            let band = allSystems[coord.page][coord.system]
            let inSystem = staves(in: band, of: stavesByPage[coord.page])
            guard !inSystem.isEmpty else { continue }
            let nearestStaff = inSystem[min(ordinal, inSystem.count - 1)]
            let graphicPiece = piece(of: link, on: page, system: coord.system,
                                     allSystems: allSystems[coord.page])
            let piece = graphicPiece ?? staffRect(nearestStaff)
            let staff: Staff
            if graphicsOnly, graphicPiece != nil {
                let full = representative[coord.page].min {
                    abs(middle($0) - piece.midY) < abs(middle($1) - piece.midY)
                } ?? nearestStaff
                let centre = index == 0 ? startY : (index == coords.count - 1 ? endY : piece.midY)
                staff = inferredStaff(for: piece, at: centre, like: full)
            } else {
                staff = nearestStaff
            }
            let lower = max(piece.minX, min(piece.maxX, index == 0 ? startX : piece.minX))
            let upper = max(lower, min(piece.maxX, index == coords.count - 1 ? endX : piece.maxX))
            let range = lower...upper
            systems.append(System(page: coord.page, ordinal: systemBase[coord.page] + coord.system,
                                  pageX: range, fraction: fraction(range, of: piece),
                                  piece: piece, system: band, staff: staff))
        }
        guard let first = systems.first, let last = systems.last else { return nil }
        let fromX = max(first.piece.minX, min(first.piece.maxX, startX))
        let toX = max(last.piece.minX, min(last.piece.maxX, endX))
        let from = Endpoint(page: first.page, pageX: fromX, fraction: fraction(fromX, of: first.piece),
                            piece: first.piece, system: first.system, staff: first.staff)
        let to = Endpoint(page: last.page, pageX: toX, fraction: fraction(toX, of: last.piece),
                          piece: last.piece, system: last.system, staff: last.staff)
        return GraphicSection(from: from, to: to, systems: systems, staffOrdinal: ordinal, link: link)
    }

    private static func staves(in band: ClosedRange<Double>, of staves: [Staff]) -> [Staff] {
        let inside = staves.filter { $0.top <= band.upperBound + 0.5 && $0.bottom >= band.lowerBound - 0.5 }
        return inside.isEmpty ? staves : inside
    }

    private static func middle(_ staff: Staff) -> Double { (staff.top + staff.bottom) / 2 }

    private static func nearest(_ bands: [ClosedRange<Double>], to y: Double) -> Int? {
        bands.indices.min { distance(bands[$0], y) < distance(bands[$1], y) }
    }

    private static func distance(_ band: ClosedRange<Double>, _ y: Double) -> Double {
        band.contains(y) ? 0 : min(abs(y - band.lowerBound), abs(y - band.upperBound))
    }

    /// The clicked graphic's part on this system, when it has one.
    private static func piece(of link: PointAndClickLocation?, on page: EngravedPage,
                              system: Int, allSystems: [ClosedRange<Double>]) -> Rect? {
        guard let link else { return nil }
        let group = page.graphics.filter { graphic in
            guard graphic.link == link else { return false }
            return nearest(allSystems, to: graphic.bounds.midY) == system
        }
        guard let bounds = EngravedPage.bounds(of: group), bounds.width > 0 else { return nil }
        return bounds
    }

    private static func staffRect(_ staff: Staff) -> Rect {
        Rect(x: staff.minX, y: staff.top, width: max(staff.maxX - staff.minX, 0.001),
             height: max(staff.bottom - staff.top, 0.001))
    }

    /// A staff where a drawing's hidden staff is: the drawing's middle,
    /// unless the drawing runs across systems (then the dragged y, which
    /// says which of its parts is meant). A staff space (and the line's
    /// width) comes from the nearest visible staff on the same system.
    private static func inferredStaff(for piece: Rect, at centre: Double, like staff: Staff) -> Staff {
        let space = staff.space > 0 ? staff.space : 1
        let middle = piece.height > 10 * space ? centre : piece.midY
        let top = middle - 2 * space
        return Staff(lineYs: (0..<5).map { top + Double($0) * space },
                     minX: staff.minX, maxX: staff.maxX)
    }

    private static func fraction(_ x: Double, of piece: Rect) -> Double {
        guard piece.width > 0 else { return 0 }
        return min(1, max(0, (x - piece.minX) / piece.width))
    }

    private static func fraction(_ range: ClosedRange<Double>, of piece: Rect) -> ClosedRange<Double> {
        fraction(range.lowerBound, of: piece)...fraction(range.upperBound, of: piece)
    }
}
