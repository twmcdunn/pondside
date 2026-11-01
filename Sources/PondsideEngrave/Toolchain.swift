import Foundation
import PondsideCore

/// Where an installation was found. Recorded so the toolchain panel can show
/// provenance, and so Pondside never installs a second copy of anything.
public enum InstallOrigin: String, Sendable, Codable, CaseIterable {
    case path          // first match on $PATH
    case homebrew
    case macports
    case application   // a .app bundle in /Applications or ~/Applications
    case managed       // Pondside's own managed directory
    case bundled       // installed by the Pondside installer (BundledToolchain)
    case other
}

public struct LilyPondInstallation: Hashable, Sendable, Codable {
    public var executable: String
    /// Symlink-resolved path, used to recognise the same install twice.
    public var resolvedPath: String
    public var version: LilyPondVersion
    public var origin: InstallOrigin

    public init(executable: String, resolvedPath: String, version: LilyPondVersion, origin: InstallOrigin) {
        self.executable = executable
        self.resolvedPath = resolvedPath
        self.version = version
        self.origin = origin
    }
}

/// Where the Pondside installer puts the tools it bundles: a pinned
/// LilyPond tarball, a static fluidsynth and a General MIDI SoundFont. Kept
/// outside Pondside.app so optional components never break its signature.
public enum BundledToolchain {
#if os(macOS)
    public static let directory: String? = "/Library/Application Support/Pondside/Toolchain"
#else
    public static let directory: String? = nil
#endif

    public static func fluidSynth(in directory: String? = directory) -> String? {
        directory.map { "\($0)/fluidsynth/bin/fluidsynth" }
            .flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }

    public static func soundFont(in directory: String? = directory) -> URL? {
        directory.map { URL(fileURLWithPath: "\($0)/soundfonts/GeneralUser-GS.sf2") }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }
}

/// Finds LilyPond installations without installing anything.
public struct ToolchainDetector: Sendable {
    public var environment: [String: String]
    public var managedDirectory: String?
    public var bundledDirectory: String?

    public init(environment: [String: String] = ProcessInfo.processInfo.environment, managedDirectory: String? = nil,
                bundledDirectory: String? = BundledToolchain.directory) {
        self.environment = environment
        self.managedDirectory = managedDirectory
        self.bundledDirectory = bundledDirectory
    }

    /// Candidate executables in priority order, with their origin.
    public func lilyPondCandidates() -> [(path: String, origin: InstallOrigin)] {
        var out: [(path: String, origin: InstallOrigin)] = []
        if let override = environment["PONDSIDE_LILYPOND"], !override.isEmpty {
            out.append((override, .other))
        }
        // The installer's copy is the version Pondside was tested with.
        if let bundledDirectory {
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: bundledDirectory)) ?? []).sorted() where name.hasPrefix("lilypond-") {
                out.append(("\(bundledDirectory)/\(name)/bin/lilypond", .bundled))
            }
        }
        for dir in (environment["PATH"] ?? "").split(separator: ":") where !dir.isEmpty {
            out.append(("\(dir)/lilypond", .path))
        }
        out.append(("/opt/homebrew/bin/lilypond", .homebrew))
        out.append(("/usr/local/bin/lilypond", .homebrew))
        out.append(("/opt/local/bin/lilypond", .macports))
        let home = environment["HOME"] ?? NSHomeDirectory()
        for apps in ["/Applications", "\(home)/Applications"] {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: apps)) ?? [] where name.lowercased().hasPrefix("lilypond") {
                out.append(("\(apps)/\(name)/Contents/Resources/bin/lilypond", .application))
            }
        }
        // Official binary tarballs unpack to lilypond-X.Y.Z/bin.
        for dir in [home, "\(home)/Applications", managedDirectory].compactMap({ $0 }) {
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where name.hasPrefix("lilypond-") {
                out.append(("\(dir)/\(name)/bin/lilypond", dir == managedDirectory ? .managed : .other))
            }
        }
        return out
    }

    /// Every distinct, runnable LilyPond, each reported once.
    public func detectLilyPond() async -> [LilyPondInstallation] {
        var seen = Set<String>()
        var result: [LilyPondInstallation] = []
        for (path, origin) in lilyPondCandidates() {
            guard FileManager.default.isExecutableFile(atPath: path) else { continue }
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
            guard seen.insert(resolved).inserted else { continue }
            guard let version = await Self.probeVersion(path) else { continue }
            let refinedOrigin: InstallOrigin
            if origin == .path {
                if resolved.hasPrefix("/opt/homebrew/") || resolved.contains("/Cellar/") { refinedOrigin = .homebrew }
                else if resolved.hasPrefix("/opt/local/") { refinedOrigin = .macports }
                else if resolved.contains(".app/") { refinedOrigin = .application }
                else { refinedOrigin = .path }
            } else {
                refinedOrigin = origin
            }
            result.append(LilyPondInstallation(executable: path, resolvedPath: resolved, version: version, origin: refinedOrigin))
        }
        return result
    }

    /// Picks the install for a score: an exact match for its `\version` if
    /// available, else the oldest stable release newer than it (the closest
    /// behaviour), else the newest install. Callers must compare the result
    /// with the declared version and offer `convert-ly` when they differ —
    /// a score is never upgraded silently.
    public static func select(from installs: [LilyPondInstallation], for declared: LilyPondVersion?) -> LilyPondInstallation? {
        guard let declared else {
            return installs.filter { $0.version.isStable }.max { $0.version < $1.version } ?? installs.first
        }
        if let exact = installs.first(where: { $0.version == declared }) { return exact }
        let newer = installs.filter { $0.version >= declared }
        return newer.filter { $0.version.isStable }.min { $0.version < $1.version }
            ?? newer.min { $0.version < $1.version }
            ?? installs.max { $0.version < $1.version }
    }

    static func probeVersion(_ executable: String) async -> LilyPondVersion? {
        guard let output = try? await ProcessRunner.run(executable, ["--version"]) else { return nil }
        return parseVersionBanner(output.stdoutString + output.stderrString)
    }

    /// Parses "GNU LilyPond 2.26.0 (running Guile 2.2)".
    public static func parseVersionBanner(_ banner: String) -> LilyPondVersion? {
        guard let r = banner.firstRange(of: "LilyPond ") else { return nil }
        return LilyPondVersion(banner[r.upperBound...])
    }
}
