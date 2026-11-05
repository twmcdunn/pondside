import Foundation
import PondsideCore

/// The executable, headless performance contract shared by the editor,
/// patch agent, offline renderer and exported performance application.
public enum PatchContract {
    public static let marker = "// @pondside init v2"
    public static let readyMarker = "PONDSIDE_PREPARED"
    public static let notice = "Keep the patch performance-ready: one main block configures s.options, reboots s, and waits for boot before all mode/dependency/buffer/SynthDef/pattern/cue/startup-synth preparation; afterward only ~triggerCue.() is needed. Sounds, except the mockup, belong under patch/resources or Platform.userAppSupportDir +/+ \"sounds\", including their child folders. Preserve the engine and cue contracts; read pondside://patch-contract."

    public static let documentation = #"""
    # Performance-ready SuperCollider contract

    \#(notice)

    Execute the main `( ... )` block once. It configures `s.options` before
    `s.reboot`; its reboot callback registers `s.waitForBoot`, and ALL required
    preparation happens in that waitForBoot function: `~mode`, dependencies,
    buffers, buses, Pbinds/functions, SynthDefs, cue handlers, MIDI setup and any
    synths needed from the start. End preparation with `s.sync`. Only after
    PONDSIDE_PREPARED has printed may the performer call `~triggerCue.()`.
    A usage comment at the top of the main file explains these two actions.

    Use `~mode = ~pondsideMode ? \live` inside preparation. The offline renderer
    supplies `~pondsideMode = \mockup`; the performance app supplies `\live`.
    The renderer supplies `~renderClock`; do not replace either override.
    Pondside's engine is `patch/dependencies/pondside.scd`; leave it generated.
    Cue functions are `~cue[\cueN] = { |cue| ... }`, under their existing markers.
    Effects on the performer read `In.ar(~live)`. The engine controls cue order
    and the score clock; there must be no second timing/cue pipeline.

    Non-mockup sound files live ONLY in `patch/resources/` (or its children),
    referenced with `~resources`, or in `Platform.userAppSupportDir +/+ "sounds"`
    (or its children), referenced with `~sharedSounds`. No Desktop, Downloads,
    SuperCollider application-bundle sounds, or other absolute paths. A dependency
    resolves paths relative to itself, but the allowed resource root is still the
    main patch's resources directory. Never use `..` to escape either sound root.

    Required dependencies must load during main preparation, with resolved paths
    captured before asynchronous boot callbacks. Use `s.sync` after loading buffers
    and SynthDefs, before starting synths that depend on them. Keep required setup
    out of loose lines and auxiliary blocks. Optional IDE-only GUI/recording may
    remain in explicitly live-only blocks, but exported apps have no Qt and cannot
    require them. Performance-app controls belong in Swift, not SC GUI classes.

    Agents edit atomically, preserve this block and paths on EVERY change, use
    sc_lexicon_add for shared effects, patch_check for verification, and patch_note
    for intent. Read existing numbered context and make the smallest adequate edit;
    do not re-read the project or run extra checks after a clean patch_check.

