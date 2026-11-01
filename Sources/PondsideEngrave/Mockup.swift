import Foundation
import PondsideCore

/// What a WAV file holds, measured: enough to refuse a silent render (the
/// documented failure of Muse Sounds from the command line) and a render at
/// the wrong sample rate (which would transpose everything in the patch).
public struct WAVInfo: Hashable, Sendable {
    public var sampleRate: Int
    public var channels: Int
    public var frames: Int
    /// Largest absolute sample, 0…1.
    public var peak: Double
    public var rms: Double

    public var seconds: Double { sampleRate > 0 ? Double(frames) / Double(sampleRate) : 0 }
    /// Below −80 dBFS everywhere.
    public var isSilent: Bool { peak < 1e-4 }

    /// Reads PCM (8/16/24/32-bit) or IEEE float (32/64-bit) WAV data.
    public init?(_ data: Data) {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { i + 1 < b.count ? Int(b[i]) | Int(b[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 3 < b.count ? u16(i) | u16(i + 2) << 16 : 0 }
        guard b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8), Array(b[8..<12]) == Array("WAVE".utf8) else { return nil }
        var format = 0, channels = 0, rate = 0, bits = 0
        var dataRange: Range<Int>?
        var i = 12
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<(i + 4)], as: UTF8.self)
            let size = u32(i + 4)
            let body = i + 8
            if id == "fmt " {
                format = u16(body)
                channels = u16(body + 2)
                rate = u32(body + 4)
                bits = u16(body + 14)
                if format == 0xFFFE, size >= 26 { format = u16(body + 24) }   // WAVE_FORMAT_EXTENSIBLE
            } else if id == "data" {
                dataRange = body..<min(b.count, body + size)
            }
            i = body + size + (size & 1)
        }
        guard let dataRange, channels > 0, bits > 0, format == 1 || format == 3 else { return nil }
        let bytesPerSample = bits / 8
        let count = dataRange.count / bytesPerSample
        var peak = 0.0, sumSquares = 0.0
        var j = dataRange.lowerBound
        for _ in 0..<count {
            let v: Double
            switch (format, bits) {
            case (1, 8): v = (Double(b[j]) - 128) / 128
            case (1, 16): v = Double(Int16(bitPattern: UInt16(u16(j)))) / 32768
            case (1, 24):
                var x = Int(b[j]) | Int(b[j + 1]) << 8 | Int(b[j + 2]) << 16
                if x & 0x80_0000 != 0 { x -= 0x100_0000 }
                v = Double(x) / 8_388_608
            case (1, 32): v = Double(Int32(bitPattern: UInt32(u32(j)))) / 2_147_483_648
            case (3, 32): v = Double(Float(bitPattern: UInt32(u32(j))))
            case (3, 64):
                let lo = UInt64(u32(j)), hi = UInt64(u32(j + 4))
                v = Double(bitPattern: lo | hi << 32)
            default: return nil
            }
            peak = max(peak, abs(v))
            sumSquares += v * v
            j += bytesPerSample
        }
        self.sampleRate = rate
        self.channels = channels
        self.frames = count / channels
        self.peak = peak
        self.rms = count > 0 ? (sumSquares / Double(count)).squareRoot() : 0
    }
}

/// Renders the acoustic parts' audio from LilyPond's MIDI, for SuperCollider
/// to play the cues against (DESIGN.md §5, M8).
///
/// MuseScore 4 first (Muse Sounds, the realistic option), fluidsynth with a
/// SoundFont as the fallback, and every result checked: a silent file or a
/// wrong sample rate is an error with a way out, never a quiet success.
public struct MockupRenderer: Sendable {
    public enum Renderer: String, Sendable, CaseIterable { case musescore, fluidsynth }

    public struct Failure: Error, CustomStringConvertible {
        public var description: String
    }

    public var sampleRate: Int
    public var soundFont: URL?
    public var cacheDirectory: URL

