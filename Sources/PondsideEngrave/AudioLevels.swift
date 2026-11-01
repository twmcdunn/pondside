import Foundation

/// RMS and peak levels of a stretch of a WAV file, for `patch_check`: what
/// a change to the patch did to the sound at a cue, as numbers an agent can
/// read (the mix is the patch rendered against the mockup).
public enum AudioLevels {
    public struct Level: Sendable, Hashable {
        public var rms: Double
        public var peak: Double
        /// dBFS, floored at −120.
        public var rmsDB: Double { Self.db(rms) }
        public var peakDB: Double { Self.db(peak) }
        static func db(_ x: Double) -> Double { x > 1e-6 ? 20 * log10(x) : -120 }

        public var description: String { String(format: "RMS %.1f dBFS, peak %.1f", rmsDB, peakDB) }
    }

    /// PCM samples (all channels interleaved, as −1…1) of `url` between
    /// `from` and `to` seconds, with the rate and channel count. 16, 24 and
    /// 32-bit integer and 32-bit float WAV.
    public static func samples(_ url: URL, from: Double, to: Double) -> (samples: [Float], rate: Int, channels: Int)? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 1 << 16), head.count > 44 else { return nil }
        let b = [UInt8](head)
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard String(decoding: b[0..<4], as: UTF8.self) == "RIFF", String(decoding: b[8..<12], as: UTF8.self) == "WAVE" else { return nil }
        var i = 12
        var format = 0, channels = 0, rate = 0, bits = 0
        var dataStart = 0, dataSize = 0
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<(i + 4)], as: UTF8.self), size = u32(i + 4)
            if id == "fmt " {
                format = u16(i + 8)
                channels = u16(i + 10)
                rate = u32(i + 12)
                bits = u16(i + 22)
                // WAVE_FORMAT_EXTENSIBLE: the sub-format's first two bytes.
                if format == 0xFFFE, size >= 26 { format = u16(i + 32) }
            } else if id == "data" {
                dataStart = i + 8
                dataSize = size
                break
            }
            i += 8 + size + (size & 1)
        }
        guard dataStart > 0, channels > 0, rate > 0, [16, 24, 32].contains(bits), format == 1 || (format == 3 && bits == 32) else { return nil }
        let frameBytes = channels * bits / 8
        let total = (dataSize > 0 && dataSize < Int(UInt32.max) ? dataSize : Int.max) / frameBytes
        let first = max(0, min(total, Int(from * Double(rate)))), last = max(first, min(total, Int(to * Double(rate))))
        guard last > first else { return ([], rate, channels) }
        try? h.seek(toOffset: UInt64(dataStart + first * frameBytes))
        guard let data = try? h.read(upToCount: (last - first) * frameBytes) else { return nil }
        let d = [UInt8](data)
        let n = d.count / (bits / 8)
        var out = [Float](repeating: 0, count: n)
        switch (format, bits) {
        case (1, 16):
            for k in 0..<n { out[k] = Float(Int16(bitPattern: UInt16(d[2 * k]) | UInt16(d[2 * k + 1]) << 8)) / 32768 }
        case (1, 24):
            for k in 0..<n {
                let v = Int32(d[3 * k]) | Int32(d[3 * k + 1]) << 8 | Int32(d[3 * k + 2]) << 16
                out[k] = Float((v << 8) >> 8) / 8_388_608
            }
        case (1, 32):
            for k in 0..<n {
                let v = UInt32(d[4 * k]) | UInt32(d[4 * k + 1]) << 8 | UInt32(d[4 * k + 2]) << 16 | UInt32(d[4 * k + 3]) << 24
                out[k] = Float(Int32(bitPattern: v)) / 2_147_483_648
            }
        default:
            for k in 0..<n {
                let v = UInt32(d[4 * k]) | UInt32(d[4 * k + 1]) << 8 | UInt32(d[4 * k + 2]) << 16 | UInt32(d[4 * k + 3]) << 24
                out[k] = Float(bitPattern: v)
            }
        }
        return (out, rate, channels)
    }

    public static func level(_ samples: [Float]) -> Level {
        guard !samples.isEmpty else { return Level(rms: 0, peak: 0) }
        var sum = 0.0, peak: Float = 0
        for s in samples {
            sum += Double(s) * Double(s)
            peak = max(peak, abs(s))
        }
        return Level(rms: (sum / Double(samples.count)).squareRoot(), peak: Double(peak))
    }

    public static func level(_ url: URL, from: Double, to: Double) -> Level? {
        samples(url, from: from, to: to).map { level($0.samples) }
    }

    /// The level of `a − b` (the mix minus the mockup: the electronics
    /// alone), when the two have the same rate and channels.
    public static func difference(_ a: URL, _ b: URL, from: Double, to: Double) -> Level? {
        guard let x = samples(a, from: from, to: to), let y = samples(b, from: from, to: to),
              x.rate == y.rate, x.channels == y.channels else { return nil }
        let n = min(x.samples.count, y.samples.count)
        return level((0..<n).map { x.samples[$0] - y.samples[$0] })
    }
}
