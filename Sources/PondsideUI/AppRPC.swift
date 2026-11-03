import AppKit
import PondsideCore
import PondsideEngrave
import PondsideBridge
import PondsideTiming

/// The running app over JSON-RPC (docs/API.md): what is open, what is
/// selected, cue times, and events when any of it changes. Scripts and
/// agents that edit the files directly use this to follow along.
@MainActor
final class AppRPC {
    static let shared = AppRPC()
    weak var app: PondsideAppDelegate?
    private var server: RPCSocketServer?
    private(set) var problem: String?

    func start() {
        let server = RPCSocketServer(path: RPCSocketServer.defaultPath) { method, params in
            // A question waits for the person's answer.
            if method == "document.ask" { return try await AppRPC.shared.ask(params) }
            return try await MainActor.run { try AppRPC.shared.handle(method, params) }
        }
        do {
            try server.start()
            self.server = server
        } catch {
            problem = "\(error)"
        }
    }

    func stop() {
        server?.stop()
        server = nil
    }

    func publish(_ event: String, _ params: JSONValue) {
        server?.publish(event, params)
    }

    private var controllers: [DocumentWindowController] { app?.documentControllers ?? [] }

    func controller(_ params: JSONValue) throws -> DocumentWindowController {
        if let path = params["path"]?.string {
            guard let c = controllers.first(where: { $0.score.file(for: path) != nil }) else {
                throw RPCSocketServer.MethodError("no open score contains \(path)")
            }
            return c
        }
        guard let c = controllers.first(where: { $0.window?.isKeyWindow == true }) ?? controllers.first else {
            throw RPCSocketServer.MethodError("no score is open")
        }
        return c
    }

