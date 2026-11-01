import Foundation
import PondsideCore
import PondsideTiming

/// Passages the MIDI can't play (an `\improvisation`, silent in the MIDI),
/// mixed into the mockup at their timing marks, so the mockup (and the
/// patch's mix) sounds like the piece:
///
/// - a recording per mark: for "improv 1", `improv1.wav` (or `improv 1.wav`,
///   `improv-1.wav`) in `[audio] parts`, else `improv/` or `resources/improv/`
///   beside the score. It starts at the mark and, if it runs on, fades out
///   just before the next mark of its kind ("improv end", "improv 2");
/// - or a script (`[audio] hook`), run as the older export ran it:
///   `sclang hook score.wav marks.txt out.wav partsDir`, which writes the
///   mockup with the parts in it (and may write each part to partsDir).
public enum MockupParts {
    public struct Part: Sendable, Hashable {
        public var mark: String
        public var file: URL
        public var start: Double
        /// Where it must have faded out: the next mark of its kind, a little early.
        public var until: Double?
    }

    /// Where recordings are looked for.
    public static func folders(score: URL, configured: URL?) -> [URL] {
        if let configured { return [configured] }
        let dir = score.deletingLastPathComponent()
        return ["improv", "resources/improv", "parts", "resources/parts", "patch/improv", "patch/resources/improv",
                "patch/parts", "patch/resources/parts"].map { dir.appendingPathComponent($0) }
    }

    /// The marks' recordings that exist. A mark "word N" (not "word end")
    /// names its file; `gap` seconds before the next mark of the same word
    /// it has faded out.
    public static func find(marks: [CueSheet.Mark], folders: [URL], gap: Double = 0.3) -> [Part] {
        var out: [Part] = []
        for (i, m) in marks.enumerated() {
            let words = m.text.split(separator: " ", maxSplits: 1).map(String.init)
            guard words.count == 2, words[1] != "end" else { continue }
            let names = ["\(words[0])\(words[1])", "\(words[0]) \(words[1])", "\(words[0])-\(words[1])"]
            let file = folders.lazy.flatMap { dir in names.map { dir.appendingPathComponent($0 + ".wav") } }
                .first { FileManager.default.fileExists(atPath: $0.path) }
            guard let file else { continue }
            let next = marks[(i + 1)...].first { $0.text.hasPrefix(words[0] + " ") && $0.seconds > m.seconds }
            out.append(Part(mark: m.text, file: file, start: m.seconds, until: next.map { max(m.seconds, $0.seconds - gap) }))
        }
        return out
    }

    /// Mixes `parts` into the WAV at `url` (rewritten as 32-bit float, same
    /// rate and channels). A part at another sample rate is resampled; a
    /// mono part goes to every channel.
    public static func mix(_ parts: [Part], into url: URL, fade: Double = 0.25) throws {
        guard !parts.isEmpty else { return }
        var base = try PCM(url: url)
        for p in parts {
            let part = try PCM(url: p.file)
            let ratio = Double(part.rate) / Double(base.rate)
            let frames = Int(Double(part.frames) / ratio)
            let first = Int((p.start * Double(base.rate)).rounded())
            let last = p.until.map { min(first + frames, Int(($0 * Double(base.rate)).rounded())) } ?? first + frames
            let fadeFrames = max(1, Int(fade * Double(base.rate)))
            let needed = last * base.channels
            if needed > base.samples.count { base.samples += [Float](repeating: 0, count: needed - base.samples.count) }
            guard last > first else { continue }
            for f in first..<last {
                let src = Double(f - first) * ratio
                let i0 = Int(src), t = Float(src - Double(i0))
                guard i0 < part.frames else { break }
                // fade in over 5 ms, and out before `until` when the part was cut
                var gain: Float = min(1, Float(f - first) / Float(max(1, base.rate / 200)))
                if p.until != nil, first + frames > last { gain *= min(1, Float(last - f) / Float(fadeFrames)) }
                for c in 0..<base.channels {
                    let pc = min(c, part.channels - 1)
                    let a = part.samples[i0 * part.channels + pc]
                    let b = i0 + 1 < part.frames ? part.samples[(i0 + 1) * part.channels + pc] : a
                    base.samples[f * base.channels + c] += gain * (a + (b - a) * t)
                }
            }
        }
        try base.write(to: url)
    }

