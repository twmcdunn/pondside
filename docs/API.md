# Pondside for agents and scripts

Pondside's first API is the file. A score is plain LilyPond. Any tool can
read and write it, and the app re-engraves when it changes on disk, merging
the change into whatever is open. Everything below is for when a tool wants
more than text: diagnostics from LilyPond itself, events with resolved
pitches, cue times, the Lexicon.

Every surface here is portable: the CLI and MCP server link no AppKit and
run on Linux.

## The CLI

```
pondside check   score.ly [--json]                 compile; diagnostics, overflowing systems; exit 1 on errors
pondside render  score.ly [--format pdf|svg|png] [--out dir] [--json]
pondside cues    score.ly [--format json|cues|marks|ec] [--rate 48000] [--out file]
pondside timeline score.ly [--json]                tempo steps: moment, seconds, quarters/min
pondside handlers score.ly [--scd f]               the patch (patch/score.scd) and its engine, with a stub per cue
pondside mix     score.ly [--scd patch.scd] [--out f]   the patch rendered offline in mockup mode (renders/score.mix.wav)
pondside patch   score.ly [--scd f] [--from f] [--fix [--agent auto|claude|opencode|codex]]   audit a patch; --fix migrates it;
                                                      --agent then has claude -p / opencode run / codex exec finish it
pondside lexicon list | search <words> | show <id> | impl <id>
pondside lexicon check score.ly | include score.ly | lock score.ly
pondside lexicon drafts | promote <id> [--to user] | discard <id>   agent drafts: only people promote them
pondside mockup  score.ly [--out file.wav] [--stems] [--timing f] [--force]   the playback (below) as audio, padded to the
                                                      end mark (renders/score.wav), its cue times beside it (renders/score.cues); --stems:
                                                      one file per staff (the app runs it after each good engraving)
pondside history score.ly [--show <rev> [--file f]] [--restore <rev>]   checkpoints, kept outside your repo
pondside links   page.svg [--json]                 point-and-click links with bounds
pondside doctor  [--json]                          every LilyPond found, version and origin
pondside watch   file --on-change <command>
pondside mcp     [--project dir]
pondside completion zsh|bash                       eval "$(pondside completion zsh)"
```

- `render` always disables point-and-click, then scans the output for local
  paths before writing it.
- `cues` and `timeline` come from LilyPond's interpretation of the score:
  a dump engraver runs during a normal compile. No timing is guessed from
  the text. Seconds are the MIDI's seconds: stepped tempos, 60 quarters a
  minute before any `\tempo`, hidden `\playTempo` changes included.
- `--format cues` writes `seconds<TAB>bar<TAB>cue N` lines, the format
  SuperCollider loaders in the lilypond-supercollider workflow already
  read; `marks` the `\timingMark` lines starting with `--prefix`
  (default `improv`) in the same shape; `ec` the pitch classes of each
  `\collection` on `--staff` (default `elecUp`) as `~ec`/`~ecWhere`, as
  `piece.ec.scd` always held them.

## Project settings: `pondside.toml`

Put `pondside.toml` at the project root. The CLI and the app read the
nearest one at or above the score, and command-line options override it.

```toml
[project]
score = "quartet.ly"          # the score the project root opens (set when the folder has several)

[lilypond]
version = "2.26.0"            # compile with this LilyPond; wins over \version

[audio]
sample-rate = 48000           # cue samples and the mockup; the quark checks it
renderer = "musescore"        # or "fluidsynth"
soundfont = "sounds/piano.sf2"
parts = "resources/improv"    # recordings mixed into the mockup at their marks (improv1.wav at "improv 1")
hook = "improv/render.scd"    # or a script that renders them: sclang hook score.wav marks.txt out.wav parts
hook-marks = "improv"         # the marks the hook gets (default improv)

[supercollider]
handlers = "patch/cues.scd"   # the default for `pondside handlers`
resources = "patch/resources"
path = "/Applications/SuperCollider.app"   # the SuperCollider pane's sclang (or sclang itself); found if omitted
```

File › LilyPond Version… in the app writes `[lilypond] version` for you.

### The project root

The app opens a project by its root folder (File › Open Project Root…), and
File › New Project… creates one. Every project gets the same structure,
added when missing each time it opens (`ProjectStructure` in
PondsideBridge); the composer's own files are never touched:

```
<root>/<name>.ly                        the score: [project] score, else the folder's only .ly,
                                        else the one nothing \includes (named after the folder, or score.ly)
<root>/lexicon.ily                      the Lexicon entries the score uses (regenerated)
<root>/patch/<name>.scd                 the SuperCollider patch (a starter until the composer writes one)
<root>/patch/dependencies/pondside.scd  its engine (kept current)
<root>/patch/resources/                 the patch's sounds, empty to start ([supercollider] resources)
<root>/renders/                         mockup, cue times, mix
<root>/.mcp.json, opencode.json, .codex/config.toml         `pondside mcp` for agents started here
```