    func handle(_ method: String, _ params: JSONValue) throws -> JSONValue {
        switch method {
        case "app.version":
            return ["name": "Pondside", "version": "0.1.0", "socket": .string(RPCSocketServer.defaultPath)]
        case "app.documents":
            return .array(controllers.map { $0.rpcSummary })
        case "document.text":
            let c = try controller(params)
            let path = params["path"]?.string ?? c.score.root.url.path
            guard let file = c.score.file(for: path) else { throw RPCSocketServer.MethodError("not in the score: \(path)") }
            return ["path": .string(file.url.path), "text": .string(file.text)]
        case "document.selection":
            return try controller(params).rpcSelection
        case "document.log":
            let c = try controller(params)
            let path = params["path"]?.string ?? c.score.root.url.path
            guard c.score.file(for: path) != nil else { throw RPCSocketServer.MethodError("not in the score: \(path)") }
            return ["path": .string(path), "log": .string(CompilerLog.tail(c.score.lastLog))]
        case "document.context":
            let c = try controller(params)
            if let path = params["path"]?.string, let line = params["line"]?.int {
                guard c.revealSource(path: path, line: line, character: params["character"]?.int ?? 0) else {
                    throw RPCSocketServer.MethodError("can't find \(path):\(line)")
                }
            }
            return c.rpcContext
        case "document.patchContext":
            let c = try controller(params)
            if let path = params["path"]?.string, let line = params["line"]?.int {
                guard c.revealSource(path: path, line: line, character: params["character"]?.int ?? 0) else {
                    throw RPCSocketServer.MethodError("can't find \(path):\(line)")
                }
            }
            guard c.score.patchURL != nil else { throw RPCSocketServer.MethodError("the score has no Pondside patch") }
            return c.rpcPatchContext(cue: params["cue"]?.string)
        case "document.select":
            let c = try controller(params)
            guard let path = params["path"]?.string, let line = params["line"]?.int else {
                throw RPCSocketServer.MethodError("document.select needs path, line and character")
            }
            guard c.revealSource(path: path, line: line, character: params["character"]?.int ?? 0) else {
                throw RPCSocketServer.MethodError("can't select \(path):\(line)")
            }
            return c.rpcSelection
        case "document.engrave":
            let c = try controller(params)
            c.score.engrave()
            return ["started": true]
        case "document.cues":
            guard let sheet = try controller(params).score.cueSheet else { return .null }
            return try JSONValue.from(sheet)
        case "document.warn":
            // An agent reports a problem: an alert on the score's window, not waited for.
            let c = try controller(params)
            guard let message = params["message"]?.string, let window = c.window else {
                throw RPCSocketServer.MethodError("document.warn needs a message")
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = params["title"]?.string ?? "The agent ran into a problem"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.beginSheetModal(for: window)
            return ["shown": true]
        case "document.open":
            guard let path = params["path"]?.string else { throw RPCSocketServer.MethodError("document.open needs a path") }
            app?.open(URL(fileURLWithPath: path))
            return ["opened": .string(path)]
        default:
            throw RPCSocketServer.MethodError(code: -32601, "method not found: \(method)")
        }
    }
}

extension AppRPC {
    /// An agent's clarifying question, as a sheet on the score's window: its
    /// suggested answers as buttons, and a field for one of the person's own.
    /// Returns the answer, or `answered: false` if the person skipped it.
    func ask(_ params: JSONValue) async throws -> JSONValue {
        let c = try controller(params)
        guard let question = params["question"]?.string, let window = c.window else {
            throw RPCSocketServer.MethodError("document.ask needs a question")
        }
        let choices = (params["choices"]?.array ?? []).compactMap(\.string).prefix(4)
        let alert = NSAlert()
        alert.messageText = "The agent asks"
        alert.informativeText = question
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = choices.isEmpty ? "Your answer" : "Or your own answer"
        alert.accessoryView = field
        for c in choices { alert.addButton(withTitle: c) }
        alert.addButton(withTitle: "Answer")
        alert.addButton(withTitle: "Skip")
        alert.window.initialFirstResponder = field
        NSApp.requestUserAttention(.informationalRequest)
        let response = await withCheckedContinuation { (k: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { k.resume(returning: $0) }
        }
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        if index >= 0, index < choices.count { return ["answered": true, "answer": .string(choices[choices.startIndex + index])] }
        if index == choices.count, !field.stringValue.isEmpty { return ["answered": true, "answer": .string(field.stringValue)] }
        return ["answered": false]
    }
}

extension DocumentWindowController {
    var rpcSummary: JSONValue {
        var status: JSONValue
        switch score.status {
        case .idle: status = "idle"
        case .noLilyPond: status = "noLilyPond"
        case .compiling: status = "compiling"
        case .clean: status = "clean"
        case .errors(let n): status = .string("errors:\(n)")
        case .failed(let why): status = .string("failed: \(why)")
        }
        // What LilyPond reported, for `check` to answer from the app's warm
        // engraving instead of compiling the score again. During a request,
        // separate diagnostics introduced after its baseline from old ones.
        var diagnostics: [JSONValue] = [], newDiagnostics: [JSONValue] = []
        for f in score.files {
            for d in f.diagnostics.filter({ $0.severity != .warning }).prefix(20) {
                let json = JSONValue.object(["severity": .string(d.severity.rawValue), "file": .string(f.url.path),
                                             "line": d.line.map { .number(Double($0)) } ?? .null,
                                             "column": d.column.map { .number(Double($0)) } ?? .null,
                                             "message": .string(d.message)])
                diagnostics.append(json)
                if agentDiagnosticIsNew(d, file: f) { newDiagnostics.append(json) }
            }
        }
        var out: [String: JSONValue] = ["root": .string(score.root.url.path), "files": .array(score.files.map { .string($0.url.path) }),
                                        "active": .string(activeFile.url.path), "status": status,
                                        "started": score.compileStarted.map { .number($0.timeIntervalSince1970) } ?? .null,
                                        "diagnostics": .array(diagnostics)]
        if hasAgentBaseline {
            out["new_diagnostics"] = .array(newDiagnostics)
            out["verification"] = rpcGraphicVerification ?? .null
        }
        return .object(out)
    }
}
