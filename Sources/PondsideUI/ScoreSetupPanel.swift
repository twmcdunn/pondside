import AppKit
import SwiftUI
import PondsideCore

/// What Score Setup shows, read from the score's files after every edit and
/// engraving. The panel keeps no state of its own: each control turns into a
/// minimal edit of the root, a file it includes, or `front-matter.ily`.
@MainActor
final class ScoreSetupModel: ObservableObject {
    enum Page: String, CaseIterable, Identifiable {
        case staves = "Staves", cover = "Cover Page", notes = "Notes", legend = "Legend"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .staves: "music.note.list"
            case .cover: "doc.richtext"
            case .notes: "text.alignleft"
            case .legend: "list.bullet.rectangle"
            }
        }
    }

    /// A symbol found in the score's instrumental music, or a Lexicon entry it uses.
    struct Candidate: Identifiable, Hashable {
        var id: String
        var title: String
        /// How the score writes it and where: `\wind #0.75 · flute.ly:252 · 12×`.
        var detail: String
        /// False when it most likely prints nothing (playback or layout only).
        var printed: Bool
        var item: FrontMatter.NewLegendItem
    }

    @Published var page: Page = .staves
    @Published var staves: [StaffSetup.Staff] = []
    @Published var fileNames: [String] = []
    @Published var header: [String: EngravingSettingsDocument.HeaderField] = [:]
    @Published var sections: Set<FrontMatter.Section> = []
    @Published var notesHeading = ""
    /// nil: the notes hold markup of the user's own.
    @Published var paragraphs: [String]? = []
    @Published var legendHeading = ""
    @Published var legendItems: [FrontMatter.LegendItem] = []
    @Published var arrangingLegend = false
    /// Symbols the instrumental music uses, which the user includes in the legend or leaves out.
    @Published var candidates: [Candidate] = []
    @Published var rootName = ""

    var onStaffChange: (Int, StaffSetup.Change) -> Void = { _, _ in }
    var onShowStaff: (Int) -> Void = { _ in }
    var onHeader: (String, String) -> Void = { _, _ in }
    var onSection: (FrontMatter.Section, Bool) -> Void = { _, _ in }
    var onHeading: (FrontMatter.Section, String) -> Void = { _, _ in }
    var onParagraphs: ([String]) -> Void = { _ in }
    var onAddLegend: ([FrontMatter.NewLegendItem]) -> Void = { _ in }
    var onAddSymbol: () -> Void = {}
    var onRemoveLegend: (String) -> Void = { _ in }
    var onEditLegend: (String, String?, String?) -> Void = { _, _, _ in }
    var onShowFrontMatter: (FrontMatter.Section?) -> Void = { _ in }
    var onArrangeLegend: (Bool) -> Void = { _ in }

    /// The staves' names, for the cover's instrumentation line.
    var instrumentation: String {
        var seen: [String] = []
        for s in staves {
            guard let name = s.instrumentName?.value, !name.isEmpty else { continue }
            if !seen.contains(name) { seen.append(name) }
        }
        return seen.joined(separator: ", ")
    }
}

/// HIG Panels: like Engraving Settings, a utility panel rather than a sheet,
/// because people change a staff or the cover and watch the score
/// re-engrave. It floats over its document, hides when the app is inactive
/// and takes the keyboard only for a text field.
@MainActor
final class ScoreSetupPanel: NSPanel {
    let model = ScoreSetupModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 540),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered, defer: true)
        title = "Score Setup"
        isFloatingPanel = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 620, height: 400)
        contentView = NSHostingView(rootView: ScoreSetupView(model: model))
        setFrameAutosaveName("Pondside.scoreSetup")
    }

    /// Esc closes the panel, as it dismisses every transient thing in Pondside.
    override func cancelOperation(_ sender: Any?) { orderOut(sender) }
}

