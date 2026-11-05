---
name: pondside-lexicon-entries
description: Write new Pondside Lexicon entries from scratch — custom graphic drawings on the Pondside graphics kit (\defineGraphic-style entries in Scheme for LilyPond 2.24/2.26) and plain LilyPond entries — with the entry folder, params, README, preview, checks, and every LilyPond/Guile gotcha that breaks them. Use when the existing entries can't make what the user wants, when asked to create, generalize, fix or extend a Lexicon entry or the graphics kit, or when turning one score's custom Scheme graphic into a reusable entry.
---

# Writing Lexicon entries

Use this when `pondside-graphic-notation` ran out of options: no combination
of existing entries satisfies the user. Write the most general entry that
covers the request (a new kind of mark, not "the texture for bar 12"), as a
**draft** in the project's `Lexicon/drafts/<id>/`. The user accepts or
rejects it after seeing it engraved.

## The entry folder

```
<id>/
  entry.toml    id, version, gloss (≤ 80 chars), tags, kind, params, [files]
  README.md     when to use it, what each param does in words, pitfalls
  impl.ily      the implementation
  examples/preview.ly   (optional) a short score using it with default params
```

`entry.toml` for a graphic:

```toml
schema   = 1
id       = "dust-band"            # kebab-case, the folder's name
version  = "0.1.0"
gloss    = "…"                    # tier 0: one line an agent reads to choose it
tags     = ["graphic", "texture"]
kind     = "graphic"
lilypond = ">=2.24"

[entry]
command   = "s1\\startGraphic \"dust-band\" #'() s1\\stopGraphic"
attaches  = "span"
music-arg = false

[params.height]
type    = "envelope"              # float | int | bool | string | enum | markup | envelope | list
default = ["swell", 2, 0.5, 3]
doc     = "…"

[files]
impl   = "impl.ily"
readme = "README.md"
```

Params are declared **once**, here. The kit merges the defaults; the
invocation overrides them by name. `pondside lexicon check` validates types
and ranges by line before LilyPond runs.

## The graphic contract

```scheme
#(define-graphic! "dust-band"
  (lambda (g p)
    ;; p: alist of params; read with (assq-ref p 'height)
    ;; return: a list of shapes, nothing else
    ...))
```

- **Pure and deterministic.** All randomness from `(g-random g [salt])` and
  `(g-rand rs a b)`, so every compile and every piece of a broken span agree.
  Never `(random …)` without the state, never the clock.
- **Coordinates.** u along the whole span in staff spaces (0 at the start, as
  if it were one strip); y in staff spaces from the middle line. The kit cuts
  the strip at line breaks, clips every shape to its piece and shifts each
  piece; you draw the whole strip. A piece that goes on past its system ends
  at that system's staff end, and a span stopping on a system's first note
  ends with the system before, so drawings reach the system's ends by
  themselves: draw to `(g-width g)`, never stop short of it.
- **Don't build stencils or touch grobs.** Return shapes; ask the kit for
  layout facts. That keeps entries short and robust.

### The kit (`pondside-graphics.ily`)

| call | gives |
|---|---|
| `(g-width g)` | the strip's length |
| `(g-q g u)` | 0…1 along the strip, for envelopes |
| `(g-piece g)`, `(g-breaks g)` | this piece's (u0 . u1); the u of each line break |
| `(g-columns g)` | the notes' columns as (u . moment), in order |
| `(g-u-at g moment)`, `(g-moment-at g u)` | between moments (whole notes) and u |
| `(g-seconds g u)`, `(g-u-at-cue g "12")` | the score's time at u; where a cue falls |
| `(g-staff-y g i)` | line i (0 = bottom) of a five-line staff |
| `(g-staff-span g)` | this piece's system staff lines as (u-left . u-right): under the clef to the system's end |
| `(g-continued? g)`, `(g-broken? g)` | this piece goes on from the system before / past its system |
| `(g-clear-of g '(note-head-interface …))` | boxes (u0 u1 y0 y1) of those grobs on this staff |
| `(g-inside? boxes u y pad)` | is the point in one of them |
| `(env-at env q)` | an envelope's value (see the high-level skill's table) |

