---
name: pondside-sc-patch-editing
description: Change a Pondside score's SuperCollider patch from a request at a point in the score ("more reverb here", "a grain cloud on this chord from cue 12", "fade the delay out by cue 14") -- as Pondside's patch agent, fast, through the cue's handler, the SuperCollider Lexicon and the patch doc. Use whenever a request about the electronics or the patch comes from Pondside's lens, or someone asks to change what the electronics do at a cue in a Pondside patch.
---

# Editing a Pondside patch

You are the patch agent. The user clicked a point in the score and typed a few
words about the electronics there. The `.ly` files are not yours (the score
agent edits them); `dependencies/pondside.scd` and `dependencies/sc-lexicon.scd`
are Pondside's. You change the patch: `patch/<score>.scd` and the files it loads.


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

## The fast path (3 calls)

1. One `edit` of the handler (or what it touches), by `from_line`/`to_line` or
   exact `old` text, from the numbered code in the context. No reading first.
   Need an effect or a pattern part? `sc_lexicon_add` it first (one call), then
   call it in the handler. The first `sc_lexicon_add` adds a load line near the
   top, so the handler is then one line further down: edit by `old` text, or
   give `old` with `from_line` so the edit checks the lines first.
2. `patch_check` with the cue: renders the mix, reports errors, and the cue
   window's levels (mix, and electronics alone) before and after. Fix and
   re-check only on errors, or if the electronics are silent where they shouldn't be.
3. `patch_note` on each item you changed: what it is for and why, in a line or
   three. Not the code: the doc's outline already has where it is.

Then reply in one line: what changed and how it sounds now, with numbers
("Cue 12: reverb mix 0.3 → 0.7, room 0.9; electronics −16 dBFS (was −24).").

## Reading patch_context

| field | use |
|---|---|
| `cue` | the cue at or before the point: `name`, `bar`, `seconds`, `handler` (`~cue[\cue12]`), `window` (until the next cue), `code` (the handler, numbered), `point_after_cue`, and `wait`/`wait_examples` when the point is over 0.5 s after it |
| `cue.touches` | what the handler uses (SynthDefs, patterns, buses, functions): `item`, `at` (file:lines), and `text` when short |
| `collections` | the score's pitch collections around the point: `pitch_classes` (C = 0) and `midi` -- "on this chord" means these |
| `doc` | the patch doc: every item with file:lines, and notes on intent. **Read the notes first**: they are what you (or the composer) worked out about this patch before |
| `stale_notes` | notes whose code changed since: trust the code, and rewrite the note when you touch it |
| `sc_lexicon` | one line per entry: id, kind, gloss, how to call it, params |
| `next_cue`, `cues` | "until 14", "from cue 5" |

A point before the first cue belongs to setup or cue 1. `point.seconds` is
the exact time of the click, and `cue.point_after_cue` how far past the cue
it is. More than 0.5 s after (`cue.wait` says so), the change must not start
on the cue: wait that long inside the handler first, the way the patch
already waits (`cue.wait_examples`; else `1.25.wait;`, or `fork { 1.25.wait; … }`
when later code in the handler mustn't be delayed). The clock's beats are
score seconds, so the wait lands on the click's time.

## Where code goes

- **What happens at a cue** goes in that cue's handler, `~cue[\cueN] = { |cue| … };`
  between `// @pondside cue …` and `// @pondside end …`. It runs as a routine:
  `wait`, `fork` and patterns work, on score seconds.
- **Something that lasts** (an effect, a pattern) started at one cue is kept in
  an environment variable (`~verb = Synth(…)`, `~cloud = Pbind(…).play`) so a
  later cue can change or stop it (`~verb.set(\mix, 0.8)`, `~cloud.stop`,
  `~verb.release(4)`). Name it in the note.
- **Setup** (SynthDefs, buffers, buses) goes inside the main block's waitForBoot preparation, not in
  a handler; a SynthDef added in a handler may not exist on the server when the
  handler's first note plays.
- Effects on the performer read `~live` (a mono bus: the mockup, or the mic
  live) and go at the tail: `Synth(\lx_reverb_mono, [\in, ~live, \mix, 1], addAction: \addToTail)`.
- Never a second timing pipeline, `SystemClock` or `AppClock`: the engine fires the cues.

## The SuperCollider Lexicon

`sc_lexicon_add` writes the entries (and what they require) into
`dependencies/sc-lexicon.scd` and loads it after the engine. Then:

| kind | call |
|---|---|
| effect | `\lx_<name>_mono` on a mono bus (`[\in, ~live]`), or `\lx_<name>` as an insert on a pattern's bus (`~lx[\withFx].(pat, [[\reverb, (mix: 0.4)]], tail)`). Every effect takes `mix`, `amp`, `gate`, `release` and its params; `.set` them live |
| synth | `\lx_grain` in a Pbind |
| pattern | `~lx[\pitches].(pcs, lo, hi)`, `~lx[\glide].(from, to, secs, curve)`, `~lx[\density].(from, to, secs)`, `~lx[\cloud].(pcs, density, amp, lo, hi, length)`, `~lx[\withFx].(pattern, effects, tail)` |

`sc_lexicon_entry` gives an entry's params and code; you rarely need it when
`sc_lexicon` names the params. When nothing fits, write the code in the patch
(a SynthDef in setup, a function or pattern in the handler) rather than
changing an entry.

## Terse words → code

| user says | do |
|---|---|
| more / less X (reverb, delay, grit) | that effect's `mix` (×2 / ×0.5), or add it at the cue |
| bigger, longer tail | `room`/`rt60` up, `release` up |
| darker / brighter | `lpf` `freq` down / up, or the effect's `damp`/`tone` |
| denser / sparser | the pattern's `\dur` (÷2 / ×2) or `~lx[\density]` |
| gradually X, "over 20 s" | `~lx[\glide]` on that key, or a `Line.kr`/`.set` loop in the handler |
| on this chord | `~lx[\pitches].(collections[0].pitch_classes)` |
| till 14, stop at 14 | stop it in cue 14's handler (`~cloud.stop`, `~verb.release(2)`) |
| quieter / louder | `amp` (×0.5 / ×2) |

Make it clearly audible unless the user asks for subtle: `patch_check`'s
electronics level should move by several dB.

## The patch doc

`patch/<score>.patch.md` is your memory, not the conversation (which is
compacted, reset, or lost with a new model). `patch_doc` rebuilds its outline
from the code; `patch_note` writes one item's note. Notes say what an item is
for, which cues use it, and what the composer asked for ("the flute's halo:
grows from cue 3, gone by 9"). The `overview` note holds the patch's plan:
the layers, which buses they share, and what each section of the piece does.
Write it on your first request if it is empty.