    /// Runs the hook: `sclang hook wav marks out partsDir`; on success the
    /// mockup is replaced by what it wrote.
    public static func runHook(sclang: String, hook: URL, wav: URL, marks: [CueSheet.Mark], prefix: String,
                               partsDir: URL, timeout: TimeInterval = 300) async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let marksFile = dir.appendingPathComponent("marks.txt"), out = dir.appendingPathComponent("out.wav")
        let lines = marks.filter { $0.text.hasPrefix(prefix) }
            .map { String(format: "%.3f", $0.seconds) + "\t\($0.position.measure)\t\($0.text)\n" }.joined()
        try Data(lines.utf8).write(to: marksFile)
        try? FileManager.default.createDirectory(at: partsDir, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sclang)
        p.arguments = [hook.path, wav.path, marksFile.path, out.path, partsDir.path]
        p.currentDirectoryURL = hook.deletingLastPathComponent()
        let log = Pipe()
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        let collected = LogCollector()
        log.fileHandleForReading.readabilityHandler = { collected.append($0.availableData) }
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning {
            if Date() > deadline { p.terminate() }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        log.fileHandleForReading.readabilityHandler = nil
        guard FileManager.default.fileExists(atPath: out.path), let info = WAVInfo(try Data(contentsOf: out)), info.frames > 0 else {
            throw MockupError("\(hook.lastPathComponent) didn't write the mockup:\n"
                              + collected.text.split(separator: "\n").suffix(20).joined(separator: "\n"))
        }
        _ = try? FileManager.default.removeItem(at: wav)
        try FileManager.default.moveItem(at: out, to: wav)
    }

    struct MockupError: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    final class LogCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ d: Data) { lock.lock(); data.append(d); lock.unlock() }
        var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
    }
}

/// A WAV as interleaved floats: PCM 8/16/24/32-bit or IEEE float 32/64-bit
/// in, 32-bit float out.
struct PCM {
    var rate: Int
    var channels: Int
    var samples: [Float]
    var frames: Int { channels > 0 ? samples.count / channels : 0 }

    init(rate: Int, channels: Int, samples: [Float]) {
        self.rate = rate
        self.channels = channels
        self.samples = samples
    }

    init(url: URL) throws {
        let b = [UInt8](try Data(contentsOf: url))
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 3 < b.count ? u16(i) | u16(i + 2) << 16 : 0 }
        guard b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WAVE".utf8) else {
            throw MockupParts.MockupError("\(url.lastPathComponent) isn't a WAV file")
        }
        var format = 0, ch = 0, sr = 0, bits = 0
        var data: Range<Int>?
        var i = 12
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<(i + 4)], as: UTF8.self), size = u32(i + 4), body = i + 8
            if id == "fmt " {
                format = u16(body); ch = u16(body + 2); sr = u32(body + 4); bits = u16(body + 14)
                if format == 0xFFFE, size >= 26 { format = u16(body + 24) }
            } else if id == "data" {
                data = body..<min(b.count, body + size)
            }
            i = body + size + (size & 1)
        }
        guard let data, ch > 0, sr > 0, bits > 0, format == 1 || format == 3 else {
            throw MockupParts.MockupError("\(url.lastPathComponent): an unsupported WAV format")
        }
        let step = bits / 8
        var out = [Float]()
        out.reserveCapacity(data.count / step)
        var j = data.lowerBound
        while j + step <= data.upperBound {
            switch (format, bits) {
            case (1, 8): out.append((Float(b[j]) - 128) / 128)
            case (1, 16): out.append(Float(Int16(bitPattern: UInt16(u16(j)))) / 32768)
            case (1, 24):
                var x = Int(b[j]) | Int(b[j + 1]) << 8 | Int(b[j + 2]) << 16
                if x & 0x80_0000 != 0 { x -= 0x100_0000 }
                out.append(Float(x) / 8_388_608)
            case (1, 32): out.append(Float(Int32(bitPattern: UInt32(u32(j)))) / 2_147_483_648)
            case (3, 32): out.append(Float(bitPattern: UInt32(u32(j))))
            case (3, 64):
                let bitsValue = UInt64(u32(j)) | UInt64(u32(j + 4)) << 32
                out.append(Float(Double(bitPattern: bitsValue)))
            default:
                throw MockupParts.MockupError("\(url.lastPathComponent): \(bits)-bit samples aren't supported")
            }
            j += step
        }
        rate = sr
        channels = ch
        samples = out
    }

    func write(to url: URL) throws {
        var d = Data()
        func u32(_ v: Int) { d.append(contentsOf: (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        func u16(_ v: Int) { d.append(contentsOf: (0..<2).map { UInt8((v >> (8 * $0)) & 0xFF) }) }
        let bytes = samples.count * 4
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); d.append(contentsOf: Array("WAVEfmt ".utf8))
        u32(16); u16(3); u16(channels); u32(rate); u32(rate * channels * 4); u16(channels * 4); u16(32)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        d.reserveCapacity(d.count + bytes)
        samples.withUnsafeBufferPointer { buf in
            for s in buf { let v = s.bitPattern; d.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]) }
        }
        try d.write(to: url, options: .atomic)
    }
}