Opening a `.ly` file from Finder resolves the project in its parent folder,
including `[project] score`. An existing `pondside.toml`, or the `patch/`
and `renders/` directories, identifies a project. Otherwise Pondside offers
Create Project or Cancel before writing anything. Creating the project
adopts that score and records it in `pondside.toml` without changing its music.

A folder with no score offers to start `<folder>.ly`; one with several
asks which and records it as `[project] score`.

### Source navigation

LilyPond (`.ly`/`.ily`) and SuperCollider source editors show line numbers.
Wrapped continuations keep their logical line number, matching compiler
diagnostics. **Go → Go to Line…** (`⌘⌥L`, or leader `gi`) accepts a
1-based line number in the active source file. From the score view it opens
the LilyPond source editor. Press Return to jump and Escape to cancel.
Source locations in preparation-error dialogs and Compiler Output are
clickable: they open the file in Pondside at the reported line and column.
Links focus an existing source pane in place. If none is visible, they add
a source pane alongside the current panes.
**View → Clear Focused Log or Terminal** (`⌘⇧K`, leader `vx`) clears only
the focused LilyPond log or terminal. In other panes it does nothing.
The next compile supplies fresh log output; clearing the terminal erases
its display and scrollback while its shell and running commands continue.
`⌘K` still opens the command palette.

### Restore Defaults and structural editing

The same **Restore Defaults** dialog appears once when a score is first
opened and is available again in Engraving Settings. It offers only the
original converter repairs (automatic beaming and key-signature
cancellation, when still disabled) and one checkbox for coordinated meter
and break editing. Unchecking a choice leaves that aspect alone. Paper,
fonts, spacing, hidden signatures, and all other engraving preferences
remain under their existing Settings controls; opening a converted score
never resets them through this dialog.

Coordinated editing runs a separate, cancellable migration with a progress
animation. **File → Make Score Pondside-Ready…** (leader `fi`) and the
matching Engraving Settings button run it again at any time. LilyPond
evaluates temporary copies of the original source, a timing probe, and
the proposed migration. Pondside compares musical events and structural
boundaries before saving. Invalid source or ambiguous timing stops the
process with compiler diagnostics; no project files are saved. Normal
engraving starts after the prepared source has been saved.

For supported scores, shared measures add a marked block before the root's
includes and wrap each voice's existing music:

```lilypond
% pondside-structure v1 breaks=1
% ... pondsideMeasure helper ...
pondsideBarA = { \time 5/4 s1*5/4 \break }
pondsideBarB = { \time 3/2 s1*3/2 }
% end pondside-structure

% In any included voice:
flute = {
  \pondsideMeasure \pondsideBarA { c''1 r4 } |
  \pondsideMeasure \pondsideBarB { d''1 r2 } |
}
```

These definitions are the authority, and their order is the score's
order. Bar names are identities, not positions: a bar added mid-score
(Add Bar ⌥B, Add Bars… ⌥⇧B) takes the next unused name, so no existing bar,
layout anchor or `\pondsideSpace` reference is ever renamed. A meter belongs to the beginning of
its measure, even when the selected note is inside a tuplet or tremolo.
A break before the selected measure belongs to the preceding definition's
end. Do not add competing local `\time`, `\break` or `\pageBreak`
commands while their shared choices are enabled.

The helper computes each body's duration when LilyPond reads it, pads
underfilled bodies with skips, and rejects overflow. Plain spacer-only
measures become elastic empty bodies (`s1*0` provides a source anchor).
Single unadorned full-measure rests also follow the shared length.
Sounding music and ordinary rests retain their written durations;
shortening cannot cut them. Layout-only skip streams use the explicit
measure-relative anchors described below. This works in normal LilyPond
compiles and mockup/MIDI exports without a running app.

GUI meter changes, Enter for system breaks, Shift-Enter for page breaks,
and unmetered entry require
the coordinated editing contract (or the corresponding choices in an
older source contract). Without it, edit structural commands in
Source. Unmetered note insertion, duration changes, dots and deletion use
a coordinated project edit; `|` selects the next measure or appends one
across the voices. Each shared measure has its own meter, so exiting
unmetered entry does not insert a local restoring meter.

Break edits display a click-through, icon-only pulsing marker immediately,
before source updates, until their engraving completes. Reduce Motion uses a
steady icon; its tooltip and accessibility label explain the pending change. Undo
and redo restore the coordinated source edit on the originating file's undo
stack. In note-entry mode, Left first selects the note immediately before
the cursor; further arrow presses navigate existing notes.

Shift-click in the notation lens extends the current note selection. Lens and
score highlights update together. Arrow navigation reuses unchanged lens layout
and indexed score links; source scrolling follows after a 0.1-second pause.
The selection used by editing commands always updates immediately.

Known engraving-only edits (breaks, paper, headers and literal grob appearance)
do not launch playback preparation. Unknown changes use the normal MIDI/cue/
parts cache, which leaves the mockup untouched when sound is unchanged; the mix
then retains its existing audio. Tempo, dynamics, pitch, durations, MIDI
instruments and opaque Scheme remain significant.

