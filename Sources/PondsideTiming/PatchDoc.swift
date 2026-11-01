import Foundation

/// A patch's documentation, `patch/<name>.patch.md`: the patch agent's
/// memory, kept in a file rather than in a conversation (which is
/// compacted, reset, or lost with a change of model). Two parts:
///
/// - the outline, rebuilt from the code every time the doc is read
///   (`PatchOutline`): each item's heading and `file:lines`;
/// - notes on intent under each heading, written by the agent
///   (`patch_note`) or by the composer, and kept across rebuilds. Each
///   note records the hash of the code it describes; when that code
///   changes the note is shown as stale until it is rewritten.
///
/// The file is plain Markdown the composer can read and edit; only the
/// generated lines (location, stale warnings) are rewritten.
public enum PatchDoc {
    public struct Note: Sendable, Hashable {
        public var text: String
        /// The code's hash when the note was written; nil for a note
        /// written by hand without one (never stale).
        public var code: String?
    }

    /// The note about the patch as a whole.
    public static let overview = "overview"

    public static func url(patch: URL) -> URL {
        patch.deletingLastPathComponent().appendingPathComponent(patch.deletingPathExtension().lastPathComponent + ".patch.md")
    }

    static let intro = """
    <!-- Pondside keeps this file. The headings and `file:lines` lines are rebuilt from the patch \
    each time it is read (patch_doc); the notes under them, by the patch agent (patch_note) or you, \
    are kept. A note is marked stale when the code it describes has changed since it was written. -->
    """
    static let staleLine = "**Stale:** the code changed since this note was written."
    static let goneLine = "*No longer in the patch.*"

    /// The notes in a doc, by item key.
    public static func notes(in markdown: String) -> [String: Note] {
        var out: [String: Note] = [:]
        var key: String?
        var body: [String] = []
        var code: String?
        var marked = false
        func flush() {
            guard let k = key else { return }
            let text = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { out[k] = Note(text: text, code: code) }
        }
        for line in markdown.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                flush()
                key = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                body = []
                code = nil
                marked = false
                continue
            }
            guard key != nil else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("<!-- note"), trimmed.hasSuffix("-->") {
                let h = trimmed.dropFirst("<!-- note".count).dropLast(3).trimmingCharacters(in: .whitespaces)
                code = h.isEmpty ? nil : h
                marked = true
                continue
            }
            if !marked, body.isEmpty, trimmed.hasPrefix("`"), trimmed.contains(":") { continue }   // the location line
            if trimmed == staleLine || trimmed == goneLine { continue }
            body.append(line)
        }
        flush()
        return out
    }

    /// The doc for `outline` with `notes`: the overview, every item in file
    /// order, then notes whose item has gone (kept, so nothing is lost).
    public static func render(outline: PatchOutline, notes: [String: Note], patchName: String) -> String {
        var out = "# \(patchName): patch doc\n\n\(intro)\n\n## \(overview)\n"
        if let n = notes[overview] { out += note(n) }
        out += "\n"
        for item in outline.items {
            out += "## \(item.key)\n`\(item.location)`" + (item.summary.isEmpty ? "" : " · " + item.summary.replacingOccurrences(of: "`", with: "'")) + "\n"
            if let n = notes[item.key] {
                if let c = n.code, c != item.hash { out += staleLine + "\n" }
                out += note(n)
            }
            out += "\n"
        }
        if !outline.lexicon.isEmpty {
            out += "## lexicon\n`dependencies/\(SCLexiconInclude.fileName)` · " + outline.lexicon.joined(separator: ", ") + "\n"
            if let n = notes["lexicon"] { out += note(n) }
            out += "\n"
        }
        let keys = Set(outline.items.map(\.key)).union([overview, "lexicon"])
        for (k, n) in notes.sorted(by: { $0.key < $1.key }) where !keys.contains(k) {
            out += "## \(k)\n\(goneLine)\n" + note(n) + "\n"
        }
        return out
    }

    static func note(_ n: Note) -> String {
        "<!-- note \(n.code ?? "") -->\n" + n.text + "\n"
    }

    /// The items whose notes are stale.
    public static func stale(outline: PatchOutline, notes: [String: Note]) -> [String] {
        outline.items.filter { i in notes[i.key].flatMap(\.code).map { $0 != i.hash } ?? false }.map(\.key)
    }

    /// Rebuilds the doc beside `patch` from its code, keeping the notes, and
    /// writes it. Returns it, with its stale items.
    @discardableResult
    public static func update(patch: URL) throws -> (text: String, stale: [String], outline: PatchOutline) {
        let file = url(patch: patch)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let outline = PatchOutline.build(patch: patch)
        let n = notes(in: existing)
        let text = render(outline: outline, notes: n, patchName: patch.lastPathComponent)
        if text != existing { try Data(text.utf8).write(to: file, options: .atomic) }
        return (text, stale(outline: outline, notes: n), outline)
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    /// Writes (or, with empty text, removes) the note on `key`, stamped
    /// with its code's current hash.
    @discardableResult
    public static func setNote(patch: URL, key: String, text: String) throws -> String {
        let file = url(patch: patch)
        let existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        let outline = PatchOutline.build(patch: patch)
        var n = notes(in: existing)
        let k = key.trimmingCharacters(in: .whitespaces)
        let resolved: String
        var code: String?
        if k == overview || k == "lexicon" {
            resolved = k
        } else if let item = outline.item(k) {
            resolved = item.key
            code = item.hash
        } else if n[k] != nil {
            resolved = k
        } else {
            throw Failure(description: "no item \(k) in the patch's outline; the keys are: "
                          + ([overview] + outline.items.map(\.key)).joined(separator: ", "))
        }
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        n[resolved] = body.isEmpty ? nil : Note(text: body, code: code)
        let doc = render(outline: outline, notes: n, patchName: patch.lastPathComponent)
        try Data(doc.utf8).write(to: file, options: .atomic)
        return resolved
    }
}
