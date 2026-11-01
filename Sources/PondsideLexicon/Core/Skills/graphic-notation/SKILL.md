---
name: pondside-graphic-notation
description: Put graphic notation (textures, grains, ripples, wedges, swells, contours, birds, any drawing) into a LilyPond score in Pondside, or change one the user clicked ("taller", "denser", "till 7") -- through the Lexicon's graphic entries or the score's own drawing code, from terse requests, fast. Use whenever someone using Pondside asks for a graphic, texture, drawing or gesture in the score or clicks one and says how to change it, even in two words. Escalate to the pondside-lexicon-entries skill only when nothing existing can draw it.
---

# Graphic notation in Pondside

The user clicks a graphic or a note and types a few words. Answer with the
edit, fast: the app re-engraves on every save and the user sees the result.

## The fast path (1 call)

A request from the lens comes with `score_context` already in it. Its code
(`definition`, `drawing`, `uses`, `music`) is numbered as in the file
(`412| `, not part of the line).

1. One `edit` by `from_line`/`to_line` or exact `old` text, straight from that
   code: no reading the file first. It returns the app's engraving of the change
   (`check`), so there is no separate check. Fix only what it reports.
   A new graphic: `graphic_insert`, then `check`.

Without a lens request, call `score_context` (no arguments) first.