In the score, ⌘C copies selected notes, chords or rests as self-contained
LilyPond notation with explicit pitches and durations; ⌘V inserts it after
the selection (or in the next shared measure when the current one is full).
⌘X copies and deletes. Pasting preserves surrounding relative pitches and
inherited durations and is one undo step. Complete tuplet and slur/beam spans
are preserved; orphaned slur/beam endpoints are omitted. Copying across voices
or from grace/tremolo passages is refused. In source and code panes these
shortcuts retain their normal text-editing behavior.

Migration measures complete musical streams with LilyPond, including
music generated by custom functions, tags, ordinary tuplets and tremolos.
Custom function calls remain in the source. Separate layout
tracks can group several measures between bar checks, use long skips
across measures, and finish before the score ends. Migration splits their
skips at the musical boundaries and expands finite spacer-only
`\repeat unfold` bodies. `\autoLineBreaksOff`, `\autoPageBreaksOff` and
`\newSpacingSection` are preserved. Existing `\break` and `\pageBreak`
commands at measure boundaries are collected into the shared timeline.
Literal commands are removed from their original voices; commands produced
by functions are stripped from the evaluated music by the shared helpers.

Inside a measure, timed layout commands are anchored by explicit rational
positions: `\pondsideSpace \pondsideBarA #1 #2` spans half of that
measure's shared length. This keeps spacing-section changes and other
supported layout events at their relative positions when a meter changes;
long skips no longer hide independent absolute-duration bookkeeping. The
helper is normal LilyPond source and does not require the app to compile.
The portable source-only importer uses these spaces. The evaluated importer
uses `\pondsideLayout` with explicit anchors for each evaluated silent
rhythmic event and a shared `pondsideTimeline`. These anchors resize the
existing layout music without flattening custom calls. Its marker includes
`evaluated=1`. An altered function that invalidates those anchors must be
corrected in Source before migration can run again.

Repeated source passages that occur at different musical positions,
pickups, cadenzas, independent meters, and ambiguous source boundaries
are rejected rather than guessed. Embedded music in Scheme helper
definitions and front-matter examples is excluded from the score's voices.
Pondside-generated cover, notes and legend bookparts keep their own example
meters and are never wrapped into the shared timeline. Validation compares
rhythmic durations as exact musical lengths, allowing equivalent full-rest
spellings such as `R4*7` and `R1..`.
A break inside a measure is reported with its moment rather than silently
moved to a different boundary. Unsupported cases are explained in the
compiler output while converter repairs remain available. Later source violations
block GUI structural edits. Reapplying the contract refreshes its generated
helper, including compatibility fixes for LilyPond's compound page-break
music (an EventChord rather than a bare PageBreakEvent).

Structured GUI edits validate the complete proposed project contract before
changing source. Source autosave also validates a managed project and writes
its dirty files together; an invalid edit remains in the source buffer, is
copied to Recovery, and is not written over the last valid files. The failure
appears in the status bar. Restore the contract in the buffer to resume saving.

Ordinary note entry checks explicit measure durations;
function-generated timing is checked by normal background engraving.
At the end of a full metered measure, entry starts the next measure of the
same voice when available, and checks that destination measure. Overflow
and too-short meters are blocked with feedback in the lens,
without a dialog. Meter shortening checks that measure across voices; an
opaque generated passage cannot be shortened without known timing.
Unmetered entry requires explicit note durations and updates the shared
length without revalidating the whole contract. Shortening leaves room for
other voices' existing music; edit opaque generated passages in Source.

The edit planner is portable (`PondsideCore/Editing/StructuralEditing`).
The app checks buffer and disk revisions before applying a project edit,
rolls back completed writes if a later write fails, refreshes the graph
once, and registers a single undo/redo action in the invoking file's
history. Files outside the loaded include graph are never rewritten.

## MCP

`pondside mcp` speaks the Model Context Protocol on stdin/stdout (JSON-RPC
2.0, one message per line). Protocol versions: 2025-06-18, 2025-03-26 and
2024-11-05.

Setup:

| Client | How |
|---|---|
| Claude Code | `claude mcp add pondside -- pondside mcp` |
| opencode | in `opencode.json`: `"mcp": { "pondside": { "type": "local", "command": ["pondside", "mcp"] } }` |
| Codex | project `.codex/config.toml`: `[mcp_servers.pondside]` with `command = "pondside"` and `args = ["mcp"]` |
| anything else | `{ "command": "pondside", "args": ["mcp"] }` in the client's MCP server list |

Per folder, with no setup: when the app opens a score it writes
`.mcp.json` (Claude Code), `opencode.json` (opencode) and
`.codex/config.toml` (Codex) in the score's
folder, and `pondside agents [dir]` does the same from the shell. An agent
started in that folder, such as in the app's terminal pane, starts
`pondside mcp` itself; Claude Code asks once to approve it. A file that
already exists only gains a missing `pondside` server: other servers and
settings stay, an existing `pondside` entry is left as it is, and a file
that isn't plain JSON (opencode's JSONC comments) is not touched.
Codex loads the project config after the user trusts the project; restart
Codex after opening an existing score to pick up the new config. Codex TOML
settings and comments are preserved by appending the missing server. Unsupported
TOML (including arrays of tables) and inline `mcp_servers` tables are left
untouched and reported as skipped by `pondside agents`. The
configs name a bare `pondside`. The terminal pane puts the app's bundled
CLI first on `PATH`; elsewhere, install it (Pondside ▸ Install Command-Line
Tool links it into `~/.local/bin`).

