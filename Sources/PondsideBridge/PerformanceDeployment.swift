import Foundation
import PondsideCore
import PondsideTiming
import PondsideEngrave

/// A locally reviewable deployment. No GitHub mutation happens until publish.
public enum PerformanceDeployment {
    public struct System: Codable, Sendable {
        public var file: String
        public var seconds: Double
        public init(file: String, seconds: Double) { self.file = file; self.seconds = seconds }
    }
    public struct Manifest: Codable, Sendable {
        public struct Cue: Codable, Sendable { public var name: String; public var seconds: Double }
        public var title: String
        public var repository: String
        public var patch: String
        public var cues: [Cue]
        public var systems: [System]
        public init(title: String, repository: String, patch: String, sheet: CueSheet, systems: [System]) {
            self.title = title; self.repository = repository; self.patch = patch
            cues = sheet.cues.map { Cue(name: $0.name, seconds: $0.seconds) }; self.systems = systems
        }
    }
    public struct SoundFile: Codable, Sendable {
        public var path: String
        public var bytes: Int
    }
    public struct Prepared: Codable, Sendable {
        public var folder: URL
        public var app: URL
        public var repository: String
        public var assetName: String
        public var tag: String
        public var downloadURL: String { "https://github.com/\(repository)/releases/latest/download/\(assetName)" }
    }
    private struct Receipt: Codable {
        var project: String
        var prepared: Prepared
    }
    private static let receiptName = "deployment.json"
    private static func samePath(_ lhs: String, _ rhs: String) -> Bool {
        let a = SourceGraph.canonical(URL(fileURLWithPath: lhs)).path
        let b = SourceGraph.canonical(URL(fileURLWithPath: rhs)).path
        if a == b { return true }
        guard let left = try? FileManager.default.attributesOfItem(atPath: a),
              let right = try? FileManager.default.attributesOfItem(atPath: b),
              let leftFile = left[.systemFileNumber] as? NSNumber,
              let rightFile = right[.systemFileNumber] as? NSNumber,
              let leftVolume = left[.systemNumber] as? NSNumber,
              let rightVolume = right[.systemNumber] as? NSNumber else { return false }
        return leftFile == rightFile && leftVolume == rightVolume
    }

