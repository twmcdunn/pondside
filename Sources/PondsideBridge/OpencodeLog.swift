import Foundation

/// opencode's own log, read for the errors it doesn't report over ACP.
///
/// When a provider refuses a request (free usage limit reached, no funds,
/// a bad key), opencode 1.19 logs `level=ERROR … message="stream error"
/// session.id=… error.error="…"` and then sends nothing more: the ACP
/// `session/prompt` call never answers. Pondside follows the log from the
/// moment it sends a request and fails the request with that error, in
/// words the user can act on.
public struct OpencodeLog: Sendable {
    public let url: URL
    /// Where this request's lines start.
    private let start: UInt64

    /// `$XDG_DATA_HOME/opencode/log/opencode.log`, else `~/.local/share/opencode/log/opencode.log`.
    public static var defaultURL: URL {
        let env = ProcessInfo.processInfo.environment
        let data = env["XDG_DATA_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share")
        return data.appendingPathComponent("opencode/log/opencode.log")
    }

    /// Starts following the log at its current end.
    public init(url: URL = OpencodeLog.defaultURL) {
        self.url = url
        start = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
    }

    /// The first error opencode logged for `session` since this watch began,
    /// from the model doing the work (not the small one that titles sessions).
    public func error(session: String) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        // A rotated (smaller) log starts again from its beginning.
        let from = size < start ? 0 : start
        guard size > from else { return nil }
        try? h.seek(toOffset: from)
        guard let data = try? h.read(upToCount: Int(min(size - from, 8_000_000))) else { return nil }
        return Self.error(in: String(decoding: data, as: UTF8.self), session: session)
    }

    static func error(in text: String, session: String) -> String? {
        for line in text.split(separator: "\n") where line.contains("level=ERROR") && line.contains("session.id=\(session)") {
            guard !line.contains("small=true"), let message = field("error.error", in: line) else { continue }
            return message
        }
        return nil
    }

    /// `key="quoted value"` or `key=value` from a logfmt line.
    static func field(_ key: String, in line: Substring) -> String? {
        guard let r = line.range(of: " \(key)=") else { return nil }
        var rest = line[r.upperBound...]
        if rest.hasPrefix("\"") {
            rest = rest.dropFirst()
            var out = ""
            var escaped = false
            for c in rest {
                if escaped { out.append(c); escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { break } else { out.append(c) }
            }
            return out
        }
        return String(rest.prefix { $0 != " " })
    }

    /// What the user should know and do, from a provider's error.
    public static func explain(_ error: String, model: String?) -> String {
        let m = model.map { " (\($0))" } ?? ""
        let lower = error.lowercased()
        let raw = error.replacingOccurrences(of: "AI_APICallError: ", with: "")
        if lower.contains("free usage limit") {
            return "opencode’s free usage limit is reached for this model\(m). Choose another model in Settings (⌘,), or add credit to your opencode account."
        }
        if lower.contains("insufficient") || lower.contains("funds") || lower.contains("credit") || lower.contains("quota") || lower.contains("402") {
            return "The account behind this model\(m) has no credit left. Add credit, or choose another model in Settings (⌘,)."
        }
        if lower.contains("401") || lower.contains("unauthorized") || lower.contains("api key") || lower.contains("authentication") {
            return "opencode isn’t signed in to this model’s provider\(m). Run `opencode auth login` in the terminal (⌃4), or choose another model in Settings (⌘,)."
        }
        if lower.contains("429") || lower.contains("rate limit") || lower.contains("too many requests") {
            return "The model’s provider is rate-limiting requests\(m). Try again in a minute, or choose another model in Settings (⌘,)."
        }
        if lower.contains("not found") || lower.contains("model") && lower.contains("unknown") {
            return "opencode can’t find this model\(m): choose another in Settings (⌘,)."
        }
        return "opencode’s model\(m) failed: \(raw)"
    }
}
