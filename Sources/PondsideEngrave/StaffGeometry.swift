import Foundation
import PondsideCore

/// A five-line staff found on an engraved page, in page coordinates.
///
/// LilyPond's SVG has no notion of a staff — just lines — so staves are
/// recovered from geometry: five horizontal strokes of one length, evenly
/// spaced. That is enough to turn a click into a staff position.
public struct Staff: Hashable, Sendable {
    /// Line heights, top to bottom.
    public var lineYs: [Double]
    public var minX: Double
    public var maxX: Double

    /// Distance between adjacent lines (one staff space).
    public var space: Double { (lineYs[lineYs.count - 1] - lineYs[0]) / Double(lineYs.count - 1) }
    public var top: Double { lineYs[0] }
    public var bottom: Double { lineYs[lineYs.count - 1] }
    public var width: Double { maxX - minX }

    /// Half-spaces above the bottom line: 0 is the bottom line, 1 the first
    /// space, 8 the top line, negatives are below the staff.
    public func position(ofY y: Double) -> Int {
        Int(((bottom - y) / (space / 2)).rounded())
    }

    public func y(ofPosition p: Int) -> Double {
        bottom - Double(p) * space / 2
    }

    /// The band a click may land in to address this staff: the staff plus
    /// `ledgerSpaces` of ledger lines above and below.
    public func band(ledgerSpaces: Double = 4) -> Rect {
        Rect(x: minX, y: top - ledgerSpaces * space, width: maxX - minX,
             height: bottom - top + 2 * ledgerSpaces * space)
    }
}

extension EngravedPage {
    /// The page's staves, top to bottom.
    public var staves: [Staff] { Self.staves(in: graphics) }

    /// The staff whose band contains `point`; the nearest when bands overlap.
    public func staff(at point: Point, among staves: [Staff]? = nil) -> Staff? {
        let candidates = (staves ?? self.staves).filter { $0.band().contains(point) }
        return candidates.min { abs($0.y(ofPosition: 4) - point.y) < abs($1.y(ofPosition: 4) - point.y) }
    }

    static func staves(in graphics: [Graphic]) -> [Staff] {
        // Horizontal stroked segments, grouped by their x extent.
        var groups: [String: (minX: Double, maxX: Double, ys: [Double])] = [:]
        for g in graphics {
            guard case .path(let path, _, let stroke, _) = g.content, stroke != nil,
                  path.elements.count == 2,
                  case .move(let a) = path.elements[0], case .line(let b) = path.elements[1],
                  abs(a.y - b.y) < 1e-6, abs(b.x - a.x) > 2 else { continue }
            let lo = min(a.x, b.x), hi = max(a.x, b.x)
            let key = "\((lo * 100).rounded()):\((hi * 100).rounded())"
            groups[key, default: (lo, hi, [])].ys.append(a.y)
        }
        var staves: [Staff] = []
        for (_, group) in groups {
            let ys = Array(Set(group.ys)).sorted()
            var i = 0
            // Greedy runs of five evenly spaced lines; gaps between staves
            // are always larger than the gaps within one.
            while i + 4 < ys.count {
                let run = Array(ys[i...(i + 4)])
                let gaps = zip(run.dropFirst(), run).map { $0 - $1 }
                let g0 = gaps[0]
                if g0 > 0, gaps.allSatisfy({ abs($0 - g0) <= g0 * 0.02 }) {
                    staves.append(Staff(lineYs: run, minX: group.minX, maxX: group.maxX))
                    i += 5
                } else {
                    i += 1
                }
            }
        }
        return staves.sorted { $0.top < $1.top || ($0.top == $1.top && $0.minX < $1.minX) }
    }

    /// The notehead among the graphics linked to one note: a glyph about one
    /// staff space tall and at least as wide — not the accidental (taller),
    /// stem (thinner), dot or flag.
    public static func notehead(among graphics: [Graphic], space: Double) -> Graphic? {
        graphics.filter { isNotehead($0, space: space) }
            .min { abs($0.bounds.height - space) < abs($1.bounds.height - space) }
    }
}

