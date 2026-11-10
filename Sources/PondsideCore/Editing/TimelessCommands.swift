/// The custom commands a score defines that take no time, read from their
/// definitions in the score's own files. Unmetered entry and the shared-measure
/// checks can then measure a bar that uses them (`\caes`, `\wind #1`,
/// `\featherOnce`) from its source.
///
/// Only definitions whose form shows they take no time count:
///
/// - `#(define-event-function …)` without a music argument, and
///   `#(make-dynamic-script …)`: a post-event.
/// - Music with no notes, rests or skips, whose commands take no time
///   themselves (`{ \once \override … \breathe }`, `\once \override …`,
///   `-\tweak … \startTextSpan`).
/// - Any definition directly after a `% pondside: no time` comment line, for
///   functions whose length the source cannot show (`define-music-function`).
///
/// Everything else (music functions, Scheme definitions, music) may take time.
/// A name defined more than once counts only if every definition does.
public enum TimelessCommands {
    public static let marker = "% pondside: no time"

    /// Built-in commands that take time, or change the meter, without a
    /// note event of their own.
    private static let timed: Set<String> = [
        "skip", "tuplet", "times", "partial", "time", "repeat", "alternative", "scaleDurations",
        "afterGrace", "unfoldRepeats", "compoundMeter", "cadenzaOn", "cadenzaOff", "breve", "longa", "maxima",
        "pondsideMeasure", "pondsideSpace", "pondsideLayout", "pondsideTimeline",
    ]

    /// Commands that end a definition's value at the top level.
    private static let topLevel: Set<String> = [
        "\\score", "\\book", "\\bookpart", "\\header", "\\paper", "\\layout", "\\midi",
        "\\include", "\\version", "\\language",
    ]

    private enum Form {
        case timeless
        case opaque
        /// Music: timeless when its commands are.
        case music(tree: Int, range: Range<Int>)
    }

    public static func names(in trees: [SyntaxTree]) -> Set<String> {
        var forms: [String: [Form]] = [:]
        for (index, tree) in trees.enumerated() {
            for (name, form) in definitions(in: tree, index: index) { forms[name, default: []].append(form) }
        }
        let sources = trees.map { LensContextScanner.Source($0) }
        let defined = Set(forms.keys)
        var result = Set(forms.filter { $0.value.allSatisfy { if case .timeless = $0 { true } else { false } } }.keys)
        // A definition may use another (`\caes` inside `{ \caesVariant }`):
        // grow the set until it is stable.
        var changed = true
        while changed {
            changed = false
            for (name, list) in forms where !result.contains(name) {
                let all = list.allSatisfy { form in
                    switch form {
                    case .timeless: return true
                    case .opaque: return false
                    case .music(let tree, let range):
                        var source = sources[tree]
                        source.timeless = result
                        return takesNoTime(source, range: range, defined: defined)
                    }
                }
                if all { result.insert(name); changed = true }
            }
        }
        return result
    }

    /// `defined`: the score's definitions; one used here counts only once
    /// it is known to take no time (`source.timeless`).
    private static func takesNoTime(_ source: LensContextScanner.Source, range: Range<Int>, defined: Set<String>) -> Bool {
        let tree = source.tree
        guard !tree.events.contains(where: { range.contains($0.range.lowerBound) }),
              !StructuralEditing.generatesMusic(tree, body: range) else { return false }
        for leaf in source.leaves(in: range) where leaf.kind == .command {
            let name = String(leaf.text.dropFirst())
            if timed.contains(name) || (defined.contains(name) && !source.timeless.contains(name)) { return false }
        }
        let context = LensContextScanner.scan(source, block: range)
        return context.custom.isEmpty && context.unsupported.allSatisfy { $0 == "markup" }
    }

    private static func definitions(in tree: SyntaxTree, index: Int) -> [(String, Form)] {
        let children = tree.root.children
        var result: [(String, Form)] = []
        var i = 0
        while i < children.count {
            defer { i += 1 }
            let node = children[i]
            guard node.kind == .assignment, let nameNode = node.children.first(where: { !$0.kind.isTrivia }),
                  nameNode.kind == .word else { continue }
            let name = tree.string(nameNode.range)
            var j = i + 1
            while j < children.count, children[j].kind.isTrivia { j += 1 }
            guard j < children.count else { result.append((name, .opaque)); continue }
            if marked(children, before: i, in: tree) {
                result.append((name, .timeless))
                continue
            }
            let first = children[j]
            switch first.kind {
            case .scheme:
                result.append((name, schemeForm(tree.string(first.range))))
            case .sequential, .simultaneous:
                result.append((name, .music(tree: index, range: first.range)))
            default:
                // `\once \override …` or `-\tweak … \startTextSpan`: every
                // node up to the next definition or top-level block.
                var end = j
                while end + 1 < children.count {
                    let next = children[end + 1]
                    if next.kind == .assignment { break }
                    if next.kind == .command, topLevel.contains(tree.string(next.range)) { break }
                    // A top-level Scheme form (`#(define …)` at the start of a line).
                    if next.kind == .scheme, next.range.lowerBound == 0 || tree.bytes[next.range.lowerBound - 1] == 10 { break }
                    end += 1
                }
                while end > j, children[end].kind.isTrivia { end -= 1 }
                result.append((name, .music(tree: index, range: first.range.lowerBound..<children[end].range.upperBound)))
            }
        }
        return result
    }

    /// `% pondside: no time` on the line just before the definition.
    private static func marked(_ children: [SyntaxNode], before index: Int, in tree: SyntaxTree) -> Bool {
        var k = index - 1
        while k >= 0 {
            let node = children[k]
            if node.kind == .whitespace {
                // A blank line between them breaks the link.
                if tree.string(node.range).filter({ $0 == "\n" }).count > 1 { return false }
                k -= 1
                continue
            }
            return node.kind == .lineComment && tree.string(node.range).hasPrefix(marker)
        }
        return false
    }

    private static func schemeForm(_ text: String) -> Form {
        let body = text.dropFirst().drop { $0 == " " || $0 == "\n" || $0 == "\t" }
        if body.hasPrefix("(make-dynamic-script") { return .timeless }
        if body.hasPrefix("(define-event-function") {
            // A music argument is parsed into the bar and would be counted.
            return text.contains("ly:music?") ? .opaque : .timeless
        }
        return .opaque
    }
}