    public init(sampleRate: Int = 48000, soundFont: URL? = nil, cacheDirectory: URL? = nil) {
        self.sampleRate = sampleRate
        self.soundFont = soundFont ?? BundledToolchain.soundFont()
        self.cacheDirectory = cacheDirectory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mockups")
    }

    /// MuseScore's command-line binary, where it usually lives.
    public static func findMuseScore(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        var candidates = [
            "/Applications/MuseScore 4.app/Contents/MacOS/mscore",
            "/Applications/MuseScore 3.app/Contents/MacOS/mscore",
        ]
        for dir in (environment["PATH"] ?? "/usr/bin:/usr/local/bin:/opt/homebrew/bin").split(separator: ":") {
            for name in ["mscore4portable", "mscore4", "mscore", "musescore"] { candidates.append("\(dir)/\(name)") }
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The installer's fluidsynth first (built for every supported macOS),
    /// then one on PATH.
    public static func findFluidSynth(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        BundledToolchain.fluidSynth() ?? (environment["PATH"] ?? "/usr/bin:/usr/local/bin:/opt/homebrew/bin").split(separator: ":")
            .map { "\($0)/fluidsynth" }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// The cache key: the MIDI's bytes and every setting that changes the audio.
    func cacheKey(midi: Data, renderer: Renderer) -> String {
        var h = ContentHash(bytes: midi).description
        h += "-\(renderer.rawValue)-\(sampleRate)"
        if renderer == .fluidsynth, let soundFont { h += "-" + ContentHash(soundFont.path).description }
        return h
    }

    /// Renders `midi` to `output`, trying MuseScore then fluidsynth unless
    /// `only` names one. Returns what was written, measured.
    public func render(midi: URL, to output: URL, only: Renderer? = nil) async throws -> (Renderer, WAVInfo) {
        let midiData = try Data(contentsOf: midi)
        var problems: [String] = []
        for renderer in only.map({ [$0] }) ?? Renderer.allCases {
            let key = cacheKey(midi: midiData, renderer: renderer)
            let cached = cacheDirectory.appendingPathComponent(key + ".wav")
            if let data = try? Data(contentsOf: cached), let info = WAVInfo(data), !info.isSilent, info.sampleRate == sampleRate {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.copyItem(at: cached, to: output)
                return (renderer, info)
            }
            do {
                let info = try await run(renderer, midi: midi, output: output)
                if info.isSilent {
                    problems.append("\(renderer.rawValue) wrote silence (a known MuseScore command-line failure with Muse Sounds)")
                    continue
                }
                if info.sampleRate != sampleRate {
                    problems.append("\(renderer.rawValue) rendered at \(info.sampleRate) Hz, not the project's \(sampleRate) Hz; set MuseScore's export sample rate or use fluidsynth")
                    continue
                }
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try? FileManager.default.removeItem(at: cached)
                try? FileManager.default.copyItem(at: output, to: cached)
                return (renderer, info)
            } catch {
                problems.append("\(renderer.rawValue): \(error)")
            }
        }
        throw Failure(description: "no usable mockup:\n- " + problems.joined(separator: "\n- "))
    }

    func run(_ renderer: Renderer, midi: URL, output: URL) async throws -> WAVInfo {
        try? FileManager.default.removeItem(at: output)
        let result: ProcessOutput
        switch renderer {
        case .musescore:
            guard let mscore = Self.findMuseScore() else { throw Failure(description: "MuseScore is not installed") }
            result = try await ProcessRunner.run(mscore, ["-o", output.path, midi.path])
        case .fluidsynth:
            guard let fluid = Self.findFluidSynth() else { throw Failure(description: "fluidsynth is not installed (run the Pondside installer, or brew install fluid-synth)") }
            guard let soundFont else { throw Failure(description: "fluidsynth needs a SoundFont (--soundfont path.sf2)") }
            result = try await ProcessRunner.run(fluid, ["-ni", "-F", output.path, "-r", String(sampleRate), soundFont.path, midi.path])
        }
        guard let data = try? Data(contentsOf: output), let info = WAVInfo(data) else {
            throw Failure(description: "no WAV was written (exit \(result.status)): " + result.stderrString.suffix(400))
        }
        return info
    }
}

/// Small, exact edits to rendered audio and to LilyPond's MIDI.
public enum AudioFiles {
    /// Pads a PCM WAV with silence to `seconds` (the score's `end` mark),
    /// so the mockup lasts as long as the piece. Returns whether it grew.
    @discardableResult
    public static func padWAV(_ url: URL, toSeconds seconds: Double) throws -> Bool {
        var b = [UInt8](try Data(contentsOf: url))
        func u16(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        func put32(_ v: Int, at i: Int) { for k in 0..<4 { b[i + k] = UInt8((v >> (8 * k)) & 0xFF) } }
        guard b.count >= 12, Array(b[0..<4]) == Array("RIFF".utf8) else { return false }
        var i = 12, channels = 0, rate = 0, bits = 0, dataAt: Int?
        while i + 8 <= b.count {
            let id = String(decoding: b[i..<(i + 4)], as: UTF8.self), size = u32(i + 4)
            if id == "fmt " { channels = u16(i + 10); rate = u32(i + 12); bits = u16(i + 22) }
            if id == "data" { dataAt = i; break }
            i += 8 + size + (size & 1)
        }
        guard let dataAt, channels > 0, rate > 0, bits > 0 else { return false }
        let frameBytes = channels * bits / 8
        let have = u32(dataAt + 4) / frameBytes
        let want = Int((seconds * Double(rate)).rounded(.up))
        guard want > have else { return false }
        let end = dataAt + 8 + have * frameBytes
        // 8-bit PCM is unsigned: its silence is 128.
        let silence: UInt8 = bits == 8 ? 128 : 0
        b.insert(contentsOf: [UInt8](repeating: silence, count: (want - have) * frameBytes), at: end)
        put32(want * frameBytes, at: dataAt + 4)
        put32(b.count - 8, at: 4)
        try Data(b).write(to: url, options: .atomic)
        return true
    }

    /// The tracks of a format-1 standard MIDI file, with their names (the
    /// staves, as LilyPond writes them; the first is the tempo track).
    public static func midiTracks(_ data: Data) -> (header: [UInt8], tracks: [(name: String, bytes: [UInt8])])? {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3]) }
        guard b.count >= 14, Array(b[0..<4]) == Array("MThd".utf8) else { return nil }
        let headerEnd = 8 + u32(4)
        var tracks: [(String, [UInt8])] = []
        var i = headerEnd
        while i + 8 <= b.count, Array(b[i..<(i + 4)]) == Array("MTrk".utf8) {
            let size = u32(i + 4)
            let chunk = Array(b[i..<min(b.count, i + 8 + size)])
            // The first track-name meta event (FF 03 len text), if any.
            var name = ""
            if let at = (8..<max(8, chunk.count - 3)).first(where: { chunk[$0] == 0xFF && chunk[$0 + 1] == 0x03 }) {
                let len = Int(chunk[at + 2])
                if at + 3 + len <= chunk.count { name = String(decoding: chunk[(at + 3)..<(at + 3 + len)], as: UTF8.self) }
            }
            tracks.append((name, chunk))
            i += 8 + size
        }
        return (Array(b[0..<headerEnd]), tracks)
    }

    /// A MIDI file with the tempo track and only track `keep`.
    public static func midi(_ data: Data, keepingTrack keep: Int) -> Data? {
        guard let (header, tracks) = midiTracks(data), tracks.indices.contains(keep), keep > 0 else { return nil }
        var h = header
        h[10] = 0; h[11] = 2   // two tracks
        return Data(h + tracks[0].bytes + tracks[keep].bytes)
    }
}
