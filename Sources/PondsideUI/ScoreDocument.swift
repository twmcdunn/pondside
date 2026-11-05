import AppKit
import PondsideCore
import PondsideEngrave
import PondsideTiming
import PondsideLexicon
import PondsideBridge
import os

enum CompileStatus: Equatable {
    case idle
    case noLilyPond
    case compiling
    case clean(milliseconds: Int)
    case errors(Int)
    case failed(String)
}

@MainActor
protocol ScoreDocumentDelegate: AnyObject {
    func document(_ document: ScoreDocument, didReloadFromDisk file: SourceFile)
    func document(_ document: ScoreDocument, hasConflictIn file: SourceFile, diskText: String)
    func documentStatusDidChange(_ document: ScoreDocument)
    func documentDidEngrave(_ document: ScoreDocument)
    /// The last engraving from the render cache is showing while the first
    /// real one runs.
    func documentDidLoadCachedRender(_ document: ScoreDocument)
    /// Files joined or left the include graph.
    func documentFilesDidChange(_ document: ScoreDocument)
    /// The playback's timing arrived (with the mockup): cue times changed.
    func documentDidUpdatePlayback(_ document: ScoreDocument)
}

/// Detected LilyPond installs, probed once per launch.
@MainActor
final class ToolchainStore {
    static let shared = ToolchainStore()
    private var task: Task<[LilyPondInstallation], Never>?

    func installs() async -> [LilyPondInstallation] {
        if let task { return await task.value }
        let t = Task { await ToolchainDetector().detectLilyPond() }
        task = t
        return await t.value
    }
}

/// Lets a @Sendable callback reach a main-actor object without retaining it.
final class WeakRef<T: AnyObject>: @unchecked Sendable {
    weak var value: T?
    init(_ value: T) { self.value = value }
}

/// One file of a score: the root or anything it `\include`s.
///
/// The file on disk is the truth. Edits autosave after 250 ms of idle;
/// external writes are recognised by content and merged.
@MainActor
final class SourceFile {
    /// Canonical location (symlinks resolved).
    let url: URL
    fileprivate(set) var text: String
    /// Parsed in context (the language in effect where it is included).
    fileprivate(set) var tree: SyntaxTree
    fileprivate(set) var entryLanguage: PitchLanguage = .nederlands
    // Revisions produced by constrained score commands (including undo).
    fileprivate var constructedRevisions: Set<ContentHash> = []
    /// The text the current pages were engraved from (their links refer to it).
    fileprivate(set) var engravedText: String?
    /// The text the current diagnostics refer to.
    fileprivate(set) var compiledText: String?
    fileprivate(set) var diagnostics: [Diagnostic] = []
    /// Source positions in this file that produced graphics, in order.
    fileprivate(set) var linkedPositions: [SourcePosition] = []
    /// One undo stack per file, as in any text editor.
    let undoManager = UndoManager()

    fileprivate var sync = DiskSync()
    fileprivate var watcher: FileWatcher?
    fileprivate var saveTask: Task<Void, Never>?
    fileprivate var pendingSnapshot: String?

    var displayName: String { url.lastPathComponent }

    /// Whether the file holds any music events with pitches.
    var hasNotes: Bool { tree.notes.contains { $0.role == .event } }

    fileprivate init(url: URL, text: String, tree: SyntaxTree) {
        self.url = url
        self.text = text
        self.tree = tree
        sync = DiskSync(lastSyncedHash: ContentHash(text))
    }

    func matches(path: String) -> Bool {
        PathMatching.same(path, url.path)
    }
}

/// An open score: the root `.ly` file and every file it includes.
///
/// The root is what LilyPond compiles. Any file in the include graph can be
/// edited from the score; each keeps its own text, undo, autosave and
/// watcher, and a change to any of them re-engraves the root.
@MainActor
final class ScoreDocument {
    let url: URL
    private(set) var files: [SourceFile]
    weak var delegate: ScoreDocumentDelegate?

    private(set) var status: CompileStatus = .idle
    /// When the latest compile started (it reads the files as they were
    /// then), so a script that wrote a file knows when its result is in.
    private(set) var compileStarted: Date?
    /// LilyPond's output from the latest compile, for the compiler-output pane.
    private(set) var lastLog = ""
    /// Cue times from the latest compile (every canvas compile logs them).
    private(set) var cueSheet: CueSheet?
    /// The latest compile's timing rows (bars, tempos), for playing from a bar.
    private(set) var timingLog: TimingLog?
    private(set) var pages: [EngravedPage] = []
    /// Systems of `pages` that run into the right margin while automatic
    /// line breaks are off; found with the pages, off the main actor.
    private(set) var overflows: [SystemOverflow] = []
    private(set) var installation: LilyPondInstallation? {
        didSet {
            if installation != oldValue {
                let old = daemon
                Task { await old?.stop() }
                daemon = installation.map { LilyPondDaemon(installation: $0) }
            }
        }
    }
    /// The warm LilyPond for canvas compiles (M4); one per open score.
    private var daemon: LilyPondDaemon?
    private(set) var declaredVersion: LilyPondVersion?
    /// Files that contribute notes but produced no point-and-click links.
    private(set) var unlinkedFiles: [SourceFile] = []

