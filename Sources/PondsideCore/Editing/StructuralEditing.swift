/// A source-only contract for GUI structural edits. Each voice keeps its music
/// in `\pondsideMeasure \pondsideBarA { ... }`; the referenced definition owns
/// its meter, length and (optionally) breaks. No timing state lives outside .ly.
public enum StructuralEditing {
    public struct File: Sendable {
        public var id: String
        public var tree: SyntaxTree
        public var entryLanguage: PitchLanguage
        public var includedLanguages: [String: PitchLanguage]
        public init(id: String, tree: SyntaxTree, entryLanguage: PitchLanguage = .nederlands,
                    includedLanguages: [String: PitchLanguage] = [:]) {
            self.id = id
            self.tree = tree
            self.entryLanguage = entryLanguage
            self.includedLanguages = includedLanguages
        }
        public func parse(_ text: String) -> SyntaxTree {
            let languages = includedLanguages
            return SyntaxTree(text, language: entryLanguage) { languages[$0] }
        }
    }

    public struct Change: Sendable {
        public var file: String
        public var edits: [TextEdit]
        public init(file: String, edits: [TextEdit]) { self.file = file; self.edits = edits }
    }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public struct Overflow: Error, Sendable, CustomStringConvertible {
        public let file: String
        public let measure: String
        public let meter: LensTime
        public var description: String { "\(file): the music exceeds \(meter.beats)/\(meter.beatType)." }
    }

    public struct Measure: Sendable {
        public var name: String
        public var body: Range<Int>
        public var invocation: Range<Int>
    }

    public static let marker = "% pondside-structure v1"
    private static let endMarker = "% end pondside-structure"
    private static let prefix = "pondsideBar"

    public static func isManaged(_ tree: SyntaxTree) -> Bool {
        tree.root.children.contains { $0.kind == .lineComment && tree.string($0.range).hasPrefix(marker) }
    }

    public static func managesBreaks(_ tree: SyntaxTree) -> Bool {
        tree.root.children.contains { $0.kind == .lineComment && tree.string($0.range).hasPrefix(marker) && tree.string($0.range).contains("breaks=1") }
    }

    /// The enclosing managed measure, rather than the nearest nested tuplet or
    /// tremolo brace. The latter is never a valid place to insert a meter.
    public static func measure(in tree: SyntaxTree, at offset: Int) -> Measure? {
        measures(in: tree).first { $0.body.contains(offset) }
    }

    public static func measures(in tree: SyntaxTree) -> [Measure] {
        var result: [Measure] = []
        tree.root.forEachNode { node in
            let children = node.children.filter { !$0.kind.isTrivia }
            for i in children.indices where children[i].kind == .command && tree.string(children[i].range) == "\\pondsideMeasure" {
                guard i + 2 < children.count, children[i + 1].kind == .command,
                      children[i + 2].kind == .sequential else { continue }
                let name = String(tree.string(children[i + 1].range).dropFirst())
                guard name.hasPrefix(prefix) else { continue }
                let range = children[i + 2].range
                result.append(Measure(name: name, body: (range.lowerBound + 1)..<(range.upperBound - 1),
                                      invocation: children[i].range.lowerBound..<range.upperBound))
            }
        }
        return result
    }

    struct Bar {
        var time: LensTime
        var breakCommand: String?
        var explicitTime: LensTime?
        var length: LensFraction
    }
    struct Part {
        var file: String
        var edits: [TextEdit]
        var bars: [Bar]
    }

