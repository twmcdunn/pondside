extension StructuralEditing {
    public struct Ratio: Sendable, Hashable {
        public var numerator: Int
        public var denominator: Int
        public init(_ numerator: Int, _ denominator: Int = 1) { self.numerator = numerator; self.denominator = denominator }
        var value: LensFraction { LensFraction(numerator, denominator) }
    }

    public struct Region: Sendable {
        public var id: String
        public var file: String
        public var range: Range<Int>
        public var layout: Bool
        public init(id: String, file: String, range: Range<Int>, layout: Bool) {
            self.id = id; self.file = file; self.range = range; self.layout = layout
        }
    }

    public struct Directive: Sendable {
        public enum Kind: String, Sendable { case meter, line, page }
        public var kind: Kind
        public var offset: Ratio
        public var meter: LensTime?
        public init(kind: Kind, offset: Ratio, meter: LensTime? = nil) { self.kind = kind; self.offset = offset; self.meter = meter }
    }

    public struct Slot: Sendable {
        public var kind: String
        public var written: Ratio
        public var start: Ratio
        public var end: Ratio
        public init(kind: String, written: Ratio, start: Ratio, end: Ratio) {
            self.kind = kind; self.written = written; self.start = start; self.end = end
        }
    }

    public struct Observation: Sendable {
        public var region: Region
        public var length: Ratio
        public var meter: LensTime
        public var directives: [Directive]
        public var slots: [Slot]
        public var hasNotes: Bool
        public init(region: Region, length: Ratio, meter: LensTime, directives: [Directive] = [], slots: [Slot] = [], hasNotes: Bool = false) {
            self.region = region; self.length = length; self.meter = meter
            self.directives = directives; self.slots = slots; self.hasNotes = hasNotes
        }
    }

    public static func isInterpreted(_ tree: SyntaxTree) -> Bool {
        tree.root.children.contains { $0.kind == .lineComment && tree.string($0.range).hasPrefix(marker) && tree.string($0.range).contains("evaluated=1") }
    }

    /// Preparation is source-only; the service measures the returned revision.
    public static func prepareForInterpretation(_ files: [File]) throws -> [File] { try expandLayoutRepeats(files) }

    struct VoiceBlock {
        var file: String
        var block: LensBlock
    }

    /// Source declarations used as score voices, excluding definitions invoked
    /// inside another music expression. A helper's notes are not extra staves.
    static func voiceBlocks(_ files: [File]) -> [VoiceBlock] {
        var declared: [(file: String, name: String, node: SyntaxNode, context: Range<Int>)] = []
        for file in files {
            let children = file.tree.root.children
            for (i, child) in children.enumerated() where child.kind == .assignment {
                guard let nameNode = child.children.first else { continue }
                let name = file.tree.string(nameNode.range)
                for value in children.dropFirst(i + 1) {
                    if value.kind == .assignment || value.kind == .scheme { break }
                    if value.kind == .sequential || value.kind == .simultaneous {
                        declared.append((file.id, name, value, child.range.upperBound..<value.range.upperBound)); break
                    }
                }
            }
        }
        var active: Set<String> = []
        for file in files {
            file.tree.root.forEachLeaf { leaf in
                guard leaf.kind == .command, !isTemplate(in: file.tree, at: leaf.range.lowerBound),
                      !declared.contains(where: { $0.file == file.id && $0.context.contains(leaf.range.lowerBound) }) else { return }
                active.insert(String(file.tree.string(leaf.range).dropFirst()))
            }
        }
        var result: [VoiceBlock] = []
        for file in files {
            for declaration in declared where declaration.file == file.id && active.contains(declaration.name) {
                let events = file.tree.events.indices.filter { declaration.node.range.contains(file.tree.events[$0].range.lowerBound) }
                result.append(VoiceBlock(file: file.id, block: LensBlock(range: declaration.node.range, context: declaration.context, label: declaration.name, events: events)))
            }
            for event in file.tree.events where !isTemplate(in: file.tree, at: event.range.lowerBound) {
                guard !declared.contains(where: { $0.file == file.id && $0.node.range.contains(event.range.lowerBound) }),
                      let block = LensBlockFinder.block(in: file.tree, at: event.range.lowerBound),
                      !result.contains(where: { $0.file == file.id && $0.block.range == block.range }) else { continue }
                result.append(VoiceBlock(file: file.id, block: block))
            }
        }
        return result
    }

    public static func regionsForInterpretation(_ files: [File]) throws -> [Region] {
        var result: [Region] = []
        let voices = voiceBlocks(files)
        for (fileIndex, file) in files.enumerated() {
            let blocks = voices.filter { $0.file == file.id }.map(\.block)
            for block in blocks {
                // A managed score already has explicit editable regions.
                let managed = measures(in: file.tree).filter { block.range.contains($0.invocation.lowerBound) }
                if !managed.isEmpty {
                    for measure in managed {
                        let range = measure.invocation
                        result.append(Region(id: "p\(fileIndex)_\(range.lowerBound)", file: file.id, range: range, layout: false))
                    }
                    continue
                }
                let context = LensContextScanner.scan(file.tree, block: block.context)
                let layout = context.times.isEmpty && block.events.allSatisfy { file.tree.events[$0].kind == .spacer || isEmptyChord(file.tree.events[$0]) }
                var node: SyntaxNode?
                file.tree.root.forEachNode { if $0.range == block.range { node = $0 } }
                guard let node, node.kind == .sequential else { throw Failure("\(file.id): separate the simultaneous music into editable voice streams before migration.") }
                let interior = (block.range.lowerBound + 1)..<(block.range.upperBound - 1)
                if layout {
                    result.append(Region(id: "p\(fileIndex)_\(interior.lowerBound)", file: file.id, range: interior, layout: true))
                } else {
                    var start = interior.lowerBound
                    for cut in node.children.filter({ $0.kind == .barCheck }).map(\.range.lowerBound) + [interior.upperBound] {
                        let range = start..<cut
                        if block.events.contains(where: { range.contains(file.tree.events[$0].range.lowerBound) }) || file.tree.string(range).contains("\\") {
                            result.append(Region(id: "p\(fileIndex)_\(start)", file: file.id, range: range, layout: false))
                        }
                        start = cut + 1
                    }
                }
            }
        }
        return result
    }

    public struct LayoutRegion: Sendable {
        public var invocation: Range<Int>
        public var body: Range<Int>
    }

    public static func layoutRegions(in tree: SyntaxTree) -> [LayoutRegion] {
        var result: [LayoutRegion] = []
        tree.root.forEachNode { node in
            let children = node.children.filter { !$0.kind.isTrivia }
            for i in children.indices where children[i].kind == .command && tree.string(children[i].range) == "\\pondsideLayout" {
                guard i + 3 < children.count, children[i + 1].kind == .scheme,
                      children[i + 2].kind == .command, children[i + 3].kind == .sequential else { continue }
                let body = children[i + 3].range
                result.append(LayoutRegion(invocation: children[i].range.lowerBound..<body.upperBound,
                                           body: (body.lowerBound + 1)..<(body.upperBound - 1)))
            }
        }
        return result
    }

    static func observation(file: String, range: Range<Int>, in observations: [Observation]) -> Observation? {
        observations.first { $0.region.file == file && $0.region.range == range }
    }

    static func interpretedLayout(file: File, block: LensBlock, bars: [Bar], observed: Observation, sharedBreaks: Bool) throws -> Part {
        guard !observed.hasNotes else { throw Failure("\(file.id): generated notes need explicit measure boundaries in this voice.") }
        var ends: [LensFraction] = []
        var cursor = LensFraction.zero
        for bar in bars { cursor = cursor + bar.time.wholeNotes; ends.append(cursor) }
        guard observed.length.value <= cursor else { throw Failure("\(file.id): the evaluated layout track extends beyond the shared score timeline.") }
        func anchor(_ at: LensFraction, endpoint: Bool) throws -> String {
            if at == .zero { return "(\(name(0)) . 0)" }
            if let i = ends.firstIndex(of: at), endpoint { return "(\(name(i)) . 1)" }
            guard let i = ends.firstIndex(where: { at < $0 }) else {
                if let i = ends.firstIndex(of: at) { return "(\(name(i)) . 1)" }
                throw Failure("A layout anchor is outside the score.")
            }
            let start = i == 0 ? .zero : ends[i - 1]
            let fraction = (at - start) * LensFraction(bars[i].time.beatType, bars[i].time.beats)
            return "(\(name(i)) . \(fraction.numerator)/\(fraction.denominator))"
        }
        let slots = try observed.slots.map { slot in
            "(\(slot.kind) \(slot.written.numerator)/\(slot.written.denominator) \((slot.end.value - slot.start.value).numerator)/\((slot.end.value - slot.start.value).denominator) \(try anchor(slot.start.value, endpoint: false)) \(try anchor(slot.end.value, endpoint: true)))"
        }.joined(separator: "\n    ")
        var outputBars = bars.map { Bar(time: $0.time, breakCommand: nil, explicitTime: nil, length: $0.time.wholeNotes) }
        for directive in observed.directives {
            guard directive.kind != .meter else { throw Failure("\(file.id): a layout function changes meter; put that meter in the musical voice before migration.") }
            guard let i = ends.firstIndex(of: directive.offset.value) else { throw Failure("\(file.id): a generated break falls inside a shared measure. Resolve its intended boundary before migration.") }
            let command = directive.kind == .page ? "\\pageBreak" : "\\break"
            if outputBars[i].breakCommand == nil || directive.kind == .page { outputBars[i].breakCommand = command }
        }
        guard sharedBreaks || observed.directives.isEmpty else { throw Failure("Interpreted layout migration requires shared breaks.") }
        let range = (block.range.lowerBound + 1)..<(block.range.upperBound - 1)
        var edits: [TextEdit] = []
        file.tree.root.forEachLeaf { leaf in
            if range.contains(leaf.range.lowerBound), leaf.kind == .command,
               ["\\break", "\\pageBreak"].contains(file.tree.string(leaf.range)) {
                edits.append(TextEdit((leaf.range.lowerBound - range.lowerBound)..<(leaf.range.upperBound - range.lowerBound), ""))
            }
        }
        let body = edits.apply(to: file.tree.string(range))
        // Keep function calls and their arguments verbatim. Structural music is
        // stripped from their evaluated results by the LilyPond helper.
        let replacement = "\n  \\pondsideLayout #'(\n    " + slots + "\n  ) \\pondsideTimeline {" + body + "\n  }\n"
        return Part(file: file.id, edits: [TextEdit((block.range.lowerBound + 1)..<(block.range.upperBound - 1), replacement)], bars: outputBars)
    }
    /// Whether the length of `body` needs LilyPond to evaluate it: generated
    /// or simultaneous music, or a command that may take time. `timeless`
    /// names the score's own commands that take none (`TimelessCommands`).
    public static func needsInterpreter(in tree: SyntaxTree, body: Range<Int>, timeless: Set<String> = []) -> Bool {
        if generatesMusic(tree, body: body) { return true }
        let context = LensContextScanner.scan(tree, block: body, timeless: timeless)
        return !context.custom.isEmpty || !context.unsupported.filter { $0 != "markup" }.isEmpty
    }

    /// Simultaneous music, or Scheme that may make music, starting in `body`.
    /// Scheme that sets a value cannot: a tweak or override value
    /// (`-\tweak stencil #(…)`, `\override X.y = #(…)`), or anything in a post-event.
    static func generatesMusic(_ tree: SyntaxTree, body: Range<Int>) -> Bool {
        func walk(_ node: SyntaxNode, inPostEvent: Bool) -> Bool {
            var previous: SyntaxNode?
            for child in node.children where !child.kind.isTrivia {
                defer { previous = child }
                guard child.range.upperBound > body.lowerBound, child.range.lowerBound < body.upperBound else { continue }
                let starts = body.contains(child.range.lowerBound)
                if starts, child.kind == .simultaneous { return true }
                if child.kind == .scheme {
                    let isValue = inPostEvent || previous.map { $0.kind == .equals || $0.kind == .propertyPath } == true
                    if isValue { continue }
                    let text = tree.string(child.range)
                    if starts, text.hasPrefix("#(") || text.hasPrefix("$") { return true }
                }
                if walk(child, inPostEvent: inPostEvent || child.kind == .postEvent) { return true }
            }
            return false
        }
        return walk(tree.root, inPostEvent: false)
    }

    static func timelineDefinition(names: [String]) -> String {
        "pondsideTimeline = #(make-sequential-music (map (lambda (name) (let ((m (ly:music-deep-copy (ly:parser-lookup name)))) (ly:music-set-property! m 'pondside-id name) m)) '(" + names.joined(separator: " ") + ")))"
    }

    static let interpretedRuntime = #"""
#(define (pondside-structural-music? m)
   (or (memq 'time-signature-music (ly:music-property m 'types))
       (memq (ly:music-property m 'name) '(LineBreakEvent PageBreakEvent))
       (ly:music-property m 'page-marker #f)))
#(define (pondside-strip-structure m)
   (if (pondside-structural-music? m)
       (make-sequential-music '())
       (begin
         (ly:music-set-property! m 'elements
           (map pondside-strip-structure (ly:music-property m 'elements)))
         (let ((element (ly:music-property m 'element)))
           (if (ly:music? element)
               (ly:music-set-property! m 'element (pondside-strip-structure element))))
         (music-map (lambda (item) item) m))))
pondsideLayout =
#(define-music-function (anchors timeline music) (list? ly:music? ly:music?)
   (let ((remaining anchors)
         (bars (ly:music-property timeline 'elements)))
     (define (point anchor)
       (let loop ((todo bars) (moment 0))
         (if (null? todo) (ly:error "Pondside: missing layout measure; rerun Make Score Pondside-Ready"))
         (let* ((bar (car todo)) (length (ly:moment-main (ly:music-length bar))))
           (if (eq? (ly:music-property bar 'pondside-id) (car anchor))
               (+ moment (* (cdr anchor) length))
               (loop (cdr todo) (+ moment length))))))
     (define (walk m)
       (let ((name (ly:music-property m 'name)))
         (if (memq 'note-event (ly:music-property m 'types))
             (ly:error "Pondside: this layout now generates notes; move them into a musical voice before retrying Make Score Pondside-Ready"))
         (if (memq name '(SkipEvent SkipMusic RestEvent MultiMeasureRestMusic))
             (begin
               (if (null? remaining) (ly:error "Pondside: layout source no longer matches its anchors; fix the layout source or anchors before retrying Make Score Pondside-Ready"))
               (let* ((anchor (car remaining))
                      (written (ly:moment-main (ly:music-length m)))
                      (expected (- (point (list-ref anchor 4)) (point (list-ref anchor 3))))
                      (effective (list-ref anchor 2)))
                 (if (or (not (eq? name (car anchor))) (not (= written (cadr anchor))))
                     (ly:error "Pondside: layout source no longer matches its anchors; restore the edited duration or correct its anchors, then retry Make Score Pondside-Ready"))
                 (if (< expected 0) (ly:error "Pondside: reversed layout anchors"))
                 (ly:music-set-property! m 'duration
                   (make-duration-of-length
                     (ly:make-moment (if (= effective 0) 0 (* written (/ expected effective))))))
                 (set! remaining (cdr remaining))))
             (begin
               (ly:music-set-property! m 'elements (map walk (ly:music-property m 'elements)))
               (let ((element (ly:music-property m 'element)))
                 (if (ly:music? element) (ly:music-set-property! m 'element (walk element))))))
         (music-map (lambda (item) item) m)))
     (let ((result (walk (pondside-strip-structure music))))
       (if (not (null? remaining)) (ly:error "Pondside: layout source no longer matches its anchors; fix the layout source or anchors before retrying Make Score Pondside-Ready"))
       (make-simultaneous-music (list result timeline)))))
"""#

}