    private var renderTask: Task<Void, Never>?
    private(set) var renderGeneration = 0
    private(set) var completedRenderGeneration = 0
    private var compilingGeneration: Int?
    private let workDirectory: URL
    private var opened = false
    private var engravingSuspended = false
    /// Pages from the render cache are showing, not yet replaced by this
    /// session's own engraving.
    private(set) var showingCachedRender = false
    /// Stores run one after another, so the last engraving is the one kept.
    private var storeTask: Task<Void, Never>?
    /// Checkpoints of the score's files, half a minute after the last save.
    private var historyTask: Task<Void, Never>?
    /// One mockup render at a time; an engraving during it asks for one more.
    private var mockupRunning = false {
        didSet { if mockupRunning != oldValue { delegate?.documentStatusDidChange(self) } }
    }

    /// What runs in the background besides engraving, for the status bar.
    var activities: [String] {
        (mockupRunning ? ["Preparing playback…"] : []) + (mixRunning ? ["Rendering the mix..."] : [])
    }
    private var mockupPending = false
    /// The cue sheet is the playback's, not the canvas's.
    private var hasPlaybackTiming = false

    static let historyRoot: URL? = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
        .appendingPathComponent("Pondside/History", isDirectory: true)

    /// Where the latest engraving of every score is kept between launches:
    /// a cache the system may purge, never beside the score (AGENTS.md).
    static let renderCache: RenderCache? = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first
        .map { RenderCache(root: $0.appendingPathComponent("Pondside/Renders", isDirectory: true)) }

    static let autosaveDelay: Duration = .milliseconds(250)

    var root: SourceFile { files[0] }

    init(url: URL) throws {
        let canonical = SourceGraph.canonical(url)
        // Fail early, as before, if the root can't be read.
        _ = try Data(contentsOf: canonical)
        self.url = canonical
        let graph = SourceGraph.load(root: canonical)
        files = graph.files.map { f in
            let file = SourceFile(url: f.url, text: f.text, tree: f.tree)
            file.entryLanguage = f.entryLanguage
            return file
        }
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Pondside", isDirectory: true)
            .appendingPathComponent(ContentHash(canonical.path).description, isDirectory: true)
        declaredVersion = LilyPondVersion.declared(in: files[0].text)
        contractRequired = StructuralEditing.isManaged(files[0].tree)
        scheduleAudit(after: .zero)
    }

    // MARK: Contract audit

    /// The project texts last known to pass `StructuralEditing.validate`.
    /// A built-in structural or note edit keeps an audited project audited
    /// (it preserves the contract by construction), so the GUI's edits skip
    /// the whole-project check (165 ms on a 4,000-line score) unless a Source
    /// or outside edit came since; that edit is audited in the background.
    private var auditedRevision: [URL: ContentHash]?
    private var auditTask: Task<Void, Never>?

    private var currentRevision: [URL: ContentHash] {
        Dictionary(uniqueKeysWithValues: files.map { ($0.url, ContentHash($0.text)) })
    }

    /// Built-in structural edits may skip `validate` (`validatingContract: false`).
    var contractAudited: Bool { auditedRevision != nil && auditedRevision == currentRevision }

    /// After a built-in edit: audited before means audited now.
    private func carryAudit(from before: [URL: ContentHash]) {
        if auditedRevision == before { auditedRevision = currentRevision } else { scheduleAudit() }
    }

