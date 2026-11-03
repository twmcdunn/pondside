# Pondside — design

Status (2026-10-28): the editing loop, multi-file scores, the interface,
speed, the timing and cue tooling, the CLI/MCP/socket, the Lexicon, and
graphic notation on a shared Scheme kit with the agent workflow around it
(§7–8) are built. §9 says what remains.

---

## 0. Principles

- **The `.ly` file is the only source of truth.** Every edit, from the
  score view, the Engraving Settings panel or an agent, is a minimal text
  edit to the user's files. The app keeps no score state anywhere else.
  The only exceptions are derived and disposable: a cache of the latest
  engraving (§8, render cache) and app preferences.
- **LilyPond decides.** Timing, links and diagnostics come from LilyPond
  itself (listeners compiled into the engraving), not from re-implementing
  its semantics. Pondside's own models (the CST, the lens) are checked
  against it.
- **Portable core, disposable shell.** Everything below `PondsideUI` builds
  and tests on Linux. The AppKit front end is a client of the portable
  modules.
- **Pondside computes time; SuperCollider plays it.** Pondside derives cue
  timestamps from the score and writes them to files. It does not schedule,
  send OSC, or own a clock. The SuperCollider pane (M5) will host sclang
  the way the terminal pane hosts a shell — Pondside launches the
  interpreter but does not drive it. §3 has the details.
- **Open source, for research. Bundle what is small and tested; detect
  or download the rest.** Pondside is academic research software, released
  open source. The installer (`scripts/make-installer.sh`, Appendix A.17)
  bundles a pinned LilyPond and a static FluidSynth with a SoundFont, and
  downloads SuperCollider and MuseScore Studio from their projects only if
  the user ticks them. Tools the user already has are still detected at run
  time: PATH, then platform application directories, then an override in
  `pondside.toml`. When a tool is absent, the feature that needs it degrades
  gracefully: panes show an informative placeholder, CLI subcommands fail
  with an actionable error. Appendix A.16 has the detection rules for each
  tool.

---

## 1. Module structure

```
                 ┌────────────────────────── portable (Linux CI) ──────────────────────────┐
 PondsideCore    │  stdlib only, not even Foundation. Lossless CST and parser (Syntax/),    │
                 │  pitch/duration model (Music/), ScoreEditor, NoteInput, EngravingMap     │
                 │  (Editing/), the command catalog (Commands/), the Notation Lens's        │
                 │  MusicXML window (Lens/), engraving settings (Settings/).                │
 PondsideEngrave │  Toolchain detection, LilyPond driver and warm daemon, session settings  │
                 │  (point-and-click, fast SVG, timing listener), include graph, SVG →      │
                 │  EngravedPage (geometry, staves, links), diagnostics, watcher, mockup    │
                 │  render, render cache.                                                   │
 PondsideTiming  │  Pure functions: the timing dump → stepped tempo map → cue times         │
                 │  (CueSheet), .scd handler sync. Writes data; plays nothing.              │
 PondsideLexicon │  entry.toml (TOML subset), scopes and tiers, validation, \lexicon        │
                 │  expansion and checking, sound expressions, pondside.toml.               │
 PondsideBridge  │  MCP server (stdio) and the app's JSON-RPC socket. No OSC.               │
 PondsideCLI     │  `pondside`. Links only the modules above.                               │
                 └──────────────────────────────────────────────────────────────────────────┘
                 ─────────────────────────────────── seam ─────────────────────────────────────
 PondsideUI      AppKit (and SwiftUI for panels). Canvas, source panes, lens, palette, hints.
 PondsideApp     Executable target: `main.swift` → PondsideUI.
```

Enforcement:

- **Only on macOS:** `Package.swift` declares `PondsideUI`, `PondsideApp`
  and their packages (SwiftTerm, swift-sheet-music) only under
  `#if os(macOS)`.
- **Linux CI:** builds and tests every portable module, against LilyPond
  2.24.3 and 2.26.0.
- **`scripts/check-seam.sh`:** rejects Apple-only imports below the seam,
  and any Foundation import in Core.

Geometry, hit-testing and link lookup live in Engrave, not UI, so they are
tested on Linux. The UI turns paths into `CGPath` and draws them.

---

## 2. The concrete syntax tree

### Decision: a hand-written lossless parser, not tree-sitter

The CST is a pure-Swift recursive-descent parser
(`Sources/PondsideCore/Syntax`), not a tree-sitter grammar:

- **The hard part would be hand-written anyway.** LilyPond's tokenization
  depends on mode (`\lyricmode`, `\chordmode`, `\markup`, Scheme with
  embedded `#{ #}`), which tree-sitter can only express through a
  hand-written C external scanner.
- **The edit model needs semantics the parser computes for free.** Relative
  octaves, inherited durations, key and note-name language are all resolved
  *lexically* by LilyPond (verified, §6). One parser pass computes them
  exactly.
- **The seam stays clean.** No C target, and Core imports only the standard
  library.
- **Speed is not a reason.** A full re-parse of a large score is fast enough
  to run on every keystroke.

A tree-sitter grammar would still be useful for highlighting in *other*
editors. It would never be the source of truth for Pondside's edits.

### Design principle: structure without meaning

LilyPond can redefine arity and even lexing from Scheme at runtime, so the
parser:

1. **Never encodes arity.** `\foo a b c` is a command followed by a flat
   sequence of items. The CST is a token stream with bracket structure, not
   an AST.
2. **Models what is lexically fixed:** comments, strings, numbers,
   `\commands`, notes (pitch, octave marks, `!`/`?`, octave check),
   durations (dots, `*n/m`), chords, `<< >>`, `{ }`, post-events,
   assignments, property paths, context specs, and Scheme datums. Scheme is
   opaque except for its extent and any embedded music.
3. **Tracks modes** the way LilyPond's lexer does.
4. **Never fails.** Stray closers and unterminated blocks are recovered and
   reported in `SyntaxTree.issues`. Every byte belongs to exactly one leaf,
   so `tree.reconstructed == text` always holds.

The only built-in knowledge is in `KnownCommands`: which bare commands
attach as post-events, which take pitch arguments, and which switch modes.

### How edits use it

Edits never re-print the tree. `ScoreEditor` turns an intention into
`TextEdit`s (byte range → replacement) over the exact characters involved.
Two kinds of compensation keep *other* notes unchanged:

- **Octave marks:** in `\relative`, the marks of exactly the notes whose
  reference changed are rewritten. Raising `d` in `\relative c' { c d e f }`
  gives `c d' e, f`.
- **Inherited durations:** the old value is written on the first inheriting
  note. `{ c'4 d' e' }` → `{ c'4 d'8 e'4 }`.

### The round-trip proof

- **Property tests:** 1,000 random graphical edits per real score, each
  checked for:
  - locality;
  - semantics (every other note keeps its absolute pitch and duration);
  - losslessness;
  - reversibility (inverse edits restore the file byte for byte).
- **Corpus, in CI:** LilyPond's regression suite, snippets and init files
  (2,423 files, 40k edits). Every file is lossless; two exotic
  Scheme-generated files need syntax recovery.
- **Oracle:** an event listener compiled into LilyPond (`EventDump`)
  reports every note's pitch and duration. The model agrees with it on
  every note of every fixture, before and after random edits.

What the corpus taught the edit model:

- **Separators:** inserted and removed text must not fuse tokens.
- **Downstream bare durations:** are written out so they keep sounding the
  same pitch.
- **Chords repeated by `q`:** a chord a later `q` repeats is copied into it
  when the chord is deleted.
- **Refused edits:** edits that can't be meaning-preserving in writing are
  refused rather than guessed.

---

## 3. Time and sound: Pondside computes, SuperCollider plays

This boundary is settled. Pondside does not own a clock, and nothing passes
between Pondside and SuperCollider at run time: no OSC, no live link. The
patch is responsible for playing cues at the right times.

**What Pondside produces**

| Output | From |
|---|---|
| Cue timestamps | `pondside cues score.ly [--format json\|cues] [--rate 48000]` |
| Cue Inspector | the app's pane |
| Handler stubs | `pondside handlers score.ly --scd cues.scd` |
| Mockup | `pondside mockup` (also writes `score.cues` beside `score.wav`) |
| Patch | `score.scd`, started by the SuperCollider pane (`HandlerSync.patchStarter`) |
| Mix | `pondside mix`: the patch rendered offline in mockup mode, `score.mix.wav` (⌘⌥P) |
| Migration | `pondside patch --fix`, `patch_migrate`, the open-time dialog: a patch written elsewhere made into one; the rest for an agent (skill sc-patch-migration). Reference: docs/SUPERCOLLIDER.md |

- **Cue timestamps.** For each cue: measure:beat, the exact rational
  moment, seconds and samples at the project rate, a stable id, and a
  handler name. The `cues` format (`seconds<TAB>bar<TAB>cue N`) is
  byte-for-byte what the lilypond-supercollider loaders already read.
- **Handler stubs.** One stub per cue. Code inside a handler is never
  touched; orphaned handlers are commented out and restored if their cue
  returns.
- **Mockup.** A WAV rendered from LilyPond's own MIDI with MuseScore, or
  fluidsynth as a fallback. Every render is measured, and silence or a
  wrong rate is refused.

**How the times are derived.** Seconds are the MIDI's seconds. The mockup
is rendered from LilyPond's MIDI, which only knows tempo steps, so the
tempo map is stepped:

- a fermata, caesura or timed section is a hidden `\playTempo` step;
- a ritardando is a run of steps.

A model with ramps would disagree with the audio it is meant to sync. The
timing listener (`TimingDump`, injected with `-dinclude-settings` into
every canvas compile) writes the tempo, cue, mark, note and meter rows.
Note rows also carry the note's source `file line character`, which the
playback head uses to find the glyph on the page. `PondsideTiming` turns
the rows into `CueSheet`. Two different tempos on one moment produce a
warning (the "never put a `\playTempo` where a printed `\tempo` is" rule).

