import Foundation
import PondsideCore

/// Snapshot, planning and coordinated disk write for a note-entry burst.
/// Call prepare/write on a worker; publish the returned source texts on the UI.
public enum UnmeteredInputTransaction {
    public struct Snapshot: Sendable {
        public var files: [StructuralEditing.File]
        public var revisions: [URL: ContentHash]
        public var dirty: Set<URL>
        public init(files: [StructuralEditing.File], revisions: [URL: ContentHash], dirty: Set<URL>) {
            self.files = files; self.revisions = revisions; self.dirty = dirty
        }
    }
    public struct Prepared: Sendable {
        public var plan: UnmeteredInputPlan.Result
        public var replacements: [URL: String]
        public var revisions: [URL: ContentHash]
    }
    public static func prepare(_ requests: [UnmeteredInputPlan.Request], snapshot: Snapshot,
                               root: String, active: String, anchor: Int) throws -> Prepared {
        let plan = try UnmeteredInputPlan.prepare(requests, files: snapshot.files, root: root, active: active, anchor: anchor)
        return preparingCommit(plan, snapshot: snapshot)
    }
    public static func preparingCommit(_ plan: UnmeteredInputPlan.Result, snapshot: Snapshot) -> Prepared {
        var replacements: [URL: String] = [:]
        for file in plan.files {
            let url = URL(fileURLWithPath: file.id)
            if snapshot.dirty.contains(url) || file.tree.text != snapshot.files.first(where: { $0.id == file.id })?.tree.text {
                replacements[url] = file.tree.text
            }
        }
        return Prepared(plan: plan, replacements: replacements, revisions: snapshot.revisions)
    }
    public static func write(_ prepared: Prepared) throws {
        try ProjectSourceTransaction.replace(expected: prepared.revisions, replacements: prepared.replacements)
    }
    public struct Proposal: Sendable {
        public var plan: UnmeteredInputPlan.Result
        public var tree: SyntaxTree
        public var lens: LensScoreWindow
    }
    /// Pure proposed source and lens construction: no disk or engraving.
    public static func propose(_ request: UnmeteredInputPlan.Request, files: [StructuralEditing.File],
                               root: String, active: String, anchor: Int) throws -> Proposal {
        let plan = try UnmeteredInputPlan.prepare([request], files: files, root: root, active: active, anchor: anchor)
        guard let tree = plan.files.first(where: { $0.id == active })?.tree,
              let structure = plan.files.first(where: { $0.id == root })?.tree,
              let lens = LensScoreBuilder.build(tree: tree, selection: plan.selectionRange, structure: structure) else {
            throw StructuralEditing.Failure("The proposed note cannot be shown in the notation lens.")
        }
        return Proposal(plan: plan, tree: tree, lens: lens)
    }
    public static func committedSnapshot(_ prepared: Prepared) -> Snapshot {
        let revisions = Dictionary(uniqueKeysWithValues: prepared.plan.files.map { (URL(fileURLWithPath: $0.id), ContentHash($0.tree.text)) })
        return Snapshot(files: prepared.plan.files, revisions: revisions, dirty: [])
    }

}
