/// A single replacement of a UTF-16 range, in the coordinates text views use.
public struct UTF16Replacement: Hashable, Sendable {
    /// Location and length in the *old* text, in UTF-16 code units.
    public var location: Int
    public var length: Int
    public var replacement: String

    public init(location: Int, length: Int, replacement: String) {
        self.location = location
        self.length = length
        self.replacement = replacement
    }

    /// Applies the replacement. Exposed so tests can prove round-trips.
    public func apply(to old: String) -> String {
        let units = Array(old.utf16)
        let head = units[..<location]
        let tail = units[(location + length)...]
        return String(decoding: head, as: UTF16.self) + replacement + String(decoding: tail, as: UTF16.self)
    }

    /// Maps an offset in the old text to the new text. Offsets inside the
    /// replaced range collapse to its end so a caret ends up after new text.
    public func mapOffset(_ offset: Int) -> Int {
        if offset <= location { return offset }
        let delta = replacement.utf16.count - length
        if offset >= location + length { return offset + delta }
        return location + replacement.utf16.count
    }
}

/// One changed span: `oldLength` UTF-16 units at `oldLocation` in the old
/// text became `newLength` units.
public struct TextHunk: Hashable, Sendable {
    public var oldLocation: Int
    public var oldLength: Int
    public var newLength: Int

    public init(oldLocation: Int, oldLength: Int, newLength: Int) {
        self.oldLocation = oldLocation
        self.oldLength = oldLength
        self.newLength = newLength
    }
}

public enum TextDiff {
    /// Every changed span between the texts, in order, so edits made in
    /// two places stay two spans and the text between them maps exactly.
    /// A shortest edit script (Myers) over what lies between the common
    /// prefix and suffix; past `maxEdits` changed units it gives up and
    /// returns the single span `minimalReplacement` would, so a large
    /// rewrite costs no more than before. Empty when the texts are equal.
    public static func hunks(from old: String, to new: String, maxEdits: Int = 256) -> [TextHunk] {
        let a = Array(old.utf16), b = Array(new.utf16)
        if a == b { return [] }
        var prefix = 0
        let maxPrefix = min(a.count, b.count)
        while prefix < maxPrefix, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        let maxSuffix = min(a.count, b.count) - prefix
        while suffix < maxSuffix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let n = a.count - prefix - suffix, m = b.count - prefix - suffix
        let whole = [TextHunk(oldLocation: prefix, oldLength: n, newLength: m)]
        if n == 0 || m == 0 { return whole }
        let limit = min(n + m, maxEdits)
        let off = limit + 1
        var v = [Int](repeating: 0, count: 2 * limit + 3)
        var trace: [[Int]] = []
        var end: Int?
        search: for d in 0...limit {
            trace.append(v)
            for k in stride(from: -d, through: d, by: 2) {
                var x = (k == -d || (k != d && v[k - 1 + off] < v[k + 1 + off])) ? v[k + 1 + off] : v[k - 1 + off] + 1
                var y = x - k
                while x < n, y < m, a[prefix + x] == b[prefix + y] { x += 1; y += 1 }
                v[k + off] = x
                if x >= n, y >= m { end = d; break search }
            }
        }
        guard let depth = end else { return whole }
        // Walk back: each step is one deleted old unit or one inserted new
        // unit, at an old position.
        var edits: [(at: Int, deletes: Bool)] = []
        var x = n, y = m
        for d in stride(from: depth, to: 0, by: -1) {
            let v = trace[d]
            let k = x - y
            let down = k == -d || (k != d && v[k - 1 + off] < v[k + 1 + off])
            let prevK = down ? k + 1 : k - 1
            let prevX = v[prevK + off], prevY = prevX - prevK
            edits.append(down ? (prevX, false) : (prevX, true))
            x = prevX; y = prevY
        }
        var out: [TextHunk] = []
        for e in edits.reversed() {
            let at = prefix + e.at
            if let last = out.last, last.oldLocation + last.oldLength == at {
                if e.deletes { out[out.count - 1].oldLength += 1 } else { out[out.count - 1].newLength += 1 }
            } else {
                out.append(TextHunk(oldLocation: at, oldLength: e.deletes ? 1 : 0, newLength: e.deletes ? 0 : 1))
            }
        }
        return out
    }

    /// The smallest single replacement turning `old` into `new`, found by
    /// trimming the common prefix and suffix. Never splits a surrogate pair.
    ///
    /// Used when an external tool rewrites the file: applying only the
    /// changed span keeps the caret, scroll position and undo history of
    /// every untouched region intact. Returns nil when the texts are equal.
    public static func minimalReplacement(from old: String, to new: String) -> UTF16Replacement? {
        let a = Array(old.utf16)
        let b = Array(new.utf16)
        if a == b { return nil }

        var prefix = 0
        let maxPrefix = min(a.count, b.count)
        while prefix < maxPrefix, a[prefix] == b[prefix] { prefix += 1 }
        if prefix > 0, UTF16.isLeadSurrogate(a[prefix - 1]) { prefix -= 1 }

        var suffix = 0
        let maxSuffix = min(a.count, b.count) - prefix
        while suffix < maxSuffix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        if suffix > 0, UTF16.isTrailSurrogate(a[a.count - suffix]) { suffix -= 1 }

        let replacement = String(decoding: b[prefix..<(b.count - suffix)], as: UTF16.self)
        return UTF16Replacement(location: prefix, length: a.count - suffix - prefix, replacement: replacement)
    }
}

/// FNV-1a, 64-bit. A fast, dependency-free content hash used to recognise
/// our own writes and to key render caches. Not cryptographic.
public struct ContentHash: Hashable, Sendable, CustomStringConvertible {
    public let value: UInt64

    public init<Bytes: Sequence>(bytes: Bytes) where Bytes.Element == UInt8 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in bytes {
            h ^= UInt64(b)
            h = h &* 0x0000_0100_0000_01B3
        }
        value = h
    }

    public init(_ string: String) {
        self.init(bytes: string.utf8)
    }

    public var description: String {
        let hex = String(value, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }
}
