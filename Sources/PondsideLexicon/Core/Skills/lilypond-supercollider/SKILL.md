---
name: lilypond-supercollider
description: LilyPond -> SuperCollider in Pondside, for pieces for acoustic instruments and live electronics -- cue times in seconds from the score's \ecue marks, the electronics staff's pitch collections as ~ec arrays, timed marks for passages SuperCollider renders (improvisations), cue handlers in the patch, and a Muse Sounds mockup to test against -- all from Pondside's own timing (pondside cues / mockup / handlers, the Pondside quark), timed exactly as the MIDI plays, hidden tempo changes for fermatas, caesuras and timed sections included. Use whenever a score and a SuperCollider patch belong to the same piece, someone wants cue times / harmonies / a test render in sc, asks why cue times moved, adds fermatas or holds that should affect timing, or sets up a new electronics piece. Builds on lilypond and lilypond-electronics-staff.
---

# LilyPond -> SuperCollider (Pondside)

The score is the source of truth for *when*. Pondside reads every cue, mark,
collection and tempo from LilyPond's own interpretation of the score (its
timing listener, injected into every compile) and turns moments into seconds
with the tempo map the MIDI plays. One compile gives the mockup and the cue
times, so they cannot disagree.

**Never add a second timing pipeline** (a `timing.ily` engraver,
`lily_timing.py`, `export_piece.sh`, a hand-written cue table): it would
compute times from a different interpretation of the score (no repeats played
out, no generated playback) and drift from the mockup. Older projects that
include `timing.ily` keep working (it only writes `score.timing`); Pondside
ignores that file.


## Performance initialization contract

Preserve `pondside://patch-contract` on every edit (full documentation:
`docs/SUPERCOLLIDER.md`, “Performance initialization contract”). The main
`.scd` starts with a usage comment: execute its main block once, then call
`~triggerCue.()` to fire live cues. A single main block sets `s.options`,
reboots the server, and puts ALL preparation in `s.waitForBoot`: `~mode`
(`\live` or `\mockup`, respecting `~pondsideMode`), dependency execution,
buffer loads, buses, SynthDefs, Pbinds, cue functions and startup synths.
Finish required asynchronous server preparation with `s.sync` before the
ready signal. Never add another required setup block or loose setup lines.
All sounds except the score mockup live in `patch/resources/` or
`Platform.userAppSupportDir +/+ "sounds"`, including child directories;
reference them through `~resources` / `~sharedSounds`. No Qt requirement in
the exported performance patch. Keep the fast edit → patch_check → patch_note
workflow: use supplied numbered context, read more only when necessary,
and repeat checks only to resolve a failure or an audible problem.

## What Pondside writes, and where

`score` below stands for the root file's name (`quartet.ly` gives
`renders/quartet.wav`, `patch/quartet.scd`, …). Use the real name; never
rename the score to match.

