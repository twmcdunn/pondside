import PondsideCore

/// A message from the LilyPond compiler, mapped to a source position.
public struct Diagnostic: Hashable, Sendable, Codable {
    public enum Severity: String, Hashable, Sendable, Codable {
        case error
        case warning
        case programmingError = "programming error"
        case fatal = "fatal error"
    }

    public var severity: Severity
    public var message: String
    /// The file as LilyPond printed it (may be relative to the working directory).
    public var file: String?
    public var line: Int?
    /// 1-based, tab-expanded display column, as LilyPond prints it.
    public var column: Int?
    /// The source line LilyPond quotes after the message, split at the error.
    public var context: [String]

    public init(severity: Severity, message: String, file: String? = nil, line: Int? = nil, column: Int? = nil, context: [String] = []) {
        self.severity = severity
        self.message = message
        self.file = file
        self.line = line
        self.column = column
        self.context = context
    }

    /// The position in `source`, converting LilyPond's display column.
    public func position(in source: SourceText) -> SourcePosition? {
        guard let line, let column else { return nil }
        return source.position(line: line, displayColumn: column)
    }
}

/// Parses LilyPond's stderr log.
///
/// The format is `file:line:column: severity: message`, optionally followed
/// by two lines quoting the source split at the error point. Messages without
/// a location (`warning: …`, `fatal error: …`) are kept too. Anything else is
/// progress chatter and is ignored.
public enum DiagnosticParser {
    private static let markers: [(String, Diagnostic.Severity)] = [
        ("programming error: ", .programmingError),
        ("fatal error: ", .fatal),
        ("error: ", .error),
        ("warning: ", .warning),
    ]

    public static func parse(_ log: String) -> [Diagnostic] {
        var result: [Diagnostic] = []
        let lines = log.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            line.last == "\r" ? line.dropLast() : line
        }
        var i = 0
        while i < lines.count {
            let line = lines[i]
            i += 1
            guard var diagnostic = parseLine(line) else { continue }
            // A located diagnostic is followed by a two-line source quote: the
            // text up to the error, then the remainder indented to the column.
            if diagnostic.line != nil, i + 1 < lines.count,
               parseLine(lines[i]) == nil, parseLine(lines[i + 1]) == nil,
               !isProgress(lines[i]), !isProgress(lines[i + 1]) {
                diagnostic.context = [String(lines[i]), String(lines[i + 1])]
                i += 2
            }
            result.append(diagnostic)
        }
        return result
    }

    static func parseLine(_ line: Substring) -> Diagnostic? {
        for (marker, severity) in markers {
            if line.hasPrefix(marker) {
                return Diagnostic(severity: severity, message: String(line.dropFirst(marker.count)))
            }
            guard let r = line.firstRange(of: ": " + marker) else { continue }
            let location = line[..<r.lowerBound]
            let message = String(line[r.upperBound...])
            // location = file:line:column (file may contain colons).
            let parts = location.split(separator: ":", omittingEmptySubsequences: false)
            if parts.count >= 3, let l = Int(parts[parts.count - 2]), let c = Int(parts[parts.count - 1]) {
                let file = parts[..<(parts.count - 2)].joined(separator: ":")
                return Diagnostic(severity: severity, message: message, file: file, line: l, column: c)
            }
            if parts.count >= 2, let l = Int(parts[parts.count - 1]) {
                let file = parts[..<(parts.count - 1)].joined(separator: ":")
                return Diagnostic(severity: severity, message: message, file: file, line: l)
            }
            return Diagnostic(severity: severity, message: message, file: String(location))
        }
        return nil
    }

    private static let progressPrefixes = [
        "Processing `", "Parsing...", "Interpreting music...", "Preprocessing graphical objects...",
        "Finding the ideal number of pages...", "Fitting music on", "Drawing systems...",
        "Converting to", "Layout output to", "Success:", "GNU LilyPond",
    ]

    static func isProgress(_ line: Substring) -> Bool {
        progressPrefixes.contains { line.hasPrefix($0) }
    }
}


/// The tail of LilyPond's log, for failures the parser cannot turn into a
/// located diagnostic (a Guile backtrace, an internal error). Bounded so an
/// agent sees the cause without a whole build log.
public enum CompilerLog {
    public static func tail(_ log: String, lines: Int = 120, characters: Int = 12_000) -> String {
        let all = log.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = all.suffix(lines).joined(separator: "\n")
        return kept.count <= characters ? kept : String(kept.suffix(characters))
    }
}