Pass `--project <dir>` if the client starts servers somewhere other than
the score's folder. Relative `file` arguments and the project Lexicon scope
resolve against it.

`--role graphics` or `--role patch` serves one of the app's two lens
agents (DESIGN.md §8): each sees only its tools and its own instructions,
and `edit` changes only its files (`.ly`/`.ily`, or the patch's `.scd`).
Without a role, as from the terminal or for a migration, every tool is
offered.

| Role | Tools it doesn't see |
|---|---|
| `graphics` | `patch_context`, `patch_doc`, `patch_note`, `patch_check`, `sc_lexicon_*`, `patch_migrate` |
| `patch` | `check`, `query`, `render`, `lexicon_*`, `graphic_preview`, `graphic_insert`, `patch_migrate` |

### Tools

| Tool | Arguments | Returns |
|---|---|---|
| `edit` | `file`, `edits: [{ old?, new, from_line?, to_line? }]`, `root?` | applies every edit or none: `old` is exact text, unique in the file (the contexts' `412| ` prefixes are stripped if copied); `from_line`…`to_line` replaces whole lines as the contexts number them, and with `old` too checks they still say it (else says where `old` is now). No reading the file first. For `.ly`/`.ily` it then returns `check`'s result (the app's engraving; `root` for an `.ily` when the app isn't open); for `.scd`, a pointer to `patch_check`. Pondside's own `pondside.scd` and `sc-lexicon.scd` are refused |
| `check` | `file` | `{ ok, pages, diagnostics: [{ severity, file, line, column, message }], overflows?, log? }`. `overflows`: with `\autoLineBreaksOff`, the systems that run into the right margin, `[{ page, mm_past_margin, first: { file, line, column }, message }]` (no spacing setting narrows them: move a bar or narrow the content). On failure, `log` is the bounded tail of LilyPond's own log, including Guile backtraces the parser cannot locate. When the app has the score open: the app's engraving of the files as they are now (`from: "the running app"`, about a second), else a compile |
| `query` | `file`, `from_line?`, `to_line?` | events in order: `{ kind, text, line, character, pitches, duration, explicitDuration }` |
| `render` | `file`, `format?` (`pdf`·`svg`·`png`), `out?` | `{ files }` |
| `cues` | `file`, `rate?` | cues.json (below) |
| `lexicon_check` | `file` | problems with `\lexicon` and `\startGraphic` uses, by line |
| `patch_audit` | `file`, `scd?` | what keeps the score's patch (or the folder's likeliest `.scd`) from being a Pondside patch: what `patch_migrate` does, what is left |
| `mix` | `file` | renders the score's patch offline in mockup mode into `renders/score.mix.wav`: whether it rendered, and the errors its setup or cues printed |
| `warn_user` | `message`, `title?`, `file?` | an alert on the score's window in the running app: something went wrong that the user must know |
| `ask_user` | `question`, `choices?` (up to 4), `file?` | a dialog asking the user; waits, and returns the answer (or that they skipped it) |
| `patch_migrate` | `file`, `scd?`, `from?` | migrates it into `patch/score.scd`, moving what it uses into `patch/` (docs/SUPERCOLLIDER.md), and lists what it did and the lines it marked `// pondside:` |
| `score_context` | `file?`, `line?`, `character?` | what "here" means: the event, its staff's `.ly`, bar, `moment` (whole notes from the staff's start, for a plain voice), the graphic at or around it (below), the marked graphics range when the user ⌥-dragged (`selection.kind: "graphic-section"`: `from`/`to` edges, `x`, `page_x`, `spanner_x` and `at` for each, and the selected range on every `systems` entry), every cue as `"7: bar 9 beat 2, moment 221/8, 75.5 s"`; from the running app also `system: { first, last, next }`. With no graphic at the point, `code` gives the root `layout` blocks and a short index of top-level definitions, so a notation/layout request does not need to read a whole file. Without arguments, the app's selection; a normal click selects or places notes, and graphics requests always come from a marked range |
| `lexicon_search` | `query`, `limit?` | tier 0 lines, best first |
| `lexicon_entry` | `id` | tier 1: params with types, ranges and docs; README |
| `graphic_preview` | `id`, `params?`, `bars?`, `music?`, `out?` | `{ svg, source, diagnostics }`: the entry engraved on its own staff |
| `graphic_insert` | `file`, `id`, `params?`, `start_line`, `start_character`, then `stop_line` + `stop_character` or `stop_moment`; `root?` | inserts `\startGraphic`…`\stopGraphic` (one staff); a stop at a moment inside a skip splits it (`s1*a s1*b\stopGraphic`); writes `lexicon.ily` and includes it in the root |
| `lexicon_propose` | `id`, `entry_toml`, `impl`, `readme` | writes a validated draft to `Lexicon/drafts/entries/<id>`; the user accepts or discards it |
| `patch_context` | `file?` (the score), `line?`, `character?`, `cue?` | the patch agent's context at a point: the cue at or before it (`name`, `bar`, `beat`, `seconds`, `handler`, `window` until the next cue, `code`: the handler numbered, `touches`: the items it uses with their code when short), `next_cue`, the pitch `collections` around it (`pitch_classes`, `midi`), the patch `doc`, `stale_notes`, every cue, and `sc_lexicon` (one line per entry). No arguments: the app's selection |
| `patch_doc` | `file` | the patch doc (below), rebuilt from the code; stale notes listed |
| `patch_note` | `file`, `item`, `note` | writes the note on one item (`cue cue-12`, `synthdef \grain`, `pattern ~cloud`, `overview`), stamped with its code's hash; an empty note removes it |
| `patch_check` | `file`, `cue?` | renders the mix (as `mix`); errors; for the cue, RMS and peak in its window of the mix and of the electronics alone (mix − mockup), before and after; notes the change made stale |
| `sc_lexicon_search` | `query`, `limit?` | SuperCollider Lexicon lines, best first |
| `sc_lexicon_entry` | `id` | an entry in full: how to call it, params, usage, README, code |
| `sc_lexicon_add` | `file`, `ids` | writes `patch/dependencies/sc-lexicon.scd` with the entries and what they require; the first time, adds its load line after the engine's and says which line moved |

