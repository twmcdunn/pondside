/// The music the lens shows: one staff's worth of source.
public struct LensBlock: Sendable, Hashable {
    public var range: Range<Int>
    /// Where the block's context starts: the assignment's value, so
    /// `\transpose c d { … }` is read along with its braces.
    public var context: Range<Int>
    public var label: String?
    public var events: [Int]

    public init(range: Range<Int>, context: Range<Int>? = nil, label: String?, events: [Int]) {
        self.range = range
        self.context = context ?? range
        self.label = label
        self.events = events
    }
}

/// Finds the staff-level block around an offset: the outermost `{ … }` on
/// the path to it that is below every staff group, so `\tuplet` and
/// `\grace` bodies never win, and a voice split (`<< { } \\ { } >>`) is
/// kept whole. A top-level assignment holding the offset names the block
/// and bounds the search.
public enum LensBlockFinder {
    public static func block(in tree: SyntaxTree, at offset: Int) -> LensBlock? {
        let path = path(to: offset, in: tree.root)
        let assignment = assignmentValue(containing: offset, in: tree)
        let within = assignment?.value ?? tree.root.range

        var candidate: SyntaxNode?
        var previous: SyntaxNode?
        for node in path where within.contains(node.range.lowerBound) {
            defer { previous = node }
            switch node.kind {
            case .simultaneous where isVoiceSplit(node, tree: tree):
                return make(range: (candidate ?? node).range, assignment: assignment, tree: tree)
            case .simultaneous:
                // A staff group: the staff is further down.
                candidate = nil
            case .sequential where candidate == nil:
                if let previous, isTopLevelBlock(node, parent: previous, tree: tree) { continue }
                candidate = node
            default:
                continue
            }
        }
        guard let candidate else { return nil }
        return make(range: candidate.range, assignment: assignment, tree: tree)
    }

    private static func make(range: Range<Int>, assignment: (name: String, value: Range<Int>)?,
                             tree: SyntaxTree) -> LensBlock? {
        let events = tree.events.indices.filter {
            range.contains(tree.events[$0].range.lowerBound) && tree.events[$0].kind != .lyric
        }
        guard !events.isEmpty else { return nil }
        let start = min(assignment?.value.lowerBound ?? range.lowerBound, range.lowerBound)
        return LensBlock(range: range, context: start..<range.upperBound, label: assignment?.name, events: events)
    }

    /// Nodes from the root down to the deepest one containing `offset`.
    static func path(to offset: Int, in root: SyntaxNode) -> [SyntaxNode] {
        var path: [SyntaxNode] = []
        var node = root
        while true {
            path.append(node)
            guard let child = node.children.first(where: { $0.range.contains(offset) }) else { return path }
            node = child
        }
    }

    /// `name = value` at the top level whose value holds `offset`. The value
    /// runs to the first braced expression after the `=` (so it includes
    /// `\relative c'' { … }`).
    static func assignmentValue(containing offset: Int, in tree: SyntaxTree) -> (name: String, value: Range<Int>)? {
        let children = tree.root.children
        for (i, node) in children.enumerated() where node.kind == .assignment {
            var end = node.range.upperBound
            for sibling in children[(i + 1)...] {
                if sibling.kind == .assignment { break }
                end = sibling.range.upperBound
                if sibling.kind == .sequential || sibling.kind == .simultaneous || sibling.kind == .scheme || sibling.kind == .string || sibling.kind == .number { break }
            }
            let value = node.range.upperBound..<end
            if value.contains(offset), let name = node.children.first {
                return (tree.string(name.range), value)
            }
        }
        return nil
    }

    /// `<< { } \\ { } >>` or `<< \new Voice … >>`: voices of one staff.
    private static func isVoiceSplit(_ node: SyntaxNode, tree: SyntaxTree) -> Bool {
        node.children.contains { child in
            (child.kind == .escapedPunct && tree.string(child.range) == "\\\\")
                || (child.kind == .word && tree.string(child.range).hasSuffix("Voice"))
        }
    }

    private static let blockCommands: Set<String> = [
        "\\score", "\\book", "\\bookpart", "\\header", "\\layout", "\\paper", "\\midi", "\\with",
    ]

    /// `\score { … }` and friends hold staves, not one staff's music.
    private static func isTopLevelBlock(_ node: SyntaxNode, parent: SyntaxNode, tree: SyntaxTree) -> Bool {
        guard let index = parent.children.firstIndex(where: { $0 === node }) else { return false }
        let before = parent.children[..<index].last { !$0.kind.isTrivia }
        guard let before, before.kind == .command else { return false }
        return blockCommands.contains(tree.string(before.range))
    }
}
