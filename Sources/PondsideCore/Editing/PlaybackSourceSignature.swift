/// A conservative sound-change test. Known engraving-only syntax is ignored;
/// opaque Scheme, custom music, tempo, dynamics, instruments and timing remain
/// significant. Uncertain changes still go through LilyPond and playback.
public enum PlaybackSourceSignature {
    public static func equivalent(_ before: String, _ after: String) -> Bool {
        tokens(in: SyntaxTree(before)) == tokens(in: SyntaxTree(after))
    }

    public static func tokens(in tree: SyntaxTree) -> [String] {
        let breaks: Set<String> = ["\\break", "\\pageBreak", "\\noBreak", "\\noPageBreak", "\\allowBreak", "\\autoLineBreaksOn", "\\autoLineBreaksOff", "\\autoPageBreaksOn", "\\autoPageBreaksOff"]
        let outputBlocks: Set<String> = ["\\layout", "\\paper", "\\header", "\\markup", "\\markuplist"]
        let grobs: Set<String> = ["TimeSignature", "NoteHead", "Stem", "Beam", "Rest", "MultiMeasureRest", "BarLine", "Clef", "KeySignature", "TupletBracket", "TupletNumber", "TextScript", "TextSpanner", "DynamicText", "Hairpin", "Slur", "Tie", "StaffSymbol", "SpacingSpanner", "PaperColumn", "NonMusicalPaperColumn", "VerticalAxisGroup", "SystemStartBar"]
        func opaqueScheme(_ node: SyntaxNode) -> Bool {
            if node.kind == .scheme {
                let value = tree.string(node.range)
                return value.hasPrefix("#(") || value.hasPrefix("$(")
            }
            return node.children.contains(where: opaqueScheme)
        }
        var result: [String] = []
        func walk(_ node: SyntaxNode) {
            if node.kind.isTrivia || node.kind == .accidentalMark { return }
            if node.children.isEmpty { result.append(tree.string(node.range)); return }
            let children = node.children.filter { !$0.kind.isTrivia }
            var i = 0
            while i < children.count {
                let text = tree.string(children[i].range)
                if children[i].kind == .command, breaks.contains(text) { i += 1; continue }
                if children[i].kind == .command, outputBlocks.contains(text), i + 1 < children.count,
                   children[i + 1].kind == .sequential, !opaqueScheme(children[i + 1]) { i += 2; continue }
                if children[i].kind == .command, ["\\bar", "\\clef"].contains(text), i + 1 < children.count,
                   [.string, .word].contains(children[i + 1].kind) { i += 2; continue }
                var commandIndex = i
                while commandIndex < children.count, ["\\once", "\\undo", "\\temporary"].contains(tree.string(children[commandIndex].range)) { commandIndex += 1 }
                if commandIndex + 1 < children.count {
                    let command = tree.string(children[commandIndex].range)
                    let property = tree.string(children[commandIndex + 1].range)
                    if ["\\omit", "\\hide", "\\revert", "\\override"].contains(command),
                       property.split(separator: ".").contains(where: { grobs.contains(String($0)) }) {
                        if command == "\\override" {
                            if commandIndex + 3 < children.count, children[commandIndex + 2].kind == .equals,
                               !opaqueScheme(children[commandIndex + 3]) {
                                i = commandIndex + 4
                                continue
                            }
                        } else { i = commandIndex + 2; continue }
                    }
                }
                if [.openBracket, .closeBracket].contains(children[i].kind) { i += 1; continue }
                walk(children[i])
                i += 1
            }
        }
        walk(tree.root)
        return result
    }
}
