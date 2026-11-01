import Foundation
import PondsideCore

/// Finds sclang without installing anything (DESIGN.md, Appendix A.16):
/// `PONDSIDE_SCLANG`, then `pondside.toml`'s `supercollider.path`, then
/// SuperCollider.app, then PATH and the usual Linux prefixes.
public enum SuperColliderToolchain {
    public static func candidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  configured: String? = nil) -> [String] {
        var out: [String] = []
        if let e = environment["PONDSIDE_SCLANG"], !e.isEmpty { out.append(e) }
        if let configured, !configured.isEmpty {
            // A path to the app means the sclang inside it.
            out.append(configured.hasSuffix(".app") ? configured + "/Contents/MacOS/sclang" : configured)
        }
        let home = environment["HOME"] ?? NSHomeDirectory()
        for apps in ["/Applications", "\(home)/Applications"] {
            out.append("\(apps)/SuperCollider.app/Contents/MacOS/sclang")
            out.append("\(apps)/SuperCollider/SuperCollider.app/Contents/MacOS/sclang")
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            out.append("\(dir)/sclang")
        }
        out += ["/opt/homebrew/bin/sclang", "/usr/local/bin/sclang", "/usr/bin/sclang"]
        // Last: the headless SuperCollider the installer bundles (no IDE, no GUI
        // classes). A full SuperCollider.app, with the user's extensions, wins.
        out.append(bundled)
        return out
    }

    /// The installer's headless sclang (scripts/installer/build-supercollider.sh).
    public static let bundled = "/Library/Application Support/Pondside/Toolchain/supercollider/SuperCollider.app/Contents/MacOS/sclang"

    /// Whether `sclang` is a headless build: it must run with
    /// `headlessConfig`, since the user's Extensions may need Qt.
    public static func isHeadless(_ sclang: String) -> Bool {
        FileManager.default.fileExists(atPath: resources(of: sclang).appendingPathComponent("pondside-headless").path)
    }

    static func resources(of sclang: String) -> URL {
        URL(fileURLWithPath: sclang).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources")
    }

    /// sclang_conf.yaml for a headless sclang: its own class library and
    /// `extra` paths, and none of the user's (`excludeDefaultPaths`).
    public static func headlessConfig(_ sclang: String, extra: [String] = []) -> String {
        let paths = [resources(of: sclang).appendingPathComponent("SCClassLibrary").path] + extra
        return "includePaths:\n" + paths.map { "    - \($0)\n" }.joined()
            + "excludePaths:\n    []\nexcludeDefaultPaths: true\npostInlineWarnings: false\n"
    }

    /// The SuperCollider IDE beside `sclang` (`SuperCollider.app/Contents/MacOS/SuperCollider`).
    /// Launched directly, it opens files even while another sclang has
    /// claimed SuperCollider.app's identity with macOS (which then routes
    /// double-clicked .scd files to that sclang, and fails); a second IDE
    /// hands its files to the one already running.
    public static func ide(forSclang sclang: String) -> String? {
        let ide = URL(fileURLWithPath: sclang).deletingLastPathComponent().appendingPathComponent("SuperCollider").path
        return FileManager.default.isExecutableFile(atPath: ide) ? ide : nil
    }

    public static func findSclang(environment: [String: String] = ProcessInfo.processInfo.environment,
                                  configured: String? = nil) -> String? {
        candidates(environment: environment, configured: configured).first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

/// A SuperCollider interpreter the user can talk to from Pondside, hosted
/// the way the terminal pane hosts a shell (DESIGN.md, M5). Code goes to
/// sclang's stdin: text ending in 0x0C is run and its result printed,
/// 0x1B runs it silently. Everything sclang prints is the post window.
///
/// Pondside still computes no time and sends no OSC: this is the user's
/// interpreter, and the only messages Pondside adds are its own requests
/// (help paths, the class list for completion), answered on marked lines
/// the post window never shows.
public final class SCLangSession: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case stopped
        case starting
        /// The class library compiled and the interpreter is waiting.
        case ready
        /// The class library failed to compile; the interpreter runs but
        /// only the code the library defines is missing.
        case libraryFailed
        case exited(Int32)
    }

    public let executable: String
    public let workingDirectory: URL
    /// Text for the post window, on an arbitrary queue.
    public var onPost: (@Sendable (String) -> Void)?
    public var onState: (@Sendable (State) -> Void)?

    private let queue = DispatchQueue(label: "pondside.sclang")
    // Guarded by `queue`.
    private var process: Process?
    private var input: FileHandle?
    private var stream = SCPostStream()
    private var undecoded = Data()
    private var replies: [Int: CheckedContinuation<String?, Never>] = [:]
    private var nextID = 1
    private var startedAt = Date()
    private var stopping = false
    private var _state: State = .stopped

    public init(executable: String, workingDirectory: URL) {
        self.executable = executable
        self.workingDirectory = workingDirectory
    }

    deinit { process?.terminate() }

    public var state: State { queue.sync { _state } }

    public func start() { queue.async { self.launch() } }

    /// Quits the interpreter (and with it any server it booted).
    public func stop() {
        queue.async {
            self.stopping = true
            self.write("0.exit", printing: false)
            let p = self.process
            self.queue.asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
        }
    }

    public func restart() {
        queue.async {
            self.stopping = true
            self.process?.terminate()
            self.process = nil
            self.launch()
        }
    }

    /// Runs `code`; with `printResult`, sclang posts `-> result`.
    public func evaluate(_ code: String, printResult: Bool = true) {
        queue.async { self.write(code, printing: printResult) }
    }

    /// ⌘. in the SuperCollider IDE: stops every sound, routine and clock.
    public func stopSound() { evaluate("CmdPeriod.run;", printResult: false) }

    public func recompile() { evaluate("thisProcess.recompile;", printResult: false) }

    /// Evaluates `expression` and returns its value as a string, or nil if
    /// it threw or took longer than `timeout`. Requests are silent.
    public func request(_ expression: String, timeout: Duration = .seconds(10)) async -> String? {
        await withCheckedContinuation { (c: CheckedContinuation<String?, Never>) in
            queue.async {
                guard self._state == .ready || self._state == .libraryFailed else { c.resume(returning: nil); return }
                let id = self.nextID
                self.nextID += 1
                self.replies[id] = c
                let code = """
                { var r = { (\(expression)).asString }.try({ |e| "" }); \
                (30.asAscii ++ "PONDSIDE \(id) " ++ r.replace("\\n", " ")).postln }.value;
                """
                self.write(code, printing: false)
                let ns = timeout.components.seconds
                self.queue.asyncAfter(deadline: .now() + .seconds(Int(ns))) {
                    self.replies.removeValue(forKey: id)?.resume(returning: nil)
                }
            }
        }
    }

    /// Writes the class library sclang has compiled to `file` and parses it.
    public func classLibrary(writingTo file: URL) async -> SCClassLibrary? {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard await request(Self.libraryDumpCode(path: file.path), timeout: .seconds(60)) == "ok",
              let data = FileManager.default.contents(atPath: file.path) else { return nil }
        return SCClassLibrary(tsv: String(decoding: data, as: UTF8.self))
    }

    /// The rendered SCDoc page for a class, method or topic (rendering it
    /// now if it is missing or stale), with `anchor` as its fragment.
    public func helpURL(for word: String, anchor: String? = nil) async -> URL? {
        let found = "SCDoc.findHelpFile(\(Self.literal(word)))"
        guard let s = await request("SCDoc.prepareHelpForURL(URI(\(found))) !? _.asString ? \"\"", timeout: .seconds(30)),
              var url = URL(string: s), !s.isEmpty else { return nil }
        if let anchor, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.fragment = anchor
            url = c.url ?? url
        }
        return url
    }

    /// Renders a help page a link points at, before the browser shows it.
    public func prepareHelp(_ url: URL) async -> URL? {
        var bare = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let fragment = bare?.fragment
        bare?.fragment = nil
        guard let target = bare?.url?.absoluteString,
              let s = await request("SCDoc.prepareHelpForURL(URI(\(Self.literal(target)))) !? _.asString ? \"\"", timeout: .seconds(30)),
              !s.isEmpty, var result = URLComponents(string: s) else { return nil }
        result.fragment = fragment
        return result.url
    }

    /// The folder SCDoc renders into, for the help browser's read access.
    public func helpDirectory() async -> URL? {
        guard let s = await request("SCDoc.helpTargetDir"), !s.isEmpty else { return nil }
        return URL(fileURLWithPath: s, isDirectory: true)
    }

    /// Boots the default server unless another program's scsynth already
    /// holds the port: SuperCollider.app and Pondside would fight over it.
    public func bootServer() async -> Bool {
        if await request("Server.default.serverRunning") != "true", await Self.otherServerRunning() {
            post("Pondside: a scsynth is already running (SuperCollider.app?). It holds port 57110, so this "
                 + "interpreter won't boot another. Quit that server, or use it from there.\n")
            return false
        }
        evaluate("Server.default.boot;", printResult: false)
        return true
    }

    public func quitServer() { evaluate("Server.default.quit;", printResult: false) }

    static func otherServerRunning() async -> Bool {
        guard let out = try? await ProcessRunner.run("/usr/bin/pgrep", ["-x", "scsynth"]) else { return false }
        return out.status == 0
    }

    /// An sclang string literal.
    public static func literal(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// sclang code writing the class list `SCClassLibrary(tsv:)` reads, and
    /// evaluating to "ok". Takes about half a second.
    public static func libraryDumpCode(path: String) -> String {
        """
        { var f = File(\(literal(path)), "w"); \
        var clean = { |s| s.asString.replace("\\t", " ").replace("\\n", " ") }; \
        var args = { |m| var names = m.argNames ? [], defs = m.prototypeFrame ? []; \
        names.drop(1).collect { |n, i| var d = defs[i + 1]; if(d.notNil) { n ++ "=" ++ clean.(d.cs) } { n.asString } }.join(",") }; \
        if(SCDoc.documents.isNil) { SCDoc.indexAllDocuments }; \
        Class.allClasses.do { |c| var doc; if(c.isMetaClass.not) { \
        doc = SCDoc.documents["Classes/" ++ c.name]; \
        f.write("C\\t" ++ c.name ++ "\\t" ++ (c.superclass !? _.name ? "") ++ "\\t" ++ (doc !? { clean.(doc.summary) } ? "") ++ "\\n"); \
        c.class.methods.do { |m| f.write("M\\t" ++ c.name ++ "\\tc\\t" ++ m.name ++ "\\t" ++ args.(m) ++ "\\n") }; \
        c.methods.do { |m| f.write("M\\t" ++ c.name ++ "\\ti\\t" ++ m.name ++ "\\t" ++ args.(m) ++ "\\n") } } }; \
        f.close; "ok" }.value
        """
    }

    // MARK: Process, on `queue`

    private func setState(_ s: State) {
        guard s != _state else { return }
        _state = s
        onState?(s)
    }

    private func post(_ text: String) { onPost?(text) }

    private func launch() {
        guard process == nil else { return }
        stopping = false
        stream = SCPostStream()
        undecoded = Data()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        // `-i` names an IDE: sclang then reads plain stdin, without readline.
        p.arguments = ["-i", "pondside"]
        // A headless sclang (the installer's): its own class library only.
        if SuperColliderToolchain.isHeadless(executable) {
            let conf = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-sclang-headless.yaml")
            if (try? Data(SuperColliderToolchain.headlessConfig(executable).utf8).write(to: conf, options: .atomic)) != nil {
                p.arguments = ["-l", conf.path] + p.arguments!
            }
        }
        p.currentDirectoryURL = workingDirectory
        let stdin = Pipe(), stdout = Pipe()
        p.standardInput = stdin
        p.standardOutput = stdout
        p.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            guard let self, !data.isEmpty else { return }
            self.queue.async { self.receive(data) }
        }
        p.terminationHandler = { [weak self] proc in
            let code = proc.terminationStatus
            guard let self else { return }
            self.queue.async { self.terminated(proc, code: code) }
        }
        do {
            try p.run()
        } catch {
            post("Couldn't start \(executable): \(error.localizedDescription)\n")
            setState(.exited(-1))
            return
        }
        process = p
        input = stdin.fileHandleForWriting
        startedAt = Date()
        setState(.starting)
    }

    private func terminated(_ p: Process, code: Int32) {
        guard p === process else { return }
        process = nil
        input = nil
        for (_, c) in replies { c.resume(returning: nil) }
        replies.removeAll()
        setState(.exited(code))
        // Restart an interpreter that crashed, but not one that can't start
        // or that the user quit.
        if !stopping, Date().timeIntervalSince(startedAt) > 3 {
            post("\nsclang exited (\(code)); restarting…\n")
            launch()
        }
    }

    private func receive(_ data: Data) {
        undecoded.append(data)
        // Keep an incomplete UTF-8 sequence for the next chunk.
        var cut = undecoded.count
        var back = 0
        while back < 3, cut - back - 1 >= 0 {
            let b = undecoded[undecoded.startIndex + cut - back - 1]
            if b & 0xC0 == 0x80 { back += 1; continue }
            if b & 0xC0 == 0xC0 {
                let need = b & 0xE0 == 0xC0 ? 2 : b & 0xF0 == 0xE0 ? 3 : 4
                if back + 1 < need { cut -= back + 1 }
            }
            break
        }
        let text = String(decoding: undecoded.prefix(cut), as: UTF8.self)
        undecoded = Data(undecoded.suffix(from: undecoded.startIndex + cut))
        for piece in stream.feed(text) {
            switch piece {
            case .post(let s):
                if s.contains("*** Welcome to SuperCollider") { setState(.ready) }
                else if s.contains("Library has not been compiled successfully") || s.contains("ERROR: There is a discrepancy") {
                    setState(.libraryFailed)
                } else if s.contains("compiling class library") { setState(.starting) }
                post(s)
            case .reply(let id, let payload):
                replies.removeValue(forKey: id)?.resume(returning: payload)
            }
        }
    }

    private func write(_ code: String, printing: Bool) {
        guard let input else {
            post("SuperCollider isn't running.\n")
            return
        }
        var data = Data(code.utf8)
        data.append(printing ? 0x0C : 0x1B)
        do { try input.write(contentsOf: data) } catch { post("Couldn't send code to sclang: \(error.localizedDescription)\n") }
    }
}