    /// Conservative import: complete, explicitly delimited sequential measures
    /// with statically known timing. Unsupported source is left entirely alone.
    /// In particular, compiling Scheme does not prove a unique editable source.
    public static func migrate(_ files: [File], root: String, sharedBreaks: Bool, observations: [Observation] = []) throws -> [Change] {
        guard let rootFile = files.first(where: { $0.id == root }) else { throw Failure("The root score is missing.") }
        if isManaged(rootFile.tree) {
            if !rootFile.tree.text.contains(runtime) {
                let nodes = rootFile.tree.root.children
                guard let index = nodes.firstIndex(where: { $0.kind == .assignment && $0.children.first.map({ rootFile.tree.string($0.range) }) == "pondsideMeasure" }),
                      let value = nodes.dropFirst(index + 1).first(where: { !$0.kind.isTrivia }), value.kind == .scheme else {
                    throw Failure("The shared-measure helper is missing. Restore its source definition before reapplying the contract.")
                }
                var start = nodes[index].range.lowerBound
                if let previous = nodes[..<index].last(where: { !$0.kind.isTrivia }), previous.kind == .scheme,
                   rootFile.tree.string(previous.range).hasPrefix("#(define (pondside-break-music?") { start = previous.range.lowerBound }
                var upgraded = files
                let i = upgraded.firstIndex(where: { $0.id == root })!
                upgraded[i].tree = upgraded[i].parse([TextEdit(start..<value.range.upperBound, (rootFile.tree.text.contains(interpretedRuntime) ? "" : interpretedRuntime + "\n") + runtime)].apply(to: rootFile.tree.text))
                let followup = try migrate(upgraded, root: root, sharedBreaks: sharedBreaks, observations: observations)
                return files.compactMap { original in
                    let text = upgraded.first(where: { $0.id == original.id })!.tree.text
                    return sourceChange(file: original.id, from: original.tree.text, to: followup.filter { $0.file == original.id }.flatMap(\.edits).apply(to: text))
                }
            }
            try validate(files, root: root)
            return try settingBreaks(sharedBreaks, files: files, root: root)
        }
        let expanded = try expandLayoutRepeats(files)
        if zip(files, expanded).contains(where: { $0.tree.text != $1.tree.text }) {
            let changes = try migrate(expanded, root: root, sharedBreaks: sharedBreaks, observations: observations)
            return files.compactMap { original in
                let normalized = expanded.first(where: { $0.id == original.id })!
                let result = changes.filter { $0.file == original.id }.flatMap(\.edits).apply(to: normalized.tree.text)
                return sourceChange(file: original.id, from: original.tree.text, to: result)
            }
        }
        guard !files.contains(where: { $0.tree.text.contains("pondsideMeasure") || $0.tree.text.contains(prefix) }) else {
            throw Failure("The score already uses reserved Pondside structural names. Rename them before restoring shared measures.")
        }
        var parts: [Part] = []
        var layouts: [(file: File, block: LensBlock)] = []
        for file in files {
            let tree = file.tree
            guard tree.issues.isEmpty else { throw Failure("\(file.id): fix syntax issues before restoring shared measures.") }
            var blocks: [LensBlock] = []
            if !observations.isEmpty {
                blocks = voiceBlocks(files).filter { $0.file == file.id }.map(\.block)
            }
            for i in tree.events.indices where observations.isEmpty {
                if isTemplate(in: tree, at: tree.events[i].range.lowerBound) { continue }
                guard tree.events[i].kind != .lyric,
                      let block = LensBlockFinder.block(in: tree, at: tree.events[i].range.lowerBound) else {
                    throw Failure("\(file.id): music outside a sequential voice cannot be migrated automatically.")
                }
                if !blocks.contains(where: { $0.range == block.range }) { blocks.append(block) }
            }
            for block in blocks {
                let context = LensContextScanner.scan(tree, block: block.context)
                let generatesNotes = observations.contains { $0.region.file == file.id && block.range.contains($0.region.range.lowerBound) && $0.hasNotes }
                if !generatesNotes, context.times.isEmpty, block.events.allSatisfy({ tree.events[$0].kind == .spacer || isEmptyChord(tree.events[$0]) }) {
                    layouts.append((file, block))
                } else {
                    parts.append(try migratePart(file: file.id, tree: tree, block: block, sharedBreaks: sharedBreaks, observations: observations))
                }
            }
        }
        if parts.isEmpty, !layouts.isEmpty {
            let seed = layouts.removeFirst()
            parts.append(try migratePart(file: seed.file.id, tree: seed.file.tree, block: seed.block, sharedBreaks: sharedBreaks, observations: observations))
        }
        guard let longest = parts.max(by: { $0.bars.count < $1.bars.count }), !longest.bars.isEmpty else {
            throw Failure("No complete measures were found to migrate.")
        }
        var bars = longest.bars
        guard parts.allSatisfy({ $0.bars.count == bars.count }) else {
            throw Failure("Parallel voices have different measure counts. Give each voice the same explicit measure boundaries first.")
        }
        var inherited = LensTime.common
        for i in bars.indices {
            let explicit = parts.compactMap { $0.bars[i].explicitTime }
            if let first = explicit.first {
                guard explicit.allSatisfy({ $0 == first }) else {
                    throw Failure("Measure \(i + 1) has conflicting staff meters. Independent meters need separate structural timelines.")
                }
                inherited = first
            }
            bars[i].time = inherited
            for part in parts {
                guard part.bars[i].length == inherited.wholeNotes else {
                    throw Failure("\(part.file): measure \(i + 1) does not contain exactly \(inherited.beats)/\(inherited.beatType). Add explicit bar checks and resolve incomplete measures before migration.")
                }
                if part.bars[i].breakCommand == "\\pageBreak" || bars[i].breakCommand == nil {
                    bars[i].breakCommand = part.bars[i].breakCommand
                }
            }
        }
        for layout in layouts {
            let interior = (layout.block.range.lowerBound + 1)..<(layout.block.range.upperBound - 1)
            let part: Part
            if let measured = observation(file: layout.file.id, range: interior, in: observations) {
                part = try interpretedLayout(file: layout.file, block: layout.block, bars: bars, observed: measured, sharedBreaks: sharedBreaks)
            } else {
                part = try migrateLayout(file: layout.file, block: layout.block, bars: bars, sharedBreaks: sharedBreaks)
            }
            for i in bars.indices {
                if part.bars[i].breakCommand == "\\pageBreak" || bars[i].breakCommand == nil { bars[i].breakCommand = part.bars[i].breakCommand }
            }
            parts.append(part)
        }
        for file in files {
            let ranges = parts.filter { $0.file == file.id }.flatMap { $0.edits.map(\.range) }
            var competing = false
            file.tree.root.forEachLeaf {
                let offset = $0.range.lowerBound
                if isTemplate(in: file.tree, at: offset) { return }
                if $0.kind == .command, ["\\time", "\\break", "\\pageBreak", "\\partial", "\\cadenzaOn", "\\cadenzaOff", "\\noBreak", "\\noPageBreak", "\\repeat", "\\scaleDurations", "\\transpose", "\\alternative"].contains(file.tree.string($0.range)),
                   !ranges.contains(where: { $0.contains(offset) }) { competing = true }
            }
            if competing { throw Failure("\(file.id): a separate global/layout expression owns meter or breaks. Convert it into complete measure streams before restoring shared measures.") }
        }
        var grouped: [String: [TextEdit]] = [:]
        for part in parts { grouped[part.file, default: []] += part.edits }
        // Definitions must precede includes, so every dependency can use them.
        let insertion = definitionOffset(rootFile.tree)
        let evaluated = !observations.isEmpty
        let header = marker + " breaks=\(sharedBreaks ? 1 : 0)" + (evaluated ? " evaluated=1" : "") + "\n" + interpretedRuntime + "\n" + runtime + "\n" + spaceRuntime + "\n"
            + (evaluated ? "pondsideInterpreted = ##t\n" : "")
            + bars.enumerated().map { i, bar in definition(name: name(i), time: bar.time, breakCommand: sharedBreaks ? bar.breakCommand : nil) }.joined(separator: "\n")
            + "\n" + (evaluated ? timelineDefinition(names: bars.indices.map { name($0) }) + "\n" : "") + endMarker + "\n"
        grouped[root, default: []].append(.insert("\n" + header, at: insertion))
        let changes = grouped.keys.sorted().map { Change(file: $0, edits: grouped[$0]!) }
        let projected = files.map { file in
            var updated = file
            updated.tree = file.parse((grouped[file.id] ?? []).apply(to: file.tree.text))
            return updated
        }
        try verifyLengths(projected, root: root)
        return changes
    }