struct ScoreSetupView: View {
    @ObservedObject var model: ScoreSetupModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(ScoreSetupModel.Page.allCases, selection: $model.page) { page in
                    Label(page.rawValue, systemImage: page.symbol).tag(page)
                }
                .listStyle(.sidebar)
                .frame(width: 170)
                Divider()
                Group {
                    switch model.page {
                    case .staves: StavesPage(model: model)
                    case .cover: CoverPage(model: model)
                    case .notes: NotesPage(model: model)
                    case .legend: LegendPage(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Divider()
            HStack {
                Text(footer)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                if model.page != .staves {
                    Button("Show in Source") { model.onShowFrontMatter(section) }
                        .disabled(model.page == .cover ? false : !model.sections.contains(section ?? .cover))
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var section: FrontMatter.Section? {
        switch model.page {
        case .staves: nil
        case .cover: .cover
        case .notes: .notes
        case .legend: .legend
        }
    }

    private var footer: String {
        switch model.page {
        case .staves: "Saved in the staves’ \\with blocks. Concert pitch: Pondside writes no transposition."
        case .cover: "The cover prints the \\header of \(model.rootName); its layout is in \(FrontMatter.fileName)."
        case .notes, .legend: "Saved in \(FrontMatter.fileName), which \(model.rootName) includes before the score."
        }
    }
}

// MARK: - Staves

private struct StavesPage: View {
    @ObservedObject var model: ScoreSetupModel

    var body: some View {
        if model.staves.isEmpty {
            ContentUnavailableView("No Staves", systemImage: "music.note.list",
                                   description: Text("Score Setup lists each \\new Staff in the score. Add staves in the source."))
        } else {
            Form {
                ForEach(model.staves) { staff in
                    StaffRow(staff: staff, model: model)
                }
            }
            .formStyle(.grouped)
        }
    }
}

private struct StaffRow: View {
    let staff: StaffSetup.Staff
    @ObservedObject var model: ScoreSetupModel

    private var instrument: Instrument? { staff.instrument }
    private let customTag = "custom"

    var body: some View {
        Section {
            Picker("Instrument", selection: Binding(
                get: { instrument?.id ?? customTag },
                set: { id in
                    if let i = Instrument.named(id) { model.onStaffChange(staff.index, .init(instrument: i)) }
                })) {
                Text("Custom").tag(customTag)
                ForEach(Instrument.Family.allCases, id: \.self) { family in
                    Section(family.rawValue) {
                        ForEach(Instrument.catalog.filter { $0.family == family }) { i in
                            Text(i.name).tag(i.id)
                        }
                    }
                }
            }
            CommitField(title: "Name", value: staff.instrumentName?.value ?? "",
                        editable: staff.instrumentName?.editable ?? true,
                        prompt: "Printed before the first system") { name in
                model.onStaffChange(staff.index, nameChange(name))
            }
            CommitField(title: "Short name", value: staff.shortInstrumentName?.value ?? "",
                        editable: staff.shortInstrumentName?.editable ?? true,
                        prompt: "Printed before later systems") { short in
                model.onStaffChange(staff.index, .init(shortInstrumentName: short))
            }
            Picker("Clef", selection: Binding(
                get: { staff.clef?.value ?? "treble" },
                set: { model.onStaffChange(staff.index, .init(clef: $0)) })) {
                ForEach(Instrument.clefs, id: \.name) { Text($0.label).tag($0.name) }
                if let c = staff.clef?.value, !Instrument.clefs.contains(where: { $0.name == c }) { Text(c).tag(c) }
            }
            soundRow
        } header: {
            HStack {
                Text(staff.label).font(.headline)
                if let name = staff.name, staff.instrumentName != nil {
                    Text("“\(name)”").foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.onShowStaff(staff.index)
                } label: {
                    Label("\(model.fileNames[safe: staff.file] ?? ""):\(staff.line)", systemImage: "arrow.right.doc.on.clipboard")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Show this staff in the source")
                .accessibilityLabel("Show \(staff.label) in the source")
            }
        }
    }

    /// The mockup's sound: written, else what the name means.
    @ViewBuilder private var soundRow: some View {
        let explicit = staff.midiInstrument?.value
        let inferred = staff.instrumentName.flatMap { Instrument.matching(name: $0.value) }
        if explicit == nil, inferred?.midi == nil, inferred != nil {
            LabeledContent("Mockup sound") {
                Text("Silent: the patch plays electronics").foregroundStyle(.secondary)
            }
        } else {
            Picker("Mockup sound", selection: Binding(
                get: { explicit ?? "" },
                set: { model.onStaffChange(staff.index, .init(midiInstrument: $0)) })) {
                Text(inferred?.midi.map { "From the name (\($0))" } ?? "Piano (no name to go by)").tag("")
                Divider()
                ForEach(Instrument.midiSounds, id: \.self) { Text($0).tag($0) }
                if let e = explicit, !Instrument.midiSounds.contains(e) { Text(e).tag(e) }
            }
            .help("The General MIDI sound the mockup plays this staff with (midiInstrument)")
        }
    }

    /// A typed name that means a known instrument takes its sound and clef,
    /// and its short name when the old one was the previous instrument's.
    private func nameChange(_ name: String) -> StaffSetup.Change {
        guard let hit = Instrument.matching(name: name), hit.id != instrument?.id else {
            return .init(instrumentName: name)
        }
        let short = staff.shortInstrumentName?.value
        let keepShort = short.map { !$0.isEmpty && $0 != instrument?.shortName } ?? false
        return .init(instrumentName: name, shortInstrumentName: keepShort ? nil : hit.shortName,
                     midiInstrument: hit.midi ?? "", clef: hit.clef)
    }
}

// MARK: - Cover

private struct CoverPage: View {
    @ObservedObject var model: ScoreSetupModel

    var body: some View {
        Form {
            Section {
                Toggle("Print a cover page", isOn: Binding(
                    get: { model.sections.contains(.cover) },
                    set: { model.onSection(.cover, $0) }))
            } footer: {
                Text("A page of its own before the score, laid out from these fields. Title, subtitle, composer and dedication also head the score’s first page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Header") {
                ForEach(FrontMatter.headerFields, id: \.key) { field in
                    let found = model.header[field.key]
                    HStack(alignment: .firstTextBaseline) {
                        CommitField(title: field.label, value: found?.value ?? "", editable: found?.editable ?? true,
                                    prompt: prompt(field.key)) { model.onHeader(field.key, $0) }
                        if field.key == "instrumentation" {
                            Button("From Staves") { model.onHeader(field.key, model.instrumentation) }
                                .disabled(model.instrumentation.isEmpty || model.instrumentation == found?.value)
                                .help("Write the staves’ names: \(model.instrumentation)")
                        }
                    }
                    if let found, !found.editable {
                        Text("Written as markup in the source; edit it there.").font(.caption).foregroundStyle(.secondary)
                    } else if let other = found?.elsewhere {
                        Label("Set in \(other.file), line \(other.line)", systemImage: "doc.text")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func prompt(_ key: String) -> String {
        switch key {
        case "subtitle": "for flute and live electronics"
        case "dedication": "for …"
        case "duration": "ca. 8′"
        case "year": "2026"
        default: ""
        }
    }
}

// MARK: - Notes

private struct NotesPage: View {
    @ObservedObject var model: ScoreSetupModel
    @State private var draft = ""
    @State private var editing = false
    @FocusState private var focused: Bool

    private var stored: String { (model.paragraphs ?? []).joined(separator: "\n\n") }

    var body: some View {
        Form {
            Section {
                Toggle("Print notes", isOn: Binding(
                    get: { model.sections.contains(.notes) },
                    set: { model.onSection(.notes, $0) }))
            } footer: {
                Text("Performance or programme notes on the pages before the score. Paragraphs flow from page to page.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.sections.contains(.notes) {
                Section {
                    CommitField(title: "Heading", value: model.notesHeading, editable: true, prompt: "Performance Notes") {
                        model.onHeading(.notes, $0)
                    }
                }
                Section {
                    if model.paragraphs == nil {
                        Text("The notes hold markup of your own, so Pondside leaves them to the source.")
                            .foregroundStyle(.secondary)
                        Button("Show in Source") { model.onShowFrontMatter(.notes) }
                    } else {
                        TextEditor(text: $draft)
                            .font(.body)
                            .frame(minHeight: 220)
                            .focused($focused)
                            .scrollContentBackground(.hidden)
                            .accessibilityLabel("Notes text")
                            .onChange(of: draft) { editing = draft != stored }
                            .onChange(of: focused) { if !focused { commit() } }
                        HStack {
                            Text("A blank line starts a new paragraph.").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Revert") { draft = stored; editing = false }.disabled(!editing)
                            Button("Update Score", action: commit).keyboardShortcut(.return, modifiers: .command).disabled(!editing)
                        }
                    }
                } header: {
                    Text("Text")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draft = stored }
        .onChange(of: stored) { if !editing { draft = stored } }
    }

    private func commit() {
        guard editing else { return }
        let paragraphs = draft.components(separatedBy: "\n\n")
            .map { $0.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        editing = false
        model.onParagraphs(paragraphs)
    }
}

// MARK: - Legend

private struct LegendPage: View {
    @ObservedObject var model: ScoreSetupModel
    @State private var showUnprinted = false

    private var inLegend: Set<String> { Set(model.legendItems.map(\.id)) }
    private var printed: [ScoreSetupModel.Candidate] { model.candidates.filter(\.printed) }
    private var unprinted: [ScoreSetupModel.Candidate] { model.candidates.filter { !$0.printed } }

    var body: some View {
        Form {
            Section {
                Toggle("Print a legend", isOn: Binding(
                    get: { model.sections.contains(.legend) },
                    set: { model.onSection(.legend, $0) }))
            } footer: {
                Text("Each symbol shown as notation, rebuilt from where the score uses it, with what it means.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                if model.candidates.isEmpty {
                    Text("No special symbols in the instrumental parts: the score uses only LilyPond’s own notation.")
                        .foregroundStyle(.secondary)
                }
                ForEach(printed) { CandidateRow(candidate: $0, included: inLegend.contains($0.id), model: model)
                    .id("candidate:\($0.id)")
                }
                if !unprinted.isEmpty {
                    DisclosureGroup("Probably not printed (\(unprinted.count))", isExpanded: $showUnprinted) {
                        ForEach(unprinted) { CandidateRow(candidate: $0, included: inLegend.contains($0.id), model: model)
                            .id("candidate:\($0.id)")
                        }
                    }
                    .help("Commands for playback or layout: their definitions hide what they make")
                }
            } header: {
                Text("Found in the Score")
            } footer: {
                HStack {
                    let missing = printed.filter { !inLegend.contains($0.id) }
                    Text("Commands the score defines itself, used in the instrumental staves.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Include All") { model.onAddLegend(missing.map(\.item)) }
                        .disabled(missing.isEmpty)
                }
            }
            if model.sections.contains(.legend) {
                Section {
                    CommitField(title: "Heading", value: model.legendHeading, editable: true, prompt: "Legend") {
                        model.onHeading(.legend, $0)
                    }
                    Toggle("Arrange on Page", isOn: Binding(get: { model.arrangingLegend }, set: { model.onArrangeLegend($0) }))
                        .help("Drag the table, its column edges and row gaps on the page; drag an example's edges to crop it, its corner to scale it")
                } footer: {
                    Text("On the page: drag to move or resize, ⌘ while dragging turns snapping off, ⌥ scales every example, ⎋ ends.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    if model.legendItems.isEmpty {
                        Text("No symbols yet.").foregroundStyle(.secondary)
                    }
                    ForEach(model.legendItems) { item in
                        LegendRow(item: item, model: model)
                            .id("legend:\(item.id)")
                    }
                } header: {
                    Text("In the Legend")
                } footer: {
                    HStack {
                        Button("Add Other Symbol") { model.onAddSymbol() }
                            .help("A row for a symbol of your own; its example notation is written in the source")
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// Include or leave out one found symbol: on adds its legend row, off removes it.
private struct CandidateRow: View {
    let candidate: ScoreSetupModel.Candidate
    let included: Bool
    @ObservedObject var model: ScoreSetupModel

    var body: some View {
        Toggle(isOn: Binding(
            get: { included },
            set: { on in
                if on { model.onAddLegend([candidate.item]) } else { model.onRemoveLegend(candidate.id) }
            })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title)
                Text(candidate.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .toggleStyle(.checkbox)
        .accessibilityLabel("\(candidate.title) in the legend")
    }
}

private struct LegendRow: View {
    let item: FrontMatter.LegendItem
    @ObservedObject var model: ScoreSetupModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CommitField(title: "Name", value: item.title?.value ?? "", editable: item.title != nil, prompt: item.id) {
                    model.onEditLegend(item.id, $0, nil)
                }
                Button {
                    model.onRemoveLegend(item.id)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove from the legend")
                .accessibilityLabel("Remove \(item.title?.value ?? item.id) from the legend")
            }
            CommitField(title: "Meaning", value: item.text?.value ?? "", editable: item.text != nil, prompt: "What the performer does") {
                model.onEditLegend(item.id, nil, $0)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Fields

/// A text field that writes when the user presses Return or leaves it, not
/// on every keystroke: each write is an edit of the score and an engraving.
private struct CommitField: View {
    let title: String
    let value: String
    let editable: Bool
    var prompt: String = ""
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text, prompt: prompt.isEmpty ? nil : Text(prompt))
            .focused($focused)
            .disabled(!editable)
            .onSubmit(send)
            .onChange(of: focused) { if !focused { send() } }
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
            .onExitCommand { text = value; focused = false }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed != value { commit(trimmed) }
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
