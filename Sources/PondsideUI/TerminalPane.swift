import AppKit
@preconcurrency import SwiftTerm

/// A login shell in the score's folder, so `git`, agents and `pondside`
/// run next to the music. The shell restarts if it exits.
@MainActor
final class TerminalPane: NSView, LocalProcessTerminalViewDelegate {
    private let terminal = LocalProcessTerminalView(frame: .zero)
    private let directory: URL
    private var startedAt = Date()

    init(directory: URL) {
        self.directory = directory
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.editorBackground.cgColor
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.font = Theme.monoFont
        terminal.nativeBackgroundColor = Theme.editorBackground
        terminal.nativeForegroundColor = Theme.text
        terminal.processDelegate = self
        addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            terminal.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            terminal.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            terminal.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The view that takes the keyboard.
    var responder: NSView { terminal }

    func clear() {
        terminal.selectNone()
        // Feed display controls to the emulator, never to the shell/PTY.
        terminal.feed(text: "\u{1B}[3J\u{1B}[2J\u{1B}[H")
        terminal.scroll(toPosition: 1)
    }

    private func start() {
        startedAt = Date()
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let quoted = "'" + directory.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["PONDSIDE_SCORE_DIR"] = directory.path
        // The bundled CLI first, so the folder's agent configs can launch
        // `pondside mcp`. Login shells' path_helper keeps the entry.
        if let resources = Bundle.main.resourceURL,
           FileManager.default.isExecutableFile(atPath: resources.appendingPathComponent("pondside").path) {
            env["PATH"] = resources.path + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        }
        terminal.startProcess(executable: shell, args: ["-l", "-c", "cd \(quoted) && exec \(shell) -l"],
                              environment: env.map { "\($0.key)=\($0.value)" })
    }

    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        // Restart a shell the user exited, but not one that cannot start.
        Task { @MainActor in
            if Date().timeIntervalSince(self.startedAt) > 2 { self.start() }
        }
    }
}
