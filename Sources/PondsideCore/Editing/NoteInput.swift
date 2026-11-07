/// A key press, abstracted from any UI toolkit.
public struct KeyInput: Hashable, Sendable {
    public enum Key: Hashable, Sendable {
        case character(Character)
        case up, down, left, right
        case delete, escape, enter
    }

    public var key: Key
    public var shift = false
    public var option = false
    public var command = false
    public var control = false

    public init(_ key: Key, shift: Bool = false, option: Bool = false, command: Bool = false, control: Bool = false) {
        self.key = key
        self.shift = shift
        self.option = option
        self.command = command
        self.control = control
    }
}

/// What a key press means in the score view.
public enum InputAction: Hashable, Sendable {
    case move(ScoreEditor.PitchMove)
    /// Apply to the selection (if any) and arm for the next inserted note.
    case setDuration(DurationValue)
    case toggleDot
    case toggleAccidental(Int)
    case insertNote(step: Int)
    case insertRest
    case delete
    case togglePostEvent(String)
    case toggleSlur
    /// Mirror the selected pitches about the centre of their range.
    case invert
    /// A pitch collection where the selection ends (`k`).
    case insertCollection
    /// The selected collection later (+1) or earlier (−1) by the input duration (⌥→ ⌥←).
    case shiftCollection(Int)
    /// The selected collection to the staff below (+1) or above (−1) (⌥⇧↓ ⌥⇧↑).
    case moveCollectionToStaff(Int)
    case select(step: Int, extend: Bool)
    case clearSelection
    case editSource
    case toggleSystemBreak
    case togglePageBreak
    /// The pending input buffer changed (shown in the status line).
    case buffer(String)
}

/// The score view's keyboard grammar. Keys are LilyPond wherever LilyPond
/// has an answer, so the text language and the GUI teach each other:
///
/// | keys | effect |
/// |---|---|
/// | `a`–`g` (`h`) | insert that note after the selection, nearest octave, current measure's accidental |
/// | `r` | insert a rest · with several events selected, repeat the selection after itself |
/// | `1 2 4 8 16 32 64 128` | duration, as in LilyPond; applies to the selection and arms the next note |
/// | `.` | toggle dot |
/// | `↑` `↓` | diatonic step · `⇧` octave · `⌥` chromatic |
/// | `←` `→` | previous / next object · `⇧` extends |
/// | `i` | invert the selection about the centre of its range |
/// | `k` | a pitch collection where the selection ends; a–g then fill it |
/// | `⌥←` `⌥→` | move the selected collection by the input duration |
/// | `⌥⇧↑` `⌥⇧↓` | move the selected collection to the staff above / below |
/// | `s` | toggle a slur over the selection (same as Space a s) |
/// | `( ) ~ [ ]` | slur endpoints, tie, beam: toggled on the selection |
/// | `=`, `-`, `0` | visible sharp, flat, natural: toggle selection or arm next note |
/// | `^.` `^>` `^-` `_1` … | directed articulations and fingerings |
/// | `\trill⏎` | any post-event command, typed as in LilyPond |
/// | `⌫` | delete · `⎋` cancel / deselect / disarm · `⏎` edit in source |
///
/// Duration entry works both ways: with a note selected it changes that note
/// (pitch-before-duration); with nothing selected it arms the next insertion
/// (duration-before-pitch). Multi-digit durations ("16") resolve as typed.
public struct NoteInput: Sendable {
    /// Quarter-tone units: sharp 2, flat -2, natural 0. Consumed by a successful note insertion.
    public private(set) var armedAccidental: Int?
    public private(set) var armedDuration: DurationValue?
    private var digits = ""
    private var lastDigitTime = 0.0
    private var command: String?   // after "\" (possibly with a direction prefix)
    private var direction: Character?

    /// Seconds within which digits combine into one duration.
    public static let digitWindow = 0.8

    public init() {}

    public var bufferText: String {
        if let command { return (direction.map(String.init) ?? "") + "\\" + command }
        if let direction { return String(direction) }
        return digits
    }

    public var isBuffering: Bool { command != nil || direction != nil || !digits.isEmpty }

    private static let durations = [1, 2, 4, 8, 16, 32, 64, 128]

