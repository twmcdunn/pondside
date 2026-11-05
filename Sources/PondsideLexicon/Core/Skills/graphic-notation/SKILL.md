---
name: pondside-graphic-notation
description: Change graphic notation in a Pondside/LilyPond score -- always from a marked range, from the start edge to the end edge, without changing anything outside it -- or add a new graphic to a marked range. Use whenever someone using Pondside asks for a graphic, texture, drawing or gesture, or clicks one and says how to change it ("taller", "denser", "different"), or marks a passage and asks for a new layer. Never rewrite the whole stencil, never touch a shared constant, seed or table.
---

# Graphic notation in Pondside

The user marks a passage with ⌥-drag: from an x on the starting system to an
x on the system nearest the release, the whole staff tall. That marked box is
the **only** range. Change exactly what is inside it and leave everything else
looking the same. A new graphic also goes into the marked range.

The request is quick: the context already carries the drawing's code. Answer
with the edit, fast: the app re-engraves on every save and the user sees the
result.

**Not every marked range is a drawing.** If the range has no drawing and the
request is notation or layout -- barlines, beams, clefs, staff lines, spacing,
noteheads, hidden meters, dynamics -- stop and follow `skill://lilypond`.
Do not create a Lexicon entry for a one-off notation change; use score code.
If the request is a drawing, texture, shape or gesture, add a graphic in the
same range (or edit the existing drawing). A request may combine both kinds:
make the drawing and traditional-notation changes, each only in that range.

