---
name: sc-patch-migration
description: Finish turning a composer's own SuperCollider patch into a Pondside patch -- after Pondside's automatic migration (patch_migrate), fix every line it marked `// pondside:` (code that never runs in the mix, hand-timed timelines, SystemClock/AppClock timing, windows, MIDI/OSC/key triggers, hardware inputs, recording) so the piece plays the same live and in the offline mix. Use when the user asks to migrate, refactor, adopt or "make Pondside-ready" a patch, mentions `// pondside:` marks or score.before-pondside.scd, or Pondside's refactor dialog sent them here. Builds on lilypond-supercollider.
---

# Migrating a patch to Pondside

A Pondside patch (`patch/<score>.scd`, first line `// @pondside patch`) is
the composer's code plus a first block that loads Pondside's engine
(`patch/dependencies/pondside.scd`, never edit it), a cue block and run
lines. It is run two ways: live, block by block with ⌘↩ and then
`~triggerCue.()` per cue; and offline after every engraving, when Pondside
runs its `( … )` blocks in mockup mode, fires every cue at its time, and
renders `renders/score.mix.wav` (⌘⌥P).
The reference for every block is docs/SUPERCOLLIDER.md in Pondside; the
short version is skill://lilypond-supercollider, "The patch".

## The loop

1. `patch_audit` (score file) lists what is left: findings, and lines marked
   `// pondside: …` in the patch and in the files it loads
   (`dependencies/x.scd:12`). If the patch isn't migrated yet, call
   `patch_migrate` once first (it moves the patch and what it uses into
   `patch/`, fixing their relative paths).
2. Fix each marked line (below) and delete its mark. Never touch the engine
   block (`// 2. Engine`) or the `// @pondside` markers.
3. `mix` (score file) must render with no errors; fix what it reports. A
   patch is done when `patch_audit` and `mix` are both clean.
4. Reply in at most 3 short lines: what changed, what you left and why.
   No headings, bullets or recaps. When something goes wrong that the user
   must know, call `warn_user`; when you can't go on without their choice
   (two readings, which cue a time belongs to), `ask_user` with choices.

Keep the composer's sound: move and re-time code, don't rewrite synthesis.
Delete only what Pondside replaces (the old cue runner, the old timing
pipeline) or what is a duplicate.

## What each mark means

| Mark | Do |
|---|---|
| runs only when run by hand | Loose code (outside `( … )`). Definitions (SynthDefs, buffers, buses, `~state = …`, `s.options`) go into a block in section 3; `s.waitForBoot { … }` may stay (the mix treats the server as booted). Things that start the piece (`~myStart.value`) become cue code; ad-hoc test lines can stay loose. |
| starts when its block runs | A `.play`/`fork` at setup: it starts at 0:00 in the mix. If it belongs to a moment of the piece, move it into that cue's handler. A drone or effect meant to sound from the start can stay: then delete the mark. |
| timed by SystemClock/AppClock | Turn it into `wait` inside a cue, or use the default clock (`TempoClock.default`, the score's clock while playing). Absolute times ("at 30 s") become the cue at or before that time plus a `wait` for the rest. |
| a hand-made timeline (`Routine { 10.wait; … 20.wait; … }` started at once) | Split it at its events: each event goes into the cue where it happens (`cues` gives every cue's seconds and bar). Keep waits shorter than the gap to the next cue inside one handler. |
| a trigger (MIDIdef, OSCdef, keys, GUI buttons) | If it advanced the composer's own cues, call `~triggerCue.()` (cue 1 starts the piece, then the next cue) or `~triggerCue.(N)` instead. Put its setup in a block whose first line is `// @pondside live` (the mix skips it). |
| opens a window | Move it into a `// @pondside live` block. |
| assigns a name the engine uses (`~cue`, `~stop`, `~live`, …) | Rename it in that file and everywhere the patch uses it (`~myCues`), or delete it if it belongs to the old cue runner. |
| a second timing pipeline | Delete it: Pondside writes `score.cues` and fires the handlers. See "Cue mapping". |
| reads a hardware input | Effects on the performer use `In.ar(~live)` (the mockup in mockup mode, input 0 live). Another input or several: change `\pondsideMic` in the engine only if the user agrees; otherwise keep `SoundIn` in a live-only path. |
| records to disk | Pondside's mix is the recording; move recording into a `// @pondside live` block. |

Renames Pondside made (`~buf` → `~myBuf`, …) are listed in the first
comment lines; keep them. A cue handler is `~cue[\cue12] = { |cue| … };`
between its markers; it runs as a routine, so `wait`, `fork`, patterns and
`s.sync` work, and everything it starts is stopped by `~stop`.

## Cue mapping: one place per cue

The goal is a patch where each cue's code sits in its handler, under the
header that says its bar and time. Don't leave a dispatcher such as
`~cue[\cue3] = { ~myCue.(\cue3) }` pointing into the old list.

1. Find the old cue mechanism: a list of functions (`~cues = [ (name:, do:) … ]`),
   a `switch` on a counter, a `~nextCue`, or a timeline routine.
2. Call `cues` for the score's cues. Map old to new by order, then check the
   ones that matter against what the score shows there (`score_context` at
   the cue's bar). If the counts differ, map what is certain, keep a mark on
   the rest, and say so.
3. Move each old cue's body into its `~cue[\cueN] = { |cue| … };` handler
   (the function's body, not a call to it). `at:` times and per-cue offsets
   become `wait`s inside the handler.
4. Delete what Pondside now does: the old list, its runner (`~nextCue`,
   `~runCues`, `~gotoCue`, `~jumpTo`, counters) and its cue-time loading
   (`piece.cues`, `export_piece.sh`). A hook that mixed improvisations into
   the old render becomes `[audio] hook` (or its solo files `[audio] parts`)
   in `pondside.toml`; tell the user rather than writing it yourself. Remove the `load` of a file that only
   held those, and keep the helpers the cues still use (`~later`, `~glide`).
   `~triggerCue.(N)` replaces jumping to a cue (`~jumpTo`: it catches up
   through the earlier cues) and playing from one.
5. Helpers that wait on `SystemClock` (`fork(…, SystemClock)`,
   `Routine.play(SystemClock)`) change to the default clock: inside a cue
   that is the score's clock, so the mix hears them and `~stop` stops them.