    private static func migratePart(file: String, tree: SyntaxTree, block: LensBlock, sharedBreaks: Bool, observations: [Observation]) throws -> Part {
        let context = LensContextScanner.scan(tree, block: block.context)
        let unsupported = context.unsupported.filter { $0 != "markup" } + context.custom
        let evaluated = observations.contains { $0.region.file == file && block.range.contains($0.region.range.lowerBound) }
        guard (unsupported.isEmpty || evaluated), context.partials.isEmpty else {
            let detail = (unsupported + (context.partials.isEmpty ? [] : ["pickup"])).prefix(6).joined(separator: ", ")
            throw Failure("\(file): \(block.label ?? "voice") uses timing that needs LilyPond interpretation (\(detail)). Its measure lengths cannot be inferred safely from source syntax alone.")
        }
        var node: SyntaxNode?
        tree.root.forEachNode { if $0.range == block.range { node = $0 } }
        guard let node, node.kind == .sequential else {
            throw Failure("\(file): simultaneous music inside a voice needs explicit separate measure streams.")
        }
        var generated = false
        node.forEachNode {
            if $0.kind == .command && tree.string($0.range) == "\\score" { generated = true }
            if $0.kind == .scheme {
                let text = tree.string($0.range)
                if text.hasPrefix("#(") || text.hasPrefix("$") { generated = true }
            }
        }
        guard !generated || evaluated else { throw Failure("\(file): Scheme-generated music needs LilyPond evaluation before migration.") }
        // Bar checks inside nested music cannot delimit the enclosing measure.
        var nestedBars = false
        for child in node.children where !child.isLeaf {
            child.forEachLeaf { if $0.kind == .barCheck { nestedBars = true } }
        }
        guard !nestedBars else { throw Failure("\(file): nested bar checks need manual measure boundaries.") }
        var cuts = node.children.filter { $0.kind == .barCheck }.map { $0.range.lowerBound }
        let end = block.range.upperBound - 1
        cuts.append(end)
        var start = block.range.lowerBound + 1
        var time = LensTime.common
        var edits: [TextEdit] = []
        var bars: [Bar] = []
        for cut in cuts {
            let range = start..<cut
            let indices = block.events.filter { range.contains(tree.events[$0].range.lowerBound) }
            let measured = observation(file: file, range: range, in: observations)
            if indices.isEmpty && measured == nil {
                // A trailing comment after the final | is harmless; an empty
                // bar or unattached structural command is not.
                let meaningful = node.children.contains { range.contains($0.range.lowerBound) && !$0.kind.isTrivia && $0.kind != .closeBrace }
                if meaningful { throw Failure("\(file): an empty measure contains commands that need an explicit music anchor.") }
                start = cut + 1
                continue
            }
            let first = indices.first
            let firstOffset = first.map { tree.events[$0].range.lowerBound } ?? range.upperBound
            let meterChanges = context.times.filter { range.contains($0.offset) }
            guard (meterChanges.count <= 1 || measured != nil),
                  meterChanges.allSatisfy({ change in change.offset < firstOffset && node.children.contains(where: { $0.kind == .command && $0.range.lowerBound == change.offset }) }) else {
                throw Failure("\(file): a meter occurs inside a measure or nested music. Move it to the measure's beginning before migration.")
            }
            let generatedMeters = measured?.directives.filter { $0.kind == .meter } ?? []
            guard Set(generatedMeters.compactMap(\.meter)).count <= 1 else { throw Failure("\(file): this passage has independent meters that cannot share one measure definition.") }
            guard generatedMeters.allSatisfy({ $0.offset.value == .zero }) else {
                throw Failure("\(file): a function changes meter inside a measure. Give that change its own measure boundary before migration.")
            }
            if let change = generatedMeters.last?.meter { time = change }
            else if let change = meterChanges.first { time = change.time }
            guard time.beats > 0, time.beatType > 0, time.beats <= 1024, time.beatType <= 1024 else {
                throw Failure("\(file): invalid or excessively large meter.")
            }
            var duration = LensFraction.zero
            for index in indices {
                let event = tree.events[index]
                if !context.isGrace(at: event.range.lowerBound) {
                    duration = duration + self.duration(event, in: tree, context: context)
                }
            }
            if let measured { duration = measured.length.value }
            var local: [TextEdit] = []
            var breakCommand: String?
            for directive in measured?.directives ?? [] where directive.kind != .meter {
                guard directive.offset.value == duration else { throw Failure("\(file): a function produces a break inside a measure. Resolve its intended boundary before migration.") }
                if directive.kind == .page || breakCommand == nil { breakCommand = directive.kind == .page ? "\\pageBreak" : "\\break" }
            }
            var leaves: [SyntaxNode] = []
            node.forEachLeaf { if range.contains($0.range.lowerBound) { leaves.append($0) } }
            let lastOffset = indices.last.map { tree.events[$0].range.upperBound } ?? range.lowerBound
            for (i, leaf) in leaves.enumerated() where leaf.kind == .command {
                let command = tree.string(leaf.range)
                if command == "\\time" {
                    let following = leaves[(i + 1)...].filter { !$0.kind.isTrivia }
                    guard following.count >= 3, following[0].kind == .number,
                          tree.string(following[1].range) == "/", following[2].kind == .number else {
                        throw Failure("\(file): only literal time signatures can be migrated.")
                    }
                    local.append(TextEdit(leaf.range.lowerBound..<following[2].range.upperBound, ""))
                }
                if ["\\break", "\\pageBreak"].contains(command) {
                    guard (measured != nil || leaf.range.lowerBound >= lastOffset),
                          node.children.contains(where: { $0.range == leaf.range }) else {
                        throw Failure("\(file): a break occurs before the measure ends. Move it to an explicit measure boundary first.")
                    }
                    if command == "\\pageBreak" || breakCommand == nil { breakCommand = command }
                    if sharedBreaks { local.append(TextEdit(leaf.range, "")) }
                }
                if ["\\partial", "\\cadenzaOn", "\\cadenzaOff", "\\noBreak", "\\noPageBreak"].contains(command) {
                    throw Failure("\(file): \(command) needs manual structural migration.")
                }
            }
            // Pure spacer measures are elastic. Other rests and all sounding
            // content remain intact; a shortening that would cut them is refused.
            let elastic = indices.allSatisfy { tree.events[$0].kind == .spacer && tree.events[$0].postEvents.isEmpty }
                && leaves.allSatisfy { leaf in
                    leaf.kind.isTrivia || indices.contains(where: { tree.events[$0].range.contains(leaf.range.lowerBound) })
                        || local.contains(where: { $0.range.contains(leaf.range.lowerBound) })
                        || (leaf.kind == .command && ["\\break", "\\pageBreak"].contains(tree.string(leaf.range)))
                }
            if elastic {
                for index in indices { local.append(TextEdit(tree.events[index].range, "s1*0")) }
            }
            // Isolate inherited durations: generated definitions and padding must
            // never change the written duration inherited by the next measure.
            if !elastic, let first, tree.events[first].explicitDuration == nil {
                local.append(.insert(tree.events[first].effectiveDuration.text, at: tree.events[first].durationInsertion))
            }
            let bytes = Array(tree.bytes[range])
            let translated = local.map { TextEdit(($0.range.lowerBound - start)..<($0.range.upperBound - start), $0.replacement) }
            let body = String(decoding: translated.apply(to: bytes), as: UTF8.self)
            let wrapped = "\n  \\pondsideMeasure \\\(name(bars.count)) {" + body + "\n  } "
            edits.append(TextEdit(range, wrapped))
            bars.append(Bar(time: time, breakCommand: breakCommand, explicitTime: generatedMeters.last?.meter ?? meterChanges.first?.time ?? (bars.isEmpty ? measured?.meter : nil), length: duration))
            start = cut + 1
        }
        return Part(file: file, edits: edits, bars: bars)
    }

