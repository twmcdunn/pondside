---
name: lilypond
description: Engrave scores with GNU LilyPond 2.26 and get them looking right -- installing it on macOS, laying out a project (score.ly + parts + a defs.ily of house commands), compiling and checking the PDF visually, horizontal and vertical spacing (tight staves, even systems, fixed breaks, margins), dynamics and hairpins in their own voice, hidden meters, Scheme callbacks and custom stencils, and the Guile/LilyPond gotchas that silently break them. Use this skill whenever someone writes or edits .ly/.ily files, asks for anything to be engraved, notated or "put in the score" in LilyPond, pastes a LilyPond error ("Guile signaled an error", "bar check failed", "unbound variable"), asks how to move/space/hide/restyle something in a LilyPond score, or starts a new piece in LilyPond -- even if they just say "the score" in a project that has .ly files. See also lilypond-contemporary-notation (aleatoric/extended), lilypond-electronics-staff (cues, collections), lilypond-supercollider (patch integration).
---

# LilyPond

LilyPond turns text into engraved music. The .ly files are source code: edit them, compile, look at the result, repeat. Treat the score files like scripts (version them); never version the PDF/MIDI they produce.

**Docs:** https://lilypond.org/doc/v2.26/Documentation -- Notation Reference (NR), Learning Manual, Internals Reference (IR: every grob, its properties and interfaces), Extending (Scheme). Rely on them rather than memory for syntax and property names; when unsure of a property, look up the grob in the IR (`.../Documentation/internals/<grob-name-lowercase>`).

## Install and run (macOS)

```bash
brew install lilypond                 # 2.26.x
lilypond --loglevel=WARN score.ly     # -> score.pdf (+ score.midi if the file has \midi)
```
If it crashes at startup with a freetype error, rebuild freetype: `brew reinstall --build-from-source freetype`.
`--loglevel=WARN` prints only problems; a clean compile prints nothing. Treat every warning as a bug to fix (bar check failed, unterminated spanner, overfull page, ...).

## Project layout

```
score/
  defs.ily        house commands and Scheme helpers (included first)
  flute.ly        one variable per voice/layer of each instrument: flute = {...}, fluteDynamics = {...}
  electronics.ly
  score.ly        \include the above; \header, \paper, the \score with \layout (and a \midi score)
```
- **Absolute pitches** (`c'4 d''8`), not `\relative` -- every note is self-contained, so editing or generating one never shifts the next.
- **One variable per layer**, each a full-length voice of skips (`s4*7`) where it has nothing: notes, dynamics, boxes/brackets, playback-only tempos, line breaks (`structure`). End each bar with `| % 12` (a bar check plus the bar number), so a wrong duration is caught at the bar where it happens.
- `\barNumberCheck #30` every ten bars or so.
- Line and page breaks in their own voice: `structure = { \autoLineBreaksOff \autoPageBreaksOff s4*7 s4*6 \break | ... }`, put in the staff as `\new Devnull \structure`.

## The working loop

1. Edit the .ly. 2. Compile with `--loglevel=WARN`; fix every warning. 3. **Look at the result** -- render the pages you touched and read the images (`scripts/render_pages.sh score.pdf 1 3` writes PNGs; zoom with `-x -y -W -H` crops at 250-400 dpi for collisions). Never report a layout change as done without having looked. 4. If the user has the PDF open (VS Code, Preview) it refreshes on its own; don't `open` it again.

**In Pondside** the loop is shorter: write the file; the app re-engraves it at once and the user sees it. Call the MCP `check` tool for diagnostics (with the app running it answers from the app's engraving in about a second; don't run `lilypond` yourself). Render and look (`render` with `format: "png"`) only for a layout change the user can't judge at a glance, never for a parameter tweak.

For a request from Pondside's lens over a marked range with no drawing (barlines,
beams, clefs, spacing, noteheads, a Staff/Score override), edit the score's
layout or helpers directly; do not create a Lexicon entry for a one-off change.
The marked range is still the only range. Use `score_context`'s `from.at` and
`to.at` as the edge times, and its `code` layout/definition index before reading
a whole file.

When a change does not show up: the PDF may not have been rewritten (compile error), or a callback ran too early and its result was cached (see references/scheme.md, "timing").

## Things that come up in every score