Then reply in one line: what changed, with the numbers ("Taller: half-height
1.06 → 2.1."). No plan, no recap, no offers, no preview.

**Make it visible at a glance.** The user judges the result by looking at the
page at normal zoom. A change too small to see (grains thinned by a third in
a dense cloud) reads as nothing happening: scale by about 2× per word, and
for "different" change the shape, not a seed's details.

Don't call `lexicon_search` or `lexicon_entry` when the table below names the
entry and its params; don't call `graphic_preview` unless the user asks to see
options; don't read files the context already quotes: `uses` has the helpers in full.

## Reading score_context

| field | use |
|---|---|
| `graphic.entry`, `params`, `start`, `stop` | a Lexicon graphic: edit its alist in place (`\startGraphic "id" #'(...)`) |
| `graphic.command`, `start`, `stop`, `definition`, `drawing[].text`, `uses`, `notes` | a graphic drawn by the score's own Scheme (`\startGrains`): `drawing` is the stencil procedure (file and lines), `uses` the helpers and constants it calls, in full (numbered) when short, else their definition line, `notes` the file's description of it. Change the number that controls what the user named; edit `uses` constants only if the drawing has no local number for it (a shared constant changes other graphics too) |
| `selection` | the user clicked **one part** of a large drawing: `x` (a fraction of the piece's width, from its left edge), `y` (staff spaces above the middle line), `spanner_x` (that system's piece), `at` (the nearest bar/moment), `scope` (the exact Scheme test for "inside the highlight") and `music_around` (the music on either side: wider than the highlight, not for scoping). The change covers exactly the highlight: gate it on `scope`, and on the piece (`spanner_x`) so the same x on another system is not changed too |
| `event`, `staff`, `music` | where a new graphic goes: the clicked staff's voice |
| `bar`, `moment` | where "here" is (moment = whole notes from the staff's start) |
| `cues` | `"7: bar 9 beat 2, moment 221/8, 75.5 s"` -- for "till 7", "from cue 5" |
| `system.first/last/next` | "to the end of the line", "until the next system" |

## Terse words → edits

| user says | do |
|---|---|
| taller / shorter, wider band | `height` (×2 / ×0.5); in custom code the half-height numbers |
| denser / sparser | `density` (×2 / ×0.5) |
| gradually denser / thinning out | `density . (linear lo hi)` / `(linear hi lo)` |
| swelling, breathing | `height . (swell 3 lo hi)` |
| louder-looking, darker / lighter | `gray` lower / higher; dot `size` up |
| higher / lower | `centre` ± 1 |
| longer / shorter, "till X" | move `\stopGraphic` (see below) |
| different, again | change `seed` |
| keep out of the notes | `avoid . (note-head-interface accidental-interface)` |
| "X here" (new) | a new graphic from `event` on this `staff` |

Scale by about 2× per word ("much taller": 3×). Numbers the user gives win.

**"till 7", "to 12", "from 5":** a number is a **cue** when `cues` has it and
bar 7 is not ahead of `bar` (we're at bar 28: "till 7" is cue 7); otherwise a
bar. `graphic_insert` takes `stop_cue: "7"` (or `stop_moment`) and splits the
skip the cue falls in; when moving a stop by hand, split the skip yourself:
`s4*7` at 3 beats → `s4*3 s4*4\stopGraphic`.

## A new graphic

`graphic_insert` with `start_line`/`start_character` = the clicked event, the
entry, params, and `stop_*`. It writes into that voice of skips. A voice holds
one graphic at a time (they are text spanners): if the clicked voice already
has a graphic over the span, insert into another voice of skips on the staff,
or add one (`\new Voice { s1*… }` beside the others) first.

| id | what | key params |
|---|---|---|
| `grain-cloud` | seeded dots in a band | `density` (env), `height` (env), `centre` (env), `size`, `avoid`, `seed` |
| `scribble` | short random strokes in a band | `density` (env), `height` (env), `length`, `spread`, `thickness`, `seed` |
| `staff-ripple` | staff lines turning into loops | `amplitude` (env), `curl`, `wavelength`, `lines`, `thickness`, `seed` |
| `wedge` | filled wedge, may dissolve into grains | `from`, `to`, `centre`, `gray`, `dissolve`, `seed` |
| `swell-shape` | solid shape following an envelope | `height` (env), `centre` (env), `side` (both/up/down), `gray` |
| `arc` | smooth contour through points, with echoes | `points` ((q y) …), `thickness`, `echoes`, `echo-offset` |
| `squiggle`, `pitch-band`, `aleatoric-box` | see `lexicon_entry` | |

Project and user entries may add more: `lexicon_search` when the table has
nothing close. **Nothing draws it** ("birds"): write a draft entry at once
(pondside-lexicon-entries skill; start from the nearest entry's `impl` via
lexicon://impl/{id}, e.g. `grain-cloud` for scattered figures, give it
`density` and `height` envelopes and a `seed`), `lexicon_propose`, then
`graphic_insert` it. One draft, no alternatives unless asked.

## Envelopes

Any `(env)` param takes a number or, over q = 0…1 along the span:
`(linear a b)`, `(swell n lo hi)`, `(pulse n lo hi)`, `(lfo cycles depth centre)`,
`(points (0 0.5) (0.3 3) (1 0.5))`, `(sum e1 e2)`, `(product e1 e2)`, `(smooth e)`.

## Conventions

- When `selection` is present, the user highlighted only that part, and the
  change covers exactly it. Paste `selection.scope` (with `x0`/`x1` from
  `g-span`, `x`/`y` the loop's point) into the band loop as the condition for
  the change. Never widen it to a bar, to `music_around`'s moments, or to the
  whole stencil; if anything, stay a little inside. If the code cannot be
  gated on x and y, ask instead of changing every bar.
- Graphics live in voices of skips, never on sounding notes.
- Units: staff spaces; y = 0 is the middle line, the lines are at −2…2.
- Keep seeds explicit so a drawing the user likes never changes.
- Layer (two voices on one span) or chain (`\stopGraphic\startGraphic` on one
  skip) existing entries before inventing one.

## The legend

Explain the score's graphics in its legend, `front-matter.ily` (Score Setup ›
Legend writes it; the root includes it before the score). Each row is
`%% legend: <entry-id>` then `\markup \pondside-legend-item "Name" "Meaning"
\score { … }`, the example calling the same entry the score uses. Add a row by
copying that shape inside the `%% ---- legend` bookpart; never make a second
legend page or file. An example may be wrapped in `\pondside-example #'((left . 3)
(right . 2) (scale . 1.2))` (crop in mm, scale); the table's layout is
`pondside-legend` in that bookpart's `\paper`. Both are written by File ›
Arrange Legend: leave them as they are.
