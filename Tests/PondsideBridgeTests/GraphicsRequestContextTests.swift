import Foundation
import XCTest
import PondsideCore
import PondsideEngrave
@testable import PondsideBridge

final class GraphicsRequestContextTests: XCTestCase {
    func testEndpointContextSkipsDrawingDependencies() throws {
        let text = "music = { c'1\\startFoo }"
        let files: [ScoreGraphic.File] = [("music.ly", text), ("defs.ily", "startFoo = #(make-music 'TextSpanEvent 'span-direction START)\n")]
        let position = SourceText(text).position(of: try XCTUnwrap(text.range(of: "\\startFoo")).lowerBound)
        let full = ScoreContext.describe(text: text, file: "music.ly", line: 1, character: position.character, files: files)
        let music = ScoreContext.describe(text: text, file: "music.ly", line: 1, character: position.character, files: files, includeGraphic: false)
        XCTAssertNotNil(full["graphic"])
        XCTAssertNil(music["graphic"])
        XCTAssertEqual(music["event"], full["event"])
        XCTAssertEqual(music["moment"], full["moment"])
        XCTAssertEqual(music["staff"], full["staff"])
    }

    func testFrozenContextBuildsOnWorkerAndInvalidatesCacheInputs() async throws {
        let text = "music = { c'4 d'4 e'4 f'4 }"
        let graphics = (0..<5).map { i in
            Graphic(content: .path(VectorPath([.move(Point(0, 10 + Double(i))), .line(Point(100, 10 + Double(i)))]),
                fill: nil, stroke: .black, style: StrokeStyle(width: 0.1)),
                bounds: Rect(x: 0, y: 10 + Double(i), width: 100, height: 0))
        }
        let page = EngravedPage(widthMM: 210, heightMM: 297, viewBox: Rect(x: 0, y: 0, width: 100, height: 140), graphics: graphics)
        let section = try XCTUnwrap(GraphicSection.make(pages: [page], from: (0, Point(20, 12)), to: (0, Point(70, 12)), link: nil))
        let from = GraphicsRequestContext.Source(file: "score.ly", text: text, position: .init(line: 1, character: 10))
        let to = GraphicsRequestContext.Source(file: "score.ly", text: text, position: .init(line: 1, character: 18))
        let snapshot = GraphicsRequestContext(source: from, files: [("score.ly", text)], root: ("score.ly", text), cues: nil,
            section: section, geometry: ["kind": "graphic-section", "from": ["page": 1], "to": ["page": 1], "systems": []],
            timing: nil, pages: [page], from: from, to: to, generation: 1)
        let context = await Task.detached { snapshot.describe() }.value
        XCTAssertEqual(context["selection"]?["kind"]?.string, "graphic-section")
        XCTAssertEqual(context["selection"]?["from"]?["at"]?["event"]?.string, "c'4")
        XCTAssertEqual(context["selection"]?["to"]?["at"]?["event"]?.string, "e'4")
        XCTAssertTrue(snapshot.matches(snapshot))
        var changed = snapshot
        changed.files[0].text += " % edit"
        XCTAssertFalse(snapshot.matches(changed))
        changed = snapshot
        changed.generation += 1
        XCTAssertFalse(snapshot.matches(changed))
        changed = snapshot
        changed.geometry = .null
        XCTAssertFalse(snapshot.matches(changed))
    }
}
