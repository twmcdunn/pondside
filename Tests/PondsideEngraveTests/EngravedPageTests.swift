import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

func fixture(_ name: String) throws -> URL {
    let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures")
    return try XCTUnwrap(url, "missing fixture \(name)")
}

/// Fixtures are real LilyPond 2.24 output (`-dbackend=svg -dpoint-and-click`)
/// with the absolute source directory rewritten to /fixtures/.
final class EngravedPageTests: XCTestCase {
    func testParsesPageGeometry() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("etude.svg")))
        XCTAssertEqual(page.widthMM, 210, accuracy: 0.001)
        XCTAssertEqual(page.heightMM, 297, accuracy: 0.001)
        XCTAssertEqual(page.viewBox.width, 119.5016, accuracy: 0.0001)
        XCTAssertEqual(page.viewBox.height, 169.0094, accuracy: 0.0001)
        XCTAssertEqual(page.graphics.count, 47) // every drawable element in the fixture
        XCTAssertTrue(page.unsupportedElements.isEmpty)
    }

    func testPointAndClickLinks() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("etude.svg")))
        let linked = page.graphics.filter { $0.link != nil }
        XCTAssertGreaterThanOrEqual(linked.count, 18)
        XCTAssertTrue(linked.allSatisfy { $0.link?.path == "/fixtures/t.ly" })

        // The `b` in `\tuplet 3/2 { a,8 b c }` on line 5.
        let b = page.linkedGraphics(at: SourcePosition(line: 5, character: 20))
        XCTAssertEqual(b.count, 1)
        let bounds = b[0].bounds
        XCTAssertTrue(bounds.contains(Point(62.1, 11.61)), "\(bounds)")
        XCTAssertLessThan(bounds.width, 2.5)

        XCTAssertEqual(page.hitTest(Point(62.1, 11.61))?.link?.position, SourcePosition(line: 5, character: 20))
        XCTAssertNil(page.hitTest(Point(1, 1)))
        XCTAssertEqual(page.linkedPositions(onLine: 4), [1, 4, 6, 7, 9, 14, 16, 19, 23, 25, 28, 31])
    }

    /// A texture of dots (closer than `clusterGap`) broken across two
    /// systems: a click between its dots finds it, a click between the systems doesn't.
    func testRegionHitFindsTexturesBetweenTheirParts() {
        func dots(_ ys: [Double]) -> String {
            ys.flatMap { y in [20.0, 21.2, 22.4].map { x in "<g transform=\"translate(\(x), \(y))\"><circle r=\"0.06\" fill=\"currentColor\"/></g>" } }
                .joined(separator: "\n")
        }
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="210.00mm" height="297.00mm" viewBox="0 0 119.5 169">
        <a style="color:inherit;" xlink:href="textedit:///s/graphics.ly:3:20:21">
        \(dots([10, 11, 12]))
        \(dots([40, 41.5]))
        </a>
        <a style="color:inherit;" xlink:href="textedit:///s/graphics.ly:4:2:3">
        <g transform="translate(60, 60)"><circle r="0.5" fill="currentColor"/></g>
        </a>
        </svg>
        """
        let page = EngravedPage(svg: Data(svg.utf8))
        XCTAssertNil(page.hitTest(Point(20.6, 11)), "nothing is directly under the click")
        XCTAssertEqual(page.regionHit(Point(20.6, 11))?.link?.position, SourcePosition(line: 3, character: 20))
        XCTAssertEqual(page.regionHit(Point(20.6, 41))?.link?.position, SourcePosition(line: 3, character: 20))
        XCTAssertNil(page.regionHit(Point(20.6, 25)), "between the systems")
        XCTAssertNil(page.regionHit(Point(60, 60)), "a single graphic is hit-tested directly, not as a region")
        let linked = page.graphics.filter { $0.link?.line == 3 }
        XCTAssertEqual(EngravedPage.regions(of: linked).count, 2)
    }

    func testTextRuns() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("etude.svg")))
        let texts: [TextRun] = page.graphics.compactMap {
            if case .text(let t) = $0.content { return t } else { return nil }
        }
        let title = try XCTUnwrap(texts.first { $0.string == "Étude" })
        XCTAssertTrue(title.bold)
        XCTAssertEqual(title.fontFamily, "serif")
        XCTAssertEqual(title.fontSize, 3.4929, accuracy: 0.0001)
        XCTAssertEqual(title.transform.e, 54.0147, accuracy: 0.0001)
        XCTAssertTrue(texts.contains { $0.string == "3" && $0.italic })
    }

    func testShapesColorsAndDashes() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("shapes.svg")))
        var sawRed = false, sawBlue = false, sawDash = false, sawUnfilledCircle = false
        for g in page.graphics {
            guard case let .path(_, fill, stroke, style) = g.content else { continue }
            if fill == RGBA(1, 0, 0) || stroke == RGBA(1, 0, 0) { sawRed = true }
            if fill == RGBA(0, 0, 1) { sawBlue = true }
            if !style.dash.isEmpty { sawDash = true }
            if fill == nil, stroke != nil, abs(g.bounds.width - 2.1) < 0.01 { sawUnfilledCircle = true }
        }
        XCTAssertTrue(sawRed, "user colours are preserved, never replaced")
        XCTAssertTrue(sawBlue)
        XCTAssertTrue(sawDash)
        XCTAssertTrue(sawUnfilledCircle)
    }
}

final class VectorPathTests: XCTestCase {
    func testRelativeCommandsAndImplicitRepeats() {
        let p = VectorPath(svgPathData: "m10 10 5 0 0 5zM0 0h3v4H0V0")
        XCTAssertEqual(p.elements, [
            .move(Point(10, 10)), .line(Point(15, 10)), .line(Point(15, 15)), .close,
            .move(Point(0, 0)), .line(Point(3, 0)), .line(Point(3, 4)), .line(Point(0, 4)), .line(Point(0, 0)),
        ])
    }

    func testCompactNumberSyntax() {
        // "108-36" is two numbers; "1.5.5" is 1.5 and .5; exponents too.
        let p = VectorPath(svgPathData: "M108-36L1.5.5L1e1-2E-1")
        XCTAssertEqual(p.elements, [.move(Point(108, -36)), .line(Point(1.5, 0.5)), .line(Point(10, -0.2))])
    }

    func testSmoothCubicReflectsControlPoint() {
        let p = VectorPath(svgPathData: "M0 0C0 1 1 1 1 0S2 -1 2 0")
        guard case let .cubic(c1, _, to) = p.elements[2] else { return XCTFail("expected cubic") }
        XCTAssertEqual(c1, Point(1, -1))
        XCTAssertEqual(to, Point(2, 0))
    }

    func testArcEndsAtTarget() {
        let p = VectorPath(svgPathData: "M0 0A5 5 0 0 1 10 0")
        guard case let .cubic(_, _, end)? = p.elements.last else { return XCTFail("expected cubic") }
        XCTAssertEqual(end.x, 10, accuracy: 1e-9)
        XCTAssertEqual(end.y, 0, accuracy: 1e-9)
        // A sweep-flag-1 semicircle from (0,0) to (10,0) bulges towards -y.
        XCTAssertLessThan(p.controlBounds!.minY, -4.9)
    }

    func testMalformedInputTerminates() {
        _ = VectorPath(svgPathData: "M 1 2 L - x C")
        _ = VectorPath(svgPathData: "12 13 14")
        _ = VectorPath(svgPathData: "M1 1 A 1 1 0 2 2 3 3")
    }

    func testTransformComposition() {
        // translate(10, 20) scale(2): scale applies first.
        let t = SVGTransformParsing.parse("translate(10, 20) scale(2)")
        XCTAssertEqual(t.apply(Point(1, 1)), Point(12, 22))
        let r = SVGTransformParsing.parse("rotate(90)")
        XCTAssertEqual(r.apply(Point(1, 0)).x, 0, accuracy: 1e-12)
        XCTAssertEqual(r.apply(Point(1, 0)).y, 1, accuracy: 1e-12)
    }
}

final class XMLTokenizerTests: XCTestCase {
    func testEntitiesCDATAAndComments() {
        var t = XMLTokenizer("<!-- c --><a x=\"1 &amp; 2\" y='&#x41;'/><s><![CDATA[a<b]]></s><t>&lt;&#233;</t>")
        var tokens: [XMLTokenizer.Token] = []
        while let tok = t.next() { tokens.append(tok) }
        XCTAssertEqual(tokens, [
            .start(name: "a", attributes: ["x": "1 & 2", "y": "A"], selfClosing: true),
            .start(name: "s", attributes: [:], selfClosing: false), .text("a<b"), .end(name: "s"),
            .start(name: "t", attributes: [:], selfClosing: false), .text("<é"), .end(name: "t"),
        ])
    }
}
