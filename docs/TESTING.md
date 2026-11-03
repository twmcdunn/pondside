# Testing

How Pondside is tested today, what each layer can and can't catch, and the
plan for what comes next. Commands are in `AGENTS.md`; this file is about
coverage and intent.

## Layers

| Layer | Runs | Catches | Needs |
|---|---|---|---|
| Seam check (`scripts/check-seam.sh`) | CI, every push | Apple-only imports below `PondsideUI`; `Foundation` in `PondsideCore` | nothing |
| Unit tests (`swift test`) | CI on macOS and Linux | logic in the portable modules | a full Xcode toolchain on macOS (XCTest) |
| Engraving tests | CI against LilyPond 2.24.3 and 2.26.0 | the driver, warm daemon, SVG, timing, Lexicon entries | LilyPond; they `XCTSkip` without it |
| Corpus round-trip / fuzz | CI with `PONDSIDE_CORPUS` | parser losslessness on LilyPond's own regression suite and snippets | the LilyPond sources |
| UI | by hand | layout, focus, HIG behaviour | the running app (`.claude/skills/pondside-ui`) |
| Agent smoke test (planned) | by hand | breaks in Claude Code or opencode | the agents installed and logged in |

A green `swift test` without LilyPond has tested nothing about engraving:
check the skipped tests before claiming success.

## What the unit tests cover now

- **Core** (`PondsideCoreTests`): lossless CST (`tree.reconstructed ==
  text`), minimal-diff `ScoreEditor` edits and their inverses, note input,
  the command catalog and keyboard audit, pane layouts (including the
  Agent Log toggle), engraving settings, the lens, SuperCollider parsing,
  Score Setup (`ScoreSetupTests`: instrument matching, staff names and
  clefs through variables and files, `front-matter.ily` sections, notes
  and legend, header fields, legend candidates found in the instrumental
  music: `LegendScanTests`).
- **Engrave**: toolchain, daemon, SVG geometry and hit-testing, mockup and
  mix rendering, playback, render cache, shadow history, timing dump; the
  marked section's interpolated edge moments (`SectionTimeMapTests`), the
  staff-line window recipe (`StaffLineWindowTests`) and the bounded raw
  compiler log (`CompilerLogTests`).
- **Timing**: cue timing, handler sync, patch migration, the patch outline
  and doc (`PatchOutlineTests`: items and their lines, what a handler
  touches, notes kept across rebuilds and flagged stale when their code
  changes, the Lexicon include's load line).
- **Lexicon**: entry loading and validation, engraving each entry, the
  front matter engraving (cover, notes, a legend of real entries) with its
  examples kept out of cue timing (`FrontMatterEngravingTests`), and the
  skills' description of `front-matter.ily`; the SuperCollider Lexicon
  (`SCLexiconTests`: every entry loads with its params in its code, and the
  include of all of them compiles in sclang and builds every SynthDef;
  skipped without SuperCollider).
- **Bridge**: MCP protocol and tools, RPC socket, score context and
  graphics (including the no-graphic `code` layout/index and the hybrid
  empty-section prompt), agent configs (`AgentSetup`), the agent log (`AgentLogTests`:
  JSONL append and incremental read, both agents' event streams, the
  pane's presentation), opencode's models, inline config and log-read
  provider errors (`OpencodeTests`); the `edit` tool's edits, the patch
  agent's context, `sc_lexicon_add`, the two roles' tools and files, and
  the prompts (`PatchAgentTests`).

## Gaps, and unit tests to add

Roughly in order of value.

1. **`AgentSession` against a fake agent.** A small script on `PATH` that
   speaks stream-json (Claude) or ACP (opencode) and replays canned
   transcripts. Tests: a request and its outcome; follow-ups reuse the
   process; restart resumes the session; a resume that fails starts a new
   session; `interrupt` (ACP `session/cancel`; Claude's process ends);
   the "previous request was stopped" note; permission requests answered;
   a process that dies mid-request fails the request and not the next
   process's calls (the race fixed on 2026-10-31); costs as differences of
   the session total. Runs in CI: no model, no network.
2. **`AgentRun`**: `arguments` for each harness (Claude's `--tools`,
   opencode's `--title`), `environment` (tool search off, opencode's
   denied tools, the log variables), `parse` of real captured outputs,
   `commandLine` quoting.
3. **MCP tool-call logging**: with `PONDSIDE_AGENT_RUN` (and the run file)
   set, `tools/call` appends an `mcp` entry with duration and arguments;
   without it, nothing is written.
4. **Prompts**: `graphicsPrompt` and `migrationPrompt` include the skill,
   the context and the speed rules; the follow-up prompt is short.
5. **Score context for real scores**: the selected graphic's definition and
   drawing are found for the scores in `Tests/Scores` (an agent without
   them searches the files and is slow).
6. **Captured transcripts as fixtures**: keep a few real event streams per
   agent version in `Tests/PondsideBridgeTests/Fixtures`, so a format
   change shows up as a diff when they are refreshed.

UI code (`PondsideUI`) stays compile-checked only; keep logic out of it
(the Agent Log's formatting lives in `AgentLogPresenter` for this reason).

## Agent smoke test (planned)

**Why.** Pondside drives two outside programs whose interfaces it doesn't
control. Claude Code's headless interface (`-p`, stream-json, `--resume`,
`--mcp-config`, `--allowedTools`) is the one its Agent SDK uses and is
fairly stable; `--tools` and `ENABLE_TOOL_SEARCH` are newer. opencode's
ACP core (`initialize`, `session/new`, `session/prompt`, `session/update`,
`session/cancel`) is a versioned protocol shared with other editors;
`session/resume` is newer. opencode's own `run --format json` output and
permission names have changed between releases. Unit tests with fake
agents can't see any of that.

**When.** By hand, not in CI: before bumping a version in
`scripts/installer/versions.env`, and when an agent update seems to have
broken requests (the Agent Log, ⌘⌥A, names the version of every session).
CI would need the agents installed and logged in, would spend money on
every push, and model answers vary, so it would fail at random.

**What.** `scripts/agent-smoke.sh`, driving Pondside's own `AgentSession`
and `AgentRun` (a small executable target, or `pondside` subcommand) in a
throwaway folder holding a tiny score, for each installed agent:

1. A request that calls `check` and answers in one word: the MCP server
   connects, a tool call and a reply arrive, the outcome isn't failed.
2. A follow-up that needs the first ("what word did I ask you to
   remember?"): the conversation is kept.
3. Close the session and ask again: the session resumes.
4. Start a longer request and stop it: it comes back stopped, and the next
   request doesn't carry it on (no file written).
5. One `AgentRun` (the migration path) with a one-line prompt.

It prints pass or fail for each step with the agent's version and the
relevant Agent Log lines, and leaves the log in the throwaway folder
(`PONDSIDE_LOG_DIR`). Roughly 30 s per agent, a few cents with Claude,
nothing with opencode's free models.

The end-to-end runs done by hand on 2026-10-31 (Claude Code 2.1.316,
opencode 1.19.4) followed these steps and are the template.
