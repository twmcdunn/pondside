import XCTest
import Foundation
import PondsideTiming
import PondsideCore
@testable import PondsideBridge

final class PerformanceDeploymentTests: XCTestCase {
    func testRepositoryNamesAreSingleOwnerAndRepository() {
        for name in ["owner/score", "o-w/score_2.0"] { XCTAssertTrue(PerformanceDeployment.validRepository(name)) }
        for name in ["", "score", "owner/../score", "owner/", "/score", "owner/..", "owner/a b", "owner/a\nb"] { XCTAssertFalse(PerformanceDeployment.validRepository(name), name) }
    }
    func testManifestRoundTripsCueTimesAndSystems() throws {
        let log = TimingLog(rows: [.init(moment: Rational(0), bar: 1, kind: .text("cue 1")), .init(moment: Rational(2), bar: 3, kind: .text("cue 2"))])
        let sheet = CueSheet(log: log, score: "piece.ly")
        let manifest = PerformanceDeployment.Manifest(title: "Piece", repository: "owner/piece", patch: "patch/piece.scd", sheet: sheet, systems: [.init(file: "systems/1.pdf", seconds: 0), .init(file: "systems/2.pdf", seconds: 4)])
        let decoded = try JSONDecoder().decode(PerformanceDeployment.Manifest.self, from: JSONEncoder().encode(manifest))
        XCTAssertEqual(decoded.cues.map(\.seconds), sheet.cues.map(\.seconds))
        XCTAssertEqual(decoded.systems.map(\.file), ["systems/1.pdf", "systems/2.pdf"])
    }
    func testPublishingCreatesRepositoryBeforePushingAndReleasing() throws {
        let prepared = PerformanceDeployment.Prepared(folder: URL(fileURLWithPath: "/tmp/prepared"), app: URL(fileURLWithPath: "/tmp/prepared/Piece.app"), repository: "owner/piece", assetName: "Piece.zip", tag: "v1")
        var commands: [[String]] = []
        try PerformanceDeployment.publish(prepared, visibility: "public") { executable, arguments in
            commands.append([executable] + arguments)
            if arguments.starts(with: ["gh", "release", "view"]) { throw NSError(domain: "NoReleaseYet", code: 1) }
            return ""
        }
        XCTAssertEqual(Array(commands.first!.prefix(6)), ["/usr/bin/env", "gh", "repo", "create", "owner/piece", "--public"])
        XCTAssertTrue(commands.last!.contains("release"))
        XCTAssertTrue(commands.last!.contains("/tmp/prepared/Assets/Piece.zip"))
        XCTAssertTrue(commands.last!.contains("/tmp/prepared/Assets/resources.zip"))
        XCTAssertTrue(commands.last!.contains("/tmp/prepared/Assets/sounds.zip"))
        XCTAssertFalse(commands.dropFirst().dropLast().contains { $0.contains("gh") && $0.contains("repo") })
    }

    func testResumeAfterPushDoesNotCreateAnotherRepositoryOrRebuild() throws {
        let prepared = PerformanceDeployment.Prepared(folder: URL(fileURLWithPath: "/tmp/prepared"), app: URL(fileURLWithPath: "/tmp/prepared/Piece.app"), repository: "owner/piece", assetName: "Piece.zip", tag: "v1")
        var commands: [[String]] = []
        try PerformanceDeployment.publish(prepared, visibility: "public", startingAt: .sourcePushed) { executable, arguments in
            commands.append([executable] + arguments); return "existing draft"
        }
        XCTAssertFalse(commands.contains { $0.contains("repo") && $0.contains("create") })
        XCTAssertFalse(commands.contains { $0.first == "/usr/bin/git" || $0.contains("swiftc") })
        XCTAssertTrue(commands.contains { $0.contains("upload") && $0.contains("--clobber") })
        XCTAssertTrue(commands.last!.contains("--draft=false"))
    }

    func testSavedBuildLibraryIgnoresIncompleteBuilds() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-deploy-library-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let project = temporary.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let folder = try PerformanceDeployment.nextBuild(for: project, in: temporary.appendingPathComponent("builds"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        XCTAssertTrue(PerformanceDeployment.savedBuilds(for: project, in: temporary.appendingPathComponent("builds")).isEmpty)
        let app = folder.appendingPathComponent("Piece.app")
        let assets = folder.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data().write(to: assets.appendingPathComponent("Piece.zip"))
        let prepared = PerformanceDeployment.Prepared(folder: folder, app: app, repository: "unpublished/piece", assetName: "Piece.zip", tag: "v1")
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(prepared))
        let receipt: [String: Any] = ["project": project.resolvingSymlinksInPath().standardizedFileURL.path, "prepared": value]
        try JSONSerialization.data(withJSONObject: receipt).write(to: folder.appendingPathComponent("deployment.json"))
        let saved = PerformanceDeployment.savedBuilds(for: project, in: temporary.appendingPathComponent("builds"))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.tag, "v1")
        XCTAssertEqual(saved.first?.repository, "unpublished/piece")
        let linkRoot = temporary.appendingPathComponent("linked-builds")
        try FileManager.default.createDirectory(at: linkRoot, withIntermediateDirectories: true)
        let link = PerformanceDeployment.library(for: project, in: linkRoot)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder.deletingLastPathComponent())
        XCTAssertEqual(PerformanceDeployment.savedBuilds(for: project, in: linkRoot).count, 1)

    }

    func testSharedSoundInventoryIncludesOnlyReferencedFilesOrFolders() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-shared-sounds-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let patch = folder.appendingPathComponent("piece.scd")
        let base = PatchContract.initialization(body: "// @pondside cues", score: "piece.ly")
        try base.write(to: patch, atomically: true, encoding: .utf8)
        XCTAssertEqual(PerformanceDeployment.sharedSoundSelection(patch: patch), [])
        let withSound = base.replacingOccurrences(of: "// @pondside cues", with: "~sample = Buffer.read(s, ~sharedSounds +/+ \"birds/take.wav\");\n// @pondside cues")
        try withSound.write(to: patch, atomically: true, encoding: .utf8)
        XCTAssertEqual(PerformanceDeployment.sharedSoundSelection(patch: patch), ["birds/take.wav"])
        let dynamic = base.replacingOccurrences(of: "// @pondside cues", with: "~sample = Buffer.read(s, ~sharedSounds +/+ ~name);\n// @pondside cues")
        try dynamic.write(to: patch, atomically: true, encoding: .utf8)
        XCTAssertNil(PerformanceDeployment.sharedSoundSelection(patch: patch))
    }

}
