import Foundation
import PondsideCore
import PondsideTiming

/// What Pondside hears: the MIDI for the mockup and the timing for cues,
/// from one compile of the same music, so the two always agree.
///
/// A score with its own `\midi` plays as its author wrote it. Any other
/// gets a playback score generated at compile time by
/// `Playback/pondside-playback.ily` (repeats and tremolos played out,
/// trills as alternating notes, `\articulate`, dynamics per staff,
/// instruments from staff names, electronics silent); the user's files
/// are never edited.
public enum PlaybackScore {
    public struct Result: Sendable {
        public var timing: TimingLog
        /// The timing rows as LilyPond printed them (`TimingDump.marker` lines).
        public var timingText: String
        /// The first score's MIDI, if one was written.
        public var midi: URL?
        /// Whether Pondside generated the playback (the score has no `\midi`).
        public var generated: Bool
    }

    public static var settingsFile: URL? {
        Bundle.module.url(forResource: "pondside-playback", withExtension: "ily", subdirectory: "Playback")
    }

    /// Whether `source` needs a generated playback: no file of the score
    /// writes MIDI itself.
    public static func generates(for source: URL) -> Bool {
        !SourceGraph.load(root: source).files.contains { EngravingSettingsDocument.writesMIDI($0.text) }
    }

    /// Interprets `source` for playback (no pages are written). With
    /// `midi`, the MIDI file is moved there.
    public static func compile(_ installation: LilyPondInstallation, source: URL, midi: URL? = nil) async throws -> Result {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let generated = generates(for: source)
        var settings = TimingDump.listener
        if generated, let file = settingsFile {
            let path = file.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            settings += "\\include \"\(path)\"\n"
        }
        let settingsURL = dir.appendingPathComponent("settings.ily")
        try Data(settings.utf8).write(to: settingsURL)
        let base = dir.appendingPathComponent("out")
        let output = try await ProcessRunner.run(
            installation.executable,
            ["-dinclude-settings=\(settingsURL.path)", "-dno-print-pages", "-dbackend=null", "-o", base.path, source.path],
            currentDirectory: source.deletingLastPathComponent().path)
        guard output.status == 0 else { throw EventDump.Failure(log: output.stderrString) }
        var written: URL?
        if let midi, let made = ["midi", "mid"].map({ base.appendingPathExtension($0) })
            .first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
            try? FileManager.default.removeItem(at: midi)
            try FileManager.default.moveItem(at: made, to: midi)
            written = midi
        }
        let text = output.stdoutString
        return Result(timing: TimingLog(parsing: text, prefix: TimingDump.marker), timingText: text,
                      midi: written, generated: generated)
    }
}
