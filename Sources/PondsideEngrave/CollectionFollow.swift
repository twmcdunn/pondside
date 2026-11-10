import PondsideCore

/// Where the next collection goes after one (`k` and `r` at a collection,
/// DESIGN.md §13): at the first note column the engraving shows clear of
/// its right edge.
///
/// A collection is anchored to one moment, but its notes are laid out a
/// fixed distance apart, so it reaches over later music by however wide it
/// is. The edge is measured on the latest engraving, whose point-and-click
/// links the pages carry, so everything here reads the engraved text. A
/// collection the engraving doesn't show yet (made since) is placed by its
/// moment and an estimate of its width.
public enum CollectionFollow {
    /// How long after the collection the next one starts.
    ///
    /// - Parameters:
    ///   - offset: where the collection's command starts in `trees[file]`
    ///     (the engraved text); nil when the engraving predates it.
    ///   - start: its moment (collections take no time, so moments match
    ///     between the engraved text and the current one).
    ///   - trees: the score's files as engraved, the root first.
    ///   - fileIndex: the file a link's path names.
    ///   - noteCount, accidentals: the collection now, which may hold more
    ///     notes than were engraved (typed since); the rest are estimated
    ///     from the engraved ones' spacing.
    public static func span(ofCollectionAt offset: Int?, moment start: LensFraction, file: Int, trees: [SyntaxTree],
                            pages: [EngravedPage], fileIndex: @escaping (String) -> Int?,
                            noteCount: Int, accidentals: Int = 0) -> LensFraction? {
        guard trees.indices.contains(file) else { return nil }
        let tree = trees[file]
        let collection = offset.flatMap { o in tree.collection(at: o).flatMap { $0.command.lowerBound == o ? $0 : nil } }
        guard var reader = ColumnReader(trees: trees, pages: pages, fileIndex: fileIndex) else { return nil }
        let space = reader.space
        func position(_ f: Int, _ o: Int) -> SourcePosition { reader.position(f, o) }
        func columns(page: EngravedPage, band: ClosedRange<Double>) -> [LensFraction: Double] {
            reader.columns(page: page, band: band)
        }

        // The collection's glyphs, by note.
        var located: (page: Int, glyphs: [Graphic], notes: [[Graphic]])?
        if let collection {
            for (p, page) in pages.enumerated() {
                let notes = collection.notes.map { n in
                    page.linkedGraphics(at: position(file, tree.notes[n].name.lowerBound)).filter { fileIndex($0.link!.path) == file }
                }.filter { !$0.isEmpty }
                if !notes.isEmpty { located = (p, notes.flatMap { $0 }, notes); break }
            }
        }

        // Its system: where its glyphs are, else the last one starting by its moment.
        var system: (page: Int, band: Int, columns: [LensFraction: Double])?
        if let found = located, let box = EngravedPage.bounds(of: found.glyphs) {
            let bands = pages[found.page].systems
            if let b = bands.firstIndex(where: { ($0.lowerBound - 6 * space)...($0.upperBound + 6 * space) ~= box.midY }) {
                system = (found.page, b, columns(page: pages[found.page], band: bands[b]))
            }
        } else {
            search: for (p, page) in pages.enumerated() {
                for (b, band) in page.systems.enumerated() {
                    let cols = columns(page: page, band: band)
                    guard let first = cols.keys.min() else { continue }
                    if start < first { break search }
                    system = (p, b, cols)
                }
            }
        }
        guard let system else { return nil }
        let page = pages[system.page]
        let bands = page.systems
        var points = system.columns
        let staffEnd = page.staves.filter { bands[system.band].contains($0.top) }.map(\.maxX).max()

        // The collection's extent, the notes typed since included.
        let heads = located?.notes.compactMap { EngravedPage.notehead(among: $0, space: space) } ?? []
        let lefts = heads.map(\.bounds.minX).sorted()
        var perNote = 2.1 * space
        if lefts.count >= 2, let first = lefts.first, let last = lefts.last {
            perNote = (last - first) / Double(lefts.count - 1)
            if perNote < 0.5 * space { perNote = 0 }   // stacked: a chord
        } else if let head = heads.first {
            perNote = head.bounds.width + 0.8 * space
        }
        let left: Double
        let right: Double
        if let found = located, let extent = EngravedPage.bounds(of: found.glyphs) {
            left = extent.minX
            right = extent.maxX + Double(max(0, noteCount - found.notes.count)) * perNote
        } else {
            guard let x = interpolatedX(at: start, in: points) else { return nil }
            left = x
            // Both enclosures, the notes, and their accidentals.
            right = x + 1.5 * space + Double(noteCount) * perNote + (perNote > 0 ? Double(accidentals) * space : 0)
        }
        let edge = right + 0.3 * space   // air after the closing enclosure
        points[start] = min(points[start] ?? .infinity, left)

        // Columns in time order; x never goes back (a grace, a centred rest).
        var ordered = points.filter { !($0.key < start) }.sorted { $0.key < $1.key }.map { (moment: $0.key, x: $0.value) }
        for i in ordered.indices.dropFirst() { ordered[i].x = max(ordered[i].x, ordered[i - 1].x) }
        if let next = ordered.first(where: { start < $0.moment && $0.x >= edge }) { return next.moment - start }

        // Past the system's end: the next system's first column.
        guard staffEnd.map({ $0 >= edge }) ?? true else { return nil }
        let following: [LensFraction: Double]
        if system.band + 1 < bands.count {
            following = columns(page: page, band: bands[system.band + 1])
        } else if system.page + 1 < pages.count, let band = pages[system.page + 1].systems.first {
            following = columns(page: pages[system.page + 1], band: band)
        } else {
            following = [:]
        }
        return following.keys.filter { start < $0 }.min().map { $0 - start }
    }

