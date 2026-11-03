/// What a pane can show. Panes are frames; content is cargo: swapping
/// content never changes a pane's geometry.
public enum PaneContent: String, CaseIterable, Codable, Hashable, Sendable {
    case score, lilypond, compilerOutput, terminal, supercollider, python, cues, lexicon, agentLog

    /// Layouts saved before a content was retired fall back to the terminal
    /// (the Agent pane was a terminal running an agent).
    public init(from decoder: Decoder) throws {
        self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .terminal
    }

    public var title: String {
        switch self {
        case .score: return "Score"
        case .lilypond: return "LilyPond Source"
        case .compilerOutput: return "Compiler Output"
        case .terminal: return "Terminal"
        case .supercollider: return "SuperCollider Source"
        case .python: return "Python Source"
        case .cues: return "Cue Inspector"
        case .lexicon: return "Lexicon"
        case .agentLog: return "Agent Log"
        }
    }

    /// ⌃1…⌃9, then ⌃0.
    public var number: Int {
        let i = Self.allCases.firstIndex(of: self)! + 1
        return i == 10 ? 0 : i
    }

    /// The key after `␣ p`.
    public var chordKey: Character {
        switch self {
        case .score: return "s"
        case .lilypond: return "l"
        case .compilerOutput: return "o"
        case .terminal: return "t"
        case .supercollider: return "c"
        case .python: return "y"
        case .cues: return "u"
        case .lexicon: return "x"
        case .agentLog: return "a"
        }
    }
}

/// A window's arrangement: panes side by side (columns) or stacked (rows),
/// each with its share of the space and its content.
public struct PaneLayout: Codable, Hashable, Sendable {
    public enum Axis: String, Codable, Hashable, Sendable { case columns, rows }

    public var name: String
    public var axis: Axis
    public var contents: [PaneContent]
    /// Shares of the window, summing to 1.
    public var fractions: [Double]
    public var focused: Int

    public init(name: String, axis: Axis = .columns, contents: [PaneContent], fractions: [Double]? = nil, focused: Int = 0) {
        self.name = name
        self.axis = axis
        self.contents = contents
        let n = Double(max(contents.count, 1))
        self.fractions = fractions ?? Array(repeating: 1 / n, count: contents.count)
        self.focused = min(max(focused, 0), max(contents.count - 1, 0))
    }

    public static let presets: [PaneLayout] = [
        PaneLayout(name: "Write", contents: [.lilypond, .score], fractions: [0.42, 0.58], focused: 1),
        PaneLayout(name: "Read", contents: [.score]),
        PaneLayout(name: "Electronics", contents: [.supercollider, .score], fractions: [0.42, 0.58], focused: 1),
        PaneLayout(name: "Debug", contents: [.lilypond, .score, .compilerOutput], fractions: [0.34, 0.46, 0.2], focused: 0),
        PaneLayout(name: "Terminal", contents: [.terminal, .score], fractions: [0.42, 0.58], focused: 0),
    ]

    public var focusedContent: PaneContent? { contents.indices.contains(focused) ? contents[focused] : nil }

    /// Moves focus to the next pane, wrapping.
    public mutating func focusNext() {
        guard !contents.isEmpty else { return }
        focused = (focused + 1) % contents.count
    }

    /// Steps the focused pane through `available` content (skipping what
    /// another pane already shows), keeping every frame where it is.
    public mutating func cycle(forward: Bool = true, available: [PaneContent] = PaneContent.allCases) {
        guard let current = focusedContent else { return }
        let others = Set(contents.enumerated().filter { $0.offset != focused }.map(\.element))
        let candidates = available.filter { !others.contains($0) || $0 == current }
        let n = candidates.count
        guard n > 1 else { return }
        // Content outside `available` steps onto its first or last entry.
        let i = candidates.firstIndex(of: current) ?? (forward ? n - 1 : 0)
        contents[focused] = candidates[(i + (forward ? 1 : n - 1)) % n]
    }

    /// Shows `content` in the focused pane. If another pane shows it already,
    /// the two swap, so nothing is shown twice and nothing moves.
    /// Shows `content` in a pane of its own beside the others (taking
    /// `share` of the window), or, if a pane shows it already, closes that
    /// pane and gives its room back. Focus stays on the pane it was on.
    public mutating func toggle(_ content: PaneContent, share: Double = 0.3) {
        if let i = contents.firstIndex(of: content) {
            guard contents.count > 1 else { return }
            let freed = fractions.indices.contains(i) ? fractions[i] : 0
            contents.remove(at: i)
            if fractions.indices.contains(i) { fractions.remove(at: i) }
            let rest = fractions.reduce(0, +)
            fractions = rest > 0 ? fractions.map { $0 / rest * (rest + freed) } : Array(repeating: 1 / Double(contents.count), count: contents.count)
            if focused > i || focused >= contents.count { focused = max(0, focused - 1) }
        } else {
            let s = min(max(share, 0.1), 0.6)
            if fractions.count != contents.count { fractions = Array(repeating: 1 / Double(max(contents.count, 1)), count: contents.count) }
            fractions = fractions.map { $0 * (1 - s) } + [s]
            contents.append(content)
        }
    }

    public mutating func show(_ content: PaneContent) {
        guard let current = focusedContent, current != content else { return }
        if let other = contents.firstIndex(of: content) { contents[other] = current }
        contents[focused] = content
    }

    /// Navigation reuses a visible pane without moving its contents. If
    /// absent, open a new pane alongside the existing ones.
    public mutating func reveal(_ content: PaneContent, share: Double = 0.42) {
        if let existing = contents.firstIndex(of: content) {
            focused = existing
        } else {
            toggle(content, share: share)
            focused = contents.count - 1
        }
    }
}

/// Named arrangements saved by the user (`⌘⇧S`). Encoded as JSON by the UI.
public struct Workspaces: Codable, Hashable, Sendable {
    public var saved: [PaneLayout]

    public init(saved: [PaneLayout] = []) { self.saved = saved }

    /// Saves `layout` under `name`, replacing one of the same name.
    public mutating func save(_ layout: PaneLayout, as name: String) {
        var l = layout
        l.name = name
        if let i = saved.firstIndex(where: { $0.name == name }) { saved[i] = l } else { saved.append(l) }
    }
}
