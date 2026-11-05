import PondsideCore
import PondsideEngrave
import PondsideTiming

/// Frozen source, engraving and section geometry for preparing a graphics
/// request away from the UI. No views, file reads or mutable document state.
public struct GraphicsRequestContext: Sendable {
    public struct Source: Sendable, Equatable {
        public var file: String
        public var text: String
        public var position: SourcePosition
        public init(file: String, text: String, position: SourcePosition) {
            self.file = file; self.text = text; self.position = position
        }
    }
    public var source: Source
    public var files: [ScoreGraphic.File]
    public var root: ScoreGraphic.File
    public var cues: CueSheet?
    public var section: GraphicSection
    public var geometry: JSONValue
    public var timing: TimingLog?
    public var pages: [EngravedPage]
    public var from: Source?
    public var to: Source?
    public var generation: Int

    public init(source: Source, files: [ScoreGraphic.File], root: ScoreGraphic.File, cues: CueSheet?,
                section: GraphicSection, geometry: JSONValue, timing: TimingLog?, pages: [EngravedPage],
                from: Source?, to: Source?, generation: Int) {
        self.source = source; self.files = files; self.root = root; self.cues = cues
        self.section = section; self.geometry = geometry; self.timing = timing; self.pages = pages
        self.from = from; self.to = to; self.generation = generation
    }

    public func matches(_ other: Self) -> Bool {
        source == other.source && from == other.from && to == other.to && section == other.section && geometry == other.geometry
            && generation == other.generation && cues == other.cues && timing == other.timing
            && root.path == other.root.path && root.text == other.root.text
            && files.count == other.files.count
            && zip(files, other.files).allSatisfy { $0.path == $1.path && $0.text == $1.text }
    }

    public func describe() -> JSONValue {
        let context = ScoreContext.describe(text: source.text, file: source.file,
            line: source.position.line, character: source.position.character, files: files, cues: cues, root: root)
        guard case .object(var fields) = context, case .object(var selection) = geometry else { return context }
        let map = timing.map { SectionTimeMap(log: $0, pages: pages) }
        let staff = fields["staff"]?.string
        for (name, endpoint, fallback) in [("from", section.from, from), ("to", section.to, to)] {
            guard case .object(var edge) = selection[name] else { continue }
            if let point = map?.edge(at: endpoint, staffName: staff) {
                var at: [String: JSONValue] = ["bar": .number(Double(point.bar)), "moment": .string(point.moment.description)]
                if let source = point.source {
                    at["source"] = ["file": .string(source.file), "line": .number(Double(source.line)), "character": .number(Double(source.character))]
                }
                edge["at"] = .object(at)
            } else if let fallback {
                // Endpoints need music/time only, never another recursive
                // drawing-definition/dependency context.
                let music = ScoreContext.describe(text: fallback.text, file: fallback.file,
                    line: fallback.position.line, character: fallback.position.character,
                    files: files, cues: cues, includeGraphic: false)
                if let bar = music["bar"], let moment = music["moment"] {
                    var at: [String: JSONValue] = ["bar": bar, "moment": moment,
                        "source": ["file": .string(fallback.file), "line": .number(Double(fallback.position.line)),
                                   "character": .number(Double(fallback.position.character))]]
                    if let event = music["event"]?["text"] { at["event"] = event }
                    edge["at"] = .object(at)
                }
            }
            selection[name] = .object(edge)
        }
        if let at = selection["from"]?["at"] { selection["at"] = at }
        if var systems = selection["systems"]?.array {
            for index in systems.indices where section.systems.indices.contains(index) {
                let system = section.systems[index]
                if let moments = map?.systemMoments(page: system.page, system: system.system), case .object(var fields) = systems[index] {
                    fields["moments"] = .array([.string(moments.first.description), .string(moments.last.description)])
                    systems[index] = .object(fields)
                }
            }
            selection["systems"] = .array(systems)
        }
        fields["selection"] = .object(selection)
        return .object(fields)
    }
}