    /// Embedded music in a Scheme function is a template, not a voice in
    /// the score. Likewise, front-matter examples do not join its timeline.
    static func isTemplate(in tree: SyntaxTree, at offset: Int) -> Bool {
        let path = LensBlockFinder.path(to: offset, in: tree.root)
        if path.contains(where: { $0.kind == .scheme || $0.kind == .embeddedMusic }) { return true }
        for pair in zip(path, path.dropFirst()) {
            let siblings = pair.0.children
            guard let index = siblings.firstIndex(where: { $0 === pair.1 }),
                  let previous = siblings[..<index].last(where: { !$0.kind.isTrivia }) else { continue }
            if previous.kind == .command, ["\\markup", "\\markuplist", "\\header", "\\paper", "\\layout", "\\with", "\\midi"].contains(tree.string(previous.range)) { return true }
            // Score Setup's legend passes unbraced \score arguments through
            // custom markup commands. The marked bookpart is front matter,
            // even though a generic arity-free scan cannot follow that chain.
            if previous.kind == .command, tree.string(previous.range) == "\\bookpart",
               let command = siblings[..<index].lastIndex(where: { !$0.kind.isTrivia }),
               let heading = siblings[..<command].last(where: { $0.kind != .whitespace }),
               heading.kind == .lineComment {
                let marker = tree.string(heading.range).split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
                if FrontMatter.Section.allCases.contains(where: { marker == "%% ---- " + $0.rawValue }) { return true }
            }
        }
        return false
    }

    static func sourceChange(file: String, from old: String, to new: String) -> Change? {
        guard let diff = TextDiff.minimalReplacement(from: old, to: new) else { return nil }
        let lo = OffsetConversion.utf8(fromUTF16: diff.location, in: old)
        let hi = OffsetConversion.utf8(fromUTF16: diff.location + diff.length, in: old)
        return Change(file: file, edits: [TextEdit(lo..<hi, diff.replacement)])
    }

    static func isEmptyChord(_ event: MusicEvent) -> Bool {
        event.kind == .chord && event.notes.isEmpty && event.explicitDuration == nil
    }

    static func duration(_ event: MusicEvent, in tree: SyntaxTree, context: LensContext) -> LensFraction {
        if isEmptyChord(event) || context.isGrace(at: event.range.lowerBound) { return .zero }
        if event.kind == .spacer, tree.string(event.range).split(separator: "*").dropFirst().contains(where: { $0.split(separator: "/").first == "0" }) { return .zero }
        let value = event.effectiveDuration.wholeNotes
        return LensFraction(value.0, value.1) * context.durationFactor(at: event.range.lowerBound)
    }

    private static func definitionOffset(_ tree: SyntaxTree) -> Int {
        let children = tree.root.children
        if let i = children.firstIndex(where: { $0.kind == .command && tree.string($0.range) == "\\version" }),
           let version = children.dropFirst(i + 1).first(where: { !$0.kind.isTrivia }), version.kind == .string {
            return version.range.upperBound
        }
        return 0
    }

    static func name(_ index: Int) -> String {
        var n = index + 1
        var suffix = ""
        while n > 0 { n -= 1; suffix = String(UnicodeScalar(65 + n % 26)!) + suffix; n /= 26 }
        return prefix + suffix
    }

    private static func definition(name: String, time: LensTime, breakCommand: String?) -> String {
        "\(name) = { \\time \(time.beats)/\(time.beatType) s1*\(time.beats)/\(time.beatType)\(breakCommand.map { " " + $0 } ?? "") }"
    }

    private static func definitions(in tree: SyntaxTree) -> [(String, SyntaxNode)] {
        var result: [(String, SyntaxNode)] = []
        let children = tree.root.children
        for (i, child) in children.enumerated() where child.kind == .assignment {
            guard let first = child.children.first else { continue }
            let name = tree.string(first.range)
            guard name.hasPrefix(prefix), let value = children.dropFirst(i + 1).first(where: { !$0.kind.isTrivia }), value.kind == .sequential else { continue }
            result.append((name, value))
        }
        return result
    }

    public static func time(in root: SyntaxTree, name: String) -> LensTime? {
        guard let (_, node) = definitions(in: root).first(where: { $0.0 == name }) else { return nil }
        return LensContextScanner.scan(root, block: node.range).times.first?.time
    }

