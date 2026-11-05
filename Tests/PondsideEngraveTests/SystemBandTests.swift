import Foundation
import XCTest
import PondsideCore
@testable import PondsideEngrave

/// A system is as tall as its start delimiter, which spans staves the page
/// shows no lines for (an electronics staff drawn by graphics): the
/// playhead covers the whole system, not just the staves with lines.
final class SystemBandTests: XCTestCase {
    /// `hidden-staff.svg`: a staff and, below it, one with no lines
    /// (`StaffSymbol.line-count = 0`), on one system.
    func testASystemReachesItsLinelessStaff() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("hidden-staff.svg")))
        XCTAssertEqual(page.staves.count, 1)
        let staff = page.staves[0]
        XCTAssertEqual(page.systems.count, 1)
        let band = try XCTUnwrap(page.systems.first)
        XCTAssertEqual(band.lowerBound, staff.top, accuracy: 0.01)
        XCTAssertGreaterThan(band.upperBound, staff.bottom + 4, "down to the lineless staff")
    }

    /// `three-staves.svg`: two systems of three staves.
    func testSystemsOfSeveralStaves() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("three-staves.svg")))
        XCTAssertEqual(page.staves.count, 6)
        let bands = page.systems
        XCTAssertEqual(bands.count, 2)
        let sorted = page.staves.sorted { $0.top < $1.top }
        XCTAssertEqual(bands[0].lowerBound, sorted[0].top, accuracy: 0.01)
        XCTAssertEqual(bands[0].upperBound, sorted[2].bottom, accuracy: 0.1)
        XCTAssertEqual(bands[1].upperBound, sorted[5].bottom, accuracy: 0.1)
    }

    /// Single-staff systems have no delimiter: each staff is its own.
    func testWithoutDelimitersTheOldGrouping() throws {
        let page = EngravedPage(svg: try Data(contentsOf: try fixture("slur.svg")))
        XCTAssertEqual(page.systems, EngravedPage.systems(of: page.staves))
    }
}
