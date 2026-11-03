import Foundation

/// A source location in compiler output or its shortened error message.
/// Ranges use UTF-16, as attributed strings and text views do.
public struct SourceDiagnosticLink: Equatable, Sendable {
    public var range: Range<Int>
    public var file: String
    public var line: Int
    public var column: Int?

    public static func links(in message: String) -> [Self] {
        let pattern = #"(?m)^([^\r\n]+?\.(?:ly|ily|scd|sc)):([1-9][0-9]*)(?::([1-9][0-9]*))?(?=:[ \t]|[ \t\r\n]|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let text = message as NSString
        return regex.matches(in: message, range: NSRange(location: 0, length: text.length)).compactMap { match in
            let file = text.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespaces)
            guard !file.contains("://"), let line = Int(text.substring(with: match.range(at: 2))) else { return nil }
            let columnRange = match.range(at: 3)
            let column = columnRange.location == NSNotFound ? nil : Int(text.substring(with: columnRange))
            return Self(range: match.range.location..<NSMaxRange(match.range), file: file, line: line, column: column)
        }
    }
}
