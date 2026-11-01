/// A key with modifiers, as a menu key equivalent or a direct key.
/// Toolkit-free: the UI translates its events into these.
public struct KeyStroke: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }
        public static let control = Modifiers(rawValue: 1)
        public static let option = Modifiers(rawValue: 2)
        public static let shift = Modifiers(rawValue: 4)
        public static let command = Modifiers(rawValue: 8)
    }

    /// A lowercase character ("k", "]", "/") or a named key ("tab", "space",
    /// "return", "escape", "delete", "up", "down", "left", "right").
    public var key: String
    public var modifiers: Modifiers

    public init(_ key: String, _ modifiers: Modifiers = []) {
        self.key = key.count == 1 ? key.lowercased() : key
        self.modifiers = modifiers
    }

    static let symbols: [String: String] = [
        "tab": "⇥", "space": "Space", "return": "↩", "escape": "⎋", "delete": "⌫",
        "up": "↑", "down": "↓", "left": "←", "right": "→",
    ]

    /// Apple's notation: ⌃⌥⇧⌘ then the key, letters in capitals.
    public var description: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + (Self.symbols[key] ?? key.uppercased())
    }

    /// Parses "⌘⇧S", "cmd+shift+s", "ctrl+tab", "⌃1".
    public init?(parsing text: String) {
        var mods: Modifiers = []
        var rest = Substring(text)
        let names: [(String, Modifiers)] = [("cmd+", .command), ("ctrl+", .control), ("alt+", .option),
                                            ("opt+", .option), ("shift+", .shift)]
        let glyphs: [Character: Modifiers] = ["⌘": .command, "⌃": .control, "⌥": .option, "⇧": .shift]
        outer: while !rest.isEmpty {
            if rest.count > 1, let first = rest.first, let m = glyphs[first] {
                mods.insert(m)
                rest = rest.dropFirst()
                continue
            }
            for (n, m) in names where rest.lowercased().hasPrefix(n) {
                mods.insert(m)
                rest = rest.dropFirst(n.count)
                continue outer
            }
            break
        }
        // A modifier alone ("⌘") is not a key.
        guard let last = rest.last, rest.count > 1 || glyphs[last] == nil else { return nil }
        let key = String(rest)
        if key.count > 1 {
            let lower = key.lowercased()
            let named = Self.symbols.first { $0.value.lowercased() == lower }?.key
            guard let k = Self.symbols[lower] != nil ? lower : named else { return nil }
            self.init(k, mods)
        } else {
            self.init(Self.symbols.first { $0.value == key }?.key ?? key, mods)
        }
    }
}

/// A leader chord: the leader key, then plain characters ("gm" = go to
/// measure). Display: "␣ g m".
public struct Chord: Hashable, Sendable, CustomStringConvertible, ExpressibleByStringLiteral {
    public var keys: [Character]

    public init(_ keys: String) { self.keys = Array(keys) }
    public init(stringLiteral value: String) { self.init(value) }

    public var description: String { (["␣"] + keys.map { $0 == " " ? "␣" : String($0) }).joined(separator: " ") }

    public func hasPrefix(_ prefix: [Character]) -> Bool {
        keys.count >= prefix.count && Array(keys.prefix(prefix.count)) == prefix
    }
}

/// What the user is looking at when a command runs. Commands declare what
/// they need; the palette and overlays rank and filter by it.
public struct CommandContext: Hashable, Sendable {
    public enum Focus: String, Hashable, Sendable { case score, source, supercollider, other }
    public var focus: Focus
    public var hasSelection: Bool
    public var durationArmed: Bool
    public var hasErrors: Bool
    public var fileCount: Int
    /// An agent is carrying out a request or finishing a patch.
    public var agentWorking: Bool

    public init(focus: Focus = .score, hasSelection: Bool = false, durationArmed: Bool = false,
                hasErrors: Bool = false, fileCount: Int = 1, agentWorking: Bool = false) {
        self.agentWorking = agentWorking
        self.focus = focus
        self.hasSelection = hasSelection
        self.durationArmed = durationArmed
        self.hasErrors = hasErrors
        self.fileCount = fileCount
    }
}

/// When a command makes sense.
public enum CommandRequirement: Hashable, Sendable {
    case always
    case selection
    case scoreFocus
    case errors
    case severalFiles
    /// The SuperCollider pane has the keyboard.
    case supercollider
    /// An agent is working in the background.
    case agentWorking

    public func isMet(in c: CommandContext) -> Bool {
        switch self {
        case .always: return true
        case .selection: return c.hasSelection
        case .scoreFocus: return c.focus == .score
        case .errors: return c.hasErrors
        case .severalFiles: return c.fileCount > 1
        case .supercollider: return c.focus == .supercollider
        case .agentWorking: return c.agentWorking
        }
    }
}

public struct CommandID: RawRepresentable, Hashable, Sendable, Comparable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(stringLiteral value: String) { self.rawValue = value }
    public var description: String { rawValue }
    public static func < (a: CommandID, b: CommandID) -> Bool { a.rawValue < b.rawValue }
}

/// One thing the user can do. Every command is reachable from the
/// keyboard: by leader chord, menu shortcut, or a direct key in the score.
public struct CommandSpec: Hashable, Sendable {
    public var id: CommandID
    public var title: String
    /// One line: what it does, for hover help and the palette.
    public var gloss: String
    public var category: String
    public var requires: CommandRequirement
    public var chords: [Chord]
    public var shortcut: KeyStroke?
    /// Direct keys handled by the score's key grammar (display only).
    public var keys: [String]

    public init(_ id: CommandID, _ title: String, _ gloss: String, category: String, requires: CommandRequirement = .always,
                chords: [Chord] = [], shortcut: KeyStroke? = nil, keys: [String] = []) {
        self.id = id
        self.title = title
        self.gloss = gloss
        self.category = category
        self.requires = requires
        self.chords = chords
        self.shortcut = shortcut
        self.keys = keys
    }

    public func isAvailable(in c: CommandContext) -> Bool { requires.isMet(in: c) }
}