    /// Check the contract after hand edits too. A marker alone is not proof
    /// that all voices still share a timeline, or that no local meter was added.
    public static func validate(_ files: [File], root: String) throws {
        guard let source = files.first(where: { $0.id == root }), isManaged(source.tree),
              source.tree.text.contains(runtime) else { throw Failure("The shared-measure helper is missing or modified. Restore its definition before structural editing.") }
        let all = definitions(in: source.tree)
        guard !all.isEmpty else { throw Failure("No shared measure definitions were found.") }
        for (i, pair) in all.enumerated() {
            let (id, node) = pair
            guard id == name(i), let meter = time(in: source.tree, name: id),
                  meter.beats > 0, meter.beatType > 0, meter.beats <= 1024, meter.beatType <= 1024,
                  source.tree.string(node.range) == String(definition(name: id, time: meter, breakCommand: breakIn(source.tree, node: node)).dropFirst(id.utf8.count + 3)) else {
                throw Failure("\(id): shared definitions must contain one literal meter, its matching skip length, and an optional final break.")
            }
            if !managesBreaks(source.tree), breakIn(source.tree, node: node) != nil {
                throw Failure("A shared break was added while shared breaks are disabled.")
            }
        }
        let expected = all.map { $0.0 }
        let activeNames = Set(voiceBlocks(files).compactMap { $0.block.label })
        func isHelper(_ tree: SyntaxTree, _ offset: Int) -> Bool {
            guard isInterpreted(source.tree), let assignment = LensBlockFinder.assignmentValue(containing: offset, in: tree) else { return false }
            return !activeNames.contains(assignment.name) && !assignment.name.hasPrefix("pondside")
        }
        var streamCount = 0
        for file in files {
            guard file.tree.issues.isEmpty else { throw Failure("\(file.id): fix syntax issues before structural editing.") }
            let measures = measures(in: file.tree)
            let layouts = layoutRegions(in: file.tree)
            guard layouts.isEmpty || isInterpreted(source.tree) else { throw Failure("Interpreted layout regions require the evaluated source contract.") }
            var streams: [Range<Int>: [String]] = [:]
            for measure in measures {
                guard expected.contains(measure.name),
                      let stream = LensBlockFinder.path(to: measure.invocation.lowerBound, in: file.tree.root).last(where: { $0.kind == .sequential }) else {
                    throw Failure("\(file.id): a measure has no shared definition or sequential voice.")
                }
                streams[stream.range, default: []].append(measure.name)
                let slots = spaces(in: file.tree, body: measure.body)
                var slotCommands = 0
                file.tree.root.forEachLeaf {
                    if measure.body.contains($0.range.lowerBound), $0.kind == .command, file.tree.string($0.range) == "\\pondsideSpace" { slotCommands += 1 }
                }
                guard slots.count == slotCommands, slots.allSatisfy({ $0.name == measure.name }),
                      slots.reduce(LensFraction.zero, { $0 + $1.fraction }) <= .one,
                      slots.isEmpty || (source.tree.text.contains(spaceRuntime) && file.tree.events.filter({ measure.body.contains($0.range.lowerBound) }).allSatisfy({ isEmptyChord($0) || $0.kind == .spacer && duration($0, in: file.tree, context: LensContext()) == .zero })) else {
                    throw Failure("\(file.id): proportional layout spaces must reference their own shared measure and fit its length.")
                }
                let context = LensContextScanner.scan(file.tree, block: measure.body)
                guard isInterpreted(source.tree) || (context.custom.isEmpty && context.unsupported.allSatisfy({ $0 == "markup" })) else {
                    throw Failure("\(file.id): custom or unsupported timing was added to a shared measure.")
                }
                var invalid: String?
                file.tree.root.forEachNode { node in
                    guard measure.body.contains(node.range.lowerBound) else { return }
                    let text = file.tree.string(node.range)
                    if (node.kind == .command && text == "\\score") || (!isInterpreted(source.tree) && (node.kind == .simultaneous || (node.kind == .scheme && (text.hasPrefix("#(") || text.hasPrefix("$"))))) {
                        invalid = "generated or simultaneous music"
                    }
                    if node.kind == .command && ["\\time", "\\partial", "\\cadenzaOn", "\\cadenzaOff", "\\noBreak", "\\noPageBreak"].contains(text) { invalid = text }
                    if managesBreaks(source.tree), node.kind == .command && ["\\break", "\\pageBreak"].contains(text) { invalid = "a local break" }
                }
                let last = file.tree.events.last(where: { measure.body.contains($0.range.lowerBound) })?.range.upperBound ?? measure.body.lowerBound
                file.tree.root.forEachLeaf {
                    if measure.body.contains($0.range.lowerBound), $0.kind == .command,
                       ["\\break", "\\pageBreak"].contains(file.tree.string($0.range)), $0.range.lowerBound < last {
                        invalid = "a break inside a measure"
                    }
                }
                if let invalid { throw Failure("\(file.id): \(invalid) conflicts with the shared measure contract.") }
            }
            streamCount += layouts.count
            for stream in streams.values {
                guard stream == expected else { throw Failure("\(file.id): a voice is missing, duplicating or reordering shared measures.") }
                streamCount += 1
            }
            for event in file.tree.events {
                let offset = event.range.lowerBound
                if isTemplate(in: file.tree, at: offset) || isHelper(file.tree, offset) { continue }
                let inDefinition = file.id == root && all.contains { $0.1.range.contains(offset) }
                guard inDefinition || measures.contains(where: { $0.body.contains(offset) }) || layouts.contains(where: { $0.body.contains(offset) }) else {
                    throw Failure("\(file.id): music was added outside the shared measure streams.")
                }
            }
            var outsideCommand = false
            file.tree.root.forEachLeaf { leaf in
                let offset = leaf.range.lowerBound
                if isTemplate(in: file.tree, at: offset) || isHelper(file.tree, offset) { return }
                guard leaf.kind == .command,
                      ["\\time", "\\break", "\\pageBreak", "\\partial", "\\cadenzaOn", "\\cadenzaOff", "\\noBreak", "\\noPageBreak", "\\repeat", "\\scaleDurations", "\\transpose", "\\alternative"].contains(file.tree.string(leaf.range)) else { return }
                let inDefinition = file.id == root && all.contains { $0.1.range.contains(offset) }
                if !inDefinition && !measures.contains(where: { $0.body.contains(offset) }) && !layouts.contains(where: { $0.body.contains(offset) }) { outsideCommand = true }
            }
            if outsideCommand { throw Failure("\(file.id): a separate expression overrides the shared meter or layout.") }
        }
        guard streamCount > 0 else { throw Failure("The shared measure definitions have no music streams.") }
        try verifyReferences(files)
    }

    private static func verifyReferences(_ files: [File]) throws {
        var names: Set<String> = []
        for file in files {
            for measure in measures(in: file.tree) {
                if let assignment = LensBlockFinder.assignmentValue(containing: measure.invocation.lowerBound, in: file.tree) { names.insert(assignment.name) }
            }
        }
        for file in files {
            var scoreRanges: [Range<Int>] = []
            file.tree.root.forEachNode { node in
                let children = node.children.filter { !$0.kind.isTrivia }
                for i in children.indices where children[i].kind == .command && file.tree.string(children[i].range) == "\\score" {
                    if i + 1 < children.count, children[i + 1].kind == .sequential { scoreRanges.append(children[i + 1].range) }
                }
            }
            var counts: [String: Int] = [:]
            var indirect = false
            file.tree.root.forEachLeaf { leaf in
                guard leaf.kind == .command else { return }
                let name = String(file.tree.string(leaf.range).dropFirst())
                guard names.contains(name) else { return }
                if LensBlockFinder.assignmentValue(containing: leaf.range.lowerBound, in: file.tree) != nil { indirect = true }
                let score = scoreRanges.firstIndex(where: { $0.contains(leaf.range.lowerBound) }) ?? -1
                counts["\(score):\(name)", default: 0] += 1
            }
            guard !indirect, counts.values.allSatisfy({ $0 <= 1 }) else {
                throw Failure("\(file.id): a music stream is reused or assembled indirectly. Use each stream once per score so selected measures have unique source identities.")
            }
        }
    }