The skills Pondside serves describe these outputs and tell agents not to
build a second timing pipeline; docs/API.md ("Skills and the files Pondside
writes") has the contract.

**On the SuperCollider side.** The patch reads the cue file and schedules
everything on its own clock. `sc/Pondside` is an optional SuperCollider
quark that does this:

- it reads the cue file;
- it plays the mockup and fires the handlers, all from one logical start
  time;
- it refuses to run at the wrong sample rate.

It is SuperCollider code running in sclang, not a connection to Pondside.

**cues.json**, as built (`CueSheet`):

```jsonc
{
  "schema": 1,
  "score": "piece.ly",
  "sampleRate": 48000,
  "tempo": [ { "moment": "0", "seconds": 0, "bpm": 72 } ],
  "cues": [
    { "id": "cue-12", "name": "12", "index": 11,
      "position": { "measure": 42, "beat": 1, "moment": "167/4" },
      "seconds": 133.333333, "samples": 6400000, "handler": "cue12",
      "source": { "file": "electronics.ly", "line": 212, "character": 14 } }
  ],
  "marks": [ { "text": "improv 1", "position": { … }, "seconds": 61.2 } ],
  "duration": 410.5,
  "warnings": []
}
```

Moments are canonical and seconds are derived; `samples` is what a patch
schedules against. Measure:beat is for humans: pickups and cadenzas make it
ambiguous, and `moment` is not.

**Known limits:**

- A file with several `\score` blocks restarts moments in each one.
- The quark and the mockup have not been tested against a real
  SuperCollider and MuseScore.

---

## 4. The Lexicon, as built

The Lexicon is Pondside's library of reusable notation with typed
parameters. Its first part is built (`PondsideLexicon`).

**Entries.** An entry is a folder `entries/<id>/` holding:

- `entry.toml`: id, version, gloss, tags, kind, params, an optional
  `[sound]`;
- `README.md`: when to use it, pitfalls;
- `impl.ily`: LilyPond/Scheme.

```toml
schema   = 1
id       = "air-tone"
version  = "1.0.0"
gloss    = "Air sound: diamond noteheads and a label; cues the patch's air noise"
tags     = ["extended", "winds", "air", "electronics"]
kind     = "texture"                # symbol | texture | pattern | gesture | layout | system
lilypond = ">=2.24"

[entry]
command   = "\\lexicon \"air-tone\" #'((amount . 0.7)) { d''2 e'' }"
attaches  = "span"                  # point | span | staff | system
music-arg = true

[params.amount]
type = "float"                      # float | int | bool | string | enum | duration | pitch | markup
default = 0.5
min = 0.0
max = 1.0
doc = "Air to tone: 0 is nearly all tone, 1 all air"

[sound]                             # optional: names a cue and the patch's parameters
synthdef = "airNoise"
cue      = "airTone"
params   = { amp = "0.05 + 0.4 * amount", dur = "spanDur", rate = "tempo / 60" }
emit     = "onset"
```

**Built**

- **Tiers.**
  - Tier 0: `index.json`, one line per entry (id, gloss, tags, param
    names; about 20 tokens).
  - Tier 1: `entry.toml` plus `README.md`.
  - Tier 2: `impl.ily`.

  Over MCP these are `lexicon://index`, `lexicon://entry/{id}` and
  `lexicon://impl/{id}`.
- **Scopes:** core (bundled) → user (`~/Library/Application
  Support/Pondside/Lexicon`, `$XDG_DATA_HOME` or `$PONDSIDE_LEXICON`) →
  project (`Lexicon/` beside the score). Later scopes win by id, and
  shadowed or broken entries are reported.
- **Validation:** reports every problem at once, so an agent can fix an
  entry in one pass.
- **Sound expressions:** `+ - * /`, parentheses, `min`/`max`. Names are
  checked against the params and `beatDur`/`spanDur`/`tempo`.
- **Invocation:**
  - `\lexicon "id" #'((param . value) …) music`, through a generated
    include (`pondside lexicon include score.ly`).
  - A `[sound]` entry puts a hidden `cue-label` at its start, so its cue
    reaches cues.json like any `\ecue`.
- **Static checking:** `pondside lexicon check` reports unknown entries
  (with near matches), unknown params and out-of-range values, by line.
- **Core entries:**
  - `air-tone`
  - `feathered-beam`
  - `niente-hairpin`
  - `proportional`
  - `senza-misura`
  - `timed-fermata`

**Built since** (2026-10-28):

- **Graphic entries** on the kit (§7): `grain-cloud`, `staff-ripple`, `wedge`,
  `swell-shape`, `scribble`, `arc`, `squiggle`, `pitch-band`,
  `aleatoric-box`. `kind = "graphic"`, `envelope` and `list` param types.
- **Drafts:** a fourth scope, `Lexicon/drafts/`, for entries an agent
  proposed. They are usable at once and accepted (`pondside lexicon promote`,
  or the Lexicon pane) or discarded by a person.
- **The Lexicon pane:** search, params, README, an engraved preview, accept
  or discard drafts, insert a graphic over the selection.
- **The version lock:** `pondside lexicon lock` writes a
  `%% pondside-lexicon-lock` comment block; `check` reports drift.
- **Sound params in cues.json:** the hidden cue event carries the entry, its
  length and its params; the dump passes them on; `CueSheet` evaluates the
  `[sound]` expressions with the cue's real `beatDur`, `spanDur` and `tempo`.
- **Checks and includes** cover every file of the score's include graph.

---

## 5. Engraving and speed

Instant editing is solved. What stands:

- **Warm daemon.** One long-lived `lilypond` process runs the per-file half
  of `lilypond-all` for each job. Nothing in LilyPond is patched.
  - Startup costs 2.9 s of a 3.3 s cold compile on a small score, so warm
    compiles are 10–20× faster.
  - It is robust: a stuck or dead job falls back to a cold compile, and the
    daemon restarts every 150 jobs. Export never uses it.
  - On 2.26, `include-settings` is append-only and the backend must be set
    at start; both are handled, and CI runs 2.24.3 and 2.26.0.
- **Fast SVG.** On large scores the SVG backend, not engraving, dominated:
  `output-svg.scm` searched the whole SVG font with a regular expression
  for every glyph. `SessionSettings.fastSVG` replaces that with a per-font
  table, taking 18.2 s to 5.0 s on a 12-page score. All pages are
  byte-identical, pinned by a test on each CI LilyPond. It checks its own
  answers and turns itself off on any difference.
- **Single-flight renders.** A new edit cancels the render in flight and
  advances a generation counter. Only the newest generation may publish
  pages.
- **The screen answers first.** Edits draw provisional marks at once: the
  real engraved notehead moved, a strike-through, or a duration badge.
- **The Notation Lens** (§8) shows the edited passage engraved instantly.
- **Render cache** (§8): a reopened score shows its last engraving
  immediately.

Rejected along the way:

- **A per-system tile renderer:** it never fitted the old page reliably.
- **`-dsvg-woff`:** it crashes on 2.24.3.
- **The brief's sub-100 ms *compiled* feedback:** impossible, since
  LilyPond breaks lines and pages globally. The perceived latency is met
  instead.

### Multi-file scores, the interface and the programmable surface

- **Multi-file scores.**
  - **The include graph:** `SourceGraph` resolves `\include`s from the
    includer's directory, then the root's, then `-I`. It parses each file in
    the language earlier includes left in effect, iterating to a fixed point.
  - **Per-file state:** every file has its own text, tree, undo stack,
    autosave, watcher, snapshot, diagnostics and links.
  - **Following clicks:** clicking a glyph from another file shows that
    file. Files with notes but no links are named in the status line.
  - **Known limit:** the default duration does not carry across
    `\include`.
- **The catalog** (`PondsideCore/Commands`) is the single list of commands.
  - **Readers:** menus, the palette, hints, the ⌥ reveal and the context
    overlay all read it.
  - **Leader:** Space in the score, ⌥Space anywhere. Groups: `f` file, `g`
    go, `a` add, `e` edit, `v` view, `p` pane, `w` workspace, `h` help.
  - **Audit:** `KeyboardAuditTests` fails if a command has no keys, or if
    chords collide or shadow each other.
  - **Remapping:** `keymap.txt`, ignored as a whole if it breaks the audit.
- **Panes** are frames and content is cargo: content is unique across
  panes, and cycling never changes geometry. The panes are score, source,
  compiler output, terminal (SwiftTerm, pinned 1.5.x; agents run here), Cue Inspector and Lexicon.
  Planned content shows a placeholder.
- **CLI:** `check`, `render`, `cues`, `timeline`, `handlers`, `mockup`,
  `lexicon …`, `links`, `doctor`, `watch`, `rpc`, `mcp`, `completion`.
- **MCP** (`pondside mcp`, stdio): tools `check`, `query`, `render`, `cues`,
  `lexicon_check`, and the graphic workflow of §8; the Lexicon tiers and the
  two skills are resources (the skills are prompts too).
- **JSON-RPC socket** for the running app:
  - methods: document state, selection, context, select, engrave, cues, open;
  - events: `score.changed`, `compile.finished`, `selection.changed`.
- **`pondside.toml`:** the LilyPond pin, sample rate, renderer, SoundFont
  and SuperCollider paths. docs/API.md documents all of it.

---

## 6. Facts established empirically (LilyPond 2.24.3, checked on 2.26 where noted)

Pinned in tests, so an upgrade that changes them fails loudly:

- **Point-and-click URIs** are `textedit://PATH:LINE:CHAR:COLUMN`:
  - `LINE` is 1-based.
  - `CHAR` is a 0-based offset in **Unicode scalars**: `{ c'4^"ééé" d'4 }`
    puts `d` at 12.
  - `COLUMN` is 1-based and tab-expanded.
- **Diagnostics** are `FILE:LINE:COLUMN: error: MSG`. `COLUMN` is a 1-based
  display column with tabs at 8.
- **Canvas SVG** uses `<path>`, `<rect ry>`, `<line>`, `<polygon>`,
  `<circle>`, `<ellipse>`, `<text><tspan>`. Colours are on `<g color>` with
  `fill="currentColor"`.
- **`\pointAndClickOff` in a user's file** (musicxml2ly writes it) is
  neutralized in canvas compiles. The session settings wrap `ly:set-option`
  and ignore any `'point-and-click` value but `#t`. Export passes
  `-dno-point-and-click` and scans its output for leaked paths.

Music semantics, measured with `EventDump` (`SemanticsTests`):

- **The `\relative` chain is lexical.** It runs across `<< >>` voices and
  `\repeat` alternatives. Chord members chain from one another, and the
  next event is relative to the chord's first note. Nested `\relative`,
  `\fixed` and `\absolute` are isolated.
- **`\transpose` pitch arguments** become the chain's reference; `\key`
  and `\transposition` arguments do not.
- **Octave checks** pin the pitch, and the chain continues from there.
- **`\relative` without a start pitch** reads as relative to the F below
  middle C.
- **The default duration is lexically global**, multipliers included.
  Tuplets scale the sounding length, not the inherited written value.
- **A bare duration repeats the previous pitch**, or the previous chord
  like `q`. A space between pitch and duration is allowed.

---

## 7. Graphic notation as Lexicon entries on a Scheme kit

Built as proposed below, with two departures found while building it:

- **Params are declared once**, in `entry.toml`; the kit merges the
  defaults. A second declaration in `\defineGraphic` would have had to be
  kept in step. Entries register with `(define-graphic! "id" (lambda (g p) …))`.
- **The invocation is a post-event on any event**, a skip or a note
  (`c''4\startGraphic …`), so a box can sit on the notes it boxes.

The kit is tested by rendering: every graphic entry across a line break,
twice (identical SVG), with its point-and-click link to the invocation.

### What graphic scores need

`Tests/Scores/large-graphic/graphics.ily` (1,700 lines, 129 definitions)
is the reference. Each graphic there:

- **is a spanner** from one moment to another on a staff;
- **is drawn at layout time**, in staff spaces, so it follows the music
  when spacing changes;
- **responds to the layout:** tongue rams sit on the real note columns,
  textures stay clear of the pitch collections, and staff lines turn into
  ripples;
- **survives line breaks**, as one piece per system;
- **is shaped by time:** envelopes (swells, densities, LFOs) driven by
  moments and by the cue times the score itself produces;
- **is reproducible** from fixed seeds.

Most of its 65 `ly:grob-*` calls are the same layout plumbing written again
for each graphic: which system, coordinates relative to a common
reference, other grobs' extents, broken spanner pieces, and note columns.
That plumbing is where the fragility lives, and it is the hard part for an
agent.

### Options considered

| | Raw Scheme per graphic | Python → data | Python → Scheme | **Kit + entries** |
|---|---|---|---|---|
| Sees the layout (columns, other grobs, systems) | yes | no | partly | **yes** |
| Follows respacing | yes | roughly | yes | **yes** |
| Languages, build steps | 1, none | 2, generate | 2, generate | **1, none** |
| What an author writes | everything | shapes | everything, twice | **shapes** |
| Reuse | copy-paste | classes | poor | **entries with typed params** |
| Compiles without Pondside | yes | yes | yes | **yes** |

**Python is out as the drawing language.** LilyPond's horizontal spacing
is not proportional to time (unless proportional notation is on), so a
drawing computed beforehand puts notes and cues in the wrong place. It also
cannot see the other grobs or the system breaks. Python stays as an
optional source of *data*: a script that turns a sound file's analysis into
a list of numbers, which an entry takes as a parameter.

### The kit: `pondside-graphics.ily`

The kit is a core Lexicon file, written and tested once, that owns the
plumbing. An entry receives a context `g` and returns shapes as plain data;
the kit turns them into the stencil.

| Kit API | Gives |
|---|---|
| `(g-width g)`, `(g-pieces g)` | the span's width; its pieces when broken across systems |
| `(g-x-at g moment)`, `(g-x-at-cue g "12")`, `(g-columns g)` | x of a moment, cue or note column, from the real paper columns |
| `(g-staff-y g line)`, `(g-lines g)` | staff line heights (y = 0 is the middle line, in staff spaces) |
| `(g-clear-of g interface)` | intervals to keep clear of (e.g. collections, dynamics), from the skylines |
| `(g-seconds g x)` | time at x, from the score's own tempo (the timing listener) |
| `(g-rand g)` | a seeded random source: same drawing every compile |
| envelopes | `(constant v)`, `(linear a b)`, `(swell peaks lo hi)`, `(lfo rate depth)`, `(from-cues …)`, composable with `env+`/`env*` |
| shapes | `(dot x y r)`, `(stroke pts thick)`, `(fill pts)`, `(wedge x0 x1 h0 h1)`, `(curve pts thick)`, `(text x y markup)`, with `gray` |

The kit handles line breaks. An entry draws as if the span were one strip,
and the kit cuts the strip at each system and shifts each piece. Entries
that care (a ripple that restarts its phase each line) can ask
`(g-pieces g)` instead.

### The entry contract

```scheme
% entries/grain-cloud/impl.ily
\defineGraphic grain-cloud
  #'((density 0.5  number?   "dots per staff space, 0..1")
     (height  (swell 3 0.5 4) envelope? "half-height of the band, staff spaces, over the span")
     (avoid   (note-collection-interface) list? "grobs to keep clear of")
     (seed    0    integer?  "same seed, same drawing"))
  #(lambda (g p)
     ;; returns a list of shapes; nothing else
     …)
```

- **One procedure, `(lambda (g p) → shapes)`.** `p` holds the declared
  params with defaults merged in. It must not draw stencils or touch grobs
  directly, so everything fragile stays in the kit.
- **Declared params are the schema.** `entry.toml` lists the same params
  for tier 0 and tier 1, and `pondside lexicon check` keeps the two in
  step.
- **Invocation is a spanner caused by an event:** `\startGraphic
  grain-cloud #'((density . 0.7)) … \stopGraphic`, in a voice of skips. It
  is linked by point-and-click, so a click on the drawing selects its
  invocation (§8).
- **Entries are generalized versions of specific code.** `graphics.ily`
  becomes a handful of entries (`staff-ripple`, `grain-cloud`, `wedge`,
  `swell-shape`, `echo-burst`, `pixelate`, `tongue-ram-row`) and one
  invocation per passage. A new piece reuses them with new params.
  Promotion is how one piece's custom code becomes the library.

### Two skills, served by the MCP

An agent works at two levels, and each has its own skill. Both are
published by `pondside mcp` as resources and prompts
(`lexicon://guide/graphics`, `lexicon://guide/entries`), and live in the
repo as Claude-style skills, so any agent gets them.

**1. Graphic notation with the Lexicon** (high level, the default). It
assumes the agent stays on the API:

- **Workflow:**
  1. `score_context` (§8).
  2. `lexicon_search`.
  3. Choose an entry and params.
  4. `graphic_preview`.
  5. `graphic_insert`.
- **The kit's vocabulary:** envelopes, shapes, `avoid` lists, cue- and
  system-relative spans, and how words map to params ("expanding and
  contracting" → `swell`; "until the next system" → end at the system
  break).
- **Composition before invention:** layer two entries, or pass an envelope
  built from others, before writing anything new.
- **When to drop down a level:** the user rejects every combination, or the
  idea needs a shape no entry can make.

**2. Writing Lexicon entries** (low level, the recourse). It is for an
agent writing an original entry, or extending the kit, from scratch:

- **The contract:** `\defineGraphic`, param predicates, shapes as data,
  determinism, and what a procedure may and may not do.
- **LilyPond and Guile conventions and gotchas:**
  - Guile 3 has no `string-match`.
  - Music types are lowercase and music names CamelCase.
  - `ly:make-duration` takes the factor as two integers.
  - Callbacks run before the layout is final, so their results get cached.
  - When `after-line-breaking` or a deferred stencil is needed.
  - Skylines and `ly:grob-extent` reference points.
  - Broken spanners and `ly:spanner-broken-into`.
  - Units: staff spaces versus `\mm`.
  - Making the drawing look the same in the PDF and the SVG backends.

  This draws on the existing `lilypond` and
  `lilypond-contemporary-notation` skills.
- **Extending the kit itself:** when a new layout query belongs there
  instead of in an entry, and how to add it with a test.
- **The entry folder:** `entry.toml`, `README.md` (when to use it,
  pitfalls), `impl.ily`, `examples/preview.ly`, and the checks to pass:
  - `pondside lexicon check`;
  - a preview compile on 2.24 and 2.26;
  - two compiles giving identical output.

The low-level skill is long and loaded only when needed. The high-level
one stays short because the kit carries the complexity.

The Lexicon is a **library of reusable notation**, not a required
intermediate representation for every score change. Existing entries and new
reusable visual effects belong there; a one-off notation/layout change
(barlines, beams, clefs, spacing) is score code and uses `skill://lilypond`.
A wavy-barline section, for example, is not a `graphic` entry: it overrides
`BarLine.stencil` over a span. If it becomes reusable, it is a `layout` entry
(`kind = "layout"`, `attaches = "span"`), not a graphic one. Forcing every
request through the Lexicon was a distraction in the run that took 5½ minutes.

### Preview, validation, trust

- **Preview.** `graphic_preview` compiles a snippet (the passage's staff,
  bars around the span, the entry) on the warm daemon in about 0.2 s and
  returns an SVG. The agent iterates without touching the score.
- **Validation.** `pondside lexicon check` compiles every entry's example
  and checks determinism (two compiles, identical SVG). It also checks that
  `entry.toml` and `\defineGraphic` agree.
- **Trust.** Scheme inside LilyPond can read and write files, so an
  agent's entry is untrusted until the user accepts it. It lives in
  `Lexicon/drafts/` and is used in the score so the user can judge it
  engraved. Accepting promotes it with a version, a README and a preview.

---

## 8. Agents and the MCP ("put a grainy texture here")

Built: `score_context` (from the files, plus the app's `document.context`
for the system: its first and last events in the staff, and the next
system's first), `lexicon_search`, `lexicon_entry`, `graphic_preview`,
`graphic_insert` (which also writes `lexicon.ily` and includes it in the
root), `lexicon_propose`, and the two skills as resources and prompts.
Systems are found from the engraved staves by their gaps
(`EngravedPage.systems`). Promotion is deliberately not an MCP tool.

The intended workflow is right. The user points, the agent reads what
"here" means, reuses or writes an entry, and the user accepts the result
before it joins the Lexicon. The best practices that make it work:

1. **"Here" comes from the app, as data, not from the agent's guess.**
   - **Today:** the MCP server runs separately and the running app's state
     is only on the JSON-RPC socket.
   - **Proposed:** the MCP server reads the socket when the app is open and
     adds a `score_context` tool. It returns:
     - the clicked point: file, line:char, staff name;
     - measure:beat, moment and seconds;
     - the system it is on: the moments where that system starts and ends,
       from the engraved pages and their links;
     - the pertinent `.ly`: the staff block's measures around the point, as
       the lens already finds them (`LensBlockFinder`), plus any
       definitions the passage uses.

     "Until the next system" is then a moment the app supplies, not an
     inference.
2. **Graphics are edited from a marked range.** A normal click is always
   note-oriented: it selects the note under it, or (on empty staff space)
   chooses the event to insert after and the clicked octave, so typing a–g
   inserts there. ⌥ is the graphics key: ⌥-drag marks a range from the
   click's x on the starting system to the release's x on the nearest
   system, the whole staff tall, and opens the request line on release;
   ⌥-click on a graphic shows its source without an outline. There is no
   clicked-part selection. `score_context` returns the Lexicon graphic's
   entry and params, or for the score's own code (`ScoreGraphic`) the
   command, its stop, definition, stencil procedure, helpers and comments,
   plus the range's `from`/`to` edges and each system's selected x. The one
   graphic skill windows the drawing so only the box changes; a new graphic
   goes in the same box.
3. **Few tools, compact answers.** The tools are:
   - `score_context`;
   - `lexicon_search` (tier 0 lines ranked by tags and gloss);
   - `lexicon_entry` (tier 1);
   - `graphic_preview` (compile an entry on the span in a snippet and
     return an SVG);
   - `graphic_insert` (one minimal edit: the invocation in the right voice
     plus its data file);
   - `lexicon_propose` (write a new entry to the project's
     `Lexicon/drafts/`);
   - the two skills of §7, as resources and prompts.

   Each answer is JSON with source positions, so the agent's next edit is
   exact.
4. **Reuse before writing.** The agent searches the Lexicon, then tries
   existing entries with new params or layered together. Only if the user
   still rejects the result does it switch to the low-level skill and write
   a new entry.
5. **A human gate on the library.**
   - A draft is used in the score at once, so the user sees it engraved,
     but it stays in `drafts/`.
   - The app shows the preview and the diff.
   - Accept promotes the draft to project or user scope, with a version,
     README and preview.
   - Reject removes the draft and its invocation as one undoable edit.
6. **Agent code is untrusted until accepted.** Scheme can reach the file
   system, so drafts run only in previews and in the user's score, and stay
   in `drafts/` until the user accepts them (§7).

**A marked section (2026-11-01).** A normal click is always note-oriented:
it selects a note or, on empty staff space, sets the insertion point and
octave. A graphics range is marked by holding ⌥ and dragging on the score.
- **What the drag makes.** It starts on whichever staff the click is nearest
  (a graphic's area or plain staff), at the click's x on that system. The box
  is the whole staff tall. The release's y picks the end system (the nearest
  system), and its x is the end edge. The start system runs from the click to
  its end, the systems between are whole, and the end system runs from its
  start to the release; a drag upwards is the same range, ordered top down.
  A normal click, a new drag, or ⎋ clears it.
- **Pattern** (HIG): an inline marquee over content, not a control. Each
  covered system gets a solid accent box over the staff, drawn without
  animation and without taking focus. On release the request popover opens
  beside the box; its field takes the keyboard because the user just asked
  to type a request. Increase Contrast is the ordinary accent line; there
  is no material.
- **What the agent gets.** `selection.kind` is `"graphic-section"`:
  `from`/`to` each carry `page`, `x` (the edge as a fraction of that system's
  broken piece), `page_x`, `spanner_x` and `at` (bar, moment, event and
  source at the edge; the moment is interpolated from the engraved notes'
  x positions by `SectionTimeMap`, before the agent runs); `systems` lists
  each covered system's selected x range, its `staff_x` fractions and its
  1-based `ordinal`. The moments identify the start and end systems; the
  edges stay the fractions.
- **The skill.** The MCP server bundles the graphic workflow at
  `lexicon://guide/graphics` (`skill://graphic-notation`) and general
  LilyPond at `skill://lilypond`. The graphic skill describes the marked
  range, the `section-window` (1 inside, 0 outside, short ramps at the
  edges), new graphics in the same range, the Lexicon entries, envelopes
  and the legend. A marked range with no drawing is either a new drawing
  (graphics) or a notation/layout change (`lilypond`); a one-off notation
  change does not force a Lexicon entry. There is no second graphic skill
  and no clicked-part selection; a normal click is a note selection or
  insertion point.

**Requests from the lens (in the app).** The same workflow runs without a
terminal:
- **Where you type.** ⌥-drag marks a range and opens the request line, a
  popover beside it with one field ("Describe what you want… e.g. grainy
  swell"). ⌘L reopens it for the marked range; a normal click never opens a
  graphics request. On notes, ⇥ switches the Notation Lens to the request
  line when a range is marked, and ⇥ switches back.
- **What runs.** ↩ sends the request to the agent chosen in Settings
  (`AgentSession`: Claude Code or opencode, each kept running between
  requests). Its prompt holds the
  selection's context (`score_context`) and the request. For an existing
  drawing it holds the graphic skill; for a range with no drawing it holds
  both the graphic skill and LilyPond, and routes between a new drawing and
  a notation/layout change. The agent edits the score's files and the edit
  tool returns the engraving.
- **While it works.** The status bar's one pulsing dot lists it ("Claude
  Code: “grainy swell…” · editing..."). When the agent changed the score,
  the dot and the badge on the selection stay ("Engraving the change...")
  until an engraving started after its last write has finished, so the
  reply never arrives over the old pages; then its one-line reply is
  flashed there. ⌘Z (or ␣ e z) puts back the files it changed, as
  one undo step on the active file's stack, and ␣ e k stops it.
- **One conversation per window** (`AgentSession`), so follow-ups ("taller",
  "the other one") have the earlier requests in context:
  - **Claude Code** runs as one process kept open (`claude -p --input-format
    stream-json`); each request is a message on its stdin. If the process
    stops (␣ e k, 30 minutes idle, a crash), the next request starts it
    again with `--resume <session>`, and the conversation carries on.
  - **opencode** runs as one process kept open too: `opencode acp`, the
    Agent Client Protocol (JSON-RPC on stdin/stdout). Pondside sends
    `initialize`, then `session/new` with its MCP server (or
    `session/resume` after a restart; a session that can't be resumed
    starts a new one, logged), then a `session/prompt` per request.
    `session/update` streams text and tool calls into the log and the status
    bar; `session/request_permission` is answered "allow" (as `--auto`);
    ␣ e k sends `session/cancel` and the process keeps running. (`opencode
    run --attach` wasn't reliable in 1.19.4; ACP is opencode's supported
    integration for editors.)
  - **No cutoff.** Both agents compact a long conversation themselves, so
    a conversation lasts until ␣ e n or the agent changes in Settings.
  - **A stopped request** stays in the agent's history unanswered, and
    agents carry it on in the next turn; the next prompt opens by saying the
    user stopped it.
  - **Follow-up prompts** are short: the request and the selection, plus a
    reminder to re-read files before editing, since you may have changed
    them.
- **Why the field may take focus.** The field is the only lens surface that
  takes the keyboard. It is opened explicitly and needs typing (HIG:
  "Avoid changing focus without people's interaction"); ⎋ returns focus to
  the score. A click on a graphic flashes the hint "⌘L: describe a
  change".

**Settings (⌘,).** Pondside ▸ Settings… holds only what belongs to the app,
not to a score: the agent (Automatic, Claude Code, opencode or Off, with
where each is installed), "Ask Again About Declined Patches", Lights Out
(also in View) and installing the command-line tool. A score's own settings
stay in its files and `pondside.toml`. The window applies changes at once,
as macOS settings windows do. The installer can install either agent
(Claude Code or opencode) with the vendor's own script, pinned by version
and script checksum (`scripts/installer/versions.env`).

**Agent Log (⌘⌥A, ␣ v a).** Every agent run the app starts (lens requests,
patch refactors) is logged as JSONL in `~/Library/Logs/Pondside/agents.jsonl`
(`AgentLog`, portable): the command line, the prompt, the context sent, each
tool call and reply from the agent's event stream, stderr, exit status,
changed files and the outcome, each with the seconds since the run started.
The agent's `pondside mcp` inherits the run (`PONDSIDE_AGENT_RUN`, or a run
file for Claude's long-lived process) and logs each tool call with its
duration, so model time and Pondside time can be told apart. ⌘⌥A adds a pane
beside the others, or closes it, without moving focus. HIG pattern: a
console-style content view, like Compiler Output, not an alert. Errors and
warnings carry a ✕ or ! as well as their colour; d, v and f toggle details,
verbose and the filter. Rotated at 8 MB.

**Agent speed (measured 2026-10-31).** Claude runs with `--tools` limited to
the file tools and `ENABLE_TOOL_SEARCH=false`, so Pondside's tools load up
front: a one-tool request went from 10 s ($0.22) to 2–5 s ($0.02–0.09).
opencode runs with its shell, web and subagent tools denied
(`OPENCODE_CONFIG_CONTENT`) and `--title` set (otherwise it asks a second
model for a session title first). Over ACP its process starts once (about
1 s, plus Pondside's MCP server); a request's first output then comes in
about 2–3 s, against about 4 s when each request started `opencode run`.
The patch migration, a single long run, still uses `opencode run`.

---

### Faster lens requests, and the patch agent (built 2026-11-01)

**Faster graphics requests.** A run timed at 38 s spent about 25 s in the
model, 5 s engraving and 3 s starting; most of the rest went on re-reading
code the context had already quoted, because it came without line numbers
and listed helpers only by signature, and because the harnesses' own edit
tools insist on a read first. Now:
- every piece of code in `score_context` (`definition`, `drawing`, `uses`,
  `music`) is numbered as in its file (`412| …`), and `uses` carries the
  helpers a drawing calls in full when short (under 60 lines, 400 in all),
  their own callees by definition line;
- the `edit` tool replaces exact text or numbered lines without a prior
  read, and for a score file returns the app's engraving (`check`), so a
  request is one tool call and a reply;
- the prompt and skill ask for a change visible at a glance (about 2× per
  word, not 1.4×): the slow run's edit "succeeded" by thinning a dense
  cloud by half, which looked like nothing.
- a failed `edit`/`check` returns the bounded tail of LilyPond's own log,
  including Guile backtraces the diagnostic parser cannot locate, and a
  diagnostic that names no open file is kept on the root instead of dropped.
  A run that failed 13 checks with `errors:1` and no message now has the
  actual error on the first failure;
- a marked range with no drawing gets the root's `\layout` blocks and a
  short index of top-level definitions, so a notation/layout request does
  not read the 100 KB graphics file. `from.at`/`to.at` are computed from
  LilyPond's timing and the engraved note x, not inferred by the model;
- the graphic skill's `system-moments` guards `ly:grob?`: a BarLine's
  `ly:grob-system` can be `()`, which used to reach `ly:grob-object` and
  fail without a diagnostic.

**The patch agent.** A request at a point in the score about the
electronics ("more reverb here", "a grain cloud on this chord") goes to a
second agent with its own conversation (⇥ from the lens's request line, or
Edit › Ask the Patch Agent…, ␣ e p). Four decisions shape it:
1. **The patch doc is the memory, not the conversation.** A conversation
   is compacted, reset, or lost when the model changes. `patch/score.patch.md`
   holds an outline built from the code on every read (`PatchOutline`:
   SynthDefs, patterns, proxies, buses, buffers, functions, cue handlers,
   live blocks, with file:lines), so it is always current, and notes on
   intent under each item (`patch_note`), each stamped with its code's
   hash and flagged stale when the code changes. The agent reads it first
   and opens only the lines it needs; ␣ e N starts a new conversation and
   loses little.
2. **The point maps to a cue.** `patch_context` (the app's
   `document.patchContext`) gives the cue at or before the point, its
   handler's code numbered, its window until the next cue, what the
   handler touches with their code, the pitch collections around it, the
   doc and the SuperCollider Lexicon, in one answer, as `score_context`
   does for graphics.
3. **Separate agents, separate files, one at a time.** Each agent's MCP
   server runs with a role (`pondside mcp --role graphics|patch`): it sees
   only its tools and instructions, and `edit` refuses the other's files
   (the patch agent changes `.scd`, never `.ly`; neither touches
   `pondside.scd` or `sc-lexicon.scd`). The app runs one request per score
   at a time, and logs it if the patch agent changed a score file anyway.
4. **Verification like `check`.** `patch_check` renders the mix (the same
   offline render as `mix`) and reports errors and the cue window's levels,
   of the mix and of the electronics alone (mix − mockup), before and
   after, so "silent" or "no change" is a number. ⌘Z restores the patch
   files the request changed, and the mix re-renders.

The SuperCollider Lexicon (`Sources/PondsideLexicon/Core/SCLexicon`)
mirrors the graphic one: entries of kind `effect` (two SynthDefs each, an
insert for a pattern's bus and a `_mono` version for `~live`), `synth` and
`pattern` (functions in `~lx`), with params, usage, README and code; a
kit builds the effects. `sc_lexicon_add` writes the ones a patch uses into
`patch/dependencies/sc-lexicon.scd`, like `lexicon.ily`. The starting set
is the sc-pattern-fx skill's effects (filter, drive, ring mod, decimate,
feedback delay, FDN tail, reverb, a buffer-free granulator) and pattern
parts (pitches from a collection, glide, density, cloud, effects on a
pattern). `SCLexiconTests` compiles them all in sclang.

**One lens, three views (2026-11-01).** The Notation Lens and the two
request lines share a mode bar (Notation · Graphics · SuperCollider, each
with its icon) and one size, so ⇥ (in that order, skipping what the
selection doesn't offer) and the bar change only what is below the bar. A
mode that isn't available is greyed, with a tooltip saying why. While an
agent works the highlighted region pulses and fades between blurred and
sharp; there is no spinner. The highlighted part of a large drawing is
always the one the agent's `selection` describes, however the highlight
was made (a click, the keyboard, a re-highlight after an engraving).

## 9. What remains

Built in this pass (2026-10-28) and no longer listed: the graphics kit and
nine graphic entries, the two skills, the MCP tools of §8 with the app's
`document.context`, drafts with promotion and discarding, previews, the
version lock, sound params in cues.json, the Lexicon pane, source
colouring, the LilyPond version picker, mockup padding and per-staff stems,
in-app audition, the shadow history and the CLI installer (§10).

**Notation Lens** (tabled, 2026-10-29)
- Multi-staff systems and repeats: tabled with the fork.
- The `swift-sheet-music` fork (`docs/SHEET_MUSIC_FORK_PLAN.md`): manual and
  feathered beams, beams reaching the middle line, and two-chord tremolo
  heads.

**Editing**
- Adding a note to a chord from the score view.
- Hover tips and the ⌥ reveal only cover a few controls.
- Vim/Emacs presets: dropped as planned. The chords are remappable
  (`keymap.txt`), but the source pane isn't a modal editor, so a preset
  would only rename chords. Revisit with M5's editor.
- Inserting before a staff's first note is still unsupported; a click on
  empty staff after a note selects the insertion anchor and octave.

**M5: editor and toolchains**

*SuperCollider pane — built (2026-10-29).*

Pondside hosts sclang the way the terminal pane hosts a shell. It still
computes no time and drives nothing: it starts the interpreter the user
has and streams its output.

- **Interpreter** (`SCLangSession`, Engrave): one sclang per app
  (`SCLangHost`), started as `sclang -i pondside` so stdin is plain, not
  readline. Code ending in `0x0c` runs and posts `-> result`; `0x1b` runs
  silently. Restarted if it crashes after a healthy start; quit with the
  app. Pondside's own requests (help paths, the class list, server load)
  are answered on lines starting with `0x1E PONDSIDE <id>`, which
  `SCPostStream` (Core) keeps out of the post window.
- **Editor** (`SCCodeView`): ⌘↩ sends the selection, else the outermost
  `( … )` whose `(` starts its line, else the line (`SCRegion`, Core,
  skipping strings, symbols and comments); ⇧↩ the line; ⌘. stops sound
  (`CmdPeriod.run`) from any pane; ⌘B boots or quits the server. Colouring
  from `SCLexer`, auto-indent, bracket matching. The `.scd` is written as
  you type and changes made elsewhere merge in, as with the `.ly`.
- **Autocomplete and signature help** (`SCCompletion`, Core): after each
  start or recompile the interpreter writes its class library (classes,
  superclasses, SCDoc summaries, methods with argument defaults) as TSV in
  ~0.5 s, cached in `~/Library/Caches/Pondside/SuperCollider`. Completion
  infers the receiver from what the text shows (a class, a literal,
  `SinOsc.ar(…)`), else offers every method; ⎋ asks explicitly.
- **Help**: ⌘D renders the SCDoc page for the class or method at the
  caret (`SCDoc.prepareHelpForURL`) and shows it below the editor; links
  are rendered before they are followed, and ⌘↩ runs code selected in a
  page.
- **Not built**: LanguageServer.quark (not needed: the interpreter answers
  directly), go-to-definition, Qt GUI windows docked in the pane (they open
  as sclang's own windows).

Detection (Appendix A.16): `PONDSIDE_SCLANG`, then `pondside.toml`'s
`supercollider.path`, then SuperCollider.app, then PATH. Collision: if
another program's scsynth is running, ⌘B says so and doesn't boot a second.

Source colouring of `.ly` comes from the CST, not tree-sitter.

**M6: programmability**
- `pondside insert` (notes from the command line) and `query --measures`.
  Agents insert graphics through `graphic_insert`.

**M7: Lexicon**
- Previews are rendered on demand (the browser, `graphic_preview`), not
  shipped as `preview.svg`.

**M8: time and sound**
- Playing the mockup through the quark against a booted server (the quark
  compiles and loads its cues in SuperCollider 3.14.1; MuseScore 4 renders
  mockups and stems; nothing was played aloud in testing).
- The timing dump reads the scores with a `\layout`; a `\score` that has only
  `\midi` (an unfolded copy for playback) restarts moments. Point the
  dump at the layout score, or keep one `\score` with both.

**M9: graphic notation**
- **Graphics voices (phase 2).** Tab through the graphics voices of a marked
  section, see each layer in isolation, and target, delete or add one. The
  section context can carry a `voice`/`layer` field when that starts.
- Microtonal accidental entries and annotation layers.
- The full aleatoric-box system with links and arrows lives in the
  `lilypond-contemporary-notation` library; `aleatoric-box` is the drawn,
  single-box form.

**From the brief**
- Licensing: a decision for the author (LilyPond is GPL-3 and runs as a
  separate process; SwiftTerm and swift-sheet-music are MIT).
- Glass on macOS 26: needs the macOS 26 SDK; floating chrome uses
  `GlassView` (blur plus a dimming layer) meanwhile.
- Canvas text fonts fall back through C059 → TeX Gyre Schola → …; only
  text can differ from the PDF.

---

## 10. Built since M3 (2026-10-28)

### Notation Lens

The lens answers the typing gap with a disposable local engraving, not a
second score file.

- **How it renders.**
  1. `PondsideCore/Lens` finds the staff-level block around the edit (the
     outermost `{ … }` below any staff group, a voice split kept whole,
     named by its top-level assignment).
  2. It scans that block's clefs, meters, pickup, tuplets, tremolos and
     graces, following variables such as `\global`.
  3. It writes one staff of MusicXML in memory.
  4. `swift-sheet-music` (pinned 4.11.0) parses and lays it out.
- **Timing comes from structure, not bar checks.** A sequence adds
  durations, every branch of `<< >>` starts together, graces take no time,
  and tuplets and `\repeat tremolo` scale.
- **What the writer spells out.** Explicit accidentals, by LilyPond's
  default rule per voice and measure.
- **Attached after parsing.** Slurs, tuplet brackets and tremolos, all of
  which the importer drops.
- **What the importer can't do.** Manual or feathered beams.
- **Presentation** (HIG Popovers and Loading; `.claude/skills/pondside-ui`).
  - **Popover:** an `NSPopover` above the edited staff, on paper a shade
    off white. It never takes key focus and stays put once open.
  - **Showing it:** it appears without animation, and fades out once the
    render has landed and it has been up 1.5 s since it last changed.
  - **Keys:** `⌘L` keeps it open until `⎋`, and ←→ step through the
    target's voice. ⇧←/→ widen the score's selection; the lens marks the
    same events (all the notes of each selected chord) and widens its
    window to keep them in view.
  - **Reduce Motion:** turns the motion into jumps.
- **Speed.** Building the window takes under 1 ms; parse plus layout
  takes 14–16 ms warm.
- **Requirements.** macOS 15 behind a macOS-14-safe protocol, built with
  Swift 6.4.1.

### Engraving Settings

File › Engraving Settings… (`⌘⇧E`, `␣ f s`) is a floating panel, because
people change a setting and watch the score. It holds LilyPond's
score-wide settings in seven groups:

- **Page:** paper size, margins, indents, page numbers.
- **Staves & Systems:** staff size, staff and system distances,
  justification and page filling.
- **Notes & Beams:** automatic and subdivided beaming, note spacing.
- **Accidentals:** style, key cancellation.
- **Meters & Bar Lines:** time signature visibility and style, bar line
  style, bar numbers, compressed rests.
- **Tuplets:** brackets, numbers.
- **Text:** tagline.

The defaults are LilyPond's own, and every statement compiles on 2.24 and
2.26.

**How it reads and writes** (`PondsideCore/Settings`):

- **Where settings are read:** each setting is read where the score keeps
  it: top-level `\paper` and `\header`, any `\layout`, and its `\Score` and
  `\Staff` contexts.
- **How a change is written:**
  - it replaces that statement in place (comments kept);
  - or it adds one line at the end of its block;
  - at the default, it removes the line.

  A missing block is added where LilyPond reads it. A user's alist is read
  but never rewritten.
- **Other files** are only read. What they set is shown under the control,
  and changing it writes an explicit statement in the root.
- **Undo:** each change is one undoable edit.

musicxml2ly writes `autoBeaming = ##f` and `printKeyCancellation = ##f`.
The first time a score with such a file opens, Pondside offers once to
write LilyPond's defaults in the root. Its `\pointAndClickOff` needs
nothing (§6).

The Add menu also gained Clef…, Time Signature…, Key Signature…, Tempo…,
Text…, Cue and a Tuplet… picker for any ratio. Clef, meter, key and tempo
replace the same command already standing before the note.

### Render cache and Open Recent

- **Render cache.** A reopened score shows its last engraving at once
  while LilyPond engraves it afresh.
  - **Where:** `PondsideEngrave/RenderCache`, one entry per score in
    `~/Library/Caches/Pondside/Renders`.
  - **What an entry holds:** LilyPond's SVG pages plus each file's text as
    engraved, so links map onto text that has changed since.
  - **Writing:** atomic replacement, one store at a time, the 50 most
    recent entries within 500 MB.
  - **Status bar:** reads "Last engraving · Engraving..." until the fresh
    pages land.
- **Open Recent.** Uses the list macOS keeps.

### Interface details

- **First engraving:** a subtle drawing staff in the empty pane, after
  250 ms.
- **Status dot:** pulses, and the ellipsis fills in, during engravings
  longer than 300 ms. Both stay still under Reduce Motion.
- **Hints:** include "⌘/ all actions".
- **Delete:** deleting a staff's last note selects the note before it, not
  the next staff's first.
- **Glass chrome** (palette, hover tips, the lens popover): the blur stays,
  with a dark layer inside (`GlassView`) so a white page behind can't wash
  out the text, and lighter secondary text (`Theme.glassSecondaryText`, above
  4.5:1). Solid under Reduce Transparency; darker, with a border, under
  Increase Contrast.
- **Menus show their keys:** commands without a macOS shortcut show their
  score key or chord in the shortcut column (in the secondary colour).
  ⌘⇧E works: Engraving Settings was missing from the File menu.
- **Panes:** the Lexicon pane (§4). Agents run in the Terminal pane:
  opening a score writes `.mcp.json` and `opencode.json` beside it, so
  `claude` or `opencode` there reaches Pondside through `pondside mcp`.
- **Source colouring** from the CST's token kinds (commands, strings,
  numbers, comments, Scheme, braces), as TextKit 2 rendering attributes, so
  undo and the text are untouched.
- **File › LilyPond Version…** lists every installation; choosing one pins
  it in pondside.toml, which the app now honours as the CLI does.
- **View › Play from Here** (⌘⇧P) plays the mockup from the selected bar,
  timed by the score's own tempo map; again to stop.
- **Pondside › Install Command-Line Tool…** (Appendix A.11).

### Playback head (2026-11-01)

Auditioning the mockup (⌘⇧P) or the mix (⌘⌥P) draws a playback head on the
score.

- **Pattern.** An inline cursor over content, not a control: a thin accent
  line with a round cap at the system top. It never takes focus, is not in
  the key loop, and disappears when the audio stops.
- **Where it is.** The timing dump now writes every note's source
  `file line character`. `PlayheadTrack` (`PondsideEngrave`, portable)
  matches those to the page's point-and-click glyphs, so repeats walk back
  through the printed bars, and the mockup and the mix use the same track.
  Notes generated by the playback (trills, tremolos) have no origin; the
  head stays on the last printed note until the next one.
- **Motion.** Between two notes on one system the line glides; crossing a
  system or page it jumps. The canvas reveals a new system only when the
  system changes, with `scrollToVisible` (an instant scroll, so Reduce
  Motion needs no special case).
- **Appearance.** Solid `Theme.accent`, with a filled round cap: colour and
  shape together. No material, so Reduce Transparency changes nothing;
  Increase Contrast thickens the line and cap. It is drawn after Lights Out
  so it stays readable.
- **Edits.** An engraving during playback rebuilds the track around the
  player's current time; the head is cleared while the new pages land and
  reappears on the next tick.

---

## 11. Score Setup: staves, cover page, notes and legend (2026-10-31)

File › Score Setup… (`⌘⇧U`, `␣ f u`) is a floating panel like Engraving
Settings, with four pages: Staves, Cover Page, Notes and Legend. It keeps
no state. Each control is a minimal edit of the root, a file it includes,
or `front-matter.ily`, undoable in that file's history.

### Decision: front matter in LilyPond, not LaTeX

`lilypond-book` puts notation inside LaTeX, and `\markup \score { … }` puts
it inside LilyPond's own text, so the cover, notes and legend can stay in
LilyPond. LaTeX would add a second source document and a second compile,
and its pages would be missing from the canvas, the render cache, and what
agents see. TeX Live is also too big to bundle (§0). LilyPond's text
setting is plainer: no hyphenation, simple justification. That is enough
for a cover and a few pages of notes. If LaTeX-set prose is ever wanted, the
place for it is a PDF joined to the export, never a parallel source.

### Staves (`PondsideCore/Setup/StaffSetup.swift`, `Instruments.swift`)

- **Reading.** Every `\new Staff` (and the other staff contexts), its
  `= "id"`, and its `\with` fields: `instrumentName`, `shortInstrumentName`,
  `midiInstrument` and `\clef`.
  - The starting clef is the first `\clef` before the staff's first note,
    following variables (`\new Staff \violinI`) into any file. A
    `\set Staff.instrumentName` there counts too.
  - A `\markup` name is shown but changed only when the user types a new
    one.
- **Writing.**
  - A string is replaced where it is.
  - A missing field is added to `\with`; a staff without one gets one.
  - A clef already in the music is changed there; otherwise it goes into
    `\with` (`\with { \clef bass }`, the staff's initial clef).
  - Treble is never written when nothing is there.
- **Instruments.** A catalog of 48 instruments: name, short name, family,
  clef, General MIDI sound and transposition.
  - Choosing one writes its names, `midiInstrument` and clef.
  - Typing a name that means an instrument ("Flute", "Vln I", "Vc") does
    the same. Any other name is a custom name, with a sound picked from
    the 128 General MIDI sounds.
  - Electronics stay silent: the patch plays them.
- **Concert pitch.** Scores are concert pitch: Pondside never writes
  `\transposition`. Octave transposers that read better at their written
  octave get the octave clef (`treble_8` for guitar and tenor, `bass_8`
  for double bass, contrabassoon and bass guitar), which keeps the sounding
  pitch. The catalog records each instrument's transposition for parts
  later.
- **Mockup sound.** The playback table in `pondside-playback.ily` still
  guesses a sound for names written by hand. An explicit `midiInstrument`
  always wins.

### `front-matter.ily` (`PondsideCore/Setup/FrontMatter.swift`)

- **The file.** `\bookpart`s that the root includes just before its first
  top-level `\score`. LilyPond makes the top-level scores after them into a
  bookpart of their own, so the root needs no other change.
  - Each part starts at a `%% ---- cover` / `notes` / `legend` line, in that
    order. Turning a part off removes it; turning it on puts it back in its
    place.
  - The preamble defines `\pondside-heading`, `\pondside-paragraphs` (a
    markup list of justified paragraphs that flows across pages) and
    `\pondside-legend-item`.
- **Cover.** It prints the root's `\header` (`title`, `subtitle`,
  `composer`, `dedication`, `instrumentation`, `duration`, `year`) through
  `bookTitleMarkup`, so the words live in one place. Instrumentation can be
  filled from the staves' names. The cover has no page header or footer;
  the score's first page still has its title.
- **Notes.** A heading and `\markuplist \pondside-paragraphs #'("…" …)`.
  - The panel edits the paragraphs as plain text (a blank line starts a new
    one) and writes on Update Score or when the editor loses focus.
  - Notes holding other markup are left to the source.
- **Legend.** Each row is `%% legend: <id>` and then
  `\markup \pondside-legend-item "Name" "Meaning" \score { … }`.
  - The example calls the same Lexicon entry as the score. A graphic gets
    two bars of a bare staff; any other entry gets its `entry.toml` example.
  - "Add from the Score" adds the entries the music uses that the legend
    doesn't explain yet. Other symbols get a row with `\null` and a comment
    showing where their notation goes.
- **Legend candidates** (`PondsideCore/Setup/LegendScan.swift`). The Legend
  page lists the special symbols the instrumental staves use, as checkboxes:
  ticking one adds its row, unticking removes it.
  - **The rule.** A candidate is a command the score defines itself and that
    appears in an instrumental staff's music. That means a music or event
    function, a variable of overrides with no events (`\slapOn`), or a
    post-event (`-\tweak …`, `#((fixed-span …))`). The walk follows
    variables into any file and looks inside voices of skips (box voices).
    LilyPond's own commands are standard notation and are left out, except
    a few extended techniques (`\xNote`, `\harmonic`, `\flageolet`…).
    Electronics staves are left out: their name, id or enclosing group says
    electronics.
  - **Variants.** Literal number, boolean and symbol arguments make variants
    (`\wind #1`, `#0.75`, `#0.5`). Index and integer arguments don't, and
    more than four values make one symbol with a parameter (`\playTempo`).
    `xOn`/`xOff` and `startX`/`stopX` pairs are one symbol.
  - **Probably not printed.** A definition that omits or hides what it makes
    (`\omit`, `stencil ##f`, `\tag #'played`), or a command named `play…` or
    `midi…`, goes under "Probably not printed". It can still be ticked.
  - **Words.** The title comes from the command name (`slapOn` → "Slap",
    `\wind #0.75` → "Wind 0.75"). The meaning is the comment above its
    definition, which is often written for the composer, so the user edits
    it.
  - **Examples.** Each is rebuilt from the first use, with notes taken only
    from the music that use is in. Pitches are absolute, durations
    effective, spelled in the root's note-name language, inside
    `\cadenzaOn` with no time signature.
    - A post-event goes after the note it followed. When it starts a spanner
      (`\startTextSpan` in its body, or a `stopX` partner), two notes follow
      and the second carries the stop.
    - A switch shows three notes between On and Off.
    - A function that takes music wraps the next three notes.
    - A `\once \override` goes before its notes, beamed when it is about
      beams.
    - A Scheme-built post-event often relies on the score's own machinery
      (a box registry), so its example is `\null`, with the notation in a
      comment for the user to try.
  - Checked on `as-the-wind3`: wind tones 1, 0.75 and 0.5, slap tongue,
    feathered beams, caesuras, trills, time fields and boxes. Every
    generated example engraves in the score's context.
- **Legend examples take no time.** A `\score` in markup is interpreted
  like any other. Without a guard, an example of an entry that has a sound
  would add a cue at 0 s. `\pondside-legend-item` sets `pondside-in-example`
  while it draws, and the timing listener (`TimingDump`) writes no rows
  then.

### Arranging the legend (2026-11-01)

The legend stays a table: rows of example | name and meaning. File ›
Arrange Legend (␣ f a, or Score Setup › Legend › Arrange on Page) turns on
handles on the legend's pages; ⎋ ends it.
- **What is written.** Everything lives in `front-matter.ily`:
  - the table in the legend's `\paper`: `pondside-legend = #'((x . 0) (top
    . 0) (example . 40) (gap . 7.5) (text . 0) (row-gap . 4) (scale . 1))`.
    That is the offset from the left margin and below the heading, the example
    column, the gap, the meaning column (0: to the right margin) and the
    space under each row, all in mm, plus the examples' scale;
  - per row, an optional `\pondside-example #'((left . 3) (right . 2)
    (scale . 1.2))` before the example: a crop in mm of the example as
    engraved, and a scale times the table's.
  The first arrange replaces a file's older definitions
  (`FrontMatter.upgradeEdits`) and the `\markup \vspace #1` spacers
  between rows, which row-gap replaces.
- **Cropping is a real clip.** In the PDF it is PostScript `rectclip`
  (`embedded-ps`). In the canvas SVG it is a `data-pondside-clip` group
  whose first `pondside-clip:` link names the rectangle;
  `EngravedPage` gives the graphics inside it a `clip`, and the renderer
  clips them. 2.26 no longer dispatches `embedded-svg`, so an SVG
  `clipPath` isn't possible.
- **Where things are.** In SVG output only, each row leaves invisible
  `pondside-legend:` links (`full`, `example`, `words`, `row`, `line`) that
  `EngravedPage.markers` collects. `LegendArrangement` (portable) builds
  the rows from them, finds the handle under the pointer, and solves a drag.
- **Handles.** The table moves (x, top). The meaning column's left edge sets
  the example column, its right edge the meaning column (dropped on the
  right margin: back to "to the margin"). The space under a row sets
  row-gap, with the next row following the pointer. An example's edges crop
  it; its corner scales it, and ⌥ scales every example.
- **Snapping** (⌘ while dragging turns it off): sides to the margins, a
  centre to the page's centre or thirds, edges to other rows' examples.
  The guides show while dragging.
- **While dragging** the affected music is drawn moved or scaled, and what a
  crop hides is veiled. On release it is one undoable edit, and the preview
  stays until the engraving replaces it.
- **Dragging again before the engraving lands** starts from the preview,
  not the old page: `LegendArrangement.Sheet.applying` applies the committed
  moves to the rows, so the handles sit where the last drop left them and a
  second drag adds to it instead of repeating or losing the first.

### Panel (HIG)

- **Pattern.** A utility panel, not a sheet, because people change a staff
  and watch it re-engrave. It is non-activating until a text field is
  clicked, and Esc closes it.
- **Writes.** Text fields write on Return or when they lose focus, never
  per keystroke, because each write is an edit and an engraving.
- **Show in Source.** A staff row's file and line jump to its `\new Staff`.
  The cover's button goes to the root's `\header`; the other pages' go to
  their part of `front-matter.ily`.

### Not built

- Adding, removing or reordering staves.
- Parts with transposition.
- Page numbering that restarts at the score.
- A template picker for the cover.
- MCP/CLI tools for Score Setup. Agents follow the skills' description of
  these files instead.

---

## 12. Agents: choosing opencode's model, stopping, provider errors (2026-10-31)

- **Model.** Settings shows a Model pull-down when the agent is opencode.
  - It lists what `opencode models` prints for the providers the user has
    set up (about 0.8 s, read in the background), grouped by provider. A
    provider with many vendors, like OpenRouter's 363 models, gets one
    submenu per vendor.
  - The choice (`Pondside.opencodeModel`) goes into the
    `OPENCODE_CONFIG_CONTENT` Pondside already passes, as `"model"`. That
    covers both `opencode acp` (lens requests) and `opencode run` (patch
    migrations); the ACP session reports it as its current model.
  - A user's own `OPENCODE_CONFIG_CONTENT` still wins. Changing the model
    starts a new conversation. "opencode's default" leaves the choice to
    opencode's config.
- **Stopping.** Edit › Stop Agent (⌘⌥., `␣ e k`, enabled only while an
  agent works), and a Stop Agent button in the status bar beside what the
  agent is doing.
  - A lens request is interrupted with `session/cancel`; the conversation is
    kept. A patch migration's process is ended.
  - Files already changed stay changed; `␣ e z` puts them back.
- **Work in progress on the page.** While a lens request runs, the region
  the agent was asked about (the selection's outline when it was sent)
  shows the agent at work.
  - **Pattern** (HIG Progress indicators, Loading): an indeterminate
    indicator on the content it describes. Not a blur or dim: the music is
    content, and blurring or dimming a region is the modal sheet idiom,
    which would hide the very passage the user is waiting to see change.
  - **The outline.** The selection's own accent outline, on a layer above
    the page (`PageView.workLayer`), breathes slowly between full and 30%
    opacity, 1.1 s each way. Only the layer animates, so the page never
    redraws per frame. It survives the agent's own re-engravings.
  - **The spinner.** A 20 pt spinner capsule (`WorkBadge`) sits on the
    outline's top-right corner. A labelled capsule above the region was
    tried and covered the staff above it, so the words moved to the status
    bar, the tooltip and VoiceOver. Clicks go through it.
  - **Settings.** Reduce Motion: no pulse, a dashed outline instead, so
    "working" still differs from "selected". Increase Contrast: a heavier
    line and fill, pulsing only down to 55%. Reduce Transparency changes
    nothing, because the capsule is solid chrome. These are re-read when
    the display options change.
  - **VoiceOver.** An announcement when work starts, and the capsule is a
    labelled progress indicator. Both fade out (0.2 s; none under Reduce
    Motion) when the request ends or is stopped.
- **Provider errors.** When a provider refuses (free usage limit, no
  credit, bad key, rate limit), opencode 1.19 logs `level=ERROR … message="stream
  error" session.id=… error.error="…"` and sends nothing over ACP: the
  `session/prompt` never answers. Checked on 2026-11-01: big-pickle's free
  limit; `opencode run` behaves the same.
  - `OpencodeLog` follows `~/.local/share/opencode/log/opencode.log` from the
    moment a request is sent and finds the working model's error for that
    session, ignoring `small=true`, the session-titling model. The request
    fails within about 1.5 s, and its turn is cancelled.
  - The message says what to do, for example "opencode's free usage limit is
    reached for this model (opencode/big-pickle). Choose another model in
    Settings (⌘,)…". It appears in an alert with Open Settings, not in a
    status-bar flash.
  - Silence with no tool running for 3 minutes also fails the request, with
    the log's path.

---

## Appendix A. Corrections to the brief (decided 2026-10-27)

1. **No MusicXML export from LilyPond.** Mockups go through LilyPond's
   MIDI (§3).
2. **Leader chords:** Space is the leader in the score (⌥Space anywhere),
   because `a`–`g` enter notes. LilyPond syntax typed into the score is the
   fast path.
3. **Sub-100 ms compiled feedback** is impossible; perceived latency is met
   instead (§5).
4. **Core Graphics into Core Animation, not Metal.** Revisit only if
   profiling asks for it.
5. **Automatic commits never touch the user's repository.** Built as
   `ShadowHistory`: a git repository per score under
   `~/Library/Application Support/Pondside/History` (its work tree the
   score's folder, so nothing is written into the project, not even a
   `.pondside/` folder, and no consent is needed). A checkpoint follows 30 s
   after the last save and on close; `pondside history` lists, shows and
   restores.
6. **Autosave races:** content-hash ownership, atomic writes, minimal-diff
   merges, and a conflict sheet with recovery files.
7. **`\ecue`, not `\cue`** (LilyPond already has cue notes). Timing comes
   from a LilyPond listener, not from parsing tempo out of the CST.
8. **Shortcuts:** they avoid macOS conventions. Workspace save is `⌘⌥S`;
   `⌘/` is the context overlay in the score.
9. **Hold-⌥ reveal:** arms only on a bare ⌥ held 500 ms.
10. **Canvas text fonts:** see §9.
11. **Install location:** Pondside › Install Command-Line Tool… links
    `pondside` into `~/.local/bin` (no admin rights) and says how to add it
    to `PATH`.
12. **Licensing and intent.** Pondside is academic research software,
    released open source. Its dependencies run as separate processes (LilyPond
    GPL-3, SuperCollider GPL-3) or are MIT (SwiftTerm, swift-sheet-music).
    Because they are not linked into the binary, GPL-3 does not propagate.
    The licence for Pondside itself is TBD by the author; candidates are MIT,
    Apache-2.0 and GPL-3 (for full copyleft compatibility).
13. **Muse Sounds from the CLI:** silence detection and the fluidsynth
    fallback are mandatory, and both are built.
14. **Over-specified brief items** (gradient budget, music font, layout
    presets) are defaults, not acceptance criteria.
15. **Glass on macOS 14 vs 26:** see §9.
16. **Toolchain detection.** Each external tool is found by the same
    strategy: check PATH, then check the platform's default application
    directories, then honour the `pondside.toml` override. The installer's
    own copies (Appendix A.17) live in
    `/Library/Application Support/Pondside/Toolchain` (`BundledToolchain`
    in `Toolchain.swift`, origin `.bundled`): its LilyPond is a candidate
    right after `PONDSIDE_LILYPOND`, and `ToolchainDetector.select` still
    picks by the score's `\version`; its fluidsynth and SoundFont are used
    before any on PATH and whenever no SoundFont is configured.

    | Tool | PATH name(s) | Default location (macOS) | `pondside.toml` key |
    |---|---|---|---|
    | LilyPond | `lilypond` | `/Applications/LilyPond.app/…/bin/lilypond` | `lilypond.path` |
    | sclang (SuperCollider) | `sclang` | `/Applications/SuperCollider.app/Contents/MacOS/sclang` | `supercollider.path` |
    | MuseScore | `mscore`, `MuseScore4` | `/Applications/MuseScore 4.app/…/mscore` | `musescore.path` |
    | FluidSynth | `fluidsynth` | Homebrew: `/opt/homebrew/bin/fluidsynth` | `fluidsynth.path` |

    **Why not bundle SuperCollider (like Sonic Pi)?** Sonic Pi bundles
    scsynth only, because it never runs sclang — it has Ruby as its own
    language layer. Running real `.scd` patches requires sclang *and*
    SCClassLibrary, and sclang links about 500 MB of Qt. A Qt-less sclang
    (`SC_QT=OFF`) would be small but drops `Window`, `Pen` and the rest of
    the GUI classes, so patches that draw would fail. The installer
    downloads the official, notarized SuperCollider.app instead.

    **Portability.** The portable modules (everything below `PondsideUI`)
    already build and test on Linux. The detection logic uses only the
    standard library; platform paths are injected from above the seam. A
    future Linux or Windows headless build would supply different defaults
    to the same code.

    **Graceful degradation.** When a tool is absent:
    - The SC pane shows: *"SuperCollider not found. Install it from
      supercollider.github.io, or set `supercollider.path` in
      pondside.toml."* The rest of the app is unaffected.
    - `pondside mockup` falls back from MuseScore to FluidSynth; if both
      are absent it exits with an actionable message.
    - `pondside cues` and `pondside check` need only LilyPond.

17. **The installer (decided 2026-10-29).** `scripts/make-installer.sh`
    builds `.build/Pondside-<version>-<arch>.pkg`, a standard flat package
    (`pkgbuild` components, `productbuild` with
    `scripts/installer/distribution.xml`). Installer.app shows welcome,
    licence and conclusion pages and a Customize pane of checkboxes:

    | Component | Default | Contents |
    |---|---|---|
    | Pondside | locked on | `Pondside.app` in `/Applications` (not relocatable, so Installer never "upgrades" a developer build elsewhere) |
    | LilyPond | locked on | pinned (`versions.env`) in `Toolchain/lilypond-<v>`: on Apple silicon built from source by `build-lilypond.sh`, on Intel the official tarball |
    | Command-line tool | on | links `/usr/local/bin/pondside` |
    | FluidSynth + SoundFont | on | static universal fluidsynth (`build-fluidsynth.sh`) and GeneralUser GS |
    | SuperCollider | on unless installed | downloaded at install time |
    | MuseScore Studio | off | downloaded at install time; Muse Sounds still needs Muse Hub |

    **Gatekeeper.** The package and app are ad-hoc signed (or unsigned),
    not notarized. A downloaded `.pkg` is quarantined, so the user opens it
    once with System Settings → Privacy & Security → Open Anyway (on
    macOS 15 Control-click → Open no longer bypasses Gatekeeper). Files
    Installer writes carry no `com.apple.quarantine` flag, only
    `com.apple.provenance`, so `Pondside.app` then opens without a prompt.
    Checked 2026-10-29 on macOS 15.2: a quarantined package's ad-hoc-signed
    payload launched with no Gatekeeper evaluation. A Developer ID
    certificate and notarization would remove the one remaining step.

    **What was measured.** Homebrew's fluidsynth targets the build machine's
    macOS (15), and FluidSynth publishes no macOS binaries, so the installer
    builds one: FluidSynth (`osal=cpp11`, no glib) and a codec-free
    libsndfile linked statically, universal, macOS 14 minimum, 2.2 MB,
    system frameworks only. LilyPond 2.26.0's official arm64 tarball requires
    macOS 26 (it calls `strchrnul`); its x86_64 tarball needs 10.15 and
    under Rosetta engraves about twice as slowly (0.56 s against 0.29 s
    for `Tests/Scores/invention.ly`). So `build-lilypond.sh` runs
    upstream's own release scripts (`release/binaries`) with
    `MACOSX_DEPLOYMENT_TARGET=14.0`: a native build, macOS 14 minimum,
    system libraries only, which engraves `invention.ly` to SVG faster
    than Homebrew's on the same machine. It takes about 30 minutes, once
    per LilyPond version, on the machine that builds the package; users
    only receive the result. One local patch: Python's configure is told
    to ignore `libintl.h`, because clang searches `/usr/local/include`
    and a leftover Intel Homebrew there broke the link. The script and
    `make-installer.sh` both refuse a binary that needs a newer macOS or
    a non-system library. The build is not byte-reproducible, so it is
    cached in `.build/installer` rather than pinned by checksum; hosting
    it as a release asset would let `make-installer.sh` fetch it pinned.
    Installed LilyPond is about
    130 MB; the package is about 115 MB.

    **Downloads at install.** `fetch-app.sh` pins each disk image's URL and
    SHA-256, checks the app's Developer ID team (SuperCollider
    `HE5VJFE9E4`, MuseScore `6EPAF2X3PR`), and copies it to
    `/Applications`. A failed download is logged to `/var/log/install.log`
    and never fails the installation; Pondside reports the missing tool
    when a feature needs it.

    **Licences.** LilyPond is GPL v3 and ships its own and its libraries'
    licence texts; FluidSynth and libsndfile are LGPL v2.1, linked
    statically (relinking is possible from the published sources and
    `build-fluidsynth.sh`); GeneralUser GS's licence asks for a local copy
    rather than a link to its author's downloads, which is why it is
    bundled. The licence page is generated from these texts. Pondside
    itself still needs a `LICENSE` file (A.12).

    **Uninstalling.** Delete `/Applications/Pondside.app`,
    `/Library/Application Support/Pondside/Toolchain` and
    `/usr/local/bin/pondside`.