- **Dynamics in their own variable, but in the notes' Voice:** `\context Voice = "flute" \fluteDynamics` (not `\new Voice`). Written as `<>\p s4*2 <>\< s4*3 <>\!`, they start/end at exact moments (also mid-note), yet a dynamic that falls on a note is placed under that note. In a separate Voice they align to the beat's column and drift off the noteheads.
- **Hairpin starting under a dynamic:** start it on the dynamic (`<>\mf\<`), so it follows on the same line; a hairpin starting a little later stacks below.
- **Hidden meters:** keep real `\time` changes (bar checks and MIDI need them) and `\omit Score.TimeSignature` in `\layout`. Tick barlines: `measureBarType = #"'"` in `\Score`.
- **Hidden rests:** `s4` instead of `r4`. A rest you remove changes the time (and every cue time after it, if the score drives anything).
- **Tuplets:** `\override TupletBracket.bracket-visibility = ##f` gives numbers only; beam each tuplet on its own (`[ ... ]` inside each `\tuplet`), or the number gets a bracket.
- **Feathered beams:** `\once \override Beam.grow-direction = #RIGHT` (accel.) / `#LEFT`.
- **Playback-only tempo:** `\once \omit Score.MetronomeMark \tempo 4 = 60` -- shapes MIDI timing (fermata holds, caesuras) without printing. Never put one at the same moment as a printed `\tempo` (it would hide the printed one).
- **Text at a fixed height** (labels that should line up across a system): `-\tweak outside-staff-priority ##f -\tweak Y-offset #-5.6 _\markup ...`.
- **Moving something up/away from a collision:** the outside-staff grob's `padding` (distance to what is below it) usually works; `staff-padding` does not apply to Score-level grobs such as MetronomeMark. `extra-offset` moves after layout -- nothing makes room for it.

## Staves, cover page and notes in Pondside

Score Setup (`⌘⇧U`) writes what these need, and an agent should write the same thing:

- **Staff names** go in the staff's `\with`: `\new Staff \with { instrumentName = "Flute" shortInstrumentName = "Fl." midiInstrument = "flute" }`. The mockup plays `midiInstrument`, or guesses it from the name. A staff with no `\clef` in its music gets its clef in `\with` too (`\clef bass`). Scores are concert pitch: don't write `\transposition`.
- **Cover, notes and legend** are `\bookpart`s in `front-matter.ily`, which the root includes just before its first `\score`. Each part starts at a `%% ---- cover` / `notes` / `legend` line. The cover prints the root's `\header` (`title`, `subtitle`, `composer`, `dedication`, `instrumentation`, `duration`, `year`), so change the words there, not in the cover. Notes are `\markuplist \pondside-paragraphs #'("…" "…")`.

## Spacing

See references/spacing.md: tight staves within a system with all spare space between systems, even systems on every page, margins, fixed breaks, why horizontal spacing is score-wide, and how to keep a grob from taking room.

## Scheme

Custom stencils, callbacks and music functions are where LilyPond is most powerful and most fragile. references/scheme.md has the patterns (spanner geometry, finding other grobs, registries, deferring a stencil until layout is final, music functions that build chords/events, custom event properties) and the gotchas that cost hours: Guile 3 has no `string-match`; music *types* are lowercase (`'note-event`) while music *names* are CamelCase (`'NoteEvent`); `ly:make-duration` takes the factor as two integers; `ly:skylines-for-stencil` takes (stencil axis); a system's `all-elements` has no spanners.

- **Staff lines over a range** (curly staff, partial hiding): read
  `references/staff-lines.md`. Do not use `StaffSymbol.transparent` or
  `\stopStaff` for a partial system; they affect the whole staff segment.
- **Official manual pages**: `references/manual-index.md` lists the small set
  worth consulting. The manual is not bundled and the agent has no web
  access; use the tested references instead of guessing.

## Checklist before saying a layout change is done

- Compiles with no output at `--loglevel=WARN`.
- Rendered and looked at every page the change can affect (for a global override: all pages).
- No collisions at the zoom level where they would show (250+ dpi crops).
- If the score drives audio/cues (lilypond-supercollider), any change to durations, rests, tempos or hidden tempos moves the cues: Pondside re-times them on the next engraving (`score.cues`); say that the times moved.