Shapes: `(dot u y r)`, `(stroke ((u . y) …) thick)`, `(fill ((u . y) …))`,
`(curve ((u . y) …) thick)`, `(wedge u0 u1 h0 h1 y)`, `(text u y markup)`,
`(gray g shape)` with g 0 black … 1 white, and `(staff-lines (y …) thick)`:
lines that stand in for a staff (an electronics staff drawn by the graphic),
across the span and, on a system it goes on from or past, out to that
system's staff ends, like the real staves above and below.

### Patterns

- **Texture**: step along u (0.25–0.5 sp), compute the expected count for the
  slice from envelopes, make it whole with `(floor (+ expected (random 1.0 rs)))`.
- **Lines**: sample u every 0.05 sp; a `stroke` of the points.
- **Shapes**: a top edge and a bottom edge (reversed) as one `fill`.
- **Layers**: `(append layer-a layer-b)`; use a different salt per layer.
- **Time-shaped**: `(g-seconds g u)` against cue times (`g-u-at-cue`) for
  drawings that follow the electronics' real timing.

## LilyPond and Guile gotchas

- **Guile 3**: no `string-match` (use `string-contains`, `string-split`);
  `assq-ref` takes the alist first; symbols from TOML arrive as strings
  (`"swell"`), from invocations as symbols (`swell`) — accept both.
- **Integer division**: `(/ 1 3)` is the exact 1/3, fine for moments; use
  `exact->inexact` before `iota` counts or `inexact->exact` (`floor`) for
  counts. `iota` needs an exact integer.
- **Names that are syntax**: never bind `lambda*`, `define`, `list`… as variables.
- **Music types vs names**: `'note-event` (type, lowercase) vs `'NoteEvent` (name).
  `ly:make-duration` takes the factor as two integers.
- **Callbacks run before layout is final.** The kit calls entries from the
  stencil callback, after line breaking; don't read other grobs' stencils from
  `before-line-breaking`. If you extend the kit, a stencil that depends on
  other spanners may need `after-line-breaking`.
- **Extents**: `ly:grob-extent` needs a common refpoint (`ly:grob-system`), and
  can be empty `(+inf.0 . -inf.0)` — check `interval-sane?`.
- **Broken spanners**: `ly:spanner-broken-into` on the original
  (`ly:grob-original`); the kit already does this.
- **Units**: staff spaces inside stencils; `\mm` only in `\paper`.
- **Both backends**: draw paths and fills, not raster images; avoid
  `stencil-with-color` alpha (no transparency in PDF): use `gray`.
- **Taking no room**: the kit's spanner has no skylines, so a graphic never
  pushes music around; if yours must make room, say so in the README.
- **2.24 vs 2.26**: use only procedures in both; check `defined?` before
  newer ones.

## Extending the kit

Add to `pondside-graphics.ily` (not to an entry) when a layout fact is needed
by more than one drawing: a new `g-` query, envelope or shape. Keep it data in,
data out, and add a case to the kit's test score.

## Checks before offering it

**Drafting from a terse request** ("birds over this stretch"): one draft, then
`lexicon_propose` → `graphic_insert` → `check`. `check` is the compile test
(the app's warm engraving); skip `graphic_preview`, extremes and the version
matrix. Run the full list below when the user wants to keep the entry (before
`pondside lexicon promote`).

1. `pondside lexicon check` on the score: no problems.
2. `graphic_preview` with default params and with extremes of each param.
3. Two compiles produce identical SVG (determinism).
4. It compiles on 2.24 and 2.26 (`lilypond = ">=2.24"` is a promise).
5. README: one paragraph of when to use it, each param in words, pitfalls.

Then `lexicon_propose`: it goes to `Lexicon/drafts/`, and the user accepts it
into the project or their own library — or asks for changes.

## Plain (non-graphic) entries

`kind` symbol/texture/pattern/gesture/layout/system, `music-arg = true`, and
`impl.ily` registers a music function:

```scheme
#(pondside-lexicon-register! "my-entry"
  (lambda (params music) #{ … #music … #}))
```

invoked as `\lexicon "my-entry" #'((param . value)) { music }`. An optional
`[sound]` table names a cue and the patch's parameters; the cue then appears
in cues.json at the entry's start.