**Beyond the marked range only when the user says so.** If a request sounds
as if it reaches past the mark ("all of them", "every system", "many
graphics stop short of the system's end"), first ask with `ask_user`
whether to change only the marked range or every place it occurs (offer
both as choices), and change only the marked range until the user picks the
wider one. Then the mark is an example: it shows the cause, so fix that
cause in every drawing where it occurs. Outside the lens (an agent started
at a terminal, with no selection, or one that isn't on an instance), ask the
user to select an example in the score instead of searching renders or
reading whole files.

## The fast path (1 call per file)

A request from the lens comes with `score_context` already in it. Its code
(`definition`, `drawing`, `uses`, `music`) is numbered as in the file
(`412| `, not part of the line).

1. One atomic MCP `edit` per file, using `from_line`/`to_line` for every hunk
   (optionally with `old` copied exactly as a guard): no reading the file
   first and no native Edit/Write. **Every range in a call refers to the same
   pre-edit snapshot; inserted lines do not renumber later hunks.** Never
   split dependent hunks into separate calls. The answer includes the
   engraving, `new_diagnostics` and vector `verification`, so there is no
   separate check. A new graphic: `graphic_insert` returns the same check.
2. Without a lens request, call `score_context` (no arguments) first.
3. Reply in one line: what changed, with the numbers ("Taller: half-height
   1.06 → 2.1."). No plan, no recap, no offers, no preview.

**Make it visible at a glance, and proportionate.** The user judges the result
at normal zoom. Scale an unqualified "taller"/"denser" by about 2× and make
"different" a different shape. "A little", "slightly" and "subtle" require a
restrained but still visible change, not 2×. Numbers the user gives win.

## Read the marked section

The context's `selection` has `kind: "graphic-section"`. It gives:

- `page`: the starting page (1-based).
- `y`: the staff's height in staff spaces above its middle line (usually
  `[-2, 2]`; the box always covers the whole staff).
- `from` and `to`: the two edges. Each has:
  - `x`: the edge as a fraction (0…1) of the broken piece's width on that
    system, exactly as the drawing's `x` runs from `(car (g-span grob))`;
  - `page_x`: the same edge in page coordinates;
  - `spanner_x`: `[left, right]` of that broken piece in page coordinates;
  - `at`: the moment at the edge: `{ bar, moment, event?, source }`, where
    `source` is `{ file, line, character }`. The moment is interpolated from
    the engraved notes' x positions, just before the agent runs.
- `systems`: every covered system, top to bottom, as
  `{ page, ordinal, x: [lo, hi], staff_x: [lo, hi], page_x: [lo, hi],
  spanner_x, moments: [first, last] }`. `ordinal` is the 1-based system
  number for the staff; `staff_x` is the same range as fractions of the staff
  line, for a `StaffSymbol.stencil` window. `moments` are the canonical first
  and last timed moments on that system. On the first system the range runs
  from `from.x` to the end of the piece, on the middle systems the whole
  piece, and on the last from the start of the piece to `to.x`.
- `units`: the coordinate meanings again.

**Canonical system moments identify systems; interpolated edge moments do
not.** For a drawing window use `systems.first.moments[0]` as `m0` and
`systems.last.moments[0]` as `m1`; on one system `m0 == m1`. The edge itself
is always `from.x` / `to.x` (or page x). Use `from.at`/`to.at` only for music
placement such as a new graphic. Never substitute a cue, bar or named range.

If the context has no `graphic`, the marked stretch has no drawing yet. If the
request is a drawing, add one (see "A new graphic" below), not a window; if it
is notation or layout, use `skill://lilypond` and score code instead.

## score_context for graphics

| field | use |
|---|---|
| `graphic.entry`, `params`, `start`, `stop` | a Lexicon graphic: edit its alist in place (`\startGraphic "id" #'(...)`) |
| `graphic.command`, `start`, `stop`, `definition`, `drawing[].text`, `uses`, `notes` | a graphic drawn by the score's own Scheme (`\startGrains`): `drawing` is the stencil procedure (file and lines), `uses` the helpers and constants it calls, in full (numbered) when short, else their definition line, `notes` the file's description |
| `graphic.section_support` | which of `g-span`, `smoothstep`, `system-moments`, `section-window` already exist, and the insertion anchor for missing ones; `staff_span`: whether the score has `staff-span` (see "Reach the system's ends"); never search for them |
| `event`, `staff`, `music` | where a new graphic goes: the clicked staff's voice |
| `bar`, `moment` | where "here" is (moment = whole notes from the staff's start) |
| `systems` | the marked systems, canonical system moments and selected x ranges |

The code is numbered as in its file. Edit it by `from_line`/`to_line`, with
`old` as an optional guard; don't read the file first. `definition` and
`drawing` carry full numbered text when under 150 lines; `uses` helpers when
under 60 lines and within the budget, other dependencies by exact range. For
a long procedure, read only its missing range, never the whole project.

## Find every drawing in the range

The context's `graphic` is the drawing at the start edge; a visual section can
contain several:

- the score's own stencils: every `\start...` in the graphics voices whose
  span overlaps the section (for example `electronicsGraphics`,
  `electronicsLowGraphics`, `electronicsBursts`, `electronicsArc`);
- Lexicon graphics (`\startGraphic "id" #'params`): their `start`/`stop` from
  `score_context`;
- dynamics and other helpers called *inside* a stencil (`swell-dynamics`,
  hairpins): they belong to that stencil's drawing.

Edit every drawing that overlaps the section, with the **same window**. A
change that appears in the dots but not in the shape underneath reads as a
mistake.

## A drawing by the score's own Scheme: a window in the code

`graphic.section_support.missing` says exactly which helpers to add and its
`file`/`insert_after_line` gives the anchor; do not search the project. Paste
these two helpers only when missing (they need `g-span` and `smoothstep`),
and include their insertion and the stencil changes in the same atomic edit:

```scheme
% The system's first and last moments (whole notes), from its columns.
#(define (system-moments grob)
   (let* ((sys (ly:grob-system grob))
          (cols (and (ly:grob? sys) (ly:grob-object sys 'columns)))
          (ms (and (ly:grob-array? cols)
                   (filter-map (lambda (c)
                                 (let ((w (ly:grob-property c 'when #f)))
                                   (and w (ly:moment-main w))))
                               (ly:grob-array->list cols)))))
     (and (pair? ms) (cons (apply min ms) (apply max ms)))))

% 1 inside the marked section, 0 outside, ramping over `ramp` staff spaces.
% m0/m1 are the endpoint moments; f0/f1 the endpoint fractions of the
% piece's width.
#(define* (section-window grob m0 m1 f0 f1 #:optional (ramp 2.0))
   (let* ((sp (g-span grob)) (x0 (car sp)) (x1 (cdr sp))
          (sy (system-moments grob)))
     (if (not (pair? sy))
         (lambda (x) 0)
         (let* ((starts (<= (car sy) m0 (cdr sy)))
                (ends (<= (car sy) m1 (cdr sy)))
                (outside (or (< (cdr sy) m0) (> (car sy) m1)))
                (xa (+ x0 (* f0 (- x1 x0))))
                (xb (+ x0 (* f1 (- x1 x0)))))
           (lambda (x)
             (if outside 0
                 (min (if starts (smoothstep (- xa ramp) xa x) 1)
                      (if ends (- 1 (smoothstep xb (+ xb ramp) x)) 1))))))))
```

In the stencil's `let*`:

```scheme
(rse (seed->random-state 4242))            ; the section's own draws
(win (section-window grob 121/4 145/4 0.3 0.6 2.0))
```

Take `m0` from `selection.systems.first.moments[0]`, `m1` from
`selection.systems.last.moments[0]`, and `f0`/`f1` from `from.x`/`to.x`.
When both endpoints are on one system, `m0 == m1` and the fractions keep only
the marked part. These are canonical system moments, not interpolated edge
moments. Do not use `section-window` for barlines or other layout overrides;
those are a `skill://lilypond` task, and a barline uses `grob-when`.

The ramp depends on what changes:

- a texture of dots or strokes (density, size): 2-3 staff spaces;
- a solid shape (a swell, band, wedge height): 6-10 staff spaces, or about 8%
  of the piece's width, whichever is larger. A large height change over 2
  spaces is a bevel; the user asked for an ease.

### Denser: a supplementary pass, so outside stays identical

The base grains come from `rs`; adding draws to that stream re-randomises
everything after the section. Give the section its own random state, generate
the extra marks from it, and merge them into the same list before sorting:

```scheme
(append
 (map (lambda (_) (list (+ x (g-rand rs 0 dx)) ...)) (iota k))
 (let ((w (win x)))
   (if (< (random 1.0 rse) (* 0.5 w))
       (map (lambda (_) (list (+ x (g-rand rse 0 dx)) ...)) (iota 2))
       '()))
 out)
```

Outside the window `w` is 0 and the supplementary pass adds nothing. Tune
the visible amount (about 2× per "denser", 3× for "much denser").

### Sparser: filter after generating

Thin after the base list exists, with a separate random state, so the base
stream never shifts:

```scheme
(filter (lambda (d) (or (<= (win (car d)) 0)
                        (>= (random 1.0 rs2) (* 0.7 (win (car d))))))
        dots)
```

### Parameters that don't change the number of draws: scale in place

Height, centre, size, grey, tilt, line thickness: multiply the value where it
is used, inside the loop, by the window:

```scheme
(hw (* base-hw (+ 1 (* 1.5 (win x)))))     ; taller only in the section
```

Because the number of random draws is unchanged, the rest of the system keeps
its exact grains.

### Where the windows go in the usual stencils

- dot/grains stencils (`texture-stencil`, `swells-stencil`): the per-x
  `d`/`k` (density), `hw` (height), the ram branch, and the extras
  (`wind-strokes`, `grain-fragments`, `freeze-stencil`). For the pixelation
  path, gate the pixel amount/step too.
- solid shapes (`lowswell-stencil`, `swell-stencil`, `bursts-stencil`):
  scale the amplitude/height per x; a local bump needs the ramps.
- envelope-driven drawings (`ripples-stencil`, `wedges-stencil`): apply the
  window to the envelope value at x, not to the envelope parameters.

## Reach the system's ends

A graphic that goes on past a line break, or stands in for a staff, ends
where the system's staff lines end, like the instruments' staves; a
drawing that stops at the last note, short of the margin, reads as a
mistake. Leave a drawing short of the end only when the music says so (the
graphic stops mid-system).

- **Lexicon graphics do this already.** Stop the graphic on the first note
  (skip) of the next system to run it to the end of a system; the kit ends
  it with that system and leaves nothing on the next. An electronics staff
  drawn by a graphic is `(staff-lines (y …) thick)`, which reaches both
  staff ends of every system it continues on.
- **The score's own Scheme** draws between `g-span` bounds, which end at the
  last column, not at the staff's end. If `section_support.staff_span` is
  false, add this helper (after `g-span`, in the same atomic edit):

```scheme
% The system's staff lines as (left . right), x relative to grob like g-span:
% from the first staff's start to the last staff's end.
#(define (staff-span grob)
   (let* ((sys (ly:grob-system grob))
          (me (ly:grob-relative-coordinate grob sys X))
          (exts (filter-map
                 (lambda (g)
                   (and (grob::has-interface g 'staff-symbol-interface)
                        (let ((e (ly:grob-extent g sys X))) (and (interval-sane? e) e))))
                 (ly:grob-array->list (ly:grob-object sys 'all-elements)))))
     (if (null? exts) (g-span grob)
         (cons (- (apply min (map car exts)) me) (- (apply max (map cdr exts)) me)))))

% Does this piece go on past its system (a line break ends it)?
#(define (broken-right? grob)
   (let* ((o (ly:grob-original grob)) (pieces (if o (ly:spanner-broken-into o) '())))
     (and (pair? pieces) (not (eq? grob (last pieces))))))
```

  Then, in each stencil whose drawing should run on: the right end is
  `(if (broken-right? grob) (cdr (staff-span grob)) x1)` instead of the
  `(- (cdr sp) 0.6)` style inset, for every layer (lines, waves, fills and
  their echoes alike); lines that stand in for staff lines start at
  `(car (staff-span grob))` on a piece continued from the system before.
  A span stopped on the first note of a system leaves a piece narrower than
  a staff space there: draw nothing on it (the piece before already
  reaches the end).
- **Verify** with the returned vector check: on every system the drawing
  covers, its right end equals the other staves' right end.

## Lexicon graphic: window in the params, or split

For a Lexicon graphic the drawing code is in the entry, so the window lives
in its params.

**One system.** `q` (0…1 along the spanner) equals the selection's `x`
fraction. For a constant param, replace it with a `points` envelope that
returns the base value outside and the new value inside:

```scheme
density . (points (0 12) (0.30 12) (0.32 24) (0.58 24) (0.60 12) (1 12))
```

Use the same shape for height, size, etc. If the param is already an envelope
and the change is additive, use `(sum old (points ...))`; if it is
multiplicative or cannot be composed, split instead.

**Across systems.** Split the spanner at the two boundary moments
(`\stopGraphic\startGraphic "id" #'params` in the skip at each moment), keep
the same entry and seed, and change only the middle segment's params. Ramp
the middle's params back to the base at its ends with `points` so the seam is
not a step; if the entry animates a shape, place the split at a visual
boundary (a peak or a rest) and accept that the animation restarts.

Don't edit a shared or user Lexicon entry to add a section gate; only a
project entry's impl may be extended, and only if the user asked.

## A new graphic

The user marks a passage and asks for a new layer. The box is its span:

1. Use `from.at.source` as `start_line`/`start_character` and
   `stop_moment` = `to.at.moment` for the end edge: it is the marked box's
   end, works across systems, and the tool splits a skip there. Never use a
   cue or bar name.
2. `graphic_insert` with the entry and params. It writes into a voice of
   skips in the clicked staff. A voice holds one graphic at a time: if it is
   occupied over the range, use another skip voice or add
   `\new Voice { s1*… }` beside it.
3. Read the returned `new_diagnostics` and `verification`; do not call
   `check` again (`graphic_insert` and `edit` already return it).

Choose an entry from the table; `lexicon_search` when it has nothing close.

| id | what | key params |
|---|---|---|
| `grain-cloud` | seeded dots in a band | `density` (env), `height` (env), `centre` (env), `size`, `avoid`, `seed` |
| `scribble` | short random strokes in a band | `density` (env), `height` (env), `length`, `spread`, `thickness`, `seed` |
| `staff-ripple` | staff lines turning into loops | `amplitude` (env), `curl`, `wavelength`, `lines`, `thickness`, `seed` |
| `wedge` | filled wedge, may dissolve into grains | `from`, `to`, `centre`, `gray`, `dissolve`, `seed` |
| `swell-shape` | solid shape following an envelope | `height` (env), `centre` (env), `side`, `gray` |
| `arc` | smooth contour through points, with echoes | `points`, `thickness`, `echoes`, `echo-offset` |
| `squiggle`, `pitch-band`, `aleatoric-box` | see `lexicon_entry` | |

Project and user entries may add more: `lexicon_search` when the table has
nothing close. **Nothing draws it** ("birds"): write a draft entry at once
(pondside-lexicon-entries skill; start from the nearest entry's `impl` via
`lexicon://impl/{id}`, e.g. `grain-cloud` for scattered figures, give it
`density` and `height` envelopes and a `seed`), `lexicon_propose`, then
`graphic_insert` it. One draft, no alternatives unless asked.

## Terse words → params

| user says | do |
|---|---|
| taller / shorter, wider band | `height` (×2 / ×0.5); in custom code the half-height numbers |
| denser / sparser | `density` (×2 / ×0.5) |
| gradually denser / thinning out | `density . (linear lo hi)` / `(linear hi lo)` |
| swelling, breathing | `height . (swell 3 lo hi)` |
| louder-looking, darker / lighter | `gray` lower / higher; dot `size` up |
| higher / lower | `centre` ± 1 |
| different, again | change the shape, or use a new section-local random stream (never the base seed) |
| keep out of the notes | `avoid . (note-head-interface accidental-interface)` |
| "X here" (new) | a new graphic in the marked range |

Scale by about 2× per word ("much taller": 3×). Numbers the user gives win.
The marked box, not a word like "longer", decides the span.

## Envelopes

Any `(env)` param takes a number or, over q = 0…1 along the span:
`(linear a b)`, `(swell n lo hi)`, `(pulse n lo hi)`, `(lfo cycles depth centre)`,
`(points (0 0.5) (0.3 3) (1 0.5))`, `(sum e1 e2)`, `(product e1 e2)`, `(smooth e)`.

## Conventions

- The marked `from`/`to` box is the only range: never widen it to a bar, a
  cue, a moment range or the whole stencil. If a change must taper, stay
  inside or ramp within the box.
- Graphics live in voices of skips, never on sounding notes.
- Units: staff spaces; y = 0 is the middle line, the lines are at −2…2.
- Keep seeds explicit so a drawing the user likes never changes.
- Layer (two voices on one span) or chain (`\stopGraphic\startGraphic` on one
  skip) existing entries before inventing one.
- Don't change a shared constant or table to make a local difference.

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

## Verify

1. Compile with `check` (or let the one `edit` call return the app's
   engraving): only the score's pre-existing warnings may appear.
2. Look at the section at 250-400 dpi, both edges: the change must be present
   throughout and must ramp, not jump. For a solid shape, crop each edge and
   check that the outline tapers; if it steps, lengthen the ramp.
3. Verify the outside. With the supplementary pass, crops outside the section
   are pixel-identical to before. With in-place density compare ink density
   strip by strip; the character must be unchanged.
4. Verify the same x on a *different* system did not change.
5. If the section spans systems, check the last part of the start system, all
   systems between, and the first part of the end system.

## Never

- Change a shared constant or table (`grain-density`, `band-gathered`,
  `place-swells`, `swells-events`, `late-swells`, `swell-peak`, ...).
- Change the seed to make a local difference.
- Edit `texture-band`/`band-state`/the stencil unconditionally.
- Gate on a cue, a bar range, or the whole spanner when the user gave a
  visual box.
- Move everything with `extra-offset` or a whole-stencil colour/scale.
- Put a second graphic on the same voice: a voice holds one text spanner at a
  time. Window the existing one, or add a new voice of skips.

## Reply

One line: the section, the numbers, and that the rest is untouched, e.g.
"Bars 12-16 (30% of system 2 to 60% of system 3): grains 2×, 2-space ramps;
the other systems and the rest of 15-16 unchanged."