    public static func library(for project: URL, in directory: URL? = nil) -> URL {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pondside/Deployments")
        return base.appendingPathComponent(ContentHash(project.resolvingSymlinksInPath().standardizedFileURL.path).description)
    }
    public static func nextBuild(for project: URL, in directory: URL? = nil) throws -> URL {
        let folder = library(for: project, in: directory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(UUID().uuidString)
    }
    public static func savedBuilds(for project: URL, in directory: URL? = nil) -> [Prepared] {
        let source = project.resolvingSymlinksInPath().standardizedFileURL.path
        let base = SourceGraph.canonical(library(for: project, in: directory))
        let folders = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey], options: [.skipsHiddenFiles])) ?? []
        return folders.sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(receiptName)),
                  let receipt = try? JSONDecoder().decode(Receipt.self, from: data), samePath(receipt.project, source),
                  samePath(receipt.prepared.folder.path, folder.path),
                  samePath(receipt.prepared.app.deletingLastPathComponent().path, folder.path),
                  FileManager.default.fileExists(atPath: receipt.prepared.app.path),
                  FileManager.default.fileExists(atPath: folder.appendingPathComponent("Assets/" + receipt.prepared.assetName).path) else { return nil }
            return receipt.prepared
        }.sorted { $0.tag > $1.tag }
    }
    private static func save(_ prepared: Prepared, project: URL) throws {
        let receipt = Receipt(project: project.resolvingSymlinksInPath().standardizedFileURL.path, prepared: prepared)
        try JSONEncoder().encode(receipt).write(to: prepared.folder.appendingPathComponent(receiptName), options: .atomic)
    }
    public static func publishedURL(_ prepared: Prepared) -> String? {
        try? String(contentsOf: prepared.folder.appendingPathComponent("published-url.txt"), encoding: .utf8)
    }
    /// Associate a locally tested build with its publishing account. This
    /// changes release metadata/signature only, never recompiles its executable.
    public static func assignRepository(_ repository: String, to prepared: Prepared) throws -> Prepared {
        guard validRepository(repository), repository.split(separator: "/").last == prepared.repository.split(separator: "/").last else { throw PatchContract.Failure("Keep the prepared repository name when publishing this build.") }
        guard repository != prepared.repository else { return prepared }
        guard !FileManager.default.fileExists(atPath: prepared.folder.appendingPathComponent("publish-stage.txt").path) else { throw PatchContract.Failure("This build has already started publishing to \(prepared.repository). Use that GitHub account to resume.") }
        var prepared = prepared
        let file = prepared.app.appendingPathComponent("Contents/Resources/performance.json")
        var manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: file))
        manifest.repository = repository
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: file, options: .atomic)
        try data.write(to: prepared.folder.appendingPathComponent("PlayerResources/performance.json"), options: .atomic)
        _ = try command("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", prepared.app.path])
        let archive = prepared.folder.appendingPathComponent("Assets/" + prepared.assetName)
        try FileManager.default.removeItem(at: archive)
        _ = try command("/usr/bin/ditto", ["-c", "-k", "--keepParent", prepared.app.path, archive.path])
        prepared.repository = repository
        let receiptFile = prepared.folder.appendingPathComponent(receiptName)
        if let receipt = try? JSONDecoder().decode(Receipt.self, from: Data(contentsOf: receiptFile)) {
            try save(prepared, project: URL(fileURLWithPath: receipt.project))
        }
        return prepared
    }
    public static func githubExecutable() throws -> String {
        let paths = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/gh" }
        guard let path = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw PatchContract.Failure("Install the GitHub CLI to publish (cli.github.com). Local testing is available without GitHub.")
        }
        return path
    }
    public static func validRepository(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count == 2 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && $0.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) } }
    }
    public static func githubUser() throws -> String {
        try command(githubExecutable(), ["api", "user", "--jq", ".login"]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Copy only patch sources/data, raster-free system PDFs and the exact
    /// no-Qt runtime supplied to Pondside. Sounds become separate release assets.
    public static func prepare(project: URL, patch: URL, manifest: Manifest, systems: [String: Data], playerSource: URL, headlessApp: URL, destination: URL, swift: String, playerExecutable: URL? = nil) throws -> Prepared {
        let project = project.resolvingSymlinksInPath().standardizedFileURL
        let patch = patch.resolvingSymlinksInPath().standardizedFileURL
        let destination = destination.resolvingSymlinksInPath().standardizedFileURL
        guard validRepository(manifest.repository), manifest.systems.count >= 2 else { throw PatchContract.Failure("Choose owner/repository and a score containing at least two systems.") }
        try PatchContract.validateProject(patch: patch, headless: true)
        guard SuperColliderToolchain.isHeadless(headlessApp.appendingPathComponent("Contents/MacOS/sclang").path) else { throw PatchContract.Failure("Deploy Patch needs Pondside's headless SuperCollider runtime. Build or install it first.") }
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw PatchContract.Failure("Deployment destination already exists.") }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let sources = destination.appendingPathComponent("Sources")
        let assets = destination.appendingPathComponent("Assets")
        try fm.createDirectory(at: sources, withIntermediateDirectories: true)
        try fm.createDirectory(at: assets, withIntermediateDirectories: true)
        try fm.copyItem(at: playerSource, to: sources.appendingPathComponent("main.swift"))
        let name = manifest.repository.split(separator: "/").last.map(String.init)!
        let app = destination.appendingPathComponent(name + ".app")
        let contents = app.appendingPathComponent("Contents"), resources = contents.appendingPathComponent("Resources")
        let macOS = contents.appendingPathComponent("MacOS")
        try fm.createDirectory(at: macOS, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)
        let runtimeProject = resources.appendingPathComponent("Project")
        try fm.createDirectory(at: runtimeProject, withIntermediateDirectories: true)
        let patchFolder = patch.deletingLastPathComponent()
        guard patchFolder.path.hasPrefix(project.path + "/"), patch.path == project.appendingPathComponent(manifest.patch).path else { throw PatchContract.Failure("The patch must live inside the project.") }
        let dependencies = PatchMigration.dependencies(of: patch)
        for dependency in dependencies where !dependency.path.hasPrefix(patchFolder.path + "/") {
            guard dependency.path.hasPrefix(project.path + "/") else { throw PatchContract.Failure("Move required dependency into the project before deploying: \(dependency.path)") }
            let target = runtimeProject.appendingPathComponent(String(dependency.path.dropFirst(project.path.count + 1)))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: dependency, to: target)
        }
        let audio: Set<String> = ["wav", "aif", "aiff", "flac", "ogg", "mp3", "caf"]
        guard let files = fm.enumerator(atPath: patchFolder.path) else { throw PatchContract.Failure("Cannot enumerate patch files.") }
        for case let relativePatch as String in files {
            if relativePatch.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
            let file = patchFolder.appendingPathComponent(relativePatch)
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw PatchContract.Failure("Replace patch symlinks with project files before deploying: \(file.path)") }
            if relativePatch == "resources" || relativePatch.hasPrefix("resources/") { files.skipDescendants(); continue }
            guard values.isRegularFile == true, !audio.contains(file.pathExtension.lowercased()) else { continue }
            let target = runtimeProject.appendingPathComponent(String(file.path.dropFirst(project.path.count + 1)))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: file, to: target)
        }
        let cues = runtimeProject.appendingPathComponent("renders/" + patch.deletingPathExtension().lastPathComponent + ".cues")
        try fm.createDirectory(at: cues.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var playerManifest = manifest
        let main = try String(contentsOf: patch, encoding: .utf8)
        guard let block = PatchContract.mainBlock(in: main) else { throw PatchContract.Failure("The patch has no initialization block") }
        let initialization = (main as NSString).substring(with: NSRange(location: block.lowerBound, length: block.count))
        let entry = runtimeProject.appendingPathComponent(manifest.patch).deletingLastPathComponent().appendingPathComponent("pondside-performance-init.scd")
        try fm.createDirectory(at: entry.deletingLastPathComponent(), withIntermediateDirectories: true)
        try initialization.write(to: entry, atomically: true, encoding: .utf8)
        playerManifest.patch = String(entry.path.dropFirst(runtimeProject.path.count + 1))
        try encoder.encode(playerManifest).write(to: resources.appendingPathComponent("performance.json"))
        // Engine cue file is derived from the source score and may have a
        // different basename from the main patch.
        let renderFolder = project.appendingPathComponent("renders")
        for file in (try? fm.contentsOfDirectory(at: renderFolder, includingPropertiesForKeys: nil)) ?? [] where ["cues", "json"].contains(file.pathExtension) {
            try fm.copyItem(at: file, to: cues.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent))
        }
        for system in manifest.systems {
            guard let data = systems[system.file], system.file.hasPrefix("systems/"), !system.file.split(separator: "/").contains("..") else { throw PatchContract.Failure("Missing score system \(system.file)") }
            let file = resources.appendingPathComponent(system.file)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
        try fm.copyItem(at: headlessApp, to: resources.appendingPathComponent("SuperCollider.app"))
        let licenses = headlessApp.deletingLastPathComponent()
        for file in (try? fm.contentsOfDirectory(at: licenses, includingPropertiesForKeys: nil)) ?? [] where file.lastPathComponent.lowercased().contains("license") || file.lastPathComponent.lowercased().contains("copying") {
            try fm.copyItem(at: file, to: resources.appendingPathComponent(file.lastPathComponent))
        }
        let inventory = ["resources.zip": try zipSounds(patchFolder.appendingPathComponent("resources"), to: assets.appendingPathComponent("resources.zip")),
                         "sounds.zip": try zipSounds(PatchContract.sharedSounds, to: assets.appendingPathComponent("sounds.zip"), selecting: sharedSoundSelection(patch: patch))]
        try encoder.encode(inventory).write(to: resources.appendingPathComponent("sound-inventory.json"))
        let tag = "v" + ISO8601DateFormatter().string(from: Date()).filter { $0.isNumber }
        let info: [String: Any] = ["CFBundleExecutable": name, "CFBundleIdentifier": "org.pondside.performance." + name.lowercased().replacingOccurrences(of: "_", with: "-"), "CFBundleName": manifest.title, "CFBundlePackageType": "APPL", "CFBundleShortVersionString": "1.0", "CFBundleVersion": String(tag.dropFirst()), "LSMinimumSystemVersion": "14.0", "NSMicrophoneUsageDescription": "The live SuperCollider patch uses audio input for performance.", "NSHighResolutionCapable": true]
        let infoData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        try infoData.write(to: destination.appendingPathComponent("Info.plist"))
        let rebuild = """
        #!/bin/sh
        set -eu
        cd "$(dirname "$0")"
        runtime="${PONDSIDE_HEADLESS_APP:?Set PONDSIDE_HEADLESS_APP to Pondside's headless SuperCollider.app}"
        app="\(name).app"
        mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
        cp Info.plist "$app/Contents/Info.plist"
        ditto PlayerResources "$app/Contents/Resources"
        ditto "$runtime" "$app/Contents/Resources/SuperCollider.app"
        swiftc -target "$(uname -m)-apple-macos14.0" -swift-version 6 -O Sources/main.swift -o "$app/Contents/MacOS/\(name)"
        codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$app"
        """
        try rebuild.write(to: destination.appendingPathComponent("build.sh"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.appendingPathComponent("build.sh").path)
        if let playerExecutable {
            try fm.copyItem(at: playerExecutable, to: macOS.appendingPathComponent(name))
        } else {
            #if arch(arm64)
            let target = "arm64-apple-macos14.0"
            #else
            let target = "x86_64-apple-macos14.0"
            #endif
            _ = try command(swift, ["-target", target, "-swift-version", "6", "-O", sources.appendingPathComponent("main.swift").path, "-o", macOS.appendingPathComponent(name).path])
        }
        _ = try command("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
        let assetName = name + ".zip"
        _ = try command("/usr/bin/ditto", ["-c", "-k", "--keepParent", app.path, assets.appendingPathComponent(assetName).path])
        try """
        # \(manifest.title)

        Standalone macOS performance app exported by Pondside. Open the app;
        missing sounds are restored before the patch initializes. Healthy
        launches work offline. Download the ZIP, unzip and open the app;
        no installer, Pondside, developer tools or separate SuperCollider is needed.
        Space / Right Arrow advances cues; Left Arrow returns to the previous cue.
        Execute the main SuperCollider block once when using the patch manually,
        then call ~triggerCue.() for live cues. No Qt or LilyPond is needed by the app.

        The bundled SuperCollider runtime retains its upstream license notices.
        The app is ad-hoc signed; distribution may require Developer ID signing
        and notarization for the intended performers' macOS security settings.
        """.write(to: destination.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        try "Assets/\n*.app/\n.DS_Store\n".write(to: destination.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        // Publish the exact source and resources needed to rebuild, excluding
        // sounds and binary artifacts (which belong to the release assets).
        try fm.createDirectory(at: destination.appendingPathComponent("PlayerResources"), withIntermediateDirectories: true)
        for file in try fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil) where file.lastPathComponent != "SuperCollider.app" {
            try fm.copyItem(at: file, to: destination.appendingPathComponent("PlayerResources").appendingPathComponent(file.lastPathComponent))
        }
        let prepared = Prepared(folder: destination, app: app, repository: manifest.repository, assetName: assetName, tag: tag)
        try save(prepared, project: project)
        return prepared
    }
    /// nil means a dynamic reference requires the full shared folder;
    /// otherwise only statically referenced files/subfolders are included.
    static func sharedSoundSelection(patch: URL) -> Set<String>? {
        var selected = Set<String>()
        let files = [patch] + PatchMigration.dependencies(of: patch)
        let shared = PatchContract.sharedSounds.standardizedFileURL.path + "/"
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let ns = text as NSString
            let tokens = SCLexer.tokenize(text).filter { $0.kind != .comment && $0.kind != .whitespace }
            for (index, token) in tokens.enumerated() {
                let value = ns.substring(with: NSRange(location: token.range.lowerBound, length: token.range.count))
                let next = index + 1 < tokens.count ? ns.substring(with: NSRange(location: tokens[index + 1].range.lowerBound, length: tokens[index + 1].range.count)) : ""
                if value == "~sharedSounds", next != "=" {
                    let tail = ns.substring(from: token.range.lowerBound)
                    let regex = try! NSRegularExpression(pattern: #"^~sharedSounds\s*\+/\+\s*"([^"]+)""#)
                    guard let match = regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) else { return nil }
                    let path = (tail as NSString).substring(with: match.range(at: 1))
                    guard !path.contains("*"), !path.contains("?"), !path.split(separator: "/").contains("..") else { return nil }
                    selected.insert(path)
                }
                if value == "userAppSupportDir" {
                    let before = ns.substring(to: token.range.lowerBound).split(separator: "\n").last.map(String.init) ?? ""
                    if !before.contains("~sharedSounds =") { return nil }
                }
                if token.kind == .string {
                    let literal = String(value.dropFirst().dropLast())
                    if literal.hasPrefix(shared) { selected.insert(String(literal.dropFirst(shared.count))) }
                }
            }
        }
        return selected
    }
    static func zipSounds(_ source: URL, to target: URL, selecting selection: Set<String>? = nil) throws -> [SoundFile] {
        let fm = FileManager.default
        let source = source.resolvingSymlinksInPath().standardizedFileURL
        let staging = fm.temporaryDirectory.appendingPathComponent("pondside-sounds-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var inventory: [SoundFile] = []
        if let files = fm.enumerator(atPath: source.path) {
            for case let relative as String in files {
                if relative.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue }
                if let selection, !selection.contains(where: { relative == $0 || relative.hasPrefix($0 + "/") }) { continue }
                let file = source.appendingPathComponent(relative)
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw PatchContract.Failure("Sound archives cannot contain symbolic links: \(file.path)") }
                guard values.isRegularFile == true else { continue }
                let target = staging.appendingPathComponent(relative)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: file, to: target)
                let size = try target.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                inventory.append(SoundFile(path: relative, bytes: size))
            }
        }
        // A marker makes even an empty sound set a valid ZIP.
        try Data().write(to: staging.appendingPathComponent(".pondside-sounds"))
        _ = try command("/usr/bin/ditto", ["-c", "-k", staging.path, target.path])
        return inventory.sorted { $0.path < $1.path }
    }
    enum PublishStage: Int { case none, repositoryCreated, sourcePushed, released }
    public static func publish(_ prepared: Prepared, visibility: String) throws {
        let gh = try githubExecutable()
        let progress = prepared.folder.appendingPathComponent("publish-stage.txt")
        let stage = (try? String(contentsOf: progress, encoding: .utf8)).flatMap { Int($0) }.flatMap(PublishStage.init(rawValue:)) ?? .none
        try publish(prepared, visibility: visibility, startingAt: stage, checkpoint: { stage in
            try String(stage.rawValue).write(to: progress, atomically: true, encoding: .utf8)
        }, execute: { executable, arguments in
            if executable == "/usr/bin/env", arguments.first == "gh" { return try command(gh, Array(arguments.dropFirst())) }
            return try command(executable, arguments)
        })
        try prepared.downloadURL.write(to: prepared.folder.appendingPathComponent("published-url.txt"), atomically: true, encoding: .utf8)
    }
    static func publish(_ prepared: Prepared, visibility: String, startingAt stage: PublishStage = .none,
                        checkpoint: (PublishStage) throws -> Void = { _ in }, execute: (String, [String]) throws -> String) throws {
        guard visibility == "public", validRepository(prepared.repository), !prepared.repository.hasPrefix("unpublished/") else { throw PatchContract.Failure("Choose a public repository and connect your GitHub account before publishing.") }
        let path = prepared.folder.path
        if stage.rawValue < PublishStage.repositoryCreated.rawValue {
            _ = try execute("/usr/bin/env", ["gh", "repo", "create", prepared.repository, "--" + visibility, "--description", "Performance patch exported by Pondside"])
            try checkpoint(.repositoryCreated)
        }
        if stage.rawValue < PublishStage.sourcePushed.rawValue {
            _ = try execute("/usr/bin/git", ["-C", path, "init", "-b", "main"])
            _ = try execute("/usr/bin/git", ["-C", path, "add", "Sources", "PlayerResources", "README.md", ".gitignore", "Info.plist", "build.sh"])
            _ = try execute("/usr/bin/git", ["-C", path, "-c", "user.name=Pondside", "-c", "user.email=pondside@localhost", "commit", "--allow-empty", "-m", "Export performance patch"])
            let address = "https://github.com/" + prepared.repository + ".git"
            do { _ = try execute("/usr/bin/git", ["-C", path, "remote", "set-url", "origin", address]) }
            catch { _ = try execute("/usr/bin/git", ["-C", path, "remote", "add", "origin", address]) }
            _ = try execute("/usr/bin/git", ["-C", path, "-c", "credential.helper=!gh auth git-credential", "push", "-u", "origin", "main"])
            try checkpoint(.sourcePushed)
        }
        if stage.rawValue < PublishStage.released.rawValue {
            let assets = prepared.folder.appendingPathComponent("Assets")
            let files = [prepared.assetName, "resources.zip", "sounds.zip"].map { assets.appendingPathComponent($0).path }
            let exists = (try? execute("/usr/bin/env", ["gh", "release", "view", prepared.tag, "--repo", prepared.repository])) != nil
            if exists {
                _ = try execute("/usr/bin/env", ["gh", "release", "upload", prepared.tag, "--repo", prepared.repository, "--clobber"] + files)
                _ = try execute("/usr/bin/env", ["gh", "release", "edit", prepared.tag, "--repo", prepared.repository, "--draft=false", "--latest"])
            } else {
                _ = try execute("/usr/bin/env", ["gh", "release", "create", prepared.tag, "--repo", prepared.repository, "--title", "Performance app", "--notes", "Unzip and open the app; sounds install automatically. No installer is needed. Space or arrows trigger cues."] + files)
            }
            try checkpoint(.released)
        }
    }
    @discardableResult static func command(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { throw PatchContract.Failure(output) }
        return output
    }
}
