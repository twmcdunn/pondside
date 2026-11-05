import AppKit
import PondsideBridge
import PondsideTiming

/// GitHub's browser/device flow. Credentials stay with gh and the Keychain;
/// Pondside displays only the temporary verification code.
@MainActor final class GitHubLogin: NSObject {
    private var process: Process?
    private var continuation: CheckedContinuation<String, Error>?
    private let code = NSTextField(labelWithString: "Opening GitHub in your browser…")
    private var alert: NSAlert?
    private var output = ""
    private let userLookup: @Sendable () throws -> String
    private let executableLookup: @Sendable () throws -> String
    init(user: @escaping @Sendable () throws -> String = { try PerformanceDeployment.githubUser() },
         executable: @escaping @Sendable () throws -> String = { try PerformanceDeployment.githubExecutable() }) {
        userLookup = user
        executableLookup = executable
        super.init()
    }

    func authenticate(on window: NSWindow) async throws -> String {
        let lookup = userLookup
        if let user = try? await Task.detached(operation: { try lookup() }).value { return user }
        let executable = try executableLookup()
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let alert = NSAlert()
            self.alert = alert
            alert.messageText = "Sign in to GitHub"
            alert.informativeText = "Complete sign-in in your browser. If GitHub asks for a device code, use the code below. Pondside never asks for your GitHub password."
            code.font = .monospacedSystemFont(ofSize: 18, weight: .semibold)
            code.isSelectable = true
            code.alignment = .center
            code.frame = NSRect(x: 0, y: 0, width: 390, height: 32)
            code.setAccessibilityLabel("GitHub device verification code")
            alert.accessoryView = code
            alert.addButton(withTitle: "Cancel")
            alert.beginSheetModal(for: window) { [weak self] _ in self?.cancel() }
            let process = Process(), input = Pipe(), output = Pipe()
            self.process = process
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["auth", "login", "--hostname", "github.com", "--git-protocol", "https", "--web"]
            var environment = ProcessInfo.processInfo.environment
            environment["GH_BROWSER"] = "/usr/bin/open"
            environment.removeValue(forKey: "GH_PROMPT_DISABLED")
            process.environment = environment
            process.standardInput = input
            process.standardOutput = output
            process.standardError = output
            output.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                Task { @MainActor in self?.receive(text) }
            }
            process.terminationHandler = { [weak self] process in
                let success = process.terminationStatus == 0
                Task { @MainActor in
                    guard let self, self.continuation != nil else { return }
                    if success {
                        do {
                            let lookup = self.userLookup
                            let user = try await Task.detached { try lookup() }.value
                            self.finish(.success(user))
                        } catch { self.finish(.failure(error)) }
                    } else { self.finish(.failure(PatchContract.Failure("GitHub sign-in did not complete. The prepared build is saved; try Publish Release again."))) }
                }
            }
            do {
                try process.run()
                // gh's web flow waits for Return before opening the browser.
                try input.fileHandleForWriting.write(contentsOf: Data("\n".utf8))
            } catch { finish(.failure(error)) }
        }
    }
    private func receive(_ text: String) {
        output += text
        if let range = output.range(of: #"\b[A-Z0-9]{4}-[A-Z0-9]{4}\b"#, options: .regularExpression) {
            code.stringValue = String(output[range])
        }
        if output.count > 4000 { output = String(output.suffix(4000)) }
    }
    private func cancel() {
        guard continuation != nil else { return }
        if process?.isRunning == true { process?.terminate() }
        finish(.failure(CancellationError()))
    }
    private func finish(_ result: Result<String, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        if let panel = alert?.window, let parent = panel.sheetParent { parent.endSheet(panel) }
        process = nil
        alert = nil
        continuation.resume(with: result)
    }
}
