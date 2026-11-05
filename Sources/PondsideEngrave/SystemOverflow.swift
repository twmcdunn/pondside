import PondsideCore

/// A system wider than the score's other systems: it runs into the right
/// margin. LilyPond widens a line whose notes cannot fit rather than
/// squeezing them closer than their minimum distances, and no spacing
/// setting (`spacing-increment` included) changes those, so the fix is the
/// user's: fewer bars on the line, a break, or narrower content.
///
/// Found on the engraved pages: the right edge most systems share is the
/// justified line's end; staff lines that run past it overflow. Pages with
/// legend markers are skipped (their examples have their own layout), and so
/// is a score whose systems share no end in the outer quarter of the page
/// (ragged-right).
public struct SystemOverflow: Sendable, Hashable {
    /// 0-based page index.
    public var page: Int
    /// The overflowing staves' vertical extent, page coordinates.
    public var band: ClosedRange<Double>
    /// Where the justified systems end, page coordinates.
    public var edge: Double
    /// Where this system's staff lines end.
    public var right: Double
    /// How far it runs past `edge`, in millimetres of paper.
    public var amountMM: Double
    /// The leftmost linked glyph on the system, for naming where it is.
    public var first: PointAndClickLocation?

    public init(page: Int, band: ClosedRange<Double>, edge: Double, right: Double, amountMM: Double,
                first: PointAndClickLocation?) {
        self.page = page
        self.band = band
        self.edge = edge
        self.right = right
        self.amountMM = amountMM
        self.first = first
    }

    /// Overflowing systems, top to bottom, page by page. Empty when no right
    /// edge is shared by at least two staves (nothing to measure against).
    /// `tolerance` is in page units (staff spaces at the default size).
    public static func detect(in pages: [EngravedPage], tolerance: Double = 0.25) -> [SystemOverflow] {
        let staves: [(page: Int, staff: Staff)] = pages.enumerated().flatMap { index, page in
            page.markers.isEmpty ? page.staves.map { (index, $0) } : []
        }
        // A shared edge well inside the page is not a justified line's end
        // (two equal short lines of a ragged-right score).
        guard let edge = justifiedEdge(staves.map(\.staff.maxX)),
              let width = pages.first(where: { $0.markers.isEmpty })?.viewBox.width,
              edge > 0.75 * width else { return [] }
        var out: [SystemOverflow] = []
        for (index, page) in pages.enumerated() {
            let over = staves.filter { $0.page == index && $0.staff.maxX > edge + tolerance }
                .map(\.staff).sorted { $0.top < $1.top }
            guard !over.isEmpty else { continue }
            let mm = page.viewBox.width > 0 ? page.widthMM / page.viewBox.width : 1
            // Staves of one system end together; a gap of a few staves'
            // height without overflow, or a different end, starts another.
            var groups: [[Staff]] = []
            for staff in over {
                if let last = groups.last?.last, abs(last.maxX - staff.maxX) < 0.05,
                   staff.top - last.bottom < 4 * (last.bottom - last.top) + 8 {
                    groups[groups.count - 1].append(staff)
                } else {
                    groups.append([staff])
                }
            }
            for group in groups {
                let band = group[0].top...group[group.count - 1].bottom
                let right = group.map(\.maxX).max()!
                let first = page.graphics
                    .filter { $0.link != nil && $0.bounds.maxY >= band.lowerBound - 2 && $0.bounds.minY <= band.upperBound + 2 }
                    .min { $0.bounds.minX < $1.bounds.minX }?.link
                out.append(SystemOverflow(page: index, band: band, edge: edge, right: right,
                                          amountMM: (right - edge) * mm, first: first))
            }
        }
        return out
    }

    /// Whether the score turns LilyPond's automatic line breaks off
    /// (`\autoLineBreaksOff` in any of its files): then every system is
    /// the user's, and one that overflows is theirs to fix. With automatic
    /// breaks LilyPond chooses the lines and an overflow is not flagged.
    public static func applies(toSources texts: [String]) -> Bool {
        texts.contains { text in
            guard text.contains("\\autoLineBreaksOff") else { return false }
            let tree = SyntaxTree(text)
            var found = false
            tree.root.forEachLeaf { leaf in
                if !found, leaf.kind == .command, tree.string(leaf.range) == "\\autoLineBreaksOff" { found = true }
            }
            return found
        }
    }

    /// The right edge most staves share (to 0.05), if at least two do; on a
    /// tie the smaller, since an overflowing line is the wider one.
    static func justifiedEdge(_ rights: [Double]) -> Double? {
        var counts: [Int: Int] = [:]
        for r in rights { counts[Int((r / 0.05).rounded()), default: 0] += 1 }
        guard let best = counts.filter({ $0.value >= 2 })
            .max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { return nil }
        // The exact value: the largest of the staves in that bin.
        return rights.filter { Int(($0 / 0.05).rounded()) == best.key }.max()
    }
}
