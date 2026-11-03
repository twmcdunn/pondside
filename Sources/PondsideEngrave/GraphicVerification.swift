/// Vector-only before/after verification for an agent's marked graphic section.
///
/// Source point-and-click links are deliberately ignored: only each graphic's
/// content, bounds and clip participate. Page order and page indices are
/// significant, but graphic order and duplicate counts are handled as multisets.
public enum GraphicVerification {
    /// Counts for one selected system. `before` and `after` include elements
    /// intersecting the region, including elements crossing its boundary.
    /// `added` and `removed` are multiset differences; `changed` pairs as many
    /// removals with additions as possible, then counts any remaining ones.
    public struct SystemReport: Sendable, Equatable {
        public let page: Int
        public let ordinal: Int
        public let before: Int
        public let after: Int
        public let added: Int
        public let removed: Int
        public let changed: Int
    }

    public enum Status: String, Sendable, Equatable {
        case ok
        case noSelectedChange
        case outsideChanged
        case inconclusive
    }

    /// The complete comparison. Aggregate selected counts are sums of the
    /// per-system counts. Outside counts are summed page by page, so moving an
    /// otherwise identical element to another page is still a change.
    public struct Report: Sendable, Equatable {
        public let systems: [SystemReport]

        public let selectedBefore: Int
        public let selectedAfter: Int
        public let selectedAdded: Int
        public let selectedRemoved: Int
        public let selectedChangedCount: Int

        /// Changes to elements wholly outside every selected region.
        public let outsideAdded: Int
        public let outsideRemoved: Int
        public let outsideAddedPages: Int
        public let outsideRemovedPages: Int

        /// Changed elements crossing a selected boundary. These make outside
        /// invariance inconclusive and are excluded from the outside multisets.
        public let changedCrossing: Int

        public var selectedChanged: Bool {
            selectedAdded > 0 || selectedRemoved > 0
        }

        /// Whether wholly-outside graphics and the page list are unchanged.
        /// Crossing changes are reported by `changedCrossing`, not hidden here.
        public var outsideUnchanged: Bool {
            outsideAdded == 0 && outsideRemoved == 0 &&
                outsideAddedPages == 0 && outsideRemovedPages == 0
        }

        /// Crossing ambiguity takes precedence, then outside changes, then a
        /// no-op. The individual counts retain any simultaneous failures.
        public var status: Status {
            if changedCrossing > 0 { return .inconclusive }
            if !outsideUnchanged { return .outsideChanged }
            if !selectedChanged { return .noSelectedChange }
            return .ok
        }

        /// A selected change with no wholly-outside or ambiguous crossing change.
        public var ok: Bool { status == .ok }
    }

    /// Compares pre-request pages with newly engraved pages using the original
    /// section geometry. Each selected region extends four staff spaces above
    /// and below its own staff. Missing or additional pages are outside changes.
    public static func compare(before: [EngravedPage], after: [EngravedPage],
                               section: GraphicSection) -> Report {
        var systems: [SystemReport] = []
        systems.reserveCapacity(section.systems.count)
        for system in section.systems {
            let region = selectionRegion(for: system)
            let beforeVisuals = visuals(in: before, page: system.page) {
                $0.bounds.intersects(region)
            }
            let afterVisuals = visuals(in: after, page: system.page) {
                $0.bounds.intersects(region)
            }
            let difference = multisetDifference(before: beforeVisuals, after: afterVisuals)
            systems.append(SystemReport(
                page: system.page, ordinal: system.ordinal,
                before: difference.before, after: difference.after,
                added: difference.added, removed: difference.removed,
                changed: difference.changed))
        }

        var regionsByPage: [Int: [Rect]] = [:]
        for system in section.systems {
            regionsByPage[system.page, default: []].append(selectionRegion(for: system))
        }

        var outsideAdded = 0, outsideRemoved = 0, changedCrossing = 0
        let pageCount = max(before.count, after.count)
        for page in 0..<pageCount {
            let regions = regionsByPage[page] ?? []
            let beforeParts = outsideAndCrossing(in: before, page: page, regions: regions)
            let afterParts = outsideAndCrossing(in: after, page: page, regions: regions)
            let outside = multisetDifference(before: beforeParts.outside, after: afterParts.outside)
            let crossing = multisetDifference(before: beforeParts.crossing, after: afterParts.crossing)
            outsideAdded += outside.added
            outsideRemoved += outside.removed
            changedCrossing += crossing.changed
        }

        return Report(
            systems: systems,
            selectedBefore: systems.reduce(0) { $0 + $1.before },
            selectedAfter: systems.reduce(0) { $0 + $1.after },
            selectedAdded: systems.reduce(0) { $0 + $1.added },
            selectedRemoved: systems.reduce(0) { $0 + $1.removed },
            selectedChangedCount: systems.reduce(0) { $0 + $1.changed },
            outsideAdded: outsideAdded,
            outsideRemoved: outsideRemoved,
            outsideAddedPages: max(after.count - before.count, 0),
            outsideRemovedPages: max(before.count - after.count, 0),
            changedCrossing: changedCrossing)
    }

    private struct Visual: Hashable {
        let content: Graphic.Content
        let bounds: Rect
        let clip: Rect?

        init(_ graphic: Graphic) {
            content = graphic.content
            bounds = graphic.bounds
            clip = graphic.clip
        }
    }

    private struct Difference {
        let before: Int
        let after: Int
        let added: Int
        let removed: Int
        let changed: Int
    }

    private static func selectionRegion(for system: GraphicSection.System) -> Rect {
        let staff = system.staff
        let space = staff.space > 0 ? staff.space : 1
        return Rect(x: system.pageX.lowerBound, y: staff.top - 4 * space,
                    width: system.pageX.upperBound - system.pageX.lowerBound,
                    height: staff.bottom - staff.top + 8 * space)
    }

    private static func visuals(in pages: [EngravedPage], page: Int,
                                where include: (Graphic) -> Bool) -> [Visual] {
        guard pages.indices.contains(page) else { return [] }
        return pages[page].graphics.filter(include).map(Visual.init)
    }

    private static func outsideAndCrossing(in pages: [EngravedPage], page: Int,
                                           regions: [Rect]) -> (outside: [Visual], crossing: [Visual]) {
        guard pages.indices.contains(page) else { return ([], []) }
        var outside: [Visual] = [], crossing: [Visual] = []
        for graphic in pages[page].graphics {
            guard regions.contains(where: { $0.intersects(graphic.bounds) }) else {
                outside.append(Visual(graphic))
                continue
            }
            let whollySelected = regions.contains { region in
                graphic.bounds.minX >= region.minX && graphic.bounds.maxX <= region.maxX &&
                    graphic.bounds.minY >= region.minY && graphic.bounds.maxY <= region.maxY
            }
            if !whollySelected { crossing.append(Visual(graphic)) }
        }
        return (outside, crossing)
    }

    private static func multisetDifference(before: [Visual], after: [Visual]) -> Difference {
        var beforeCounts: [Visual: Int] = [:], afterCounts: [Visual: Int] = [:]
        for visual in before { beforeCounts[visual, default: 0] += 1 }
        for visual in after { afterCounts[visual, default: 0] += 1 }
        var added = 0, removed = 0
        for visual in Set(beforeCounts.keys).union(afterCounts.keys) {
            let difference = (afterCounts[visual] ?? 0) - (beforeCounts[visual] ?? 0)
            if difference > 0 { added += difference } else { removed -= difference }
        }
        return Difference(before: before.count, after: after.count, added: added,
                          removed: removed, changed: max(added, removed))
    }
}