/// Turns a click on a staff into a note to insert.
///
/// The staff's clef is never parsed: the pitches of the notes already on
/// the staff calibrate it. Whatever clef, transposition or `\ottava` is in
/// force, the nearest notehead says which pitch sits on which line.
public enum MouseEntry {
    /// Something on the staff the click can relate to.
    public struct Anchor: Hashable, Sendable {
        /// The event's glyph bounds (the notehead for notes).
        public var bounds: Rect
        /// The notehead's absolute pitch; nil for rests and the like.
        public var pitch: Pitch?
        /// The caller's identifier for the event.
        public var ref: Int

        public init(bounds: Rect, pitch: Pitch?, ref: Int) {
            self.bounds = bounds
            self.pitch = pitch
            self.ref = ref
        }
    }

    public struct Target: Hashable, Sendable {
        /// Diatonic index (octave × 7 + step) of the clicked position.
        public var diatonicIndex: Int
        /// The clicked staff position (half-spaces above the bottom line).
        public var position: Int
        /// Insert after this anchor's event.
        public var after: Int

        public var step: Int { ((diatonicIndex % 7) + 7) % 7 }
        public var octave: Int { Int((Double(diatonicIndex) / 7).rounded(.down)) }
    }

    public enum Failure: Error, Hashable, Sendable {
        /// Nothing on the staff to the left of the click.
        case nothingBefore
        /// No notehead on the staff to say what its lines mean.
        case uncalibrated
    }

    public static func target(click: Point, staff: Staff, anchors: [Anchor]) -> Result<Target, Failure> {
        let onStaff = anchors.filter { $0.bounds.midX >= staff.minX && $0.bounds.midX <= staff.maxX }
        guard let before = onStaff.filter({ $0.bounds.minX <= click.x }).max(by: { $0.bounds.minX < $1.bounds.minX }) else {
            return .failure(.nothingBefore)
        }
        let pitched = onStaff.filter { $0.pitch != nil }
        guard let calibration = pitched.min(by: { abs($0.bounds.midX - click.x) < abs($1.bounds.midX - click.x) }),
              let pitch = calibration.pitch else {
            return .failure(.uncalibrated)
        }
        let offset = pitch.diatonicIndex - staff.position(ofY: calibration.bounds.midY)
        let position = staff.position(ofY: click.y)
        return .success(Target(diatonicIndex: offset + position, position: position, after: before.ref))
    }
}

extension MouseEntry {
    /// The anchors one source file contributes to `staff`; `ref` is the
    /// event index in `tree`.
    ///
    /// - Parameters:
    ///   - linkedFrom: whether a link path names this file.
    ///   - offset: the UTF-8 offset in `tree` of a link's position (through
    ///     the engraving map when the text changed since the compile).
    public static func anchors(on staff: Staff, page: EngravedPage, tree: SyntaxTree,
                               linkedFrom: (String) -> Bool, offset: (SourcePosition) -> Int?) -> [Anchor] {
        let band = staff.band()
        var groups: [SourcePosition: [Graphic]] = [:]
        var order: [SourcePosition] = []
        for g in page.graphics {
            guard let link = g.link, band.contains(Point(g.bounds.midX, g.bounds.midY)), linkedFrom(link.path) else { continue }
            if groups[link.position] == nil { order.append(link.position) }
            groups[link.position, default: []].append(g)
        }
        var anchors: [Anchor] = []
        for position in order {
            guard let graphics = groups[position], let o = offset(position) else { continue }
            if let n = tree.noteIndex(startingAt: o), tree.notes[n].role == .event, let e = tree.notes[n].event {
                guard let head = EngravedPage.notehead(among: graphics, space: staff.space) else { continue }
                anchors.append(Anchor(bounds: head.bounds, pitch: tree.notes[n].absolute, ref: e))
            } else if let e = tree.eventIndex(at: o), tree.events[e].range.lowerBound == o,
                      let bounds = EngravedPage.bounds(of: graphics) {
                // Rests, skips with glyphs, `q`: position without pitch.
                anchors.append(Anchor(bounds: bounds, pitch: nil, ref: e))
            }
        }
        return anchors
    }
}

