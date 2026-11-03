import Foundation
import PondsideCore
import PondsideEngrave
import PondsideTiming
import PondsideLexicon

/// Pondside as an MCP server (stdio transport: one JSON-RPC message per
/// line). Tools are the headless half of the app — check, render, query,
/// cues, Lexicon checks — and the Lexicon's three tiers are resources, so
/// progressive disclosure happens by construction (DESIGN.md §3).
///
/// Vendor-neutral: any MCP client can launch `pondside mcp`.
public actor MCPServer {
    public static let serverName = "pondside"
    public static let serverVersion = "0.1.0"
    static let supportedProtocols = ["2025-06-18", "2025-03-26", "2024-11-05"]

    /// Where `\lexicon` resources come from: the standard scopes plus the
    /// project folder (the working directory unless told otherwise).
    let project: URL

    /// Which agent the server serves, when Pondside started it for one:
    /// each sees only its own tools and instructions, and edits only its
    /// own files (the score's, or the patch's), so the two never collide.
    public enum Role: String, Sendable {
        /// The lens's requests about the score (graphics, notation): `.ly`/`.ily` only.
        case graphics
        /// The patch agent: the SuperCollider patch and its doc only.
        case patch
    }

    let role: Role?

    public init(project: URL, role: Role? = nil) {
        self.project = project
        self.role = role
    }

    // MARK: Transport

    /// Reads requests from stdin until it closes, answering each on stdout.
    public func serveStdio() async {
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let reply = await handle(line: line) {
                FileHandle.standardOutput.write(Data((reply + "\n").utf8))
            }
        }
    }

    /// One message in, at most one message out (notifications get none).
    public func handle(line: String) async -> String? {
        guard let data = line.data(using: .utf8), let message = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return Self.error(id: .null, code: -32700, message: "parse error").jsonString()
        }
        let id = message["id"]
        guard let method = message["method"]?.string else {
            return id == nil ? nil : Self.error(id: id ?? .null, code: -32600, message: "invalid request").jsonString()
        }
        let params = message["params"] ?? .object([:])
        do {
            let result = try await dispatch(method, params)
            guard let id else { return nil }
            return JSONValue.object(["jsonrpc": "2.0", "id": id, "result": result]).jsonString()
        } catch let e as RPCError {
            guard let id else { return nil }
            return Self.error(id: id, code: e.code, message: e.message).jsonString()
        } catch {
            guard let id else { return nil }
            return Self.error(id: id, code: -32603, message: "\(error)").jsonString()
        }
    }

    struct RPCError: Error {
        var code: Int
        var message: String
    }

    static func error(id: JSONValue, code: Int, message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]
    }

    // MARK: Methods

    func dispatch(_ method: String, _ params: JSONValue) async throws -> JSONValue {
        switch method {
        case "initialize":
            if let run = AgentLog.inheritedRun() {
                let client = params["clientInfo"]?["name"]?.string ?? "?"
                run.log("mcp", "pondside mcp started for \(client) in \(project.lastPathComponent) (process \(ProcessInfo.processInfo.processIdentifier))",
                        level: .debug)
            }
            let asked = params["protocolVersion"]?.string ?? Self.supportedProtocols[0]
            let version = Self.supportedProtocols.contains(asked) ? asked : Self.supportedProtocols[0]
            return [
                "protocolVersion": .string(version),
                "capabilities": ["tools": [:], "resources": [:], "prompts": [:]],
                "serverInfo": ["name": .string(Self.serverName), "version": .string(Self.serverVersion)],
                "instructions": .string(role == .patch ? Self.patchInstructions : Self.instructions),
            ]
        case "ping", "notifications/initialized", "notifications/cancelled":
            return [:]
        case "tools/list":
            return ["tools": .array(Self.tools(for: role).map(\.json))]
        case "tools/call":
            guard let name = params["name"]?.string else { throw RPCError(code: -32602, message: "tools/call needs a name") }
            let args = params["arguments"] ?? [:]
            // In a run Pondside started, each call goes into its log with its time.
            let run = AgentLog.inheritedRun()
            let started = Date()
            func logged(_ text: String, failed: Bool) {
                guard let run else { return }
                let ms = Date().timeIntervalSince(started) * 1000
                run.log("mcp", String(format: "%@ %@ in %.0f ms", name, failed ? "failed" : "answered", ms),
                        level: failed ? .warning : .info,
                        detail: "arguments: \(args.jsonString())\n\n" + text)
            }
            do {
                let text = try await callTool(name, args)
                logged(text, failed: false)
                return ["content": [["type": "text", "text": .string(text)]], "isError": false]
            } catch let e as RPCError {
                logged(e.message, failed: true)
                throw e
            } catch {
                logged("\(error)", failed: true)
                // Tool failures are results the model should see, not protocol errors.
                return ["content": [["type": "text", "text": .string("\(error)")]], "isError": true]
            }
        case "prompts/list":
            return ["prompts": .array(Self.skills.map { s -> JSONValue in
                ["name": .string(s.prompt), "description": .string(s.description)]
            })]
        case "prompts/get":
            guard let name = params["name"]?.string, let skill = Self.skills.first(where: { $0.prompt == name }),
                  let text = Self.skillText(skill) else {
                throw RPCError(code: -32602, message: "unknown prompt")
            }
            return ["description": .string(skill.description),
                    "messages": [["role": "user", "content": ["type": "text", "text": .string(text)]]]]
        case "resources/list":
            let lex = lexicon()
            var list: [JSONValue] = [
                ["uri": "lexicon://index", "name": "Lexicon index", "mimeType": "application/json",
                 "description": "Tier 0: every entry's id, gloss, tags and param names, one line each"],
            ]
            for s in Self.skills {
                list.append(["uri": .string(s.uri), "name": .string(s.prompt), "mimeType": "text/markdown",
                             "description": .string(s.description)])
            }
            for id in lex.ids {
                list.append(["uri": .string("lexicon://entry/\(id)"), "name": .string(id), "mimeType": "text/markdown",
                             "description": .string(lex.entries[id]?.entry.gloss ?? "")])
            }
            return ["resources": .array(list)]
        case "resources/templates/list":
            return ["resourceTemplates": [
                ["uriTemplate": "lexicon://entry/{id}", "name": "Lexicon entry (tier 1)", "mimeType": "text/markdown"],
                ["uriTemplate": "lexicon://impl/{id}", "name": "Lexicon implementation (tier 2)", "mimeType": "text/x-lilypond"],
                ["uriTemplate": "skill://{skill}/{path}", "name": "A file of a skill (library, reference, script)", "mimeType": "text/plain"],
            ]]
        case "resources/read":
            guard let uri = params["uri"]?.string else { throw RPCError(code: -32602, message: "resources/read needs a uri") }
            AgentLog.inheritedRun()?.log("mcp", "read resource \(uri)", level: .debug)
            let (text, mime) = try readResource(uri)
            return ["contents": [["uri": .string(uri), "mimeType": .string(mime), "text": .string(text)]]]
        default:
            throw RPCError(code: -32601, message: "method not found: \(method)")
        }
    }

    func lexicon() -> Lexicon {
        Lexicon.load(Lexicon.standardScopes(project: project))
    }

    func readResource(_ uri: String) throws -> (String, String) {
        let lex = lexicon()
        if uri == "lexicon://index" { return (lex.indexJSON(), "application/json") }
        if let skill = Self.skills.first(where: { $0.uri == uri }), let text = Self.skillText(skill) {
            return (text, "text/markdown")
        }
        if uri.hasPrefix("skill://") {
            let parts = uri.dropFirst("skill://".count).split(separator: "/", maxSplits: 1).map(String.init)
            if parts.count == 2, let skill = Self.skills.first(where: { $0.folder == parts[0] }),
               let text = Self.skillFile(skill, parts[1]) {
                return (text, parts[1].hasSuffix(".md") ? "text/markdown" : "text/plain")
            }
            throw RPCError(code: -32002, message: "no skill file \(uri)")
        }
        for (prefix, tier) in [("lexicon://entry/", 1), ("lexicon://impl/", 2)] where uri.hasPrefix(prefix) {
            let id = String(uri.dropFirst(prefix.count))
            if let text = tier == 1 ? lex.tier1(id) : lex.tier2(id) {
                return (text, tier == 1 ? "text/markdown" : "text/x-lilypond")
            }
            throw RPCError(code: -32002, message: "no Lexicon entry \(id)")
        }
        throw RPCError(code: -32002, message: "unknown resource \(uri)")
    }

    /// What every client is told first. Short on purpose: the skills hold
    /// the detail, and the user wants terse, fast turns.
    static let instructions = """
    Pondside scores are plain LilyPond files: read and edit them directly; the running app re-engraves on \
    every save. Be terse: act, then reply in one short line saying what changed ("Swell taller: peak \
    1.06 → 1.5."). No plans, recaps, options or offers; ask only when the score can't settle it.
    "Here", "this" and the like refer to the user's selection: call score_context with no arguments \
    first (a request from the lens already includes it). It returns the selected event or graphic, its staff's music, bar and moment, \
    and for a graphic drawn by the score's own code its definition and drawing procedure. For a range \
    with no drawing it also returns the root layout and a short definition index.
    For graphic notation follow lexicon://guide/graphics. Graphics are always edited from the marked range \
    (selection.kind "graphic-section", made by ⌥-drag in the score): window the drawing so only the marked \
    box changes. A new graphic goes in the same marked range. If the marked range has no drawing and the \
    request is notation or layout (barlines, beams, clefs, spacing, noteheads), follow skill://lilypond and \
    edit the score's layout or helpers; do not force a Lexicon entry. Edit with the edit tool (exact text, or lines \
    as the context numbers them; no need to read the file first): it returns the app's engraving of the change, \
    so no separate check. Make the change big enough to see at a glance.
    Cue times, the mockup and SuperCollider handlers are Pondside's (cues, `pondside mockup`, `pondside \
    handlers`): never set up a second timing pipeline (skill://lilypond-supercollider). A patch with \
    `// pondside:` marks, or a request to migrate one: skill://sc-patch-migration. When something goes wrong \
    that the user must know, call warn_user; when you can't go on without their choice, ask_user (a dialog).
    Other skills, read only when needed: skill://lilypond (writing, spacing, debugging LilyPond), \
    skill://lilypond-contemporary-notation, skill://lilypond-electronics-staff; lexicon://guide/entries only \
    when no existing entry or combination will do. Lexicon: lexicon://index, lexicon://entry/{id}, \
    lexicon://impl/{id}; a skill's files are skill://<skill>/<path>.
    """

    /// The patch agent's: short, the skill holds the detail.
    static let patchInstructions = """
    You are Pondside's patch agent: you change the score's SuperCollider patch (patch/<score>.scd and the \
    files it loads), never the .ly files. Be terse: act, then reply in one short line saying what changed \
    and how it sounds now ("Cue 12: reverb on the flute, mix 0.4 → 0.7; electronics −18 dBFS.").
    The request comes with patch_context: the cue at the user's point, its handler's code (numbered), what \
    it touches, the collections there, the patch doc (outline + notes) and the SuperCollider Lexicon. Edit \
    with the edit tool by line or exact text without reading the file; read other lines only by range. \
    Effects and pattern parts: sc_lexicon_entry, sc_lexicon_add. Verify with patch_check (renders the mix, \
    reports errors and the cue's levels). Then keep the doc current: patch_note on what you changed, with \
    intent, not code. Follow skill://sc-patch-editing. warn_user when something fails; ask_user only when \
    two readings really differ.
    """

    // MARK: Skills

    /// The two skills of DESIGN.md §7, the high-level one for working with
    /// the Lexicon's graphic entries and the low-level one for writing new
    /// entries, then every other bundled skill (LilyPond itself,
    /// contemporary notation, electronics staves, SuperCollider), found in
    /// `Core/Skills` with its description from SKILL.md's front matter.
    struct Skill {
        var folder: String
        var uri: String
        var prompt: String
        var description: String
    }

    static let guides = [
        Skill(folder: "graphic-notation", uri: "lexicon://guide/graphics", prompt: "graphic-notation",
              description: "Graphic notation from a marked range: score_context, one edit, check; window the drawing so only the box changes; terse requests (\"taller\", \"denser\") and new graphics in the same range"),
        Skill(folder: "lexicon-entries", uri: "lexicon://guide/entries", prompt: "lexicon-entries",
              description: "Writing new Lexicon entries: the graphics kit, the entry folder, LilyPond and Guile gotchas, checks"),
    ]

    static let skills: [Skill] = {
        guard let dir = Lexicon.coreDirectory?.appendingPathComponent("Skills"),
              let folders = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return guides }
        let others = folders.sorted().filter { f in !guides.contains { $0.folder == f } }.compactMap { folder -> Skill? in
            guard let text = try? String(contentsOf: dir.appendingPathComponent("\(folder)/SKILL.md"), encoding: .utf8) else { return nil }
            let description = text.split(separator: "\n").first { $0.hasPrefix("description:") }
                .map { $0.dropFirst("description:".count).trimmingCharacters(in: .whitespaces) } ?? folder
            return Skill(folder: folder, uri: "skill://\(folder)", prompt: folder, description: description)
        }
        return guides + others
    }()

    static func skillDirectory(_ s: Skill) -> URL? {
        Lexicon.coreDirectory?.appendingPathComponent("Skills/\(s.folder)")
    }

    /// SKILL.md, followed by the URIs of the skill's other files: its paths
    /// are relative to the skill, which an agent reaches only through us.
    static func skillText(_ s: Skill) -> String? {
        guard let dir = skillDirectory(s),
              let text = try? String(contentsOf: dir.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
        let files = (FileManager.default.subpaths(atPath: dir.path) ?? []).sorted().filter { path in
            path != "SKILL.md" && !path.hasPrefix(".") && !path.contains("/.")
                && !((try? dir.appendingPathComponent(path).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true)
        }
        guard !files.isEmpty else { return text }
        return text + "\n\n---\nThis skill's files, read with resources/read (copy a library into the score's folder before including it):\n"
            + files.map { "- skill://\(s.folder)/\($0)" }.joined(separator: "\n") + "\n"
    }

    static func skillFile(_ s: Skill, _ path: String) -> String? {
        guard let dir = skillDirectory(s), !path.split(separator: "/").contains("..") else { return nil }
        return try? String(contentsOf: dir.appendingPathComponent(path), encoding: .utf8)
    }

    // MARK: Tools

    struct Tool {
        var name: String
        var description: String
        var properties: [String: JSONValue]
        var required: [String]

        var json: JSONValue {
            ["name": .string(name), "description": .string(description),
             "inputSchema": ["type": "object", "properties": .object(properties),
                             "required": .array(required.map { .string($0) })]]
        }
    }

    static let file: JSONValue = ["type": "string", "description": "Path to a .ly file (absolute, or relative to the server's directory)"]

    /// The tools a role sees (all of them for no role: the CLI, migration).
    static func tools(for role: Role?) -> [Tool] {
        guard let role else { return tools }
        let patchOnly: Set<String> = ["patch_context", "patch_doc", "patch_note", "patch_check", "sc_lexicon_search",
                                      "sc_lexicon_entry", "sc_lexicon_add"]
        let graphicsOnly: Set<String> = ["graphic_preview", "graphic_insert", "lexicon_propose", "lexicon_check", "lexicon_search",
                                         "lexicon_entry", "render", "query", "check"]
        let migration: Set<String> = ["patch_migrate"]
        switch role {
        case .graphics: return tools.filter { !patchOnly.contains($0.name) && !migration.contains($0.name) }
        case .patch: return tools.filter { !graphicsOnly.contains($0.name) && !migration.contains($0.name) }
        }
    }

    static let tools: [Tool] = [
        Tool(name: "edit", description: "Atomically edit a file without reading it first. Prefer from_line…to_line from the numbered context, optionally with old as a guard; exact old text is for small unique replacements. ALL ranges in one call address the SAME pre-edit snapshot: inserted lines never renumber other hunks, and all hunks apply together or none. Never split dependent hunks into separate calls. For .ly/.ily it waits for the app's engraving and returns check, new_diagnostics when a request baseline exists, and vector verification of the marked range (selected no-op, wholly-outside changes, boundary-crossing ambiguity); don't call check after it.",
             properties: ["file": ["type": "string", "description": "The file to edit (absolute, or relative to the server's directory)"],
                          "edits": ["type": "array", "description": "All hunks against the same pre-edit file snapshot",
                                    "items": ["type": "object", "properties": [
                                        "old": ["type": "string", "description": "Exact text to replace, or the expected text guarding a line range"],
                                        "new": ["type": "string", "description": "Its replacement (lines without number prefixes)"],
                                        "from_line": ["type": "integer", "description": "First line to replace in the original snapshot"],
                                        "to_line": ["type": "integer", "description": "Last line to replace (default from_line)"]],
                                              "required": ["new"]]],
                          "root": ["type": "string", "description": "The score's root .ly, when editing an .ily (for the check)"]],
             required: ["file", "edits"]),
        Tool(name: "check", description: "Diagnostics (file, line, column, message) from LilyPond itself. When the app has the score open, waits for its engraving of the files as they are now (about a second, warm); otherwise compiles.",
             properties: ["file": file], required: ["file"]),
        Tool(name: "query", description: "List a score's musical events in order: kind, absolute pitches (Dutch names, c' = middle C), duration, and source line:character, for precise edits.",
             properties: ["file": file,
                          "from_line": ["type": "integer", "description": "First source line to include"],
                          "to_line": ["type": "integer", "description": "Last source line to include"]],
             required: ["file"]),
        Tool(name: "render", description: "Engrave a score for export (PDF, SVG or PNG) with point-and-click disabled. Returns the written files.",
             properties: ["file": file, "format": ["type": "string", "enum": ["pdf", "svg", "png"]],
                          "out": ["type": "string", "description": "Output directory (default: beside the score)"]],
             required: ["file"]),
        Tool(name: "cues", description: "Every electronics cue (\\ecue, and Lexicon entries with sounds) with moment, bar, beat, seconds and samples, timed exactly as the MIDI plays.",
             properties: ["file": file, "rate": ["type": "integer", "description": "Sample rate (default 48000)"]],
             required: ["file"]),
        Tool(name: "patch_audit", description: "Check the score's SuperCollider patch (or, without one, the folder's likeliest .scd) against Pondside's patch layout: what patch_migrate fixes by itself (automatic) and what is left for you (skill sc-patch-migration).",
             properties: ["file": file, "scd": ["type": "string", "description": "The patch, if not <score>.scd or pondside.toml's"]],
             required: ["file"]),
        Tool(name: "patch_migrate", description: "Make the patch a Pondside patch: wrap it in the mode, engine, cue and play sections, convert quark handlers, rename names the engine uses, feed SoundIn.ar(0) from ~live, add cue stubs, and mark each line left for you with a // pondside: comment. Writes <score>.scd (keeping an original it rewrites as .before-pondside.scd). Returns what it did and what is left, with lines.",
             properties: ["file": file, "scd": ["type": "string", "description": "Where the patch goes, if not <score>.scd or pondside.toml's"],
                          "from": ["type": "string", "description": "The file to migrate, if not the one patch_audit found"]],
             required: ["file"]),
        Tool(name: "mix", description: "Render the score's Pondside patch offline in mockup mode (as the app does after each engraving) into <score>.mix.wav. Returns whether it rendered, and the errors its setup or cues printed. A patch is done only when this renders cleanly.",
             properties: ["file": file], required: ["file"]),
        Tool(name: "warn_user", description: "Tell the user something went wrong (a render that fails, a file you couldn't fix, a request you couldn't carry out): an alert in the running app. Not for progress or summaries.",
             properties: ["file": ["type": "string", "description": "The score (.ly) the work is for, so the alert shows on its window"],
                          "title": ["type": "string", "description": "A few words, e.g. \"The mix didn't render\""],
                          "message": ["type": "string", "description": "What went wrong and what the user can do, in one to three sentences"]],
             required: ["message"]),
        Tool(name: "ask_user", description: "Ask the user a clarifying question when you genuinely can't go on without their choice (two readings of a request; which cue an old timeline belongs to). A dialog in the running app; waits for the answer. Offer up to 4 short choices when you can.",
             properties: ["file": ["type": "string", "description": "The score (.ly) the work is for"],
                          "question": ["type": "string", "description": "One short question"],
                          "choices": ["type": "array", "items": ["type": "string"], "description": "Up to 4 short answers to offer"]],
             required: ["question"]),
        Tool(name: "lexicon_check", description: "Check a score's \\lexicon and \\startGraphic uses against the Lexicon: unknown entries, unknown params, values out of range.",
             properties: ["file": file], required: ["file"]),
        Tool(name: "score_context", description: "What \"here\" means: the user's selection in the running app (no arguments), or a point. The event, its staff's .ly, bar, moment (whole notes from the staff's start), the graphic at or around it (a Lexicon entry's params; or a graphic drawn by the score's own code: its command, start/stop, definition, drawing procedure and what it uses), the marked graphics range when the user ⌥-dragged (selection.kind \"graphic-section\": from/to edges, their x fractions, page x, and the moment at each edge interpolated from the engraved notes, and the selected range on each system), every cue (bar, beat, moment, seconds), and the system's first, last and next events. With no drawing at the point, code gives the root layout and a short definition index; use skill://lilypond for a notation/layout change, lexicon://guide/graphics for a drawing. Call this first; the marked range is the only range.",
             properties: ["file": file,
                          "line": ["type": "integer", "description": "1-based line (omit to use the app's selection)"],
                          "character": ["type": "integer", "description": "0-based character on the line"]],
             required: []),
        Tool(name: "lexicon_search", description: "Find Lexicon entries for a description (\"grainy texture\", \"ripple\", \"wedge\"): tier 0 lines, best first.",
             properties: ["query": ["type": "string"], "limit": ["type": "integer"]], required: ["query"]),
        Tool(name: "lexicon_entry", description: "One entry's params (types, ranges, defaults, docs) and README pitfalls: tier 1.",
             properties: ["id": ["type": "string"]], required: ["id"]),
        Tool(name: "graphic_preview", description: "Engrave a graphic entry with given params over a span of bars on its own staff and return the SVG's path, to look at before inserting.",
             properties: ["id": ["type": "string"],
                          "params": ["type": "string", "description": "Scheme alist, e.g. ((height . (swell 3 0.5 4)) (seed . 2))"],
                          "bars": ["type": "integer", "description": "Span length in 4/4 bars (default 4)"],
                          "music": ["type": "string", "description": "Optional LilyPond for a staff above, e.g. the passage's music"],
                          "out": ["type": "string", "description": "Directory for the SVG (default: a temporary one)"]],
             required: ["id"]),
        Tool(name: "graphic_insert", description: "Insert a Lexicon graphic as a minimal edit: \\startGraphic on the event at the range start, \\stopGraphic on the event at the range stop or at a moment (a skip it falls inside is split), on the same staff; write lexicon.ily and include it in the root, then return the engraving/check and any marked-range vector verification.",
             properties: ["file": file, "id": ["type": "string"], "params": ["type": "string", "description": "Scheme alist"],
                          "start_line": ["type": "integer"], "start_character": ["type": "integer"],
                          "stop_line": ["type": "integer"], "stop_character": ["type": "integer"],
                          "stop_moment": ["type": "string", "description": "Stop at this moment (whole notes, e.g. \"221/8\") instead of an event"],
                          "root": ["type": "string", "description": "The score's root file, if not `file`"]],
             required: ["file", "id", "start_line", "start_character"]),
        Tool(name: "patch_context", description: "What the patch agent needs at a point in the score: the cue there (or named), its handler's code with line numbers, its window (until the next cue), what the handler touches (SynthDefs, patterns, buses, with code), the pitch collections around it, the patch doc (outline + notes, stale ones flagged), every cue and the SuperCollider Lexicon. No arguments: the user's selection in the app. A request from the lens already includes it.",
             properties: ["file": ["type": "string", "description": "The score (.ly)"],
                          "line": ["type": "integer", "description": "1-based line in the score (omit for the app's selection)"],
                          "character": ["type": "integer", "description": "0-based character on the line"],
                          "cue": ["type": "string", "description": "A cue's name (\"12\") instead of a point"]],
             required: []),
        Tool(name: "patch_doc", description: "The patch's doc (patch/<name>.patch.md): its outline rebuilt from the code (every SynthDef, pattern, proxy, bus, buffer, function, cue handler and live block, with file:lines) and the notes on intent kept under each item, stale ones flagged. The patch agent's memory: read it before searching the patch.",
             properties: ["file": file], required: ["file"]),
        Tool(name: "patch_note", description: "Write the note on one item of the patch doc (its key as the outline gives it, e.g. \"cue cue-12\", \"synthdef \\\\grain\", \"pattern ~cloud\", or \"overview\"): what it is for and why, in a few lines, not the code. Replaces the old note; stamps it with the code's hash so it goes stale when the code changes. Empty note removes it.",
             properties: ["file": file, "item": ["type": "string"], "note": ["type": "string"]], required: ["file", "item", "note"]),
        Tool(name: "patch_check", description: "Verify the patch: render it offline against the mockup (as the app does), report setup and cue errors, and the levels in a cue's window (the mix, and the electronics alone: mix minus mockup) before and after. Also rebuilds the patch doc and lists notes the change made stale.",
             properties: ["file": file, "cue": ["type": "string", "description": "The cue whose window to measure (its name)"]],
             required: ["file"]),
        Tool(name: "sc_lexicon_search", description: "Find SuperCollider Lexicon entries (effects, synths, pattern parts) for a description (\"echo\", \"grainy cloud\", \"getting denser\"): one line each, best first.",
             properties: ["query": ["type": "string"], "limit": ["type": "integer"]], required: ["query"]),
        Tool(name: "sc_lexicon_entry", description: "One SuperCollider Lexicon entry in full: how to call it, params with defaults, usage, README and code.",
             properties: ["id": ["type": "string"]], required: ["id"]),
        Tool(name: "sc_lexicon_add", description: "Make SuperCollider Lexicon entries available to the patch: (re)writes patch/dependencies/sc-lexicon.scd with them and what they require, and loads it after the engine. Then call them in a handler (\\lx_reverb_mono on ~live, ~lx[\\cloud], …).",
             properties: ["file": file, "ids": ["type": "array", "items": ["type": "string"]]], required: ["file", "ids"]),
        Tool(name: "lexicon_propose", description: "Write a new entry as a draft in the project's Lexicon/drafts/ (validated; usable in the score at once). The user accepts or rejects it; never promote it yourself.",
             properties: ["id": ["type": "string"], "entry_toml": ["type": "string"], "impl": ["type": "string"],
                          "readme": ["type": "string"]],
             required: ["id", "entry_toml", "impl", "readme"]),
    ]

    func path(_ args: JSONValue) throws -> URL {
        guard let f = args["file"]?.string else { throw RPCError(code: -32602, message: "missing argument: file") }
        let url = f.hasPrefix("/") ? URL(fileURLWithPath: f) : project.appendingPathComponent(f)
        guard FileManager.default.fileExists(atPath: url.path) else { throw ToolFailure("no such file: \(url.path)") }
        return url.standardizedFileURL
    }

    struct ToolFailure: Error, CustomStringConvertible {
        var description: String
        init(_ d: String) { description = d }
    }

    func lilypond(for source: URL) async throws -> LilyPondInstallation {
        let installs = await ToolchainDetector().detectLilyPond()
        let declared = (try? String(contentsOf: source, encoding: .utf8)).flatMap(LilyPondVersion.declared(in:))
        guard let lily = ToolchainDetector.select(from: installs, for: declared) else {
            throw ToolFailure("LilyPond is not installed (run the Pondside installer, or brew install lilypond)")
        }
        return lily
    }

    func callTool(_ name: String, _ args: JSONValue) async throws -> String {
        switch name {
        case "check":
            let source = try path(args)
            if let fromApp = await appCheck(source) { return fromApp }
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mcp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let result = try await LilyPondEngraver(installation: try await lilypond(for: source))
                .engrave(source, purpose: .canvas, outputDirectory: scratch)
            // Pondside's own canvas options aren't the score's problems.
            let diagnostics: [JSONValue] = result.diagnostics.filter { !$0.message.hasPrefix("ignoring unsupported formats") }.map { d -> JSONValue in
                let file: JSONValue = d.file.map(JSONValue.string) ?? .null
                let line: JSONValue = d.line.map { JSONValue.number(Double($0)) } ?? .null
                let column: JSONValue = d.column.map { JSONValue.number(Double($0)) } ?? .null
                return ["severity": .string(d.severity.rawValue), "file": file, "line": line, "column": column,
                        "message": .string(d.message)]
            }
            let ok = result.errors.isEmpty && result.succeeded
            var report: [String: JSONValue] = ["ok": .bool(ok), "pages": .number(Double(result.outputFiles.count)),
                                               "diagnostics": .array(diagnostics)]
            if !ok { report["log"] = .string(CompilerLog.tail(result.messages)) }
            return JSONValue.object(report).jsonString(pretty: true)
        case "query":
            let source = try path(args)
            let text = try String(contentsOf: source, encoding: .utf8)
            return ScoreQuery.events(in: text, fromLine: args["from_line"]?.int, toLine: args["to_line"]?.int)
                .jsonString(pretty: true)
        case "render":
            let source = try path(args)
            guard let format = ExportFormat(rawValue: args["format"]?.string ?? "pdf") else { throw ToolFailure("format must be pdf, svg or png") }
            let out = args["out"]?.string.map { URL(fileURLWithPath: $0) } ?? source.deletingLastPathComponent()
            let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pondside-mcp-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: scratch) }
            let result = try await LilyPondEngraver(installation: try await lilypond(for: source))
                .engrave(source, purpose: .export(format), outputDirectory: scratch)
            guard result.succeeded else {
                throw ToolFailure("render failed:\n" + result.diagnostics.map { "\($0.line.map(String.init) ?? "?"): \($0.message)" }.joined(separator: "\n"))
            }
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            var written: [JSONValue] = []
            for f in result.outputFiles {
                let dest = out.appendingPathComponent(f.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: f, to: dest)
                written.append(.string(dest.path))
            }
            return JSONValue.object(["files": .array(written)]).jsonString(pretty: true)
        case "cues":
            let source = try path(args)
            let log = try await TimingDump.run(try await lilypond(for: source), source: source)
            let lex = Lexicon.load(Lexicon.standardScopes(project: source.deletingLastPathComponent()))
            let sheet = CueSheet(log: log, score: source.lastPathComponent, sampleRate: args["rate"]?.int ?? 48000,
                                 soundParams: { lex.soundParams(entry: $0, params: $1, beatDur: $2, spanDur: $3, tempo: $4) })
            return String(decoding: try sheet.json(), as: UTF8.self)
        case "patch_audit", "patch_migrate":
            let source = try path(args)
            let configured = try args["scd"]?.string.map { try path(["file": .string($0)]) }
                ?? (try? ProjectConfig.find(from: source))?.handlers
            let target = PatchMigration.patchURL(score: source, configured: configured)
            let found: (source: URL, target: URL, findings: [PatchMigration.Finding])?
            if let from = try args["from"]?.string.map({ try path(["file": .string($0)]) }) {
                found = (from, target, PatchMigration.audit(try String(contentsOf: from, encoding: .utf8)))
            } else {
                found = PatchMigration.candidate(score: source, configured: configured)
            }
            let marked = PatchMigration.allMarks(patch: target)
                .map { "- \($0.file):\($0.line): \($0.text)" }.joined(separator: "\n")
            guard let c = found else {
                guard FileManager.default.fileExists(atPath: target.path) else { return "There is no .scd beside the score." }
                return marked.isEmpty ? "Nothing to do: \(target.lastPathComponent) is a Pondside patch with no findings and no marks."
                    : "No new findings. Marked lines still to fix (fix each, then delete its mark):\n\(marked)"
            }
            func show(_ fs: [PatchMigration.Finding], _ file: URL) -> String {
                fs.map { f in "- " + (f.line.map { "\(f.file ?? file.lastPathComponent):\($0): " } ?? "") + f.message }.joined(separator: "\n")
            }
            if name == "patch_audit" {
                let auto = c.findings.filter(\.automatic), manual = c.findings.filter { !$0.automatic }
                return "\(c.source.path) → \(c.target.path)\npatch_migrate does:\n\(show(auto, c.source))\nleft for you:\n\(show(manual, c.source))"
                    + (marked.isEmpty ? "" : "\nMarked lines still to fix:\n\(marked)")
            }
            var sheet: CueSheet?
            if let log = try? await TimingDump.run(try await lilypond(for: source), source: source) {
                sheet = CueSheet(log: log, score: source.lastPathComponent)
            }
            let (result, backup, moved) = try PatchMigration.write(score: source, source: c.source, target: c.target, sheet: sheet)
            return "Wrote \(c.target.path)" + (backup.map { " (original kept as patch/\($0.lastPathComponent))" } ?? "")
                + (moved.isEmpty ? "" : ". Moved: " + moved.joined(separator: "; "))
                + ".\nDone:\n\(show(result.applied, c.source))\nLeft for you, each line marked // pondside: (fix it, then remove the mark):\n"
                + (result.manual.isEmpty ? "- nothing" : show(result.manual, c.target))
        case "mix":
            let source = try path(args)
            let config = try? ProjectConfig.find(from: source)
            guard let patch = PatchRender.patch(for: source, configured: config?.handlers) else {
                return "No Pondside patch for \(source.lastPathComponent) (patch_migrate makes one)."
            }
            let wav = HandlerSync.Layout.mockup(score: source)
            guard FileManager.default.fileExists(atPath: wav.path) else { return "No mockup yet (\(wav.lastPathComponent)): the app writes it after an engraving." }
            guard let sclang = SuperColliderToolchain.findSclang(configured: config?.sclang?.path) else { return "SuperCollider isn't installed." }
            let out = PatchRender.output(for: source)
            do {
                let problems = try await PatchRender.render(sclang: sclang, patch: patch, wav: wav, out: out)
                return "Rendered \(out.lastPathComponent)." + (problems.isEmpty ? "" : " Errors in cues (each stopped that cue):\n" + problems.joined(separator: "\n"))
            } catch {
                return "Didn't render. \(error)"
            }
        case "warn_user", "ask_user":
            var params: [String: JSONValue] = [:]
            if let f = args["file"]?.string { params["path"] = .string(try path(["file": .string(f)]).path) }
            for k in ["title", "message", "question", "choices"] { if let v = args[k] { params[k] = v } }
            let method = name == "warn_user" ? "document.warn" : "document.ask"
            guard let reply = try? RPCClient.call(method, .object(params)) else {
                return "Pondside isn't running (or has no score open), so nobody saw this: say it in your final reply instead."
            }
            if name == "warn_user" { return "Shown to the user." }
            return reply["answered"] == .bool(true) ? "The user answered: \(reply["answer"]?.string ?? "")"
                : "The user skipped the question: make the conservative choice, and say what you assumed."
        case "lexicon_check":
            let source = try path(args)
            let problems = lexicon().check(try String(contentsOf: source, encoding: .utf8))
            if problems.isEmpty { return "No problems: every \\lexicon use names a known entry with valid params." }
            return problems.map { "line \($0.line): \($0.message)" }.joined(separator: "\n")
        case "score_context":
            if let f = args["file"]?.string, let line = args["line"]?.int {
                let source = try path(["file": .string(f)])
                let character = args["character"]?.int ?? 0
                // The app knows more (the system, the cues, unsaved text): ask it first.
                if let app = try? RPCClient.call("document.context", ["path": .string(source.path), "line": .number(Double(line)),
                                                                      "character": .number(Double(character))]) {
                    return app.jsonString(pretty: true)
                }
                let text = try String(contentsOf: source, encoding: .utf8)
                let files = Self.neighbours(of: source)
                let root: ScoreGraphic.File? = source.pathExtension.lowercased() == "ly"
                    ? (source.path, text)
                    : files.first { $0.path.hasSuffix("/score.ly") || $0.path == "score.ly" }
                        ?? files.first { $0.path.hasSuffix(".ly") }
                return ScoreContext.describe(text: text, file: source.path, line: line, character: character,
                                             files: files, root: root).jsonString(pretty: true)
            }
            do {
                return try RPCClient.call("document.context", [:]).jsonString(pretty: true)
            } catch {
                throw ToolFailure("Pondside isn't running, so there is no selection: pass file and line")
            }
        case "lexicon_search":
            let lines = lexicon().search(args["query"]?.string ?? "", limit: args["limit"]?.int ?? 8)
            return lines.isEmpty ? "No entries match. Try other words, or lexicon://index for all." : lines.joined(separator: "\n")
        case "lexicon_entry":
            guard let id = args["id"]?.string, let text = lexicon().tier1(id) else { throw ToolFailure("no Lexicon entry \(args["id"]?.string ?? "")") }
            return text
        case "graphic_preview":
            return try await preview(args)
        case "graphic_insert":
            let source = try path(args)
            guard let id = args["id"]?.string, lexicon().entries[id] != nil else { throw ToolFailure("no Lexicon entry \(args["id"]?.string ?? "")") }
            let text = try String(contentsOf: source, encoding: .utf8)
            let params = args["params"]?.string ?? "()"
            let start = (args["start_line"]?.int ?? 0, args["start_character"]?.int ?? 0)
            let new: String
            if let line = args["stop_line"]?.int {
                new = try GraphicEdit.insert(into: text, id: id, params: params, start: start,
                                             stop: (line, args["stop_character"]?.int ?? 0))
            } else if let moment = stopMoment(args) {
                new = try GraphicEdit.insert(into: text, id: id, params: params, start: start, stopMoment: moment)
            } else {
                throw ToolFailure("give stop_line and stop_character or stop_moment")
            }
            let problems = lexicon().check(new)
            guard problems.isEmpty else {
                throw ToolFailure(problems.map { "line \($0.line): \($0.message)" }.joined(separator: "\n"))
            }
            try Data(new.utf8).write(to: source, options: .atomic)
            let root = try args["root"]?.string.map { try path(["file": .string($0)]) } ?? source
            let include = try GraphicEdit.prepareLexiconInclude(root: root, lexicon: lexicon())
            let done = "Inserted \(id) in \(source.lastPathComponent); wrote \(include.lastPathComponent)."
            if let fromApp = await appCheck(root) { return done + " check:\n" + fromApp }
            return done + " check:\n" + (try await callTool("check", ["file": .string(root.path)]))
        case "edit":
            return try await edit(args)
        case "patch_context":
            return try await patchContext(args).jsonString(pretty: true)
        case "patch_doc":
            let patch = try patchFile(for: try path(args))
            let doc = try PatchDoc.update(patch: patch)
            return doc.text + (doc.stale.isEmpty ? "" : "\nStale notes (the code changed since): " + doc.stale.joined(separator: ", "))
        case "patch_note":
            let patch = try patchFile(for: try path(args))
            let key = try PatchDoc.setNote(patch: patch, key: args["item"]?.string ?? "", text: args["note"]?.string ?? "")
            return "Noted \(key) in \(PatchDoc.url(patch: patch).lastPathComponent)."
        case "patch_check":
            return try await patchCheck(args)
        case "sc_lexicon_search":
            let lines = SCLexicon.load(project: project).search(args["query"]?.string ?? "", limit: args["limit"]?.int ?? 8)
            return lines.isEmpty ? "No entries match; the patch's own code may already do it (patch_doc)." : lines.joined(separator: "\n")
        case "sc_lexicon_entry":
            guard let id = args["id"]?.string, let text = SCLexicon.load(project: project).describe(id) else {
                throw ToolFailure("no SuperCollider Lexicon entry \(args["id"]?.string ?? ""); sc_lexicon_search finds them")
            }
            return text
        case "sc_lexicon_add":
            let source = try path(args)
            let patch = try patchFile(for: source)
            let ids = (args["ids"]?.array ?? []).compactMap(\.string) + (args["ids"]?.string.map { [$0] } ?? [])
            let (all, inserted) = try PatchContext.addLexiconReportingShift(ids, patch: patch, lexicon: SCLexicon.load(project: source.deletingLastPathComponent()))
            return "dependencies/\(SCLexiconInclude.fileName) now has \(all.joined(separator: ", "))."
                + (inserted.map { " The patch now loads it at line \($0): every line of \(patch.lastPathComponent) after it is one further down than your context says (add 1, or edit by old text)." }
                   ?? " The patch already loads it.")
        case "lexicon_propose":
            guard let id = args["id"]?.string else { throw ToolFailure("missing id") }
            let dir = try Lexicon.propose(id: id, toml: args["entry_toml"]?.string ?? "", impl: args["impl"]?.string ?? "",
                                          readme: args["readme"]?.string ?? "", project: project)
            return "Draft written to \(dir.path). Preview it with graphic_preview, show the user, and let them accept it (pondside lexicon promote \(id)) or reject it."
        default:
            throw RPCError(code: -32602, message: "unknown tool: \(name)")
        }
    }

    /// The moment `stop_moment` names (whole notes, e.g. 221/8); the marked
    /// range's end edge is the only source of a stop.
    func stopMoment(_ args: JSONValue) -> Rational? {
        guard let m = args["stop_moment"]?.string else { return nil }
        return Rational(parsing: m)
    }

    /// The score's diagnostics from the running app, once it has engraved
    /// the files as they are now; nil when the app doesn't have the score
    /// open or doesn't start a compile in time (then `check` compiles).
    func appCheck(_ source: URL) async -> String? {
        func document() -> JSONValue? {
            guard let docs = (try? RPCClient.call("app.documents"))?.array else { return nil }
            return docs.first { d in
                d["files"]?.array?.contains { $0.string.map { URL(fileURLWithPath: $0).standardizedFileURL.path == source.path } ?? false } ?? false
            }
        }
        guard let first = document() else { return nil }
        let files = (first["files"]?.array ?? []).compactMap(\.string)
        let written = files.compactMap { try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date }.max() ?? .distantPast
        let deadline = Date().addingTimeInterval(60)
        var nudge = Date().addingTimeInterval(3)
        var nudged = false
        while Date() < deadline {
            guard let doc = document() else { return nil }
            let started = doc["started"]?.number.map { Date(timeIntervalSince1970: $0) } ?? .distantPast
            let status = doc["status"]?.string ?? ""
            if status == "noLilyPond" { return nil }
            if started >= written, status != "compiling" {
                let diagnostics = doc["diagnostics"]?.array ?? []
                let failed = diagnostics.contains { d in
                    let severity = d["severity"]?.string ?? ""
                    return severity == Diagnostic.Severity.error.rawValue || severity == Diagnostic.Severity.fatal.rawValue
                        || severity == Diagnostic.Severity.programmingError.rawValue
                }
                let ok = status.hasPrefix("clean") && !failed
                var report: [String: JSONValue] = ["ok": .bool(ok), "status": .string(status), "diagnostics": .array(diagnostics),
                                                   "from": "the running app"]
                if let new = doc["new_diagnostics"] { report["new_diagnostics"] = new }
                if let verification = doc["verification"], verification != .null { report["verification"] = verification }
                if !ok, let reply = try? RPCClient.call("document.log", ["path": .string(source.path)]),
                   let log = reply["log"]?.string, !log.isEmpty {
                    report["log"] = .string(log)
                }
                return JSONValue.object(report).jsonString(pretty: true)
            }
            if started < written, status != "compiling", Date() > nudge {
                // The app hasn't picked the change up: ask it once, then compile here.
                if nudged { return nil }
                _ = try? RPCClient.call("document.engrave", ["path": .string(source.path)])
                nudged = true
                nudge = Date().addingTimeInterval(5)
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// The .ly and .ily files beside `source`: where a graphic's definition
    /// is looked for when the app isn't running.
    static func neighbours(of source: URL) -> [ScoreGraphic.File] {
        let dir = source.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.sorted().filter { $0.hasSuffix(".ly") || $0.hasSuffix(".ily") }.compactMap { name in
            let url = dir.appendingPathComponent(name)
            return (try? String(contentsOf: url, encoding: .utf8)).map { (url.path, $0) }
        }
    }

    // MARK: Editing

    /// The `edit` tool: applies the edits, then for a score file returns
    /// the app's engraving of it (check), for a patch file a pointer to
    /// patch_check.
    func edit(_ args: JSONValue) async throws -> String {
        let source = try path(args)
        let ext = source.pathExtension.lowercased()
        let isScore = ext == "ly" || ext == "ily"
        let pondsideOwned = source.lastPathComponent == SCLexiconInclude.fileName
            || (source.lastPathComponent == "pondside.scd" && source.deletingLastPathComponent().lastPathComponent == "dependencies")
        switch role {
        case .graphics?:
            guard isScore else { throw ToolFailure("you edit the score's .ly/.ily files only; the patch agent changes the SuperCollider patch") }
        case .patch?:
            guard ext == "scd" else { throw ToolFailure("you edit the patch's .scd files only (the score agent changes .ly files; patch_note writes the doc)") }
        case nil:
            guard isScore || ext == "scd" else { throw ToolFailure("edit changes .ly, .ily and .scd files") }
        }
        guard !pondsideOwned else { throw ToolFailure("\(source.lastPathComponent) is Pondside's (rewritten by it): change the patch instead") }
        let changes = (args["edits"]?.array ?? []).map { e in
            FileEdit.Change(old: e["old"]?.string, new: e["new"]?.string ?? "", fromLine: e["from_line"]?.int, toLine: e["to_line"]?.int)
        }
        let text = try String(contentsOf: source, encoding: .utf8)
        let (new, lines) = try FileEdit.apply(changes, to: text)
        guard new != text else { return "Nothing changed: the new text is the same as the old." }
        try Data(new.utf8).write(to: source, options: .atomic)
        let range = lines.count > 1 ? "lines \(lines.lowerBound)–\(lines.upperBound)" : "line \(lines.lowerBound)"
        let done = "Edited \(source.lastPathComponent), \(range)."
        guard isScore else { return done + " Call patch_check to hear it (renders the mix)." }
        let root = try args["root"]?.string.map { try path(["file": .string($0)]) }
        if let fromApp = await appCheck(root ?? source) { return done + " check:\n" + fromApp }
        guard let target = root ?? (ext == "ly" ? source : nil) else {
            return done + " The app isn't open on this score: call check on the root .ly."
        }
        return done + " check:\n" + (try await callTool("check", ["file": .string(target.path)]))
    }

    // MARK: The patch agent

    /// The score's Pondside patch, or a failure that says how to make one.
    func patchFile(for score: URL) throws -> URL {
        let config = try? ProjectConfig.find(from: score)
        guard let patch = PatchRender.patch(for: score, configured: config?.handlers) else {
            throw ToolFailure("\(score.lastPathComponent) has no Pondside patch (patch_audit, then patch_migrate, makes one)")
        }
        return patch
    }

    /// The score's cue sheet: the app's latest, else from a compile.
    func cueSheet(_ source: URL) async -> CueSheet? {
        if let sheet = try? RPCClient.call("document.cues", ["path": .string(source.path)]), sheet != .null,
           let data = try? JSONEncoder().encode(sheet), let decoded = try? JSONDecoder().decode(CueSheet.self, from: data) {
            return decoded
        }
        guard let lily = try? await lilypond(for: source), let log = try? await TimingDump.run(lily, source: source) else { return nil }
        return CueSheet(log: log, score: source.lastPathComponent)
    }

    func patchContext(_ args: JSONValue) async throws -> JSONValue {
        guard let f = args["file"]?.string else {
            do {
                return try RPCClient.call("document.patchContext", args["cue"].map { ["cue": $0] } ?? [:])
            } catch {
                throw ToolFailure("Pondside isn't running, so there is no selection: pass file (the score) and line, or cue")
            }
        }
        let source = try path(["file": .string(f)])
        var params: [String: JSONValue] = ["path": .string(source.path)]
        for k in ["line", "character", "cue"] { if let v = args[k] { params[k] = v } }
        if let app = try? RPCClient.call("document.patchContext", .object(params)) { return app }
        let patch = try patchFile(for: source)
        // The app isn't running: one compile gives the cues and the collections.
        var sheet: CueSheet?, collections: [Collections.Collection] = [], tempo: TempoMap?
        if let lily = try? await lilypond(for: source), let log = try? await TimingDump.run(lily, source: source) {
            sheet = CueSheet(log: log, score: source.lastPathComponent)
            collections = PatchContext.collections(in: log)
            tempo = TempoMap(log)
        }
        var point = PatchContext.Point(cue: args["cue"]?.string)
        var context: JSONValue?
        if let line = args["line"]?.int {
            let text = try String(contentsOf: source, encoding: .utf8)
            context = ScoreContext.describe(text: text, file: source.path, line: line, character: args["character"]?.int ?? 0)
            point.bar = context?["bar"]?.int
            point.moment = context?["moment"]?.string.flatMap(Rational.init(parsing:))
            point.seconds = point.moment.flatMap { m in tempo?.seconds(at: m) }
        }
        return PatchContext.describe(score: source, patch: patch, sheet: sheet, at: point, collections: collections, scoreContext: context,
                                     lexicon: SCLexicon.load(project: source.deletingLastPathComponent()))
    }

    /// Renders the mix; reports errors, the cue window's levels before and
    /// after, and the notes the change made stale.
    func patchCheck(_ args: JSONValue) async throws -> String {
        let source = try path(args)
        let patch = try patchFile(for: source)
        let config = try? ProjectConfig.find(from: source)
        let wav = HandlerSync.Layout.mockup(score: source)
        guard FileManager.default.fileExists(atPath: wav.path) else { return "No mockup yet (\(wav.lastPathComponent)): the app writes it after an engraving." }
        guard let sclang = SuperColliderToolchain.findSclang(configured: config?.sclang?.path) else { return "SuperCollider isn't installed." }
        let out = PatchRender.output(for: source)
        var window: (name: String, from: Double, to: Double)?
        if let cue = args["cue"]?.string, let sheet = await cueSheet(source) {
            guard let i = sheet.cues.firstIndex(where: { $0.name == cue || $0.id == cue }) else {
                throw ToolFailure("no cue \(cue); the score's cues: \(sheet.cues.map(\.name).joined(separator: " "))")
            }
            let end = i + 1 < sheet.cues.count ? sheet.cues[i + 1].seconds : sheet.cues[i].seconds + 30
            window = (sheet.cues[i].name, sheet.cues[i].seconds, end)
        }
        func levels() -> (mix: AudioLevels.Level, electronics: AudioLevels.Level?)? {
            guard let w = window, let mix = AudioLevels.level(out, from: w.from, to: w.to) else { return nil }
            return (mix, AudioLevels.difference(out, wav, from: w.from, to: w.to))
        }
        let before = levels()
        let problems: [String]
        do {
            problems = try await PatchRender.render(sclang: sclang, patch: patch, wav: wav, out: out)
        } catch {
            return "Didn't render (the last good mix is kept). \(error)"
        }
        var report = "Rendered \(out.lastPathComponent)."
            + (problems.isEmpty ? " No errors." : " Errors in cues (each stopped that cue):\n" + problems.joined(separator: "\n"))
        if let w = window, let after = levels() {
            func line(_ l: (mix: AudioLevels.Level, electronics: AudioLevels.Level?)) -> String {
                "mix \(l.mix.description)" + (l.electronics.map { "; electronics alone \($0.description)" } ?? "")
            }
            report += String(format: "\nCue %@ window %.2f–%.2f s: ", w.name, w.from, w.to) + line(after)
            if let b = before { report += "\n  before this render: " + line(b) }
            if let e = after.electronics, e.rmsDB < -70 { report += "\n  The electronics are silent in this window." }
        }
        if let doc = try? PatchDoc.update(patch: patch), !doc.stale.isEmpty {
            report += "\nStale notes, rewrite them with patch_note: " + doc.stale.joined(separator: ", ")
        }
        return report
    }

    /// A graphic on its own staff over `bars` bars, engraved to SVG.
    func preview(_ args: JSONValue) async throws -> String {
        guard let id = args["id"]?.string else { throw ToolFailure("missing id") }
        let lex = lexicon()
        guard lex.entries[id] != nil else { throw ToolFailure("no Lexicon entry \(id)") }
        let bars = max(1, min(32, args["bars"]?.int ?? 4))
        let params = args["params"]?.string ?? "()"
        let dir = args["out"]?.string.map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("pondside-preview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(lex.includeFile(for: [id]).utf8).write(to: dir.appendingPathComponent("lexicon.ily"), options: .atomic)
        guard let entry = lex.entries[id]?.entry else { throw ToolFailure("no Lexicon entry \(id)") }
        let score = GraphicEdit.previewSource(entry: entry, params: params, bars: bars, music: args["music"]?.string)
        let file = dir.appendingPathComponent("preview.ly")
        try Data(score.utf8).write(to: file, options: .atomic)
        let lily = try await lilypond(for: file)
        let result = try await LilyPondEngraver(installation: lily).engrave(file, purpose: .export(.svg), outputDirectory: dir.appendingPathComponent("svg"))
        let problems = result.diagnostics.filter { $0.severity != .warning || $0.file?.hasSuffix("preview.ly") == true }
            .map { "\($0.severity.rawValue) \($0.line.map(String.init) ?? "?"): \($0.message)" }
        guard result.succeeded else { throw ToolFailure("preview failed:\n" + problems.joined(separator: "\n")) }
        return JSONValue.object(["svg": .array(result.outputFiles.map { .string($0.path) }),
                                 "source": .string(file.path),
                                 "diagnostics": .array(problems.map { .string($0) })]).jsonString(pretty: true)
    }
}
