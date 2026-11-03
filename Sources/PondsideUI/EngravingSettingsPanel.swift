import AppKit
import SwiftUI
import PondsideCore

/// The score's engraving settings, as LilyPond reads them from its files.
/// Every control edits the `.ly` text directly (a minimal edit, undoable in
/// the source), so the panel holds no state of its own and the score
/// re-engraves as you go.
@MainActor
final class EngravingSettingsModel: ObservableObject {
    @Published var values: [String: EngravingSettingsDocument.Found] = [:]
    @Published var group = EngravingSetting.groups[0]
    @Published var rootName = ""
    var onChange: (EngravingSetting, EngravingValue) -> Void = { _, _ in }
    var onRestoreAll: () -> Void = {}
    var onShowSource: () -> Void = {}
    var onMigrateStructure: () -> Void = {}
    @Published var structuralStatus = ""
    @Published var migrationRunning = false

    func value(_ setting: EngravingSetting) -> EngravingValue {
        values[setting.id]?.value ?? setting.defaultValue
    }

    var hasChanges: Bool {
        EngravingSetting.all.contains { value($0) != $0.defaultValue }
    }
}

/// HIG Panels: a panel, not a sheet, because people change a setting and
/// watch the score; it floats over its document, hides when the app is
/// inactive, and takes the keyboard only for a field that needs typing.
@MainActor
final class EngravingSettingsPanel: NSPanel {
    let model = EngravingSettingsModel()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 640, height: 500),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow],
                   backing: .buffered, defer: true)
        title = "Engraving Settings"
        isFloatingPanel = true
        hidesOnDeactivate = true
        becomesKeyOnlyIfNeeded = true
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 560, height: 380)
        contentView = NSHostingView(rootView: EngravingSettingsView(model: model))
        setFrameAutosaveName("Pondside.engravingSettings")
    }
}

struct EngravingSettingsView: View {
    @ObservedObject var model: EngravingSettingsModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                List(EngravingSetting.groups, id: \.self, selection: $model.group) { group in
                    Text(group)
                }
                .listStyle(.sidebar)
                .frame(width: 170)
                Divider()
                Form {
                    ForEach(EngravingSetting.all.filter { $0.group == model.group }) { setting in
                        SettingRow(setting: setting, model: model)
                    }
                }
                .formStyle(.grouped)
            }
            Divider()
            HStack {
                Text(model.structuralStatus)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Make Score Pondside-Ready…", action: model.onMigrateStructure)
                    .disabled(model.migrationRunning)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            HStack {
                Text("Saved in \(model.rootName)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Show in Source", action: model.onShowSource)
                Button("Restore Defaults…", action: model.onRestoreAll)
                    .disabled(model.migrationRunning)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct SettingRow: View {
    let setting: EngravingSetting
    @ObservedObject var model: EngravingSettingsModel

    private var found: EngravingSettingsDocument.Found? { model.values[setting.id] }
    private var value: EngravingValue { model.value(setting) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                control
                if value != setting.defaultValue {
                    Button {
                        model.onChange(setting, setting.defaultValue)
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Back to LilyPond's default")
                    .accessibilityLabel("Restore default for \(setting.title)")
                }
            }
            if !setting.help.isEmpty {
                Text(setting.help).font(.caption).foregroundStyle(.secondary)
            }
            if let found, !found.inRoot, let other = found.elsewhere.last {
                // What another file says, in words: passive status near the setting.
                Label("Set in \(other.file), line \(other.line): \(other.statement)", systemImage: "doc.text")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help("Changing it here writes the setting in \(model.rootName), which LilyPond reads last.")
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .toggle:
            Toggle(setting.title, isOn: Binding(
                get: { value.bool ?? false },
                set: { model.onChange(setting, .bool($0)) }))
        case let .choice(choices):
            Picker(setting.title, selection: Binding(
                get: { value.choice ?? "" },
                set: { model.onChange(setting, .choice($0)) })) {
                ForEach(choices, id: \.value) { Text($0.label).tag($0.value) }
                if let current = value.choice, !choices.contains(where: { $0.value == current }) {
                    Text(current).tag(current)
                }
            }
        case let .number(unit, range, step):
            LabeledContent(setting.title) {
                HStack(spacing: 6) {
                    TextField(setting.title, value: Binding(
                        get: { value.number ?? range.lowerBound },
                        set: { model.onChange(setting, .number(min(max($0, range.lowerBound), range.upperBound))) }),
                              format: .number.precision(.fractionLength(0...1)))
                        .labelsHidden()
                        .multilineTextAlignment(.trailing)
                        .frame(width: 64)
                    Stepper(setting.title, value: Binding(
                        get: { value.number ?? range.lowerBound },
                        set: { model.onChange(setting, .number($0)) }), in: range, step: step)
                        .labelsHidden()
                    Text(unit).foregroundStyle(.secondary).frame(minWidth: 44, alignment: .leading)
                }
            }
        }
    }
}