    static func interpolatedX(at t: LensFraction, in points: [LensFraction: Double]) -> Double? {
        if let exact = points[t] { return exact }
        let sorted = points.sorted { $0.key < $1.key }
        guard let after = sorted.firstIndex(where: { t < $0.key }) else { return sorted.last?.value }
        guard after > 0 else { return sorted[after].value }
        let a = sorted[after - 1], b = sorted[after]
        return a.value + (b.value - a.value) * ((t - a.key).double / (b.key - a.key).double)
    }
}

/// The leftmost notehead of each moment on a system, read from an engraving
/// through its point-and-click links (into `trees`, the engraved text).
struct ColumnReader {
    let trees: [SyntaxTree]
    let fileIndex: (String) -> Int?
    let space: Double
    private var moments: VoiceMoments
    private var sources: [Int: SourceText] = [:]

    init?(trees: [SyntaxTree], pages: [EngravedPage], fileIndex: @escaping (String) -> Int?) {
        guard let space = pages.lazy.compactMap({ $0.staves.first?.space }).first, space > 0 else { return nil }
        self.trees = trees
        self.fileIndex = fileIndex
        self.space = space
        moments = VoiceMoments(trees: trees)
    }

    private mutating func source(_ f: Int) -> SourceText {
        if let s = sources[f] { return s }
        let s = SourceText(trees[f].text)
        sources[f] = s
        return s
    }

    mutating func position(_ f: Int, _ o: Int) -> SourcePosition {
        let text = trees[f].text
        return source(f).position(of: text.utf8.index(text.startIndex, offsetBy: o))
    }

    private mutating func utf8Offset(_ f: Int, _ p: SourcePosition) -> Int? {
        let text = trees[f].text
        return source(f).index(of: p).map { text.utf8.distance(from: text.startIndex, to: $0) }
    }

    mutating func columns(page: EngravedPage, band: ClosedRange<Double>) -> [LensFraction: Double] {
        columns(page: page, bands: [band])[0]
    }

    /// Every band's columns in one pass over the page's glyphs.
    mutating func columns(page: EngravedPage, bands: [ClosedRange<Double>]) -> [[LensFraction: Double]] {
        let reaches = bands.map { ($0.lowerBound - 4 * space)...($0.upperBound + 4 * space) }
        var groups: [[PointAndClickLocation: [Graphic]]] = Array(repeating: [:], count: bands.count)
        for g in page.graphics {
            guard let link = g.link else { continue }
            for (b, reach) in reaches.enumerated() where reach ~= g.bounds.midY { groups[b][link, default: []].append(g) }
        }
        return groups.map { columns(of: $0) }
    }

    /// The moment of every linked event read so far (a collection's notes:
    /// the collection's), by link and by file and position.
    private(set) var linkMoments: [PointAndClickLocation: LensFraction] = [:]
    private(set) var positionMoments: [Int: [SourcePosition: LensFraction]] = [:]