    /// Root edits against the proposed file revision. Pair wrapper occurrences,
    /// not just IDs: several voices in one dependency share the same IDs.
    public static func resizingForContentChange(in fileID: String, proposed: SyntaxTree, files: [File], root: String) throws -> [Change] {
        guard let index = files.firstIndex(where: { $0.id == fileID }),
              let rootIndex = files.firstIndex(where: { $0.id == root }) else { throw Failure("The edited file or root is missing.") }
        let old = measures(in: files[index].tree)
        let new = measures(in: proposed)
        if isInterpreted(files[rootIndex].tree) {
            for (before, after) in zip(old, new) where files[index].tree.string(before.body) != proposed.string(after.body) {
                let context = LensContextScanner.scan(proposed, block: after.body)
                if !context.custom.isEmpty || !context.unsupported.filter({ $0 != "markup" }).isEmpty {
                    throw Failure("This passage has generated timing. Edit it in Source and rerun Make Score Pondside-Ready; unmetered entry needs explicit note durations.")
                }
            }
        }
        guard old.count == new.count, zip(old, new).allSatisfy({ $0.name == $1.name }) else {
            throw Failure("A content edit cannot add, remove or reorder shared measures.")
        }
        var affected: [String: LensTime] = [:]
        for (before, after) in zip(old, new) where files[index].tree.string(before.body) != proposed.string(after.body) {
            guard let meter = contentMeter(in: proposed, measure: after),
                  meter != contentMeter(in: files[index].tree, measure: before) else { continue }
            if affected[after.name].map({ $0.wholeNotes < meter.wholeNotes }) ?? true { affected[after.name] = meter }
        }
        var projected = files
        projected[index].tree = proposed
        let initial = projected[rootIndex].tree
        for name in affected.keys.sorted() {
            var desired = affected[name]!
            // Unmetered deletion may shrink this voice, but must leave room
            // for the other voices' existing music. Opaque timing retains the
            // current length when a shorter length cannot be proved safe.
            for file in projected {
                for measure in measures(in: file.tree) where measure.name == name {
                    let needed = needsInterpreter(in: file.tree, body: measure.body)
                        ? time(in: initial, name: name) : contentMeter(in: file.tree, measure: measure)
                    if let needed, desired.wholeNotes < needed.wholeNotes { desired = needed }
                }
            }
            let changes = try changeMeter(desired, measure: name, files: projected, root: root, validatingContract: false)
            for change in changes {
                let i = projected.firstIndex(where: { $0.id == change.file })!
                projected[i].tree = projected[i].parse(change.edits.apply(to: projected[i].tree.text))
            }
        }
        guard let difference = TextDiff.minimalReplacement(from: initial.text, to: projected[rootIndex].tree.text) else { return [] }
        let lower = OffsetConversion.utf8(fromUTF16: difference.location, in: initial.text)
        let upper = OffsetConversion.utf8(fromUTF16: difference.location + difference.length, in: initial.text)
        return [Change(file: root, edits: [TextEdit(lower..<upper, difference.replacement)])]
    }

    public static func verifyLengths(_ files: [File], root: String) throws {
        try validate(files, root: root)
        guard let source = files.first(where: { $0.id == root }) else { throw Failure("The root score is missing.") }
        for file in files {
            for measure in measures(in: file.tree) {
                guard let meter = time(in: source.tree, name: measure.name) else { throw Failure("The shared meter is missing.") }
                let context = LensContextScanner.scan(file.tree, block: measure.body)
                if isInterpreted(source.tree), needsInterpreter(in: file.tree, body: measure.body) { continue }
                guard contentLength(file.tree, body: measure.body, context: context) <= meter.wholeNotes else {
                    throw Overflow(file: file.id, measure: measure.name, meter: meter)
                }
            }
        }
    }

    /// Keystroke validation trusts the migrated wrapper structure and checks
    /// only bodies changed by this edit. Opaque functions are checked by the
    /// normal background engraving, never by a synchronous preflight.
    public static func verifyContentEdit(in file: String, before: SyntaxTree, proposed: SyntaxTree, root: SyntaxTree) throws {
        let old = measures(in: before), new = measures(in: proposed)
        guard old.count == new.count, zip(old, new).allSatisfy({ $0.name == $1.name }) else {
            throw Failure("A note edit cannot add, delete or reorder shared measures.")
        }
        for (previous, measure) in zip(old, new) where before.string(previous.body) != proposed.string(measure.body) {
            guard let meter = time(in: root, name: measure.name) else { throw Failure("The shared meter is missing.") }
            if needsInterpreter(in: proposed, body: measure.body) { continue }
            let context = LensContextScanner.scan(proposed, block: measure.body)
            if contentLength(proposed, body: measure.body, context: context) > meter.wholeNotes {
                throw Overflow(file: file, measure: measure.name, meter: meter)
            }
        }
    }

    /// At the end of a complete metered bar, entry continues in the next
    /// wrapper of the same voice. Never borrow a measure from another voice.
    public static func nextMeasureForEntry(after event: Int, in tree: SyntaxTree, root: SyntaxTree) -> Measure? {
        guard tree.events.indices.contains(event),
              let current = measure(in: tree, at: tree.events[event].range.lowerBound),
              !needsInterpreter(in: tree, body: current.body),
              let meter = time(in: root, name: current.name),
              let block = LensBlockFinder.block(in: tree, at: tree.events[event].range.lowerBound) else { return nil }
        let context = LensContextScanner.scan(tree, block: current.body)
        let members = tree.events.filter { current.body.contains($0.range.lowerBound) }
        let fullRest = members.count == 1 && members[0].kind == .multiMeasureRest && members[0].postEvents.isEmpty
        guard (fullRest || contentLength(tree, body: current.body, context: context) == meter.wholeNotes),
              tree.events.indices.last(where: {
                  current.body.contains(tree.events[$0].range.lowerBound)
                      && duration(tree.events[$0], in: tree, context: context) > .zero
              }) == event else { return nil }
        return measures(in: tree).first {
            $0.invocation.lowerBound >= current.invocation.upperBound && block.range.contains($0.invocation.lowerBound)
        }
    }

    /// Every use is checked before modifying the shared definition. Music is
    /// preserved; only pure spacer bodies automatically follow a new length.
    public static func changeMeter(_ time: LensTime, measure name: String, files: [File], root: String, validatingContract: Bool = true) throws -> [Change] {
        if validatingContract { try validate(files, root: root) }
        guard time.beats > 0, time.beatType > 0, time.beats <= 1024, time.beatType <= 1024,
              let file = files.first(where: { $0.id == root }), isManaged(file.tree),
              let (_, node) = definitions(in: file.tree).first(where: { $0.0 == name }) else { throw Failure("The shared measure definition is missing or invalid.") }
        for source in files {
            for measure in measures(in: source.tree) where measure.name == name {
                let context = LensContextScanner.scan(source.tree, block: measure.body)
                guard isInterpreted(file.tree) || (context.unsupported.allSatisfy({ $0 == "markup" }) && context.custom.isEmpty) else {
                    throw Failure("\(source.id): this measure contains timing that needs LilyPond validation.")
                }
                if isInterpreted(file.tree), needsInterpreter(in: source.tree, body: measure.body) {
                    if !validatingContract, let old = self.time(in: file.tree, name: name), time.wholeNotes < old.wholeNotes {
                        throw Failure("Cannot shorten function-generated music without measuring it. Edit its timing in Source first.")
                    }
                    continue
                }
                let length = contentLength(source.tree, body: measure.body, context: context)
                guard length <= time.wholeNotes else {
                    throw Overflow(file: source.id, measure: name, meter: time)
                }
            }
        }
        let command = breakIn(file.tree, node: node)
        return [Change(file: root, edits: [TextEdit(node.range, String(definition(name: name, time: time, breakCommand: command).dropFirst(name.utf8.count + 3)))])]
    }

    private static func contentLength(_ tree: SyntaxTree, body: Range<Int>, context: LensContext) -> LensFraction {
        let members = tree.events.filter { body.contains($0.range.lowerBound) }
        if members.count == 1, members[0].kind == .multiMeasureRest, members[0].postEvents.isEmpty { return .zero }
        var length = LensFraction.zero
        for event in tree.events where body.contains(event.range.lowerBound) && !context.isGrace(at: event.range.lowerBound) {
            length = length + duration(event, in: tree, context: context)
        }
        return length
    }