    /// Audits the current texts off the main thread, after a pause so that
    /// typing in Source doesn't start one per keystroke.
    private func scheduleAudit(after delay: Duration = .milliseconds(400)) {
        auditTask?.cancel()
        guard StructuralEditing.isManaged(root.tree) else { auditedRevision = nil; return }
        let revision = currentRevision
        let snapshot = files.map { StructuralEditing.File(id: $0.url.path, tree: $0.tree) }
        let rootID = root.url.path
        auditTask = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let valid = await Task.detached(priority: .utility) {
                (try? StructuralEditing.validate(snapshot, root: rootID)) != nil
            }.value
            guard !Task.isCancelled, let self, valid, self.currentRevision == revision else { return }
            self.auditedRevision = revision
        }
    }

    func file(for path: String) -> SourceFile? {
        if let f = files.first(where: { $0.matches(path: path) }) { return f }
        // LilyPond reports some paths relative to the root's folder.
        guard !path.hasPrefix("/") else { return nil }
        let absolute = url.deletingLastPathComponent().appendingPathComponent(path).path
        return files.first { $0.matches(path: absolute) }
    }

    func open() {
        opened = true
        for f in files { startWatching(f) }
        showCachedRender()
        Task {
            let installs = await ToolchainStore.shared.installs()
            // pondside.toml's pin wins over the score's \\version (as in the CLI).
            let pinned = (try? ProjectConfig.find(from: url))?.lilypondVersion.flatMap { LilyPondVersion($0) }
            installation = ToolchainDetector.select(from: installs, for: pinned ?? declaredVersion)
            if installation == nil { setStatus(.noLilyPond) } else { engrave() }
        }
    }

    /// Shows the last engraving at once; LilyPond engraves afresh anyway.
    /// The cached text of each file lets the engraving map line its links
    /// up with text that changed since, as for any stale engraving.
    private func showCachedRender() {
        guard pages.isEmpty, let entry = Self.renderCache?.load(for: url) else { return }
        let cached = entry.pages.map(EngravedPage.init(svg:)).filter { !$0.graphics.isEmpty }
        guard !cached.isEmpty else { return }
        pages = cached
        for f in files { f.engravedText = entry.snapshots[f.url.standardizedFileURL.path] }
        distributeLinks()
        showingCachedRender = true
        delegate?.documentDidLoadCachedRender(self)
    }

    /// The git that keeps checkpoints, once found to work; nil while
    /// unchecked or when there is none (Revert to Checkpoint… is greyed).
    private(set) static var checkpointGit: String?
    private static var checkpointGitDetection: Task<String?, Never>?

    /// Looks for a working git off the main thread, once per launch.
    @discardableResult
    static func detectCheckpointGit() -> Task<String?, Never> {
        if let task = checkpointGitDetection { return task }
        let task = Task { @MainActor in
            let git = await Task.detached(priority: .utility) { ShadowHistory.workingGit() }.value
            checkpointGit = git
            return git
        }
        checkpointGitDetection = task
        return task
    }

    /// The shadow history of this score, if checkpoints are being kept.
    var history: ShadowHistory? {
        guard let root = Self.historyRoot, let git = Self.checkpointGit else { return nil }
        return ShadowHistory(score: url, root: root, git: git)
    }

    /// Checkpoints now (after saving), so the current state can be returned
    /// to, e.g. before reverting.
    func checkpointNow(message: String) async {
        flushPendingSaves()
        // A checkpoint already running finishes first: two gits at once
        // would collide on the history's index lock.
        let pending = historyTask
        pending?.cancel()
        await pending?.value
        guard let history else { return }
        let urls = files.map(\.url)
        _ = try? await history.checkpoint(urls, message: message)
    }

    /// A checkpoint in the shadow history (never the user's own git repo).
    private func scheduleCheckpoint(after delay: Duration) {
        guard let root = Self.historyRoot else { return }
        historyTask?.cancel()
        let url = url
        let urls = files.map(\.url)
        let detection = Self.detectCheckpointGit()
        historyTask = Task.detached(priority: .background) {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let git = await detection.value else { return }
            try? await ShadowHistory(score: url, root: root, git: git).checkpoint(urls)
        }
    }

    /// Uses `install` for this score from now on (the choice is in pondside.toml).
    func use(_ install: LilyPondInstallation) {
        installation = install
        engrave()
    }

    func close() {
        opened = false
        flushPendingSaves()
        scheduleCheckpoint(after: .zero)
        renderTask?.cancel()
        inputEngraveTask?.cancel()
        renderTask = nil
        let d = daemon
        Task { await d?.stop() }
        for f in files {
            f.watcher?.stop()
            f.watcher = nil
        }
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Re-checks the disk immediately (e.g. when the app becomes active).
    func revalidate() {
        files.forEach { $0.watcher?.pollNow() }
    }

    private func startWatching(_ file: SourceFile) {
        guard opened, file.watcher == nil else { return }
        let ref = WeakRef(self)
        let fileRef = WeakRef(file)
        let w = FileWatcher(url: file.url) { change in
            Task { @MainActor in
                guard let doc = ref.value, let f = fileRef.value else { return }
                doc.diskChanged(f, change.text)
            }
        }
        w.start()
        file.watcher = w
    }

    // MARK: The include graph

    /// Re-reads the graph using the in-memory texts, re-parsing every file
    /// in context and picking up includes that were added or removed.
    private func refreshGraph() {
        var overrides: [URL: String] = [:]
        for f in files { overrides[f.url] = f.text }
        let graph = SourceGraph.load(root: url, overrides: overrides)
        var byURL: [URL: SourceFile] = [:]
        for f in files { byURL[f.url] = f }
        var next: [SourceFile] = []
        var changed = false
        for g in graph.files {
            if let f = byURL[g.url] {
                f.tree = g.tree
                f.entryLanguage = g.entryLanguage
                next.append(f)
            } else {
                let f = SourceFile(url: g.url, text: g.text, tree: g.tree)
                f.entryLanguage = g.entryLanguage
                next.append(f)
                startWatching(f)
                changed = true
            }
        }
        for f in files where !next.contains(where: { $0 === f }) {
            f.watcher?.stop()
            f.watcher = nil
            changed = true
        }
        files = next
        contractRequired = contractRequired || StructuralEditing.isManaged(root.tree)
        declaredVersion = LilyPondVersion.declared(in: root.text)
        if changed { delegate?.documentFilesDidChange(self) }
    }

    // MARK: Editing and saving

    func userEdited(_ file: SourceFile, text newText: String, prepared: SyntaxTree? = nil) {
        if let prepared {
            let revision = currentRevision
            let before = ContentHash(file.text)
            if before == file.sync.lastSyncedHash || file.constructedRevisions.contains(before) {
                file.constructedRevisions.insert(before)
                file.constructedRevisions.insert(ContentHash(newText))
            }
            file.text = newText
            file.tree = prepared
            carryAudit(from: revision)
        } else {
            file.text = newText
            refreshGraph()
            scheduleAudit()
        }
        file.saveTask?.cancel()
        file.saveTask = Task { [weak self, weak file] in
            try? await Task.sleep(for: ScoreDocument.autosaveDelay)
            guard !Task.isCancelled, let self, let file else { return }
            if await self.autosave(file) { self.engrave() }
        }
    }

    func inputSnapshot() -> UnmeteredInputTransaction.Snapshot {
        var dirty = Set<URL>()
        var revisions: [URL: ContentHash] = [:]
        let inputFiles = files.map { file -> StructuralEditing.File in
            file.saveTask?.cancel()
            file.saveTask = nil
            if ContentHash(file.text) != file.sync.lastSyncedHash { dirty.insert(file.url) }
            revisions[file.url] = file.sync.lastSyncedHash
            var languages: [String: PitchLanguage] = [:]
            for include in file.tree.includes {
                if let url = SourceGraph.resolve(include.path, from: file.url, root: self.url, exists: { FileManager.default.fileExists(atPath: $0.path) }),
                   let dependency = self.file(for: url.path) { languages[include.path] = dependency.tree.finalLanguage }
            }
            return StructuralEditing.File(id: file.url.path, tree: file.tree, entryLanguage: file.entryLanguage, includedLanguages: languages)
        }
        return .init(files: inputFiles, revisions: revisions, dirty: dirty)
    }

    func willWriteInput(_ prepared: UnmeteredInputTransaction.Prepared) {
        for (url, text) in prepared.replacements { file(for: url.path)?.watcher?.noteOwnWrite(text) }
    }

    private var inputEngraveTask: Task<Void, Never>?

    func adoptInput(_ prepared: UnmeteredInputTransaction.Prepared) {
        let revision = currentRevision
        defer { carryAudit(from: revision) }
        for source in prepared.plan.files {
            guard let file = file(for: source.id) else { continue }
            file.text = source.tree.text
            file.tree = source.tree
            if prepared.replacements[file.url] != nil { file.sync.noteSynced(source.tree.text) }
        }
        contractRequired = StructuralEditing.isManaged(root.tree)
        scheduleCheckpoint(after: .seconds(30))
        inputEngraveTask?.cancel()
        inputEngraveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            self?.engrave()
        }
    }

    /// A coordinated structural edit: validate every buffer and disk revision
    /// before writing, then publish the complete project and engrave once.
    /// `preservesContract`: the edit keeps an audited project audited (built-in
    /// structural edits); otherwise the result is audited afresh.
    func replaceProjectSources(expected: [URL: String], replacements: [URL: String], preservesContract: Bool = true) throws {
        let audit = currentRevision
        var revisions: [URL: ContentHash] = [:]
        for (url, text) in expected {
            guard let file = file(for: url.path), file.text == text else {
                throw StructuralEditing.Failure("The score changed while this edit was being prepared. Try again.")
            }
            let disk = try Data(contentsOf: url)
            let diskText = String(decoding: disk, as: UTF8.self)
            guard ContentHash(diskText) == file.sync.lastSyncedHash || diskText == text else {
                throw StructuralEditing.Failure("\(file.displayName) changed on disk. Resolve that change before editing structure.")
            }
            revisions[url] = ContentHash(bytes: disk)
        }
        try ProjectSourceTransaction.replace(expected: revisions, replacements: replacements, willWrite: { url, text in
            self.file(for: url.path)?.watcher?.noteOwnWrite(text)
        })
        for (url, text) in replacements {
            guard let file = file(for: url.path) else { continue }
            file.saveTask?.cancel()
            file.saveTask = nil
            file.text = text
            file.sync.noteSynced(text)
        }
        refreshGraph()
        contractRequired = StructuralEditing.isManaged(root.tree)
        if preservesContract { carryAudit(from: audit) } else { scheduleAudit(after: .zero) }
        scheduleCheckpoint(after: .seconds(30))
        engrave()
    }

    func flushPendingSaves() {
        for f in files where f.saveTask != nil {
            f.saveTask?.cancel()
            f.saveTask = nil
            save(f)
        }
    }

    /// Saves now, on the main thread: for a flush that must finish before it
    /// returns (closing, quitting, resolving a conflict).
    @discardableResult
    private func save(_ file: SourceFile) -> Bool {
        file.saveTask = nil
        guard ContentHash(file.text) != file.sync.lastSyncedHash else { return true }
        do {
            if let pending = try managedSave() {
                try commitManagedSave(pending, graph: try Self.auditedGraph(root: url, replacements: pending.replacements, audit: pending.audit))
            } else {
                try writeUnmanaged(file)
            }
            scheduleCheckpoint(after: .seconds(30))
            return true
        } catch {
            saveFailed(file, error)
            return false
        }
    }

    /// The timed autosave. In a managed score, reading the dependencies and
    /// auditing the contract (165 ms on a 4,000-line score) run off the main
    /// thread (DESIGN.md §0, "All UI is instant"); only the disk transaction
    /// returns here, and only for the texts that were audited. An edit made
    /// meanwhile cancels this task and schedules its own save.
    private func autosave(_ file: SourceFile) async -> Bool {
        guard ContentHash(file.text) != file.sync.lastSyncedHash else { file.saveTask = nil; return true }
        do {
            guard let pending = try managedSave() else {
                file.saveTask = nil
                try writeUnmanaged(file)
                scheduleCheckpoint(after: .seconds(30))
                return true
            }
            let root = url
            let graph = try await Task.detached(priority: .userInitiated) {
                try Self.auditedGraph(root: root, replacements: pending.replacements, audit: pending.audit)
            }.value
            guard !Task.isCancelled else { return false }
            file.saveTask = nil
            // Changed some other way meanwhile (a structural commit or a
            // reload): audit what is there now.
            let now = files.filter { ContentHash($0.text) != $0.sync.lastSyncedHash }
            guard Dictionary(uniqueKeysWithValues: now.map { ($0.url, $0.text) }) == pending.replacements else {
                return now.isEmpty ? true : await autosave(now.contains { $0 === file } ? file : now[0])
            }
            try commitManagedSave(pending, graph: graph)
            scheduleCheckpoint(after: .seconds(30))
            return true
        } catch {
            file.saveTask = nil
            saveFailed(file, error)
            return false
        }
    }

    private struct PendingSave: Sendable {
        var replacements: [URL: String]
        /// Arbitrary Source edits need an audit. Built-in notation commands
        /// already preserve the contract by construction.
        var audit: Bool
    }

    /// What a managed score must write together; nil for an unmanaged one.
    private func managedSave() throws -> PendingSave? {
        guard contractRequired || StructuralEditing.isManaged(root.tree) else { return nil }
        guard StructuralEditing.isManaged(root.tree) else {
            throw StructuralEditing.Failure("The generated shared-measure contract was removed. Restore it before saving; see pondside://contract.")
        }
        let dirty = files.filter { ContentHash($0.text) != $0.sync.lastSyncedHash }
        return PendingSave(replacements: Dictionary(uniqueKeysWithValues: dirty.map { ($0.url, $0.text) }),
                           audit: !dirty.allSatisfy { $0.constructedRevisions.contains(ContentHash($0.text)) })
    }

    /// The project as it would be saved, audited. Reads unchanged
    /// dependencies from disk, including generated includes that may have
    /// changed before their watcher fires. Main-actor free.
    nonisolated private static func auditedGraph(root: URL, replacements: [URL: String], audit: Bool) throws -> [URL] {
        let graph = SourceGraph.load(root: root, overrides: replacements)
        if audit {
            let proposed = graph.files.map { StructuralEditing.File(id: $0.url.path, tree: $0.tree) }
            try StructuralEditing.verifyLengths(proposed, root: root.path)
        }
        return graph.files.map(\.url)
    }

    private func commitManagedSave(_ pending: PendingSave, graph: [URL]) throws {
        var revisions: [URL: ContentHash] = [:]
        for source in graph {
            let bytes = try Data(contentsOf: source)
            if let dirtyFile = files.first(where: { $0.url == source && pending.replacements[source] != nil }),
               ContentHash(bytes: bytes) != dirtyFile.sync.lastSyncedHash {
                throw StructuralEditing.Failure("\(dirtyFile.displayName) changed on disk. Resolve its conflict before saving.")
            }
            revisions[source] = ContentHash(bytes: bytes)
        }
        try ProjectSourceTransaction.replace(expected: revisions, replacements: pending.replacements, willWrite: { url, text in
            self.file(for: url.path)?.watcher?.noteOwnWrite(text)
        })
        for source in files where pending.replacements[source.url] != nil {
            source.saveTask?.cancel()
            source.saveTask = nil
            source.sync.noteSynced(source.text)
        }
        contractRequired = true
    }

    private func writeUnmanaged(_ file: SourceFile) throws {
        file.watcher?.noteOwnWrite(file.text)
        try Data(file.text.utf8).write(to: file.url, options: .atomic)
        file.sync.noteSynced(file.text)
    }

    private func saveFailed(_ file: SourceFile, _ error: Error) {
        stashRecovery(file.text, for: file, label: "unsaved-contract")
        setStatus(.failed("Not saved: \(error). The source buffer is retained; see pondside://contract."))
    }

    /// Resolve a conflict in favour of the buffer or the disk. The losing
    /// side is kept in a recovery file — never discarded.
    func resolveConflict(in file: SourceFile, keepMine: Bool, diskText: String) {
        if keepMine {
            stashRecovery(diskText, for: file, label: "disk")
            file.sync.noteSynced(diskText)
            file.saveTask?.cancel()
            guard save(file) else { return }
        } else {
            stashRecovery(file.text, for: file, label: "unsaved")
            adopt(diskText, in: file)
            delegate?.document(self, didReloadFromDisk: file)
        }
        engrave()
    }

    private func diskChanged(_ file: SourceFile, _ diskText: String) {
        switch file.sync.classify(diskText: diskText, bufferText: file.text) {
        case .ignore:
            file.sync.noteSynced(diskText)
        case .reload:
            adopt(diskText, in: file)
            delegate?.document(self, didReloadFromDisk: file)
            engrave()
        case .conflict:
            delegate?.document(self, hasConflictIn: file, diskText: diskText)
        }
    }

    private func adopt(_ diskText: String, in file: SourceFile) {
        file.saveTask?.cancel()
        file.saveTask = nil
        file.text = diskText
        file.sync.noteSynced(diskText)
        refreshGraph()
        scheduleAudit()
    }

    func stashRecovery(_ contents: String, for file: SourceFile, label: String) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("Pondside/Recovery", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let name = "\(file.url.deletingPathExtension().lastPathComponent)-\(label)-\(stamp).\(file.url.pathExtension)"
        try? Data(contents.utf8).write(to: dir.appendingPathComponent(name), options: .atomic)
    }

    // MARK: Engraving

    /// Compiles the root on disk. Only the newest request may finish: a
    /// request cancels any render still in flight, and its result is thrown
    /// away even if LilyPond had already answered.
    func suspendForStructuralWork() {
        engravingSuspended = true
        renderGeneration += 1
        renderTask?.cancel()
        renderTask = nil
        setStatus(.idle)
    }

    func resumeAfterStructuralWork(render: Bool) {
        engravingSuspended = false
        if render { engrave() }
    }

    func structuralWorkFailed(_ message: String) {
        lastLog = message
        setStatus(.failed("Score migration failed"))
    }

    func engrave() {
        guard opened, !engravingSuspended, let installation else { return }
        let prior = renderTask
        let needsStop = compilingGeneration != nil
        renderGeneration += 1
        let generation = renderGeneration
        prior?.cancel()
        compileStarted = Date()
        setStatus(.compiling)
        let engraver = LilyPondEngraver(installation: installation, daemon: daemon)
        let source = url
        // Exactly what LilyPond will read, so links and diagnostics can be
        // mapped back onto text that has moved on since.
        for f in files { f.pendingSnapshot = (try? String(contentsOf: f.url, encoding: .utf8)) ?? f.text }
        let out = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let daemon = self.daemon
        let texts = files.map { $0.pendingSnapshot ?? $0.text }
        renderTask = Task { [weak self] in
            guard let self else { return }
            if needsStop { await daemon?.stop() }
            await prior?.value
            guard !Task.isCancelled, self.renderGeneration == generation else { return }
            self.compilingGeneration = generation
            let outcome = await Self.compile(engraver, source: source, out: out, texts: texts)
            if self.compilingGeneration == generation { self.compilingGeneration = nil }
            guard !Task.isCancelled, self.renderGeneration == generation else { return }
            self.renderTask = nil
            self.finish(outcome)
        }
    }

    /// The audio mockup beside the score (`pondside mockup`: MuseScore with
    /// Muse Sounds when installed, else fluidsynth), in its own process after
    /// each good engraving; a score without `\midi` gets a generated playback
    /// (PlaybackScore). The same compile's timing replaces the canvas's for
    /// cue times, so they match the audio (repeats played out, \articulate).
    /// A render is never killed (MuseScore would be orphaned): engravings
    /// during one queue a single re-render of the newest text.
    /// The score's files as the last mockup started from: an edit that
    /// touched only the front matter (the legend, the cover) can't change the
    /// sound, so it renders nothing.
    private var contractRequired = false
    private var mockupTexts: [URL: String]?
    private var mockupInFlightTexts: [URL: String]?
    /// What the last mix was rendered from (the mockup, its cues, the patch
    /// and what it loads): the mix renders only when one of them changed.
    private var mixInputs: String?

    private func renderMockup() {
        guard let tool = Bundle.main.resourceURL?.appendingPathComponent("pondside"),
              FileManager.default.isExecutableFile(atPath: tool.path) else { return }
        let texts = Dictionary(files.map { ($0.url.standardizedFileURL, $0.text) }, uniquingKeysWith: { a, _ in a })
        let baseline = mockupRunning ? mockupInFlightTexts : mockupTexts
        if let last = baseline {
            let changed = Set(texts.keys).union(last.keys).filter { texts[$0] != last[$0] }
            let soundUnchanged = changed.allSatisfy { url in
                if url.lastPathComponent == FrontMatter.fileName { return true }
                guard let before = last[url], let after = texts[url] else { return false }
                return PlaybackSourceSignature.equivalent(before, after)
            }
            if soundUnchanged {
                if mockupRunning { mockupPending = false }
                else { mockupTexts = texts }
                return
            }
        }
        if mockupRunning { mockupPending = true; return }
        mockupInFlightTexts = texts
        let process = Process()
        process.executableURL = tool
        let timing = workDirectory.appendingPathComponent("playback-\(UUID().uuidString).timing")
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        process.arguments = ["mockup", url.path, "--timing", timing.path]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let ref = WeakRef(self)
        process.terminationHandler = { p in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if p.terminationStatus != 0 {
                Logger(subsystem: "app.pondside", category: "mockup").notice("\(message, privacy: .public)")
            }
            let text = try? String(contentsOf: timing, encoding: .utf8)
            try? FileManager.default.removeItem(at: timing)
            let rendered = p.terminationStatus == 0
            Task { @MainActor in
                guard let doc = ref.value else { return }
                doc.mockupRunning = false
                doc.mockupInFlightTexts = nil
                if rendered { doc.mockupTexts = texts }
                if let text, !doc.mockupPending { doc.adoptTiming(TimingLog(parsing: text, prefix: TimingDump.marker)) }
                if doc.mockupPending {
                    doc.mockupPending = false
                    doc.renderMockup()
                } else if rendered {
                    doc.syncPatch()
                    doc.renderMix()
                }
            }
        }
        do {
            try process.run()
            mockupRunning = true
        } catch {
            mockupInFlightTexts = nil
            Logger(subsystem: "app.pondside", category: "mockup").notice("\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: The patch

    /// The Pondside patch beside the score (`[supercollider] handlers`, else
    /// `<name>.scd`), if there is one.
    var patchURL: URL? {
        PatchRender.patch(for: url, configured: (try? ProjectConfig.find(from: url))?.handlers)
    }

    /// Stubs for new cues in the patch, its cue comments brought up to date
    /// (HandlerSync); the SuperCollider pane merges the change in.
    private func syncPatch() {
        guard let patch = patchURL, let sheet = cueSheet,
              let text = try? String(contentsOf: patch, encoding: .utf8) else { return }
        let (new, _) = HandlerSync.sync(text, with: sheet)
        if new != text { try? Data(new.utf8).write(to: patch, options: .atomic) }
        // The engine is Pondside's: always the current one.
        try? PatchMigration.ensureEngine(patch: patch, name: url.deletingPathExtension().lastPathComponent)
    }

    /// One mix render at a time; a mockup during it asks for one more.
    private var mixRunning = false {
        didSet { if mixRunning != oldValue { delegate?.documentStatusDidChange(self) } }
    }
    private var mixPending = false

    /// The score with its electronics (`pondside mix`: the patch rendered
    /// offline in mockup mode) into `<name>.mix.wav`, after each mockup.
    func renderMix() {
        guard let patch = patchURL, let tool = Bundle.main.resourceURL?.appendingPathComponent("pondside"),
              FileManager.default.isExecutableFile(atPath: tool.path) else { return }
        if mixRunning {
            mixPending = true
            return
        }
        // Nothing the mix hears changed (the mockup wasn't rewritten, the
        // patch is as it was): keep the last mix.
        func stamp(_ u: URL) -> String {
            let a = try? FileManager.default.attributesOfItem(atPath: u.path)
            return "\((a?[.size] as? Int) ?? -1):\(((a?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)"
        }
        let inputs = ([HandlerSync.Layout.mockup(score: url), HandlerSync.Layout.cues(score: url), patch] + PatchMigration.dependencies(of: patch))
            .map(stamp).joined(separator: "|")
        if inputs == mixInputs, FileManager.default.fileExists(atPath: HandlerSync.Layout.mix(score: url).path) { return }
        mixInputs = inputs
        let process = Process()
        process.executableURL = tool
        process.arguments = ["mix", url.path]
        process.currentDirectoryURL = url.deletingLastPathComponent()
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        let ref = WeakRef(self)
        process.terminationHandler = { p in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let ok = p.terminationStatus == 0
            if !ok { Logger(subsystem: "app.pondside", category: "mix").notice("\(message, privacy: .public)") }
            Task { @MainActor in
                guard let doc = ref.value else { return }
                doc.mixRunning = false
                doc.mixProblem = ok ? nil : message.split(separator: "\n").last.map(String.init) ?? "the patch didn't render"
                if !ok { doc.mixInputs = nil }   // try again next time
                if doc.mixPending {
                    doc.mixPending = false
                    doc.renderMix()
                }
            }
        }
        do {
            try process.run()
            mixRunning = true
        } catch {
            Logger(subsystem: "app.pondside", category: "mix").notice("\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Why the latest mix failed, for the play command to say.
    private(set) var mixProblem: String?

    private func setTiming(_ log: TimingLog) {
        let rate = (try? ProjectConfig.find(from: url))?.sampleRate ?? 48000
        let lex = Lexicon.load(Lexicon.standardScopes(project: url.deletingLastPathComponent()))
        timingLog = log
        cueSheet = CueSheet(log: log, score: url.lastPathComponent, sampleRate: rate,
                            soundParams: { lex.soundParams(entry: $0, params: $1, beatDur: $2, spanDur: $3, tempo: $4) })
    }

    private func adoptTiming(_ log: TimingLog) {
        guard !log.rows.isEmpty else { return }
        setTiming(log)
        hasPlaybackTiming = true
        delegate?.documentDidUpdatePlayback(self)
    }

    private struct Outcome: Sendable {
        var result: EngraveResult?
        var pages: [EngravedPage]
        var overflows: [SystemOverflow] = []
        /// The SVGs the pages came from, for the render cache.
        var svgs: [Data] = []
        var error: String?
    }

    /// Runs off the main actor: the compile and the SVG parsing.
    /// `texts`: the files as engraved, to tell whether automatic line breaks
    /// are off (only then is an overflowing system looked for).
    nonisolated private static func compile(_ engraver: LilyPondEngraver, source: URL, out: URL, texts: [String]) async -> Outcome {
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            let result = try await engraver.engrave(source, purpose: .canvas, outputDirectory: out)
            let svgs = result.outputFiles.compactMap { try? Data(contentsOf: $0) }
            let pages = svgs.map(EngravedPage.init(svg:))
            let overflows = SystemOverflow.applies(toSources: texts) ? SystemOverflow.detect(in: pages) : []
            return Outcome(result: result, pages: pages, overflows: overflows, svgs: svgs, error: nil)
        } catch {
            return Outcome(result: nil, pages: [], error: String(describing: error))
        }
    }

    private func finish(_ outcome: Outcome) {
        lastLog = outcome.result?.messages ?? outcome.error ?? ""
        if let result = outcome.result, result.succeeded {
            renderMockup()
            // The canvas's timing until the first playback timing arrives with
            // the mockup; after that the last playback's, until the next one.
            if !hasPlaybackTiming { setTiming(result.timing) }
        }
        if let result = outcome.result {
            for f in files {
                f.compiledText = f.pendingSnapshot
                f.diagnostics = result.diagnostics.filter { d in
                    guard let file = d.file else { return f === root }
                    return f.matches(path: file) || (file == f.displayName && !file.contains("/"))
                }
            }
            // A diagnostic can name a path no SourceFile claims (a generated
            // file, a relative path). It still is why the compile failed:
            // keep it on the root instead of dropping it, or check answers
            // "errors:1" with an empty diagnostics list.
            root.diagnostics += result.diagnostics.filter { d in
                guard let file = d.file, !file.isEmpty else { return false }
                return !files.contains { f in
                    f.matches(path: file) || (file == f.displayName && !file.contains("/"))
                }
            }
            // Keep showing the last good engraving while the source has errors,
            // so the score never blanks out mid-thought.
            if !outcome.pages.isEmpty {
                pages = outcome.pages
                overflows = outcome.overflows
                distributeLinks()
                for f in files { f.engravedText = f.pendingSnapshot }
                showingCachedRender = false
                storeRender(outcome.svgs)
            }
            let errorCount = result.errors.count
            if errorCount > 0 {
                setStatus(.errors(errorCount))
            } else if !result.succeeded {
                setStatus(.failed("LilyPond exited with status \(result.exitStatus)"))
            } else {
                let c = result.duration.components
                setStatus(.clean(milliseconds: Int(c.seconds) * 1000 + Int(c.attoseconds / 1_000_000_000_000_000)))
            }
            completedRenderGeneration = renderGeneration
            delegate?.documentDidEngrave(self)
        } else {
            setStatus(.failed(outcome.error ?? "unknown error"))
        }
    }

    /// Replaces the score's cache entry, off the main actor.
    private func storeRender(_ svgs: [Data]) {
        guard let cache = Self.renderCache, !svgs.isEmpty else { return }
        var snapshots: [String: String] = [:]
        for f in files { snapshots[f.url.standardizedFileURL.path] = f.engravedText }
        let entry = RenderCache.Entry(pages: svgs, snapshots: snapshots,
                                      lilypondVersion: installation.map { "\($0.version)" })
        let score = url
        let prior = storeTask
        storeTask = Task.detached(priority: .utility) {
            await prior?.value
            try? cache.store(entry, for: score)
        }
    }

    /// Splits the pages' links by file, and notes files whose music produced
    /// no links at all (DESIGN.md M2.1 B: never fail silently).
    private func distributeLinks() {
        var byPath: [String: SourceFile?] = [:]
        var positions: [ObjectIdentifier: Set<SourcePosition>] = [:]
        for page in pages {
            for g in page.graphics {
                guard let link = g.link else { continue }
                let f: SourceFile?
                if let cached = byPath[link.path] { f = cached } else {
                    f = file(for: link.path)
                    byPath[link.path] = f
                }
                if let f { positions[ObjectIdentifier(f), default: []].insert(link.position) }
            }
        }
        for f in files { f.linkedPositions = (positions[ObjectIdentifier(f)] ?? []).sorted() }
        unlinkedFiles = files.filter { $0.hasNotes && $0.linkedPositions.isEmpty }
    }

    private func setStatus(_ s: CompileStatus) {
        status = s
        delegate?.documentStatusDidChange(self)
    }

    // MARK: Export

    /// Engraves a PDF for distribution — point-and-click off, leak-checked —
    /// and moves it to `destination`.
    func exportPDF(to destination: URL) async throws {
        flushPendingSaves()
        guard let installation else { throw CocoaError(.featureUnsupported) }
        let engraver = LilyPondEngraver(installation: installation)
        let out = workDirectory.appendingPathComponent("export-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let result = try await engraver.engrave(url, purpose: .export(.pdf), outputDirectory: out)
        guard result.succeeded, let pdf = result.outputFiles.first else {
            throw NSError(domain: "Pondside", code: 1, userInfo: [NSLocalizedDescriptionKey: result.errors.first?.message ?? "LilyPond failed"])
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.moveItem(at: pdf, to: destination)
    }
}
