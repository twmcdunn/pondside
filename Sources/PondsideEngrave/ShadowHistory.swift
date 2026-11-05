import Foundation
import PondsideCore

/// Checkpoints of a score's files, so no edit is ever lost, without
/// touching the user's own git repository (DESIGN.md, Appendix A.5).
///
/// A separate git repository per score, kept outside the project (its
/// `GIT_DIR` under the app's support folder, its work tree the score's
/// folder), records only the score's `.ly`/`.ily` files. The user's repo,
/// index and folder are never written; deleting the history loses nothing
/// but the checkpoints.
public struct ShadowHistory: Sendable {
    public let gitDir: URL
    public let workTree: URL
    public let git: String

    /// `root`: where histories live (e.g. ~/Library/Application Support/Pondside/History).
    public init(score: URL, root: URL, git: String = ShadowHistory.findGit() ?? "/usr/bin/git") {
        workTree = score.deletingLastPathComponent().standardizedFileURL
        gitDir = root.appendingPathComponent(ContentHash(workTree.path).description + ".git", isDirectory: true)
        self.git = git
    }

    public static func findGit() -> String? {
        ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// A git that actually runs, or nil. On macOS `/usr/bin/git` exists on
    /// every Mac but is only a stub until the Command Line Tools or Xcode are
    /// installed; run then, it shows Apple's install dialog and fails. So the
    /// stub is used only when a developer directory with a real git exists,
    /// and any candidate must answer `git --version`. Blocking: call it off
    /// the main thread.
    public static func workingGit() -> String? {
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) {
            #if os(macOS)
            if path == "/usr/bin/git" {
                guard let dir = try? ProcessRunner.runBlocking("/usr/bin/xcode-select", ["-p"]), dir.status == 0 else { continue }
                let developer = dir.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
                guard FileManager.default.isExecutableFile(atPath: developer + "/usr/bin/git") else { continue }
            }
            #endif
            if let out = try? ProcessRunner.runBlocking(path, ["--version"]), out.status == 0 { return path }
        }
        return nil
    }

    public struct Checkpoint: Sendable, Hashable {
        public var revision: String
        public var date: String
        public var message: String
    }

    private func run(_ args: [String]) async throws -> ProcessOutput {
        try await ProcessRunner.run(git, ["--git-dir=\(gitDir.path)", "--work-tree=\(workTree.path)"] + args,
                                    currentDirectory: workTree.path,
                                    environment: ["GIT_AUTHOR_NAME": "Pondside", "GIT_AUTHOR_EMAIL": "history@pondside.local",
                                                  "GIT_COMMITTER_NAME": "Pondside", "GIT_COMMITTER_EMAIL": "history@pondside.local",
                                                  "PATH": "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"])
    }

    /// Records `files` (paths inside the score's folder) if any changed.
    /// Returns whether a checkpoint was made.
    @discardableResult
    public func checkpoint(_ files: [URL], message: String = "checkpoint") async throws -> Bool {
        if !FileManager.default.fileExists(atPath: gitDir.path) {
            try FileManager.default.createDirectory(at: gitDir.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = try await run(["init", "--quiet"])
        }
        let inside = files.map(\.standardizedFileURL.path).filter { $0.hasPrefix(workTree.path + "/") }
            .map { String($0.dropFirst(workTree.path.count + 1)) }
        guard !inside.isEmpty else { return false }
        _ = try await run(["add", "--"] + inside)
        let status = try await run(["status", "--porcelain", "--untracked-files=no", "--"] + inside)
        guard !status.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let commit = try await run(["commit", "--quiet", "-m", message, "--"] + inside)
        return commit.status == 0
    }

    /// Newest first.
    public func checkpoints(limit: Int = 100) async throws -> [Checkpoint] {
        guard FileManager.default.fileExists(atPath: gitDir.path) else { return [] }
        let out = try await run(["log", "-n", String(limit), "--format=%h\t%ci\t%s"])
        return out.stdoutString.split(separator: "\n").compactMap { line in
            let f = line.split(separator: "\t", maxSplits: 2).map(String.init)
            return f.count == 3 ? Checkpoint(revision: f[0], date: f[1], message: f[2]) : nil
        }
    }

    /// The text of `file` at `revision`.
    public func text(of file: URL, at revision: String) async throws -> String {
        let path = String(file.standardizedFileURL.path.dropFirst(workTree.path.count + 1))
        let out = try await run(["show", "\(revision):\(path)"])
        guard out.status == 0 else { throw Failure("no \(path) at \(revision)") }
        return out.stdoutString
    }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
        init(_ d: String) { description = d }
    }
}