extension EngravedPage {
    /// The staves that set a page's systems: those as wide as the page's
    /// widest. Short five-line symbols — the lines a graphic draws under a
    /// collection when its staff is hidden — sit between systems, and
    /// counting them would join two systems into one.
    static func systemStaves(of staves: [Staff]) -> [Staff] {
        guard let widest = staves.map(\.width).max(), widest > 0 else { return [] }
        let full = staves.filter { $0.width >= widest * 0.35 }
        return (full.isEmpty ? staves : full).sorted { $0.top < $1.top }
    }

    /// The page's systems as vertical bands, top to bottom. LilyPond's SVG
    /// has no systems either, so staves are grouped by the gaps between
    /// them: a gap clearly wider than the narrowest starts a new system. A
    /// page of single-staff systems, where every gap is alike, is one
    /// system per staff.
    public static func systems(of staves: [Staff]) -> [ClosedRange<Double>] {
        let sorted = systemStaves(of: staves)
        guard let first = sorted.first else { return [] }
        let gaps = zip(sorted, sorted.dropFirst()).map { $1.top - $0.bottom }
        let narrowest = gaps.min() ?? 0
        let alike = gaps.allSatisfy { $0 <= narrowest * 1.25 + 0.5 }
        var bands: [ClosedRange<Double>] = []
        var top = first.top, bottom = first.bottom
        for (gap, staff) in zip(gaps, sorted.dropFirst()) {
            if alike || gap > narrowest * 1.25 + 0.5 {
                bands.append(top...bottom)
                top = staff.top
            }
            bottom = staff.bottom
        }
        bands.append(top...bottom)
        return bands
    }

    /// The page's systems as vertical bands, top to bottom, the whole system
    /// tall. A system of several staves starts with LilyPond's start
    /// delimiter (SystemStartBar): a thin vertical line at the staves' left
    /// edge from the top staff's top down to the bottom staff's bottom. It
    /// spans staves the page shows no lines for too (an electronics staff
    /// a graphic draws), which the staff gaps alone can't see. Staves no
    /// delimiter covers are systems of their own; a page with no delimiter
    /// at all falls back to `systems(of:)`.
    public var systems: [ClosedRange<Double>] { Self.systems(of: staves, graphics: graphics) }

    public static func systems(of staves: [Staff], graphics: [Graphic]) -> [ClosedRange<Double>] {
        let sorted = systemStaves(of: staves)
        guard let space = sorted.first?.space, space > 0 else { return systems(of: staves) }
        var bands: [ClosedRange<Double>] = []
        for g in graphics where g.link == nil && g.bounds.width < 0.6 * space && g.bounds.height > 5 * space {
            guard let top = sorted.first(where: { abs($0.top - g.bounds.minY) < 0.5 * space && abs($0.minX - g.bounds.minX) < space })
            else { continue }
            bands.append(top.top...max(top.bottom, g.bounds.maxY))
        }
        guard !bands.isEmpty else { return systems(of: staves) }
        for staff in sorted where !bands.contains(where: { $0.lowerBound - 0.5 <= staff.top && staff.bottom <= $0.upperBound + 0.5 }) {
            bands.append(staff.top...staff.bottom)
        }
        var merged: [ClosedRange<Double>] = []
        for band in bands.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = merged.last, band.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound...max(last.upperBound, band.upperBound)
            } else {
                merged.append(band)
            }
        }
        return merged
    }

    /// Every linked graphic on the system holding height `y`, with its
    /// ledger-line reach above and below.
    public func links(onSystemAt y: Double) -> [PointAndClickLocation] {
        let s = staves
        guard let band = systems.first(where: { ($0.lowerBound - 6)...($0.upperBound + 6) ~= y }) else { return [] }
        let space = s.first?.space ?? 1
        let reach = (band.lowerBound - 4 * space)...(band.upperBound + 4 * space)
        return graphics.compactMap { g in
            guard let link = g.link, reach ~= g.bounds.midY else { return nil }
            return link
        }
    }
}