    Further details: docs/SUPERCOLLIDER.md in Pondside's source repository.
    """#

    public static var sharedSounds: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share"))
            .appendingPathComponent("SuperCollider/sounds", isDirectory: true)
    }

    public struct Failure: Error, Sendable, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    /// A single evaluation prepares the complete patch; live cues are always
    /// fired manually. The offline render supplies ~renderClock and overrides
    /// ~pondsideMode before evaluating this same block.
    public static func initialization(body: String, options: String = "s.options.memSize = 262144;\ns.options.numWireBufs = 1024;", score: String) -> String {
        """
        \(HandlerSync.patchMarker) for \(score). Execute the main block once; then ~triggerCue.() fires each live cue.
        \(marker)
        (
        var patchFile = thisProcess.nowExecutingPath, patchFolder, prepare;
        patchFolder = patchFile.dirname;
        \(options)
        prepare = {
        s.waitForBoot({
        thisProcess.nowExecutingPath = patchFile;
        ~mode = ~pondsideMode ? \\live; // \\live or \\mockup; the renderer/exporter may override it.
        ~resources = patchFolder +/+ "resources";
        ~sharedSounds = Platform.userAppSupportDir +/+ "sounds";
        (patchFolder +/+ "\(HandlerSync.Layout.engineFile)").load;
        \(body)
        s.sync;
        "\(readyMarker)".postln;
        });
        };
        // reboot's callback runs while the server is off, so preparation can
        // never run against the server that is about to be replaced.
        if(~renderClock.notNil) { prepare.value } { s.reboot(prepare) };
        )
        // After the main block is ready: ~triggerCue.();  // next live cue
        // ~triggerCue.(12);  // jump to cue 12
        // ~stop.();
        """
    }

    public static func mainBlock(in text: String) -> Range<Int>? {
        guard text.contains(marker) else { return nil }
        return SCRegion.topLevelBlocks(in: text).first { range in
            let block = (text as NSString).substring(with: NSRange(location: range.lowerBound, length: range.count))
            return block.contains("s.waitForBoot") && block.contains("s.reboot")
        }
    }

    public static func isLiveOnly(_ range: Range<Int>, in text: String) -> Bool {
        let body = (text as NSString).substring(with: NSRange(location: range.lowerBound + 1, length: max(0, range.count - 2)))
        return body.split(separator: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces).hasPrefix(HandlerSync.liveOnlyMarker) == true
    }

    /// Normalize old multi-block Pondside patches without reprinting user
    /// functions. Each original block keeps its local scope and its comments.
    public static func consolidate(_ text: String, score: String) -> String {
        let ranges = SCRegion.topLevelBlocks(in: text)
        let required = ranges.filter { !isLiveOnly($0, in: text) }
        if required.count == 1, mainBlock(in: text) == required.first { return text }
        let ns = text as NSString
        var options: [String] = []
        var bodies: [String] = []
        var live: [String] = []
        func replace(_ pattern: String, in value: String, template: String = "") -> String {
            guard let re = try? NSRegularExpression(pattern: pattern) else { return value }
            return re.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
        }
        func append(_ original: String, canonical: Bool = false) {
            var body = original
            let optionRE = try! NSRegularExpression(pattern: #"(?m)^\s*s\.options\.[A-Za-z][A-Za-z0-9_]*\s*=\s*[^;]+;"#)
            for match in optionRE.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
                options.append((body as NSString).substring(with: match.range).trimmingCharacters(in: .whitespacesAndNewlines))
            }
            body = optionRE.stringByReplacingMatches(in: body, range: NSRange(body.startIndex..., in: body), withTemplate: "")
            if canonical,
               let begin = body.range(of: "(patchFolder +/+ \"dependencies/pondside.scd\").load;"),
               let end = body.range(of: "s.sync;\n\"" + readyMarker + "\".postln;", options: .backwards), begin.upperBound <= end.lowerBound {
                body = String(body[begin.upperBound..<end.lowerBound])
            }
            body = replace(#"(?m)^\s*~mode\s*=\s*[^;]+;"#, in: body)
            body = replace(#"(?m)^\s*"(?:dependencies/)?pondside\.scd"\.(?:loadRelative|resolveRelative\.load)\s*;"#, in: body)
            body = replace(#"(?m)^\s*s\.(?:boot|reboot)\s*;"#, in: body)
            body = replace(#"(?m)^\s*~(?:triggerCue|stop)\.\([^;]*;[^\n]*$"#, in: body)
            body = replace(#"(?m)^\s*// @pondside init v2[^\n]*$"#, in: body)
            body = synchronousBootBodies(body).trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { bodies.append("{\n" + body + "\n}.value;") }
        }
        var previous = 0
        for range in ranges {
            if previous < range.lowerBound { append(ns.substring(with: NSRange(location: previous, length: range.lowerBound - previous))) }
            previous = range.upperBound
            if isLiveOnly(range, in: text) {
                live.append(ns.substring(with: NSRange(location: range.lowerBound, length: range.count)))
                continue
            }
            let body = ns.substring(with: NSRange(location: range.lowerBound + 1, length: range.count - 2))
            append(body, canonical: mainBlock(in: text) == range)
        }
        if previous < ns.length { append(ns.substring(from: previous)) }
        if !bodies.joined().contains(HandlerSync.cuesAnchor) { bodies.append(HandlerSync.cuesAnchor) }
        return initialization(body: bodies.joined(separator: "\n\n"),
            options: options.isEmpty ? "s.options.memSize = 262144;\ns.options.numWireBufs = 1024;" : options.joined(separator: "\n"), score: score)
            + (live.isEmpty ? "\n" : "\n\n" + live.joined(separator: "\n\n") + "\n")
    }


    /// Old boot callbacks become local functions inside the single boot
    /// routine, preserving their locals and their completion order.
    private static func synchronousBootBodies(_ text: String) -> String {
        var text = text
        while true {
            let units = Array(text.utf16), tokens = SCLexer.tokenize(text).filter { $0.kind != .whitespace && $0.kind != .comment }
            var change: (Range<Int>, Range<Int>)?
            for i in tokens.indices where i + 4 < tokens.count {
                func word(_ n: Int) -> String { String(decoding: units[tokens[n].range], as: UTF16.self) }
                guard word(i) == "s", word(i + 1) == ".", word(i + 2) == "waitForBoot" else { continue }
                let parenthesized = tokens[i + 3].kind == .openParen
                let brace = parenthesized ? i + 4 : i + 3
                guard tokens[brace].kind == .openBrace else { continue }
                var depth = 1, j = brace + 1
                while j < tokens.count, depth > 0 {
                    if tokens[j].kind == .openBrace { depth += 1 }
                    if tokens[j].kind == .closeBrace { depth -= 1 }
                    j += 1
                }
                guard depth == 0 else { continue }
                if parenthesized {
                    guard j < tokens.count, tokens[j].kind == .closeParen else { continue }
                    change = (tokens[i].range.lowerBound..<tokens[brace].range.lowerBound, tokens[j].range)
                } else {
                    let end = tokens[j - 1].range.upperBound
                    change = (tokens[i].range.lowerBound..<tokens[brace].range.lowerBound, end..<end)
                }
                break
            }
            guard let change else { return text }
            var changed = units
            changed.replaceSubrange(change.1, with: Array(".value".utf16))
            changed.removeSubrange(change.0)
            text = String(decoding: changed, as: UTF16.self)
        }
    }

    public static func issues(in text: String, patch: URL? = nil, headless: Bool = false) -> [String] {
        var issues: [String] = []
        let blocks = SCRegion.topLevelBlocks(in: text).filter { !isLiveOnly($0, in: text) }
        if blocks.count != 1 || mainBlock(in: text) != blocks.first {
            issues.append("All required preparation must be in one main initialization block (pondside init v2).")
        }
        if let main = mainBlock(in: text) {
            let body = (text as NSString).substring(with: NSRange(location: main.lowerBound, length: main.count))
            for token in ["s.options", "s.reboot", "s.waitForBoot", "~mode", "dependencies/pondside.scd", HandlerSync.cuesAnchor] where !body.contains(token) {
                issues.append("The main initialization block is missing \(token).")
            }
        }
        if let main = mainBlock(in: text) {
            let units = Array(text.utf16)
            let tokens = SCLexer.tokenize(text).filter { $0.kind != .whitespace && $0.kind != .comment && main.contains($0.range.lowerBound) }
            func word(_ i: Int) -> String { tokens.indices.contains(i) ? String(decoding: units[tokens[i].range], as: UTF16.self) : "" }
            var boot: Range<Int>?
            for i in tokens.indices where word(i) == "s" && word(i + 1) == "." && word(i + 2) == "waitForBoot" {
                let brace = i + (word(i + 3) == "(" ? 4 : 3)
                guard tokens.indices.contains(brace), tokens[brace].kind == .openBrace else { continue }
                var depth = 1, j = brace + 1
                while j < tokens.count, depth > 0 {
                    if tokens[j].kind == .openBrace { depth += 1 }
                    if tokens[j].kind == .closeBrace { depth -= 1 }
                    j += 1
                }
                if depth == 0 { boot = tokens[brace].range.lowerBound..<tokens[j - 1].range.upperBound; break }
            }
            if let boot {
                let preparation = String(decoding: units[boot], as: UTF16.self)
                for required in ["~mode", "~resources", "~sharedSounds", "dependencies/pondside.scd", HandlerSync.cuesAnchor, "s.sync", readyMarker] where !preparation.contains(required) {
                    issues.append("Required \(required) must be inside s.waitForBoot preparation.")
                }
                for i in tokens.indices where !boot.contains(tokens[i].range.lowerBound) {
                    if (tokens[i].kind == .environment && word(i + 1) == "=") || (tokens[i].kind == .className && ["Buffer", "SynthDef", "Pbind", "Synth", "Bus"].contains(word(i))) {
                        issues.append("Move required setup into s.waitForBoot: \(word(i)).")
                    }
                }
            } else { issues.append("The main block needs an executable s.waitForBoot preparation function.") }
            var loose = units
            for block in SCRegion.topLevelBlocks(in: text).reversed() { loose.removeSubrange(block) }
            let remainder = String(decoding: loose, as: UTF16.self)
            for line in remainder.split(separator: "\n") {
                let code = SCLexer.tokenize(String(line)).filter { $0.kind != .whitespace && $0.kind != .comment }
                guard !code.isEmpty else { continue }
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if !trimmed.hasPrefix("~triggerCue.(") && !trimmed.hasPrefix("~stop.(") {
                    issues.append("Required preparation cannot be a loose line outside the main block."); break
                }
            }
        }
        issues += resourceIssues(in: text, patch: patch)
        if headless {
            let executable: String
            if let main = mainBlock(in: text) { executable = (text as NSString).substring(with: NSRange(location: main.lowerBound, length: main.count)) } else { executable = text }
            let ns = executable as NSString
            let qt = SCLexer.tokenize(executable).filter { $0.kind == .className }.map { ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count)) }
            if qt.contains(where: { ["Window", "View", "WebView", "Slider", "Button", "FreqScope", "Stethoscope"].contains($0) }) {
                issues.append("The deployed patch must run without Qt; move GUI controls to Pondside or the performance app.")
            }
        }
        return issues
    }

    public static func resourceIssues(in text: String, patch: URL? = nil, resourcesRoot: URL? = nil, mockupName: String? = nil) -> [String] {
        let ns = text as NSString
        let tokens = SCLexer.tokenize(text)
        let audio: Set<String> = ["wav", "aif", "aiff", "flac", "ogg", "mp3", "caf"]
        var issues: [String] = []
        for token in tokens where token.kind == .string {
            let literal = ns.substring(with: NSRange(location: token.range.lowerBound + 1, length: max(0, token.range.count - 2)))
            guard audio.contains(URL(fileURLWithPath: literal).pathExtension.lowercased()) else { continue }
            let lineStart = (ns.substring(to: token.range.lowerBound) as NSString).range(of: "\n", options: .backwards).location
            let start = lineStart == NSNotFound ? 0 : lineStart + 1
            let prefix = ns.substring(with: NSRange(location: start, length: token.range.lowerBound - start))
            let allowedExpression = prefix.range(of: #"(?:~resources|~sharedSounds|Platform\.userAppSupportDir\s*\+/\+\s*"sounds")\s*\+/\+\s*$"#, options: .regularExpression) != nil
            let path = URL(fileURLWithPath: literal, relativeTo: patch?.deletingLastPathComponent()).standardizedFileURL
            let resources = (resourcesRoot ?? patch?.deletingLastPathComponent().appendingPathComponent("resources"))?.standardizedFileURL.path
            let inResources = resources.map { path.path.hasPrefix($0 + "/") } ?? literal.hasPrefix("resources/")
            let inShared = path.path.hasPrefix(sharedSounds.standardizedFileURL.path + "/")
            let mockup = literal.contains("renders/") && (mockupName ?? patch?.deletingPathExtension().lastPathComponent).map { literal.hasSuffix($0 + ".wav") } == true
            if literal.split(separator: "/").contains("..") && allowedExpression {
                issues.append("Sound path escapes an allowed sound root: \(literal).")
            } else if !allowedExpression && !inResources && !inShared && !mockup {
                issues.append("Move \(literal) under resources/ or Platform.userAppSupportDir +/+ \"sounds\"; see pondside://patch-contract.")
            }
        }
        return issues
    }

    public static func validateProject(patch: URL, overrides: [URL: String] = [:], headless: Bool = false) throws {
        let root = patch.standardizedFileURL
        var queue = [root], seen = Set<URL>(), failures: [String] = []
        while !queue.isEmpty {
            let file = queue.removeFirst()
            guard seen.insert(file).inserted else { continue }
            guard let text = overrides[file] ?? (try? String(contentsOf: file, encoding: .utf8)) else {
                throw Failure("Missing patch dependency: \(file.path)")
            }
            if file == root { failures += issues(in: text, patch: file, headless: headless) }
            else {
                failures += resourceIssues(in: text, patch: file, resourcesRoot: root.deletingLastPathComponent().appendingPathComponent("resources"), mockupName: root.deletingPathExtension().lastPathComponent).map { file.lastPathComponent + ": " + $0 }
                if headless {
                    let ns = text as NSString
                    let gui = SCLexer.tokenize(text).contains { $0.kind == .className && ["Window", "View", "WebView", "Slider", "Button", "FreqScope", "Stethoscope"].contains(ns.substring(with: NSRange(location: $0.range.lowerBound, length: $0.range.count))) }
                    if gui { failures.append(file.lastPathComponent + ": required dependency uses Qt GUI classes.") }
                }
            }
            let source = PatchMigration.Source(text, dependency: file != root)
            for path in source.loads {
                let dependency = URL(fileURLWithPath: path, relativeTo: file.deletingLastPathComponent()).standardizedFileURL
                if dependency.lastPathComponent == "pondside.scd" { continue }
                queue.append(dependency)
            }
        }
        if !failures.isEmpty { throw Failure(failures.joined(separator: "\n")) }
    }
}