    public mutating func handle(_ input: KeyInput, now: Double) -> [InputAction] {
        if input.command || input.control { return [] }

        // Command buffer: \name⏎
        if command != nil {
            switch input.key {
            case .character(let c) where c.isLetter:
                command! += String(c)
                return [.buffer(bufferText)]
            case .delete:
                if command!.isEmpty { command = nil; direction = nil } else { command!.removeLast() }
                return [.buffer(bufferText)]
            case .enter:
                let text = (direction.map(String.init) ?? "") + "\\" + command!
                let done = !command!.isEmpty
                command = nil
                direction = nil
                return done ? [.togglePostEvent(text), .buffer("")] : [.buffer("")]
            case .escape:
                command = nil
                direction = nil
                return [.buffer("")]
            default:
                return []
            }
        }

        if direction == nil, case .character(let c) = input.key, ["=", "-", "0"].contains(c) {
            let value = c == "=" ? 2 : (c == "-" ? -2 : 0)
            armedAccidental = armedAccidental == value ? nil : value
            digits = ""
            return [.toggleAccidental(value), .buffer("")]
        }

        // Direction prefix: ^ or _ then a shorthand, a digit, or a command.
        if let dir = direction {
            if case .character(let c) = input.key {
                if ".->^+!_".contains(c) {
                    direction = nil
                    return [.togglePostEvent(String(dir) + String(c)), .buffer("")]
                }
                if c.isNumber {
                    direction = nil
                    return [.togglePostEvent(String(dir) + String(c)), .buffer("")]
                }
                if c == "\\" {
                    command = ""
                    return [.buffer(bufferText)]
                }
            }
            direction = nil
            if case .escape = input.key { return [.buffer("")] }
        }

        switch input.key {
        case .up, .down:
            let sign = input.key == .up ? 1 : -1
            if input.shift && input.option { return [.moveCollectionToStaff(-sign)] }
            if input.shift { return [.move(.octave(sign))] }
            if input.option { return [.move(.chromatic(sign))] }
            return [.move(.step(sign))]
        case .left, .right:
            if input.option && !input.shift { return [.shiftCollection(input.key == .right ? 1 : -1)] }
            return [.select(step: input.key == .right ? 1 : -1, extend: input.shift)]
        case .delete:
            if !digits.isEmpty { digits = ""; return [.buffer("")] }
            return [.delete]
        case .escape:
            if !digits.isEmpty { digits = ""; return [.buffer("")] }
            return [.clearSelection]
        case .enter:
            digits = ""
            return [input.shift ? .togglePageBreak : .toggleSystemBreak]
        case .character(let c):
            return handleCharacter(c, now: now)
        }
    }

    private mutating func handleCharacter(_ c: Character, now: Double) -> [InputAction] {
        if let d = c.wholeNumberValue, c.isASCII {
            if now - lastDigitTime > Self.digitWindow { digits = "" }
            lastDigitTime = now
            var candidate = digits + String(d)
            if !Self.isDurationPrefix(candidate) { candidate = String(d) }
            guard Self.isDurationPrefix(candidate) else {
                digits = ""
                return [.buffer("")]
            }
            digits = candidate
            if let n = Int(candidate), Self.durations.contains(n), let value = DurationValue(denominator: n) {
                armedDuration = value
                // Keep the buffer if a longer duration could still follow
                // ("1" may become "16"); applying twice is harmless.
                let extendable = Self.durations.contains { String($0).hasPrefix(candidate) && String($0) != candidate }
                if !extendable { digits = "" }
                return [.setDuration(value), .buffer(digits)]
            }
            return [.buffer(digits)]
        }
        digits = ""
        switch c {
        case "a", "b", "c", "d", "e", "f", "g", "h":
            let step = ["c": 0, "d": 1, "e": 2, "f": 3, "g": 4, "a": 5, "b": 6, "h": 6][String(c)]!
            return [.insertNote(step: step)]
        case "r":
            return [.insertRest]
        case "s":
            return [.toggleSlur]
        case "i":
            return [.invert]
        case "k":
            return [.insertCollection]
        case ".":
            if var armed = armedDuration { armed.dots = armed.dots == 0 ? 1 : 0; armedDuration = armed }
            return [.toggleDot]
        case "(", ")", "~", "[", "]":
            return [.togglePostEvent(String(c))]
        case "^", "_":
            direction = c
            return [.buffer(bufferText)]
        case "\\":
            command = ""
            return [.buffer(bufferText)]
        default:
            return []
        }
    }

    static func isDurationPrefix(_ s: String) -> Bool {
        durations.contains { String($0).hasPrefix(s) }
    }

    /// Cancel an unfinished key sequence without changing armed values.
    public mutating func cancelPendingInput() { command = nil; direction = nil; digits = "" }

    public mutating func clearAccidental() { armedAccidental = nil }

    /// Arms a duration directly (e.g. from the palette).
    public mutating func arm(_ d: DurationValue?) {
        armedDuration = d
    }
}
