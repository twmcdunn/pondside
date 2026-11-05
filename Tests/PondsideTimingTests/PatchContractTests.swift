import XCTest
import Foundation
import PondsideCore
@testable import PondsideTiming

final class PatchContractTests: XCTestCase {
    func testStarterIsOnePreparedMainBlock() {
        let text = HandlerSync.patchStarter(CueSheet(log: TimingLog(rows: []), score: "s.ly"), name: "s")
        XCTAssertEqual(SCRegion.topLevelBlocks(in: text).count, 1)
        XCTAssertNotNil(PatchContract.mainBlock(in: text))
        XCTAssertTrue(PatchContract.issues(in: text).isEmpty)
        XCTAssertTrue(text.hasPrefix("// @pondside patch for s.ly. Execute"))
        XCTAssertEqual(PatchContract.consolidate(text, score: "s.ly"), text)
    }
    func testLegacyBootCallbacksStayInsidePreparation() {
        let old = "(s.options.memSize = 12345; s.boot;)\n(s.waitForBoot({ var local = 1; ~prepared = local; });)\n~triggerCue.();\n"
        let text = PatchContract.consolidate(old, score: "s.ly")
        XCTAssertEqual(SCRegion.topLevelBlocks(in: text).count, 1)
        XCTAssertEqual(text.components(separatedBy: "s.waitForBoot").count, 2)
        XCTAssertTrue(text.contains("var local = 1; ~prepared = local;"))
        XCTAssertFalse(text.contains("s.boot;"))
        XCTAssertTrue(PatchContract.issues(in: text).isEmpty)
    }
    func testLooseAndMisplacedPreparationIsRejected() {
        let main = PatchContract.initialization(body: HandlerSync.cuesAnchor, score: "s.ly")
        XCTAssertFalse(PatchContract.issues(in: main + "\n~outside = Buffer.alloc(s, 1024);\n").isEmpty)
        let misplaced = main.replacingOccurrences(of: "s.options.memSize", with: "~outside = Synth(\\test);\ns.options.memSize")
        XCTAssertFalse(PatchContract.issues(in: misplaced).isEmpty)
    }
    func testSoundRootsAndEscapes() {
        XCTAssertTrue(PatchContract.resourceIssues(in: "Buffer.read(s, ~resources +/+ \"child/a.wav\");").isEmpty)
        XCTAssertTrue(PatchContract.resourceIssues(in: "Buffer.read(s, ~sharedSounds +/+ \"a.wav\");").isEmpty)
        XCTAssertFalse(PatchContract.resourceIssues(in: "Buffer.read(s, ~resources +/+ \"../a.wav\");").isEmpty)
        XCTAssertFalse(PatchContract.resourceIssues(in: "~resources; Buffer.read(s, \"/tmp/a.wav\");").isEmpty)
    }
}