    public static func contentMeter(in tree: SyntaxTree, measure: Measure) -> LensTime? {
        let context = LensContextScanner.scan(tree, block: measure.body)
        guard context.unsupported.allSatisfy({ $0 == "markup" }), context.custom.isEmpty else { return nil }
        let length = contentLength(tree, body: measure.body, context: context)
        guard length > .zero else { return nil }
        return LensTime(beats: length.numerator, beatType: length.denominator)
    }

    private static func breakIn(_ tree: SyntaxTree, node: SyntaxNode) -> String? {
        var command: String?
        node.forEachLeaf {
            let text = tree.string($0.range)
            if $0.kind == .command && ["\\break", "\\pageBreak"].contains(text) { command = text }
        }
        return command
    }

    /// A boundary before a selected measure belongs to its predecessor's end.
    public static func toggleBreak(before measure: String, files: [File], root: String) throws -> [Change] {
        try validate(files, root: root)
        guard let file = files.first(where: { $0.id == root }), managesBreaks(file.tree) else { throw Failure("Shared breaks are not enabled in Restore Defaults.") }
        let all = definitions(in: file.tree)
        guard let index = all.firstIndex(where: { $0.0 == measure }), index > 0 else { throw Failure("There is no system boundary before the first measure.") }
        let (name, node) = all[index - 1]
        guard let time = time(in: file.tree, name: name) else { throw Failure("The preceding measure has no literal meter.") }
        let command: String? = breakIn(file.tree, node: node) == nil ? "\\break" : nil
        return [Change(file: root, edits: [TextEdit(node.range, String(definition(name: name, time: time, breakCommand: command).dropFirst(name.utf8.count + 3)))])]
    }

    public static func settingBreaks(_ enabled: Bool, files: [File], root: String) throws -> [Change] {
        try validate(files, root: root)
        guard let source = files.first(where: { $0.id == root }), isManaged(source.tree) else { return [] }
        if enabled == managesBreaks(source.tree) { return [] }
        var edits: [String: [TextEdit]] = [:]
        let all = definitions(in: source.tree)
        var commands: [String: String] = [:]
        for (name, node) in all { commands[name] = breakIn(source.tree, node: node) }
        for file in files {
            for measure in measures(in: file.tree) {
                if enabled {
                    var local: [SyntaxNode] = []
                    file.tree.root.forEachLeaf {
                        if measure.body.contains($0.range.lowerBound), $0.kind == .command,
                           ["\\break", "\\pageBreak"].contains(file.tree.string($0.range)) { local.append($0) }
                    }
                    let last = file.tree.events.filter { measure.body.contains($0.range.lowerBound) }.last?.range.upperBound ?? measure.body.lowerBound
                    for leaf in local {
                        guard leaf.range.lowerBound >= last else { throw Failure("\(file.id): move a local break to the end of its measure before sharing breaks.") }
                        let command = file.tree.string(leaf.range)
                        if command == "\\pageBreak" || commands[measure.name] == nil { commands[measure.name] = command }
                        edits[file.id, default: []].append(TextEdit(leaf.range, ""))
                    }
                } else if let (_, node) = all.first(where: { $0.0 == measure.name }), let command = breakIn(source.tree, node: node) {
                    edits[file.id, default: []].append(.insert(" " + command + " ", at: measure.body.upperBound))
                }
            }
        }
        for (name, node) in all {
            guard let time = time(in: source.tree, name: name) else { throw Failure("The shared meter is missing.") }
            let command: String? = enabled ? commands[name] : nil
            edits[root, default: []].append(TextEdit(node.range, String(definition(name: name, time: time, breakCommand: command).dropFirst(name.utf8.count + 3))))
        }
        if let comment = source.tree.root.children.first(where: { $0.kind == .lineComment && source.tree.string($0.range).hasPrefix(marker) }) {
            edits[root, default: []].append(TextEdit(comment.range, marker + " breaks=\(enabled ? 1 : 0)" + (isInterpreted(source.tree) ? " evaluated=1" : "")))
        }
        return edits.keys.sorted().map { Change(file: $0, edits: edits[$0]!) }
    }

    /// Turning off shared measures expands the current definitions back into
    /// ordinary LilyPond. The current music, padding and layout are preserved.
    public static func removeContract(_ files: [File], root: String) throws -> [Change] {
        guard let source = files.first(where: { $0.id == root }), isManaged(source.tree) else { return [] }
        try validate(files, root: root)
        guard !files.contains(where: { !layoutRegions(in: $0.tree).isEmpty }) else { throw Failure("Interpreted layout anchors must be expanded through LilyPond, not by a source-only opt-out.") }
        var changes: [Change] = []
        for file in files {
            var edits: [TextEdit] = []
            for measure in measures(in: file.tree) {
                guard let meter = time(in: source.tree, name: measure.name),
                      let (_, definitionNode) = definitions(in: source.tree).first(where: { $0.0 == measure.name }) else { throw Failure("The shared measure definition is missing.") }
                let context = LensContextScanner.scan(file.tree, block: measure.body)
                guard context.unsupported.allSatisfy({ $0 == "markup" }), context.custom.isEmpty else { throw Failure("\(file.id): resolve custom timing before removing shared measures.") }
                let slots = spaces(in: file.tree, body: measure.body)
                let spaceLength = slots.reduce(LensFraction.zero) { $0 + $1.fraction * meter.wholeNotes }
                let padding = meter.wholeNotes - contentLength(file.tree, body: measure.body, context: context) - spaceLength
                guard padding >= .zero else { throw Failure("\(file.id): a measure exceeds its shared length.") }
                let members = file.tree.events.filter { measure.body.contains($0.range.lowerBound) }
                let elasticRest = members.count == 1 && members[0].kind == .multiMeasureRest && members[0].postEvents.isEmpty
                var localBreaks: [SyntaxNode] = []
                file.tree.root.forEachLeaf {
                    if measure.body.contains($0.range.lowerBound), $0.kind == .command,
                       ["\\break", "\\pageBreak"].contains(file.tree.string($0.range)) { localBreaks.append($0) }
                }
                let finalBars = trailingBars(in: file.tree, body: measure.body)
                var localEdits = (localBreaks.map(\.range) + finalBars.map(\.range)).map { TextEdit(($0.lowerBound - measure.body.lowerBound)..<($0.upperBound - measure.body.lowerBound), "") }
                for slot in slots {
                    let length = slot.fraction * meter.wholeNotes
                    localEdits.append(TextEdit((slot.range.lowerBound - measure.body.lowerBound)..<(slot.range.upperBound - measure.body.lowerBound), "s1*\(length.numerator)/\(length.denominator)"))
                }
                if elasticRest {
                    let event = members[0]
                    localEdits.append(TextEdit((event.range.lowerBound - measure.body.lowerBound)..<(event.range.upperBound - measure.body.lowerBound), "R1*\(meter.beats)/\(meter.beatType)"))
                }
                let body = localEdits.apply(to: file.tree.string(measure.body))
                let rest = !elasticRest && padding > .zero ? " s1*\(padding.numerator)/\(padding.denominator)" : ""
                let ownedBreak = breakIn(source.tree, node: definitionNode)
                let localCommand = localBreaks.map { file.tree.string($0.range) }.first(where: { $0 == "\\pageBreak" }) ?? localBreaks.first.map { file.tree.string($0.range) }
                let command = (ownedBreak ?? localCommand).map { " " + $0 } ?? ""
                let barCommands = finalBars.map { " " + $0.text }.joined()
                edits.append(TextEdit(measure.invocation, "{ \\time \(meter.beats)/\(meter.beatType) " + body + rest + barCommands + command + " }"))
            }
            if file.id == root {
                guard let start = source.tree.root.children.first(where: { $0.kind == .lineComment && source.tree.string($0.range).hasPrefix(marker) }),
                      let end = source.tree.root.children.first(where: { $0.kind == .lineComment && source.tree.string($0.range) == endMarker }) else { throw Failure("The structural contract block is incomplete.") }
                edits.append(TextEdit(start.range.lowerBound..<end.range.upperBound, ""))
            }
            if !edits.isEmpty { changes.append(Change(file: file.id, edits: edits)) }
        }
        return changes
    }