`score_context`'s `graphic` is a Lexicon graphic's `{ entry, params,
start, stop }`, or, for a graphic drawn by the score's own code (a
`\startGrains` defined as a text spanner with a custom stencil),
`{ command, start, stop, definition, drawing, uses, notes }`: the command's
definition line, the stencil procedure it names (file, lines, and its text
when under 150 lines), the helpers and constants that procedure uses with
their definition lines, and the comments in the score's files that
describe the command. Paths beside the clicked file are relative to it.

When there is no graphic at the point, `code` is
`{ layout: [{ file, from_line, to_line, text? }], definitions: [{ name, file, line, text }] }`:
the root's layout blocks and a short index of top-level definitions. It is
the no-drawing context for a notation/layout request; read only the lines
it names.

`selection` is the marked graphics range: `{ kind: "graphic-section", page,
x: [from, to], y: [low, high], spanner_x: [[from], [to]], from, to, systems,
units }`. `from` and `to` each carry `{ page, x, page_x, spanner_x, at }`;
`x` is the edge as a fraction of that system's broken piece, `page_x` the
same edge in page coordinates, and `at` the moment at that edge
(`{ bar, moment, event?, source }`, `source` being file, line and character),
interpolated from the engraved notes' x positions. `systems` lists every
covered system with its selected `x`, `staff_x`, `page_x` and `spanner_x`
range, and its 1-based `ordinal` (for a `StaffSymbol.stencil` window). The
moments identify the start and end systems; the edges are the fractions.
Follow `lexicon://guide/graphics` for drawings. A marked range with no
drawing is either a new drawing (graphics) or a notation/layout change
(`skill://lilypond`); a one-off notation change does not need a Lexicon
entry. A normal click without ⌥ selects or places notes; it never creates a
graphics selection.

Code in `score_context` and `patch_context` (`definition`, `drawing`,
`uses`, `music`, a cue's `code` and `touches`) is numbered as in its file,
`412| (define …`, so an agent edits it with `edit` without reading the file.
A drawing's `uses` are the helpers and constants it calls, in full when
under 60 lines (400 lines in all), and what those call by their definition
line.

### The patch doc

`patch/score.patch.md` is the patch agent's memory (docs/SUPERCOLLIDER.md,
"The patch agent"). Its headings and `file:lines` lines are the outline,
rebuilt from the code on every read (`PatchOutline`: SynthDefs, patterns,
`Pdef`/`Ndef`/`Tdef`, buses, buffers, groups, synths, functions, routines
and other values assigned to `~names`, cue handlers, live-only blocks, and
the Lexicon entries the patch loads); under each heading is a note, kept:

```markdown
## pattern ~cloud
`score.scd:12-15` · ~cloud = Pbind(
**Stale:** the code changed since this note was written.
<!-- note e83ca850 -->
The flute's halo: starts at cue 12.
```

`<!-- note HASH -->` is the code's hash when the note was written (runs of
whitespace ignored); the stale line is shown while it differs. A note
whose item has gone stays at the end, marked *No longer in the patch.*
Notes written by hand without a hash never go stale.

`query` pitches are absolute Dutch names (`c'` is middle C) in any input
language, with `\relative` and chord-repeat (`q`) resolved. `character` is
the 0-based Unicode-scalar offset within the line, as in LilyPond's
point-and-click. Tool failures, such as a missing file or LilyPond not
installed, come back as results with `isError: true`, not as protocol
errors.

### The .ly contract for agents

