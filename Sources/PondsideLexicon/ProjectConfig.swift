import Foundation

/// `pondside.toml` at a project's root: settings a piece needs everywhere,
/// in one human-readable, git-committable file.
///
///     [project]
///     score = "quartet.ly"        # the score a project root opens (when the folder has several)
///
///     [lilypond]
///     version = "2.26.0"          # the version this piece compiles with
///
///     [audio]
///     sample-rate = 48000         # mockup and cue samples; the quark checks it
///     renderer = "musescore"      # or "fluidsynth"
///     soundfont = "sounds/piano.sf2"
///     parts = "resources/improv"  # recordings mixed in at their marks (improv1.wav at "improv 1")
///     hook = "improv/render.scd"  # or a script that renders them: sclang hook wav marks out parts
///     hook-marks = "improv"       # the marks the hook gets (default improv)
///
///     [supercollider]
///     handlers = "patch/cues.scd" # kept in sync by `pondside handlers`
///     resources = "patch/resources"
///     path = "/Applications/SuperCollider.app" # or sclang itself; found if omitted
public struct ProjectConfig: Sendable, Hashable {
    /// The folder holding pondside.toml (relative paths resolve against it).
    public var root: URL
    /// The score the project root opens.
    public var score: URL?
    public var lilypondVersion: String?
    public var sampleRate: Int
    public var renderer: String?
    public var soundFont: URL?
    /// Recordings mixed into the mockup at their timing marks (MockupParts).
    public var parts: URL?
    /// A script that renders those parts into the mockup instead.
    public var hook: URL?
    public var hookMarks = "improv"
    public var handlers: URL?
    public var resources: URL?
    /// The SuperCollider.app or sclang the SuperCollider pane runs.
    public var sclang: URL?

    public static let fileName = "pondside.toml"

    public init(root: URL) {
        self.root = root
        self.sampleRate = 48000
    }

    public init(toml text: String, root: URL) throws {
        let doc = try TOML.parse(text)
        self.init(root: root)
        func path(_ v: TOMLValue?) -> URL? {
            guard let s = v?.string, !s.isEmpty else { return nil }
            return s.hasPrefix("/") ? URL(fileURLWithPath: s) : root.appendingPathComponent(s)
        }
        score = path(doc["project"]?["score"])
        lilypondVersion = doc["lilypond"]?["version"]?.string
        if let r = doc["audio"]?["sample-rate"]?.int {
            guard [22050, 32000, 44100, 48000, 88200, 96000, 176400, 192000].contains(r) else {
                throw TOMLError(line: 0, message: "audio.sample-rate \(r) is not a standard rate")
            }
            sampleRate = r
        }
        renderer = doc["audio"]?["renderer"]?.string
        soundFont = path(doc["audio"]?["soundfont"])
        parts = path(doc["audio"]?["parts"])
        hook = path(doc["audio"]?["hook"])
        if let m = doc["audio"]?["hook-marks"]?.string { hookMarks = m }
        handlers = path(doc["supercollider"]?["handlers"])
        resources = path(doc["supercollider"]?["resources"])
        sclang = path(doc["supercollider"]?["path"])
    }

    /// The nearest pondside.toml at or above `start` (a file or a folder);
    /// defaults rooted at the score's folder when there is none.
    public static func find(from start: URL) throws -> ProjectConfig {
        var dir = start.hasDirectoryPath ? start : start.deletingLastPathComponent()
        let fallback = dir
        while true {
            let candidate = dir.appendingPathComponent(fileName)
            if let data = FileManager.default.contents(atPath: candidate.path) {
                return try ProjectConfig(toml: String(decoding: data, as: UTF8.self), root: dir)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path || dir.path == "/" { return ProjectConfig(root: fallback) }
            dir = parent
        }
    }
}

extension ProjectConfig {
    /// `text` (a pondside.toml, possibly empty) with `[lilypond] version`
    /// set to `version`, changing only that line or adding it.
    public static func settingLilyPond(version: String, in text: String) -> String {
        setting(section: "lilypond", key: "version", value: version, in: text)
    }

    /// `text` with `[section] key = "value"` set, changing only that line
    /// or adding it (and the table, if missing).
    public static func setting(section: String, key: String, value: String, in text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.last == "" { lines.removeLast() }
        let table = lines.firstIndex { $0.trimmingCharacters(in: .whitespaces) == "[\(section)]" }
        let entry = "\(key) = \"\(value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\""))\""
        func isKey(_ line: String) -> Bool {
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix(key) && t.dropFirst(key.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }
        if let table {
            var i = table + 1
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                if isKey(lines[i]) { lines[i] = entry; return lines.joined(separator: "\n") + "\n" }
                i += 1
            }
            lines.insert(entry, at: table + 1)
        } else {
            if !lines.isEmpty { lines.append("") }
            lines += ["[\(section)]", entry]
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