    private static func trailingBars(in tree: SyntaxTree, body: Range<Int>) -> [(range: Range<Int>, text: String)] {
        let last = tree.events.last(where: { body.contains($0.range.lowerBound) })?.range.upperBound ?? body.lowerBound
        var leaves: [SyntaxNode] = []
        tree.root.forEachLeaf { if body.contains($0.range.lowerBound), !$0.kind.isTrivia { leaves.append($0) } }
        var result: [(Range<Int>, String)] = []
        for (i, leaf) in leaves.enumerated() where leaf.kind == .command && tree.string(leaf.range) == "\\bar" && leaf.range.lowerBound >= last {
            if i + 1 < leaves.count, leaves[i + 1].kind == .string {
                let range = leaf.range.lowerBound..<leaves[i + 1].range.upperBound
                result.append((range, tree.string(range)))
            }
        }
        return result
    }

    public static func appendMeasure(after name: String, time: LensTime, files: [File], root: String) throws -> [Change] {
        try validate(files, root: root)
        guard let source = files.first(where: { $0.id == root }),
              let last = definitions(in: source.tree).last, last.0 == name else { throw Failure("Finish this measure by selecting the next existing measure.") }
        let next = self.name(definitions(in: source.tree).count)
        var result: [Change] = []
        for file in files {
            var edits: [TextEdit] = []
            for measure in measures(in: file.tree) where measure.name == name {
                let finalBars = trailingBars(in: file.tree, body: measure.body).filter { $0.text == "\\bar \"|.\"" }
                for bar in finalBars { edits.append(TextEdit(bar.range, "")) }
                let ending = finalBars.map { " " + $0.text }.joined()
                edits.append(.insert(" | \\pondsideMeasure \\\(next) { s1*0" + ending + " } ", at: measure.invocation.upperBound))
            }
            if file.id == root {
                edits.append(.insert("\n" + definition(name: next, time: time, breakCommand: nil), at: last.1.range.upperBound))
                if isInterpreted(source.tree) {
                    let children = source.tree.root.children
                    if let index = children.firstIndex(where: { $0.kind == .assignment && $0.children.first.map({ source.tree.string($0.range) }) == "pondsideTimeline" }),
                       let value = children.dropFirst(index + 1).first(where: { !$0.kind.isTrivia }) {
                        let names = definitions(in: source.tree).map { $0.0 } + [next]
                        edits.append(TextEdit(children[index].range.lowerBound..<value.range.upperBound, timelineDefinition(names: names)))
                    }
                }
            }
            if !edits.isEmpty { result.append(Change(file: file.id, edits: edits)) }
        }
        return result
    }

    // Only literal source definitions are editable. The helper preserves the
    // relative-pitch chain by returning sequential music, and computes padding
    // afresh whenever LilyPond reads the .ly files (including CLI/MIDI exports).
    private static let spaceRuntime = #"""
pondsideSpace =
#(define-music-function (structure numerator denominator) (ly:music? integer? integer?)
   (make-skip-music
     (make-duration-of-length
       (ly:make-moment (* (ly:moment-main (ly:music-length structure))
                          (/ numerator denominator))))))
"""#

    private static let runtime = #"""
#(define (pondside-break-music? music)
   (or (memq (ly:music-property music 'name) '(LineBreakEvent PageBreakEvent))
       (ly:music-property music 'page-marker #f)))
pondsideMeasure =
#(define-music-function (structure music) (ly:music? ly:music?)
   (let* ((expected (ly:music-length structure))
          (music (if (eq? #t (ly:parser-lookup 'pondsideInterpreted))
                     (pondside-strip-structure music) music))
          (raw-body (ly:music-property music 'elements))
          (local-breaks (filter pondside-break-music? raw-body))
          (without-breaks (filter (lambda (m) (not (pondside-break-music? m))) raw-body))
          (end-bars (let loop ((todo (reverse without-breaks)) (found '()))
                      (if (and (pair? todo) (eq? (ly:music-property (car todo) 'name) 'BarEvent))
                          (loop (cdr todo) (cons (car todo) found)) found)))
          (body (take without-breaks (- (length without-breaks) (length end-bars))))
          (unused-breaks (ly:music-set-property! music 'elements body))
          (rhythmic (filter (lambda (m) (ly:moment<? ZERO-MOMENT (ly:music-length m))) body))
          (elastic-rest (and (= (length rhythmic) 1)
                            (eq? (ly:music-property (car rhythmic) 'name) 'MultiMeasureRestMusic)
                            (null? (ly:music-property (car rhythmic) 'articulations))))
          (unused (if elastic-rest
                      (ly:music-set-property! (car rhythmic) 'duration (make-duration-of-length expected))))
          (actual (ly:music-length music))
          (padding (ly:moment-sub expected actual))
          (elements (ly:music-property structure 'elements))
          (timing (filter (lambda (m) (and (not (pondside-break-music? m))
                           (not (memq (ly:music-property m 'name) '(SkipEvent SkipMusic))))) elements))
          (breaks (filter pondside-break-music? elements)))
     (if (ly:moment<? expected actual)
         (ly:error "Pondside: measure content exceeds its shared length"))
     (make-music 'SequentialMusic 'elements
       (append timing (list music (make-skip-music (make-duration-of-length padding))) end-bars local-breaks breaks))))
"""#
}
