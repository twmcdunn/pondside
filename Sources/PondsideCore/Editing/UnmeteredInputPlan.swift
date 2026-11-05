/// A batch of note-entry intentions, prepared away from the UI thread.
/// Its only working state is the proposed .ly text and its derived CSTs.
public enum UnmeteredInputPlan {
    public enum Request: Sendable {
        /// A constrained ScoreEditor content edit against the current draft.
        case content(ScoreEdit)
        /// Exact source revisions and selection saved by note undo/redo.
        case restore(texts: [String: String], selection: Range<Int>, name: String)
        /// Resolve against the latest draft anchor while persistence catches up.
        case action(InputAction)
        case insert(step: Int?, duration: DurationValue, octave: Int?, accidental: Int?)
    }
    public struct Result: Sendable {
        public var files: [StructuralEditing.File]
        public var selection: Int
        public var selectionRange: Range<Int>
        public var name: String
        /// Chronological, minimal edits for mapping clicks through a draft.
        public var changes: [StructuralEditing.Change]
    }

    public static func prepare(_ requests: [Request], files: [StructuralEditing.File], root: String,
                               active: String, anchor initialAnchor: Int) throws -> Result {
        if requests.count == 1, case let .restore(texts, selection, name) = requests[0] {
            return try restoring(texts, selection: selection, name: name, files: files, active: active)
        }
        var files = files
        guard let index = files.firstIndex(where: { $0.id == active }) else { throw StructuralEditing.Failure("The input file is no longer open.") }
        guard files[index].tree.events.indices.contains(initialAnchor) else { throw StructuralEditing.Failure("The input cursor no longer refers to a note or empty measure.") }
        var transformations: [StructuralEditing.Change] = []
        var anchor = initialAnchor
        var selection = files[index].tree.events[anchor].range.lowerBound
        var actionName: String?
        var selectedAnchors = [selection]
        for request in requests {
            let tree = files[index].tree
            let edit: ScoreEdit?
            switch request {
            case .restore: throw StructuralEditing.Failure("History restoration must be prepared as its own revision.")
            case .content(let content): edit = content; actionName = content.name
            case .action(let action):
                let editor = ScoreEditor(tree)
                switch action {
                case .move(let move): edit = editor.move(events: [anchor], by: move)
                case .setDuration(let duration): edit = editor.setDuration(events: [anchor], to: duration)
                case .toggleDot: edit = editor.toggleDot(events: [anchor])
                case .toggleAccidental(let alteration): edit = editor.toggleAccidental(alteration, events: [anchor], structure: files.first { $0.id == root }?.tree)
                case .delete: edit = editor.delete(events: [anchor])
                case .togglePostEvent(let text): edit = editor.togglePostEvent(text, events: [anchor])
                default: throw StructuralEditing.Failure("This command is not a draft content edit.")
                }
                actionName = edit?.name
            case let .insert(step, duration, octave, accidental):
                edit = ScoreEditor(tree).insert(step: step, after: anchor, duration: duration, octave: octave, accidental: accidental)
            }
            guard let edit else { throw StructuralEditing.Failure("This note cannot be inserted at the input cursor.") }
            transformations.append(.init(file: active, edits: edit.edits))
            let proposed = files[index].parse(edit.edits.apply(to: tree.text))
            let changes = try StructuralEditing.resizingForContentChange(in: active, proposed: proposed, files: files, root: root)
            files[index].tree = proposed
            selectedAnchors = edit.selectionAnchors.isEmpty ? [selection] : edit.selectionAnchors
            selection = selectedAnchors.last ?? selection
            for change in changes {
                transformations.append(change)
                guard let file = files.firstIndex(where: { $0.id == change.file }) else { throw StructuralEditing.Failure("A shared input dependency is missing.") }
                files[file].tree = files[file].parse(change.edits.apply(to: files[file].tree.text))
                if file == index {
                    selection = change.edits.mapOffset(selection)
                    selectedAnchors = selectedAnchors.map { change.edits.mapOffset($0) }
                }
            }
            guard let next = files[index].tree.eventIndex(at: selection) else { throw StructuralEditing.Failure("The new input cursor could not be resolved.") }
            anchor = next
            selection = files[index].tree.events[anchor].range.lowerBound
        }
        // These constrained insertions and coordinated meter edits preserve
        // wrappers and timing by construction; never audit the whole project
        // on the per-keystroke preview path.
        let name = requests.count == 1 ? (actionName ?? "Unmetered Note Entry") : "Unmetered Note Entry"
        let final = files[index].tree
        let selected = selectedAnchors.compactMap { final.eventIndex(at: $0) }
        let range: Range<Int>
        if let last = requests.last, case .insert = last { range = selection..<selection }
        else if let first = selected.min(), let last = selected.max() { range = final.events[first].range.lowerBound..<final.events[last].range.upperBound }
        else { range = selection..<selection }
        return Result(files: files, selection: selection, selectionRange: range, name: name, changes: transformations)
    }

    /// Restoring an already constructed revision must not resize it again or
    /// infer selection through a replacement spanning shared meters and music.
    private static func restoring(_ texts: [String: String], selection: Range<Int>, name: String,
                                  files: [StructuralEditing.File], active: String) throws -> Result {
        var files = files
        var changes: [StructuralEditing.Change] = []
        for i in files.indices {
            guard let text = texts[files[i].id], text != files[i].tree.text else { continue }
            if let difference = TextDiff.minimalReplacement(from: files[i].tree.text, to: text) {
                let old = files[i].tree.text
                let lower = OffsetConversion.utf8(fromUTF16: difference.location, in: old)
                let upper = OffsetConversion.utf8(fromUTF16: difference.location + difference.length, in: old)
                changes.append(.init(file: files[i].id, edits: [TextEdit(lower..<upper, difference.replacement)]))
            }
            files[i].tree = files[i].parse(text)
        }
        guard let tree = files.first(where: { $0.id == active })?.tree,
              selection.upperBound <= tree.bytes.count,
              let event = tree.eventIndex(at: selection.lowerBound) else {
            throw StructuralEditing.Failure("The saved note selection no longer belongs to this file.")
        }
        return Result(files: files, selection: tree.events[event].range.lowerBound,
                      selectionRange: selection, name: name, changes: changes)
    }
}

