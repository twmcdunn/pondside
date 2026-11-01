import Foundation
import XCTest
import PondsideTiming
@testable import PondsideEngrave

/// Recordings of passages the MIDI can't play (improvisations), mixed into
/// the mockup at their marks.
final class MockupPartsTests: XCTestCase {
    private func temp() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-parts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("improv"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func wav(_ url: URL, seconds: Double, rate: Int = 1000, channels: Int = 2, value: Float) throws {
        try PCM(rate: rate, channels: channels, samples: [Float](repeating: value, count: Int(seconds * Double(rate)) * channels)).write(to: url)
    }

    private func sheet(_ marks: [(String, Double)]) -> [CueSheet.Mark] {
        // 60 bpm in 4/4: one second a beat.
        var text = "PONDSIDE-TIMING\t0\t1\t@0\ttempo\t60\n"
        for (t, s) in marks { text += "PONDSIDE-TIMING\t\(Rational(Int(s * 4), 16))\t1\t@0\ttext\t\(t)\n" }
        return CueSheet(log: TimingLog(parsing: text, prefix: "PONDSIDE-TIMING\t"), score: "s.ly").marks
    }

    func testARecordingStartsAtItsMarkAndEndsBeforeTheNext() throws {
        let dir = try temp()
        let marks = sheet([("improv 1", 1), ("improv end", 3), ("improv 2", 4)])
        try wav(dir.appendingPathComponent("improv/improv1.wav"), seconds: 5, channels: 1, value: 0.5)
        let parts = MockupParts.find(marks: marks, folders: MockupParts.folders(score: dir.appendingPathComponent("s.ly"), configured: nil))
        XCTAssertEqual(parts.map(\.mark), ["improv 1"], "no file for improv 2")
        XCTAssertEqual(parts[0].start, 1, accuracy: 1e-9)
        XCTAssertEqual(parts[0].until ?? 0, 2.7, accuracy: 1e-9)

        let mockup = dir.appendingPathComponent("s.wav")
        try wav(mockup, seconds: 5, value: 0)
        try MockupParts.mix(parts, into: mockup)
        let out = try PCM(url: mockup)
        func at(_ s: Double) -> Float { out.samples[Int(s * 1000) * 2 + 1] }   // right channel: the mono part in both
        XCTAssertEqual(at(0.5), 0)
        XCTAssertEqual(at(2), 0.5, accuracy: 1e-6)
        XCTAssertEqual(at(2.9), 0, "faded out before the next mark")
        XCTAssertEqual(out.frames, 5000)
    }
}