    private mutating func columns(of groups: [PointAndClickLocation: [Graphic]]) -> [LensFraction: Double] {
        var out: [LensFraction: Double] = [:]
        for (link, glyphs) in groups {
            guard let f = fileIndex(link.path), trees.indices.contains(f), let o = utf8Offset(f, link.position) else { continue }
            let tree = trees[f]
            let note = tree.noteIndex(startingAt: o).flatMap { tree.notes[$0].role == .event ? $0 : nil }
            guard let e = note.flatMap({ tree.notes[$0].event }) ?? tree.eventIndex(at: o) else { continue }
            if let collection = tree.collection(containingEvent: e) {
                if let m = moments.moment(file: f, offset: collection.command.lowerBound) { record(link, file: f, m) }
                continue
            }
            guard let (onset, duration) = moments.event(file: f, index: e) else { continue }
            record(link, file: f, onset)
            guard note != nil, LensFraction.zero < duration,
                  let head = EngravedPage.notehead(among: glyphs, space: space) else { continue }
            out[onset] = min(out[onset] ?? .infinity, head.bounds.minX)
        }
        return out
    }

    private mutating func record(_ link: PointAndClickLocation, file: Int, _ m: LensFraction) {
        linkMoments[link] = m
        positionMoments[file, default: [:]][link.position] = m
    }
}

/// Where each moment falls across an engraving's systems: for drawing a
/// collection's anchor on the page while it is moved, before the
/// engraving that shows it lands. Built once per engraving.
public struct MomentMap: Sendable {
    public struct System: Sendable {
        public var page: Int
        public var top: Double
        public var bottom: Double
        public var staffEnd: Double?
        /// In time order; x never goes back.
        public var columns: [(moment: LensFraction, x: Double)]
    }

    public private(set) var systems: [System] = []
    private var linkMoments: [PointAndClickLocation: LensFraction] = [:]
    private var positionMoments: [Int: [SourcePosition: LensFraction]] = [:]

    /// The moment of the event a glyph's link names (a collection's note:
    /// the collection's), as engraved: a lookup, for an instant line at a click.
    public func moment(of link: PointAndClickLocation) -> LensFraction? { linkMoments[link] }

    /// The earliest moment among engraved positions in file `file`.
    public func moment(file: Int, positions: some Sequence<SourcePosition>) -> LensFraction? {
        guard let known = positionMoments[file] else { return nil }
        return positions.compactMap { known[$0] }.min()
    }

    /// `trees` are the score's files as engraved, the root first.
    public init(trees: [SyntaxTree], pages: [EngravedPage], fileIndex: @escaping (String) -> Int?) {
        guard var reader = ColumnReader(trees: trees, pages: pages, fileIndex: fileIndex) else { return }
        for (p, page) in pages.enumerated() {
            let staves = page.staves
            let bands = EngravedPage.systems(of: staves, graphics: page.graphics)
            for (band, columns) in zip(bands, reader.columns(page: page, bands: bands)) {
                var ordered = columns.sorted { $0.key < $1.key }.map { (moment: $0.key, x: $0.value) }
                guard !ordered.isEmpty else { continue }
                for i in ordered.indices.dropFirst() { ordered[i].x = max(ordered[i].x, ordered[i - 1].x) }
                let end = staves.filter { band.contains($0.top) }.map(\.maxX).max()
                systems.append(System(page: p, top: band.lowerBound - 2 * reader.space,
                                      bottom: band.upperBound + 2 * reader.space, staffEnd: end, columns: ordered))
            }
        }
        linkMoments = reader.linkMoments
        positionMoments = reader.positionMoments
    }

    /// The line over the system at moment `t`: between two columns in
    /// proportion, after a system's last column towards its staff's end.
    public func position(at t: LensFraction) -> PlayheadPosition? {
        guard !systems.isEmpty, !(t < .zero) else { return nil }
        let i = systems.lastIndex { !(t < $0.columns[0].moment) } ?? 0
        let s = systems[i]
        var points = s.columns
        if let last = points.last, last.moment < t {
            if i + 1 < systems.count, let end = s.staffEnd, let next = systems[i + 1].columns.first?.moment, last.moment < next {
                points.append((next, max(end, last.x)))
            } else if points.count >= 2 {
                // The score's end: on at the system's pace, up to its staff's end.
                let a = points[points.count - 2]
                let slope = (last.x - a.x) / (last.moment - a.moment).double
                let x = last.x + slope * (t - last.moment).double
                return PlayheadPosition(page: s.page, x: min(x, s.staffEnd ?? x), top: s.top, bottom: s.bottom)
            }
        }
        var map: [LensFraction: Double] = [:]
        for p in points { map[p.moment] = p.x }
        guard let x = CollectionFollow.interpolatedX(at: t, in: map) else { return nil }
        return PlayheadPosition(page: s.page, x: x, top: s.top, bottom: s.bottom)
    }
}
