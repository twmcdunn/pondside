import AppKit
import PondsideCore
import PondsideEngrave
import PondsideLexicon

/// The app's one SuperCollider interpreter. Every window's SuperCollider
/// pane talks to it, as in the SuperCollider IDE: two interpreters would
/// fight over the language and server ports. It starts when a pane first
/// needs it and quits with the app.
@MainActor
final class SCLangHost {
    static let shared = SCLangHost()

    static let postDidChange = Notification.Name("PondsideSCPost")
    static let stateDidChange = Notification.Name("PondsideSCState")
    static let libraryDidChange = Notification.Name("PondsideSCLibrary")
    static let serverDidChange = Notification.Name("PondsideSCServer")

    private(set) var session: SCLangSession?
    private(set) var state: SCLangSession.State = .stopped
    /// Classes and methods for completion: the cached copy until the
    /// interpreter has compiled its own.
    private(set) var library = SCClassLibrary()
    /// What the post window shows, newest last, trimmed from the front.
    private(set) var log = ""
    /// "Server off", or its load while it runs.
    private(set) var serverStatus = "Server off"
    private(set) var serverRunning = false
    /// Why there is no interpreter, if there isn't one.
    private(set) var missing: String?
    private(set) var helpDirectory: URL?
    private var pollTask: Task<Void, Never>?
    private static let maxLog = 200_000

    private static var cacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pondside/SuperCollider/classes.tsv")
    }

    private init() {
        if let data = FileManager.default.contents(atPath: Self.cacheURL.path) {
            library = SCClassLibrary(tsv: String(decoding: data, as: UTF8.self))
        }
    }

    /// Starts sclang if it isn't running, in the score's folder, using the
    /// project's `supercollider.path` if it names one.
    func start(near score: URL) {
        guard session == nil else { return }
        let configured = (try? ProjectConfig.find(from: score))?.sclang?.path
        guard let sclang = SuperColliderToolchain.findSclang(configured: configured) else {
            missing = "SuperCollider isn't installed. Install it from supercollider.github.io, "
                + "or set [supercollider] path in pondside.toml."
            NotificationCenter.default.post(name: Self.stateDidChange, object: self)
            return
        }
        missing = nil
        let s = SCLangSession(executable: sclang, workingDirectory: score.deletingLastPathComponent())
        s.onPost = { text in Task { @MainActor in SCLangHost.shared.append(text) } }
        s.onState = { state in Task { @MainActor in SCLangHost.shared.stateChanged(state) } }
        session = s
        pathHook = false
        s.start()
    }

    func shutdown() {
        pollTask?.cancel()
        session?.stop()
    }

    // MARK: Commands

    /// Runs code; sclang posts its result. With `path`, the code runs as part of
    /// that file, as SC's IDE runs a document's code: `thisProcess.nowExecutingPath`
    /// is the file, so `"x.scd".loadRelative` and `resolveRelative` find files beside it.
    func evaluate(_ code: String, path: String? = nil) {
        guard let session, ready else { return notRunning() }
        if let path {
            // sclang clears nowExecutingPath after each evaluation: the
            // interpreter's preprocessor sets it again, from ~pondsideExecutingPath.
            if !pathHook {
                session.evaluate("thisProcess.interpreter.preProcessor = { |code| thisProcess.nowExecutingPath = ~pondsideExecutingPath; code }",
                                 printResult: false)
                pathHook = true
            }
            let quoted = path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            session.evaluate("~pondsideExecutingPath = \"\(quoted)\"", printResult: false)
        }
        session.evaluate(code)
    }

    /// Whether this interpreter has the preprocessor that sets nowExecutingPath.
    private var pathHook = false

    func stopSound() {
        guard let session else { return }
        session.stopSound()
    }

    func toggleServer() {
        guard let session, ready else { return notRunning() }
        if serverRunning {
            session.quitServer()
        } else {
            Task { _ = await session.bootServer() }
        }
    }

    func recompile() {
        pathHook = false
        guard let session else { return notRunning() }
        session.recompile()
    }

    func restart() {
        pathHook = false
        guard let session else { return notRunning() }
        session.restart()
    }

    func clearLog() {
        log = ""
        NotificationCenter.default.post(name: Self.postDidChange, object: self, userInfo: ["cleared": true])
    }

    /// The rendered page for what ⌘D found at the caret.
    func helpURL(for topic: SCCompletion.HelpTopic) async -> URL? {
        guard let session, ready else { notRunning(); return nil }
        if helpDirectory == nil { helpDirectory = await session.helpDirectory() }
        if let cls = topic.className { return await session.helpURL(for: cls, anchor: topic.anchor) }
        return await session.helpURL(for: topic.word)
    }

    func prepareHelp(_ url: URL) async -> URL? {
        guard let session, ready else { return nil }
        return await session.prepareHelp(url)
    }

    var ready: Bool { state == .ready || state == .libraryFailed }

    var statusText: String {
        if let missing { return missing.components(separatedBy: ".").first ?? missing }
        switch state {
        case .stopped: return "Interpreter stopped"
        case .starting: return "Compiling class library…"
        case .ready: return "Interpreter ready"
        case .libraryFailed: return "Class library failed to compile"
        case .exited(let code): return "Interpreter exited (\(code))"
        }
    }

    // MARK: Updates

    private func notRunning() {
        append(missing.map { $0 + "\n" } ?? (state == .starting ? "The interpreter is still starting.\n" : "SuperCollider isn't running: ␣ s i restarts it.\n"))
    }

    private func append(_ text: String) {
        log += text
        if log.count > Self.maxLog { log = String(log.suffix(Self.maxLog * 3 / 4)) }
        NotificationCenter.default.post(name: Self.postDidChange, object: self, userInfo: ["text": text])
    }

    private func stateChanged(_ new: SCLangSession.State) {
        state = new
        NotificationCenter.default.post(name: Self.stateDidChange, object: self)
        if new == .ready { reloadLibrary() }
        if ready { startPolling() } else { pollTask?.cancel(); setServer(running: false, status: "Server off") }
    }

    /// Asks the freshly compiled interpreter for its classes (after every
    /// start and recompile, so new .sc classes complete too).
    private func reloadLibrary() {
        guard let session else { return }
        Task {
            if let lib = await session.classLibrary(writingTo: Self.cacheURL), !lib.isEmpty {
                library = lib
                NotificationCenter.default.post(name: Self.libraryDidChange, object: self)
            }
        }
    }

    /// The server's load, as the SuperCollider IDE's status bar shows it.
    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let session = self?.session else { return }
                let s = await session.request("""
                Server.default.serverRunning.if({ var s = Server.default; \
                "%|% %|%".format(s.avgCPU.round(0.1), s.numSynths, "synths", s.numUGens) }, "off")
                """, timeout: .seconds(3))
                if let s {
                    let parts = s.split(separator: "|")
                    if s == "off" || parts.count < 3 { self?.setServer(running: false, status: "Server off") }
                    else { self?.setServer(running: true, status: "Server \(parts[0])% · \(parts[1]) · \(parts[2]) UGens") }
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func setServer(running: Bool, status: String) {
        guard running != serverRunning || status != serverStatus else { return }
        serverRunning = running
        serverStatus = status
        NotificationCenter.default.post(name: Self.serverDidChange, object: self)
    }
}
