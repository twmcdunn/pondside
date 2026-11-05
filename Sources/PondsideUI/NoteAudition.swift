import Foundation
import PondsideCore
import PondsideEngrave
import os

/// Plays a newly selected note's pitch at once (View ▸ Hear Selected Notes,
/// ⌥N; on unless turned off). One fluidsynth process per app, kept running
/// with its SoundFont loaded and fed shell commands (`noteon …`) on stdin,
/// so a note sounds as soon as it is selected: nothing waits for a render.
@MainActor
final class NoteAudition {
    static let shared = NoteAudition()
    static let defaultsKey = "Pondside.hearSelectedNotes"

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.defaultsKey) as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            if !newValue { shutdown() }
        }
    }

    private var process: Process?
    private var input: FileHandle?
    private var font: URL?
    private var sounding: [Int] = []
    private var release: DispatchWorkItem?
    /// No fluidsynth or no SoundFont: looked for once per font, then quiet.
    private var missing: Set<String> = []
    private let log = Logger(subsystem: "app.pondside", category: "audition")

    private init() {
        // A write to a fluidsynth that has quit must fail, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Starts fluidsynth ahead of the first selection (loading a SoundFont
    /// takes a moment), off the main thread's critical path.
    func prepare(soundFont configured: URL?) {
        guard isEnabled else { return }
        _ = ensureRunning(soundFont: configured)
    }

    /// Sounds `pitches` (MIDI numbers) together, silencing what was sounding.
    func play(_ pitches: [Int], soundFont configured: URL?) {
        guard isEnabled, !pitches.isEmpty, let input = ensureRunning(soundFont: configured) else { return }
        release?.cancel()
        var commands = sounding.map { "noteoff 0 \($0)\n" }.joined()
        let notes = Array(Set(pitches.map { min(127, max(0, $0)) })).sorted()
        commands += notes.map { "noteon 0 \($0) 92\n" }.joined()
        guard send(commands, to: input) else { return }
        sounding = notes
        let work = DispatchWorkItem { [weak self] in
            guard let self, let input = self.input else { return }
            _ = self.send(self.sounding.map { "noteoff 0 \($0)\n" }.joined(), to: input)
            self.sounding = []
        }
        release = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: work)
    }

    func shutdown() {
        release?.cancel()
        release = nil
        sounding = []
        if let input { _ = send("quit\n", to: input); try? input.close() }
        process?.terminate()
        process = nil
        input = nil
    }

    /// The MIDI note of a resolved pitch (`c'` is 60); quarter tones round.
    static func midi(_ pitch: Pitch) -> Int {
        let natural = [0, 2, 4, 5, 7, 9, 11][pitch.step]
        return 48 + pitch.octave * 12 + natural + Int((Double(pitch.alteration) / 2).rounded())
    }

    private func send(_ commands: String, to input: FileHandle) -> Bool {
        guard !commands.isEmpty else { return true }
        do {
            try input.write(contentsOf: Data(commands.utf8))
            return true
        } catch {
            log.notice("fluidsynth stopped listening: \(String(describing: error), privacy: .public)")
            process = nil
            self.input = nil
            return false
        }
    }

    private func ensureRunning(soundFont configured: URL?) -> FileHandle? {
        guard let font = Self.soundFont(configured: configured) else { return nil }
        if let process, process.isRunning, self.font == font, let input { return input }
        shutdown()
        guard !missing.contains(font.path) else { return nil }
        guard let fluid = Self.fluidSynth() else {
            missing.insert(font.path)
            log.notice("no fluidsynth: selected notes stay silent")
            return nil
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: fluid)
        // Shell on stdin, no MIDI input, a small buffer for low latency.
        p.arguments = ["-q", "-n", "-a", "coreaudio", "-z", "256", "-g", "0.6",
                       "-o", "synth.reverb.active=0", "-o", "synth.chorus.active=0", font.path]
        let pipe = Pipe()
        p.standardInput = pipe
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.process === p else { return }
                self.process = nil
                self.input = nil
            }
        }
        do {
            try p.run()
        } catch {
            missing.insert(font.path)
            log.notice("fluidsynth did not start: \(String(describing: error), privacy: .public)")
            return nil
        }
        process = p
        input = pipe.fileHandleForWriting
        self.font = font
        return input
    }

    /// The installer's fluidsynth, else one where Homebrew or MacPorts put
    /// it (an app launched from the Finder has a short PATH).
    private static func fluidSynth() -> String? {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", env["PATH"] ?? "/usr/bin"].joined(separator: ":")
        return MockupRenderer.findFluidSynth(environment: env)
    }

    /// The score's `[audio] soundfont`, the installer's General MIDI font,
    /// a font in ~/Library/Audio/Sounds/Banks, then a shared default.sf2.
    /// Never Homebrew's fluid-synth test font: synth waves, not instruments.
    private static func soundFont(configured: URL?) -> URL? {
        let fm = FileManager.default
        var candidates: [URL] = []
        if let configured { candidates.append(configured) }
        if let bundled = BundledToolchain.soundFont() { candidates.append(bundled) }
        let banks = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Audio/Sounds/Banks")
        if let found = try? fm.contentsOfDirectory(at: banks, includingPropertiesForKeys: nil) {
            candidates += found.filter { ["sf2", "sf3"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        for prefix in ["/opt/homebrew", "/usr/local", "/opt/local"] {
            candidates.append(URL(fileURLWithPath: "\(prefix)/share/soundfonts/default.sf2"))
        }
        return candidates.first { fm.isReadableFile(atPath: $0.path) }
    }
}