| File | Written by | Format |
|---|---|---|
| `renders/score.wav` | the app after every good engraving (`pondside mockup score.ly`) | the playback, padded to the end mark (improvisation recordings mixed in) |
| `renders/score.cues` | the same run | `seconds<TAB>bar<TAB>cue N`, one line per cue, in order |
| `renders/score.collections.scd` | the same run, when the score has collections | `~collections` (every staff's `\collection`, in score order, each an Event: `pcs`, `midi`, `staff`, `bar`, `time`, `cue`, `index`) and `~collectionsOn['elecUp']`; the engine loads it |
| any `--out` file | `pondside cues score.ly --format cues` | the same lines |
| | `pondside cues score.ly --format collections` | the same `~collections` file |
| | `pondside cues score.ly --format ec [--staff elecUp]` | `~ec = [...]; ~ecWhere = [...];` (pitch classes of each `\collection` on one staff; older patches) |
| | `pondside cues score.ly --format marks [--prefix improv]` | `seconds<TAB>bar<TAB>improv 1` lines |
| | `pondside cues score.ly` (json) / MCP `cues` | cues.json: moment, bar, beat, seconds, samples, handler name |
| `patch/score.scd` | the SuperCollider pane when there is no patch, or `pondside handlers score.ly` | the patch (below); after each mockup the app adds a `~cue[\cue12] = { |cue| … };` stub per new cue that has no handler yet |
| `patch/dependencies/pondside.scd` | the same, kept current by the app | the engine: never edit it |
| `renders/score.mix.wav` | the app after each mockup (`pondside mix score.ly`) | the patch rendered offline in mockup mode: the score with its electronics; ⌘⌥P plays it from the selection |

Cue names: `\ecue "12"` → `cue 12` → handler `\cue12` (`"FxSwell"` →
`\fxSwell`). The sample rate is `[audio] sample-rate` in `pondside.toml`.

## The patch (`patch/score.scd`)

The composer's code and cue handlers live in one main initialization block.
Its `s.waitForBoot` prepares all dependencies and sound resources after
options and reboot. The generated engine loads there using
`(patchFolder +/+ "dependencies/pondside.scd").load;`. Each cue has one
`~cue[\cue12] = { |cue| … };` between Pondside's existing markers. After
executing the main block once:

- `~triggerCue.()`: cue 1 starts the piece (mockup: the mockup plays and
  the cues fire on time; live: the mic is the live signal); after that, the
  next cue (live: from a pedal in a `// @pondside live` block).
- `~triggerCue.(12)`: start at, or jump to, cue 12; the cues before it run at once.
- `~stop.()`.

Effects on the performer read `In.ar(~live)`. The engine's other state is
in `~pondside` (read by key), so a patch's own names are free.

Cue code is ordinary SuperCollider: a cue runs as a routine on the score's
clock, so `wait`, `fork`, patterns, `s.sync` and buffer actions are heard in
the mix as live (not code timed by `SystemClock`/`AppClock`). The render runs
the `( … )` blocks one at a time with `~mode = \mockup`, then
`~triggerCue.()`; loose lines are ignored, and a block whose first line is
`// @pondside live` runs live only (windows, MIDI/OSC setup, recording). A
render that fails keeps the last good mix. A patch written elsewhere, or one
with `// pondside:` marks: skill://sc-patch-migration (`pondside patch
score.ly --fix` first).

An older file for the Pondside quark (`p = Pondside(dir, "score");
p.on(\cue12, { … });`) keeps working with `pondside handlers` (stubs, and
the `p = Pondside(…)` line if missing), but is not rendered into a mix.

Collections: `"pondside cues ../score.ly --format ec --out ec.scd".unixCmd({ "ec.scd".resolveRelative.load })`
(or run it once from the shell). Never edit inside a `// @pondside` handler's
markers by script: that code is the composer's; `pondside handlers` only adds
stubs, updates the comment line, and comments out handlers whose cue left.

## The score side

Copy `assets/playback.ily` (this skill) and `electronics.ily`
(lilypond-electronics-staff) into the score's folder and include them.

- **Cues:** `\ecue "N"` in the electronics cues voice. Number them in score order.
- **Collections:** `\collection { ... }` on any staff (Pondside's own, through `lexicon.ily`; not in `electronics.ily`). Name the staff (`\new Staff = "elecUp"`): that is its `staff` in `~collections`. In the patch, `~collections[3].pcs` or `Scale(~collectionsOn['elecUp'][0].pcs)`; a patch that used `~ec` can keep it with `~ec = ~collectionsOn['elecUp'].collect(_.pcs);` after the engine loads.
- **The MIDI:** a score without its own `\midi` gets Pondside's generated
  playback (repeats played out, trills, `\articulate`, electronics staves
  silent; music tagged `printed` silent). A score with a `\midi` block plays
  exactly as written; then the MIDI score holds only what the render plays:
  ```lilypond
  \score { \new Staff \with { midiInstrument = "flute" } <<
      \new Voice \midiTrills \removeWithTag #'printed \inst
      \new Voice \instDynamics  \new Voice \instPlayback >>  \midi { } }
  ```
  and the printed score uses `\removeWithTag #'played \inst`. Keep the cues in
  the `\layout` score: Pondside times what the layout score's contexts hear.
- **Holds:** hidden `\playTempo` changes in a playback voice of skips -- a
  4-beat bar lasting 20 s: `\playTempo 12`; a fermata (whole note at 60 = 4 s);
  a caesura (`s4` at 30 = 2 s). Restore the tempo at the next bar unless a
  printed `\tempo` is there; never put `\playTempo` at the same moment as a
  printed `\tempo` (Pondside warns). The Lexicon's `timed-fermata` and
  `senza-misura` entries do the same with params.
- **Improvisations in the mockup:** a recording per mark (`improv/improv1.wav`
  for "improv 1", or `[audio] parts`) is mixed in at its mark, or an
  `[audio] hook` script renders them (docs: SUPERCOLLIDER.md, "Parts the MIDI
  can't play"). Don't render them into a second wav by hand.
- **Passages SuperCollider plays:** `\improvisation 1 { ... }` prints the music,
  is silent in the MIDI, and marks `improv 1` / `improv end`. `\silentInMidi { ... }`
  silences without marks.
- **The end:** `<>\timingMark "end"`; the mockup is padded to it.

`templates/score.ly` is a starting point with every layer.

## When times change

Changing durations, rests (removing a hidden rest!) or any tempo moves every
later cue; layout changes don't. After such an edit the app rewrites
`renders/score.cues` with the next mockup; tell the user how far the cues moved (the
Cue Inspector, or diff the old and new `score.cues`).

## Verifying

- `renders/score.cues`: one line per `\ecue`, times increasing (Pondside warns
  otherwise). Spot-check one: sum of beats × 60/bpm.
- `~collections` has one entry per `\collection`, in score order; `sclang` can load the file.
- Commit the `.ly`/`.ily` files and `patch/`, not `renders/`, `score.timing`,
  PDFs or MIDI.
