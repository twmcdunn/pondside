import Foundation
import XCTest
@testable import PondsideEngrave

/// The tested staff-line window recipe: the selected system loses its lines
/// inside the window; the other system and the edges remain.
final class StaffLineWindowTests: XCTestCase {
    func testTheWindowRecipeCompiles() async throws {
        let installs = await ToolchainDetector().detectLilyPond()
        guard let chosen = ToolchainDetector.select(from: installs, for: nil) else {
            throw XCTSkip("LilyPond not installed")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-staff-window-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("staff-lines.ly")
        let fixture = try Data(contentsOf: try XCTUnwrap(Bundle.module.url(forResource: "staff-lines",
                                                                           withExtension: "ly", subdirectory: "Fixtures")))
        try fixture.write(to: source)
        let result = try await LilyPondEngraver(installation: chosen)
            .engrave(source, purpose: .canvas, outputDirectory: dir.appendingPathComponent("out"))
        XCTAssertTrue(result.succeeded, result.log)
        XCTAssertTrue(result.errors.isEmpty, result.log)
    }
}
