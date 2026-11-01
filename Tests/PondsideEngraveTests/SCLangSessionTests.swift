import XCTest
import PondsideCore
@testable import PondsideEngrave

final class SCLangSessionTests: XCTestCase {
    func testDetectionHonoursOverridesFirst() {
        let c = SuperColliderToolchain.candidates(environment: ["PONDSIDE_SCLANG": "/x/sclang", "PATH": "/p", "HOME": "/h"],
                                                  configured: "/Apps/SuperCollider.app")
        XCTAssertEqual(Array(c.prefix(3)), ["/x/sclang", "/Apps/SuperCollider.app/Contents/MacOS/sclang",
                                            "/Applications/SuperCollider.app/Contents/MacOS/sclang"])
        XCTAssertTrue(c.contains("/p/sclang"))
    }

    func testLiteralEscapes() {
        XCTAssertEqual(SCLangSession.literal("a\"b\\c"), "\"a\\\"b\\\\c\"")
    }

    /// Talks to a real sclang: runs code, answers requests, dumps the class
    /// library and renders a help page. Skips without SuperCollider.
    func testRealInterpreter() async throws {
        guard let sclang = SuperColliderToolchain.findSclang() else { throw XCTSkip("sclang not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-sclang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = SCLangSession(executable: sclang, workingDirectory: dir)
        let posts = Posts()
        session.onPost = { posts.append($0) }
        session.start()
        defer { session.stop() }
        for _ in 0..<300 where session.state != .ready { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertEqual(session.state, .ready, posts.text)

        session.evaluate("40 + 2")
        let answer = await session.request("6 * 7")
        XCTAssertEqual(answer, "42")
        XCTAssertTrue(posts.text.contains("-> 42"), posts.text)
        XCTAssertFalse(posts.text.contains("PONDSIDE"), "replies never reach the post window")
        let failed = await session.request("nil.notAMethod")
        XCTAssertEqual(failed, "", "an error still answers")

        let library = await session.classLibrary(writingTo: dir.appendingPathComponent("classes.tsv"))
        let sinOsc = library?.method("ar", of: "SinOsc", classSide: true)
        XCTAssertEqual(sinOsc?.arguments.first?.name, "freq")
        XCTAssertFalse(library?.classes["SinOsc"]?.summary.isEmpty ?? true)

        let help = await session.helpURL(for: "SinOsc", anchor: "*ar")
        XCTAssertEqual(help?.lastPathComponent, "SinOsc.html")
        XCTAssertEqual(help?.fragment, "*ar")
        if let help { XCTAssertTrue(FileManager.default.fileExists(atPath: help.path)) }
    }
}

private final class Posts: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    func append(_ s: String) { lock.lock(); buffer += s; lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
}