Every agent request and score-editing tool includes a sentence explaining the
shared-measure contract and a link to [the complete contract](pondside://contract).
Read it with `resources/read` using URI `pondside://contract`; it is available
in installed builds, as well as this document's
[structural editing section](#restore-defaults-and-structural-editing).
The `edit` and `graphic_insert` tools preflight managed source before writing.
Interpreter-dependent timing is still checked by LilyPond during engraving.

### Resources: the Lexicon in three tiers

| URI | Tier | Content |
|---|---|---|
| `lexicon://index` | 0 | one JSON line per entry: id, gloss, kind, tags, param names, whether it has a sound |
| `lexicon://entry/{id}` | 1 | entry.toml plus the README: param types and ranges, when to use, pitfalls |
| `lexicon://impl/{id}` | 2 | impl.ily, to read only when adapting the entry |

Read the index first, open an entry only when it is a candidate, and read
its implementation only to adapt it.

### Skills (resources and prompts)

| URI / prompt | Use |
|---|---|
| `lexicon://guide/graphics` · `graphic-notation` | graphic notation from the marked range: one `edit` from the numbered context (it returns the engraving); the `section-window` so only the box changes; terse words to params ("taller", "denser"), scaled to be visible at a glance; new graphics in the same box; the core entries; envelopes; legend. It routes notation/layout requests to `skill://lilypond` |
| `lexicon://guide/entries` · `lexicon-entries` | writing a new entry when no combination satisfies the user: the graphics kit's API, the entry folder, LilyPond and Guile gotchas, checks |
| `skill://lilypond` · `lilypond` | writing, spacing and debugging LilyPond: project layout, the compile-and-look loop, Scheme and Guile gotchas. The route for a marked range with no drawing and a notation/layout request; edit score code, not a forced Lexicon entry |
| `skill://lilypond-contemporary-notation` | aleatoric boxes, links, timed improvisation, air/slap notation (library `contemporary.ily`) |
| `skill://lilypond-electronics-staff` | an electronics staff: `\ecue`, `\edesc`, `\collection` (library `electronics.ily`) |
| `skill://lilypond-supercollider` | the score-to-patch workflow: timing, holds, Muse Sounds renders |
| `skill://sc-patch-migration` | finishing a migrated patch: the lines marked `// pondside:` (Claude Code: `/mcp__pondside__sc-patch-migration`) |
| `skill://sc-patch-editing` | the patch agent: a request at a point → `edit` the cue's handler → `patch_check` → `patch_note`; where code goes; the SuperCollider Lexicon; terse words to code |

Every folder in `Sources/PondsideLexicon/Core/Skills` is served this way.
A skill's other files are resources at `skill://<skill>/<path>`, listed at
the end of its text; agents copy a library into the score's folder before
including it.

### Graphic entries

`\startGraphic "id" #'((param . value) …)` on an event and `\stopGraphic`
on a later one in the same staff draw a graphic between them, at layout
time, through the graphics kit (`pondside-graphics.ily`, included by
`lexicon.ily`). Core graphic entries: `grain-cloud`, `staff-ripple`,
`wedge`, `swell-shape`, `scribble`, `arc`, `squiggle`, `pitch-band`,
`aleatoric-box`. `envelope` params take a number or `(swell n lo hi)`,
`(linear a b)`, `(pulse …)`, `(lfo …)`, `(points (q v) …)`, `(sum …)`,
`(product …)`, `(smooth …)`. Graphics are linked by point-and-click to
their `\startGraphic` (as are a score's own graphic spanners to their start
command); clicking anywhere in a graphic's area selects it. Drafts in `Lexicon/drafts/` are usable at once and
listed as drafts; `pondside lexicon lock` records the versions a score uses
in a comment block, and `check` warns when an entry has changed since.

### Agent log

With `PONDSIDE_AGENT_RUN` (or `PONDSIDE_AGENT_RUN_FILE`) in its environment,
as when the app starts an agent, `pondside mcp` appends each tool call
(name, arguments, result, duration) to the agent log,
`~/Library/Logs/Pondside/agents.jsonl` (`PONDSIDE_LOG_DIR` overrides). One
JSON object per line: `time`, `run`, `kind` (`graphics`, `refactor`, `mcp`),
`level`, `event`, `message`, `elapsed`, `detail`.

## Playback

What the mockup plays and what cue times are computed from come from one
compile of the same music, so they agree. A score with its own `\midi`
block plays as written. Any other gets a playback score generated at
compile time (`Sources/PondsideEngrave/Playback/pondside-playback.ily`,
loaded with `-dinclude-settings`); the `.ly` files are never edited:

- repeats are played out (`\unfoldRepeats`), so a cue inside a repeat fires
  on each pass, and bars count the music as played, not as printed;
- tremolos between notes play as alternating notes, `c2:32` as repeated ones;
- trills play as alternating notes in 32nds, from the written note:
  `\trill`, `\startTrillSpan … \stopTrillSpan` over several (tied) notes,
  `\pitchedTrill`, a `trill-upper` sign ("♯" "♭" "♮") and `\shapedTrill`
  speeds (`trill-shape`: 32nds at 1, eighths at 0); the upper note follows
  the key signature;
- `\articulate` (LilyPond's own) shortens staccatos, joins slurs and plays
  ornaments and "rall."; a voice it fails on plays as written;
- dynamics are read per staff, so dynamics in a voice of their own reach
  the notes, over velocities 0.15–1;
- `midiInstrument` comes from a staff's `instrumentName` when it has none
  (flute, clarinet, violin, piano …); staves named Electronics or Tape keep
  their cues but are silent;
- music tagged `printed` (the lilypond-supercollider convention for an
  improvisation) is silent but keeps its time.

Holds and timed passages are hidden tempos (`\playTempo`, the
`timed-fermata` and `senza-misura` entries); `\articulate` leaves fermatas
alone. Scores inside a `\book` are not covered yet: give them a `\midi`.

## cues.json

```jsonc
{
  "schema": 1,
  "score": "piece.ly",
  "sampleRate": 48000,
  "tempo": [ { "moment": "0", "seconds": 0, "bpm": 72 }, … ],   // quarters per minute
  "cues": [
    {
      "id": "cue-12",               // name + occurrence: stable when the cue moves
      "name": "12",
      "index": 12,
      "position": { "measure": 42, "beat": 1, "moment": "167/4" },  // moment: whole notes, exact
      "seconds": 133.333,
      "samples": 6400000,           // round(seconds × sampleRate)
      "handler": "cue12",           // the handler's name in the generated .scd
      "entry": "air-tone",          // a Lexicon entry's cue: the entry, and its
      "params": { "amp": 0.25, "dur": 4, "rate": 1 }   // [sound] params with real timing
    }
  ],
  "marks": [ { "text": "improv 1", "position": { … }, "seconds": 210.5 } ],
  "duration": 412.0,                // to the "end" mark, else the last event
  "warnings": [ "two different tempos at moment 21/2: …" ]
}
```

Cues are `\ecue "N"` (the electronics staff library) or Lexicon entries
with a `[sound]` binding. Both put a `cue-label` on a hidden text event.

## SuperCollider

The whole reference (every block of the patch, the offline render, and
migrating a patch written elsewhere) is docs/SUPERCOLLIDER.md.

**The patch.** `patch/score.scd` (marked `// @pondside patch`) is the
composer's code with a first block that sets `~mode` (`\mockup` or `\live`)
and loads the engine, `patch/dependencies/pondside.scd`, which Pondside
writes and keeps current. Then come a cue block (`~cue[\cue12] = { |cue| … };`
per cue) and the run lines: `~triggerCue.()` (cue 1 starts the piece, then
the next cue), `~triggerCue.(12)` (start at or jump to cue 12) and
`~stop.()`. The SuperCollider pane starts one when the score has none;
`pondside handlers` does the same. The full reference is
docs/SUPERCOLLIDER.md.

After each mockup the app adds stubs for new cues to the patch, then runs
`pondside mix`: the patch's `( … )` blocks run in a generated sclang
script, in mockup mode, on a clock far faster than real time, with the
server replaced by a recorder that keeps every message at its score time
(and answers `/sync`, `/done` and `/b_query` as scsynth would); scsynth then
renders them in non-real time against the mockup into `score.mix.wav`, the
score with its electronics. ⌘⌥P (Play with Electronics) plays it from the
selection's bar, as ⌘⇧P plays the mockup. Cues run as routines on the
score's clock (`TempoClock.default` while playing), so `wait`, `fork`,
patterns, `s.sync` and buffer actions render as they sound live. Code timed
by `SystemClock` or `AppClock` is not, and blocks whose first line is
`// @pondside live` (windows, MIDI) are skipped.

`pondside patch score.ly` checks a patch, or the folder's likeliest `.scd`,
against Pondside's layout; `--fix` migrates it (the app offers the same
when it opens a score).

`pondside handlers score.ly --scd file` keeps any handler file in step.
Run it again after editing the score: it adds stubs for new cues (in the
file's style: a patch's `~cue[…]`, else the quark's `p.on(…)`, adding the
quark's `p = Pondside(…)` line when the file has none), updates the comment
line above each handler, and comments out handlers whose cue has gone
(with `//~ `, restored exactly if the cue returns). It never changes code
inside a handler.

The quark in `sc/Pondside` plays the mockup and fires `p.on` handlers:

```supercollider
p = Pondside("~/scores/piece", "score");    // score.cues + score.wav beside score.ly
p.on(\cue12, { |cue| ~swell.set(\amp, 0.5) });
p.play(from: "42");                          // bar 42, or seconds
```

It refuses to play when the server's sample rate differs from the
mockup's, and prints the line that fixes it.

## Skills and the files Pondside writes

The skills `pondside mcp` serves describe the files Pondside itself
produces, so an agent following a skill never builds a second, disagreeing
copy of them. `SkillConsistencyTests` checks that every file a skill names
is bundled with it and that the SuperCollider skill describes the real cue
format.

Names follow the root file: `quartet.ly` gives `quartet.cues`,
`quartet.wav`, `quartet.scd` and `quartet.mix.wav`.

| What | Written by | Skills that use it |
|---|---|---|
| Cue times: `renders/score.cues` (`seconds<TAB>bar<TAB>cue N`) | `pondside mockup`, run by the app after every good engraving; `pondside cues --format cues` | lilypond-supercollider (the quark reads it), lilypond-electronics-staff (`\ecue` → `cue N`) |
| Mockup: `renders/score.wav` | the same run | lilypond-supercollider |
| cues.json | `pondside cues`, MCP `cues`, RPC `document.cues` | lilypond-supercollider, sc-patch-editing |
| Collections `~ec`, marks | `pondside cues --format ec` / `marks` | lilypond-supercollider, lilypond-electronics-staff |
| The patch `patch/score.scd` (`// @pondside patch`), its engine `patch/dependencies/pondside.scd` | the SuperCollider pane when the score has no patch; `pondside handlers`; stubs for new cues and the current engine after each mockup | lilypond-supercollider, sc-patch-migration |
| The mix `renders/score.mix.wav` | `pondside mix`, run by the app after each mockup | — (⌘⌥P plays it) |
| `score.before-pondside.scd` | `pondside patch --fix`, `patch_migrate`, the app's refactor dialog | sc-patch-migration |
| `lexicon.ily` | `graphic_insert`, `pondside lexicon include` | graphic-notation, lexicon-entries |
| `patch/dependencies/sc-lexicon.scd` (`// @pondside sc-lexicon <ids>`) and its load line after the engine's | `sc_lexicon_add` | sc-patch-editing |
| The patch doc `patch/score.patch.md` | `patch_doc`, `patch_note`, `patch_context`, `patch_check` | sc-patch-editing |
| `front-matter.ily`: cover, notes, legend (`%% ---- cover` …, `%% legend: <id>` rows) and its `\include` before the root's first `\score` | the app's Score Setup (`⌘⇧U`) | lilypond, graphic-notation (the legend) |
| Staff names, `midiInstrument`, `\clef` in a staff's `\with` | Score Setup › Staves | lilypond |
| `.mcp.json`, `opencode.json`, `.codex/config.toml` | the app, `pondside agents` | — |

All cue times come from one interpretation of the score: the playback
compile (`PlaybackScore`) with Pondside's timing listener. The bundled
libraries only mark things for it: `\ecue` sets `cue-label`,
`\timingMark`/`\improvisation` set `timing-label`, `\playTempo` is a
hidden `\tempo`, `\collection` wraps its notes in `\startGroup`/`\stopGroup`.
A score that still includes the old workflow's `timing.ily` keeps writing
`score.timing` (into the score's folder, as LilyPond runs there); Pondside
reads its own rows, and the two agree (`pondside cues --format cues` and
`lily_timing.py … cues` give identical lines on Tests/Scores/large-graphic).
The skill tells agents not to set that pipeline up again.

Graphics: the Lexicon kit's `\startGraphic`/`\stopGraphic` and a score's
own graphic spanners are all text spanners, so one voice holds one graphic
at a time; the graphic-notation skill says so.

## The running app: JSON-RPC over a Unix socket

While Pondside runs, it listens on
`~/Library/Application Support/Pondside/pondside.sock` (or
`$PONDSIDE_SOCKET`). Only the user can connect: the socket is mode 0600.
Messages are JSON-RPC 2.0, one per line. `pondside rpc <method> [params]`
calls a method from the shell.

| Method | Params | Result |
|---|---|---|
| `app.version` | | name, version, socket path |
| `app.documents` | | each open score: `root`, `files`, `active` file, `status`, `started` (when the latest compile began, Unix seconds), `diagnostics` (its errors) |
| `document.text` | `path?` | `{ path, text }`: the app's current text, including unsaved edits |
| `document.selection` | `path?` | `{ path, start, end, text, events }`, with positions as `{ line, character }` |
| `document.context` | `path?`, `line?`, `character?` | the selection's (or that point's) `score_context`, with `system: { first, last, next }` from the engraving |
| `document.log` | `path?` | the bounded tail of the last LilyPond log for the score, for a failure whose diagnostic has no location |
| `document.patchContext` | `path?`, `line?`, `character?`, `cue?` | the selection's (or that point's, or that cue's) `patch_context`; an error when the score has no Pondside patch |
| `document.select` | `path, line, character` | puts the caret there (the score highlights it); returns the selection |
| `document.engrave` | `path?` | starts a compile; the result arrives as `compile.finished` |
| `document.cues` | `path?` | the latest cues.json |
| `document.open` | `path` | opens a score in a window |
| `subscribe` / `unsubscribe` | `events: [names]` (`"*"` for all) | the current subscriptions |

`path` names any file in an open score's include graph. Without it, the
frontmost score is used.

Events, sent as notifications to subscribers:

| Event | Params |
|---|---|
| `score.changed` | `{ path, by }`, where `by` is `app` (typed in Pondside) or `disk` (another tool wrote the file) |
| `compile.finished` | the score's summary, as in `app.documents` |
| `selection.changed` | the selection, as in `document.selection` |
