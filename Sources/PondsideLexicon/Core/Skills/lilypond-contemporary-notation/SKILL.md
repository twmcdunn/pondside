---
name: lilypond-contemporary-notation
description: Contemporary and aleatoric notation in LilyPond 2.26 from a ready-made library (assets/contemporary.ily) -- aleatoric boxes drawn around a gesture (centred on their contents, dynamics inside, the staff below clearing them), heavy links and arrows between boxes, timed improvisation brackets ("improvise ... 30″"), wind-tone / air circles, slap-tongue noteheads, caesuras, niente, fanned (feathered) beams, hidden meters, tick barlines, tuplets without brackets, and fermata/caesura holds for playback. Use whenever someone wants extended techniques, graphic or aleatoric elements, boxes, arrows, timed sections, proportional/free passages, air/breath notation, or "make it look like the contemporary score" in a LilyPond project -- also when adjusting how any of these look (box padding, link thickness, arrow room, circle fill). Builds on the lilypond skill (load that too for spacing and Scheme gotchas).
---

# Contemporary notation in LilyPond

`assets/contemporary.ily` is a tested library of these elements. In Pondside, the Lexicon has entries for some of the same things (`aleatoric-box`, `niente-hairpin`, `feathered-beam`, `timed-fermata`, `senza-misura`): use whichever the score already uses, never both for one notation in a score. Copy it into the project (next to score.ly), `\include "contemporary.ily"` before the music, and adapt it there -- the project's copy is the source from then on. Read its comments: each command documents its options. All sizes are staff spaces.

## Aleatoric boxes, links, arrows

A box is a spanner in its **own voice of skips** in the instrument's staff, so it starts and ends at exact moments regardless of what the notes do:

```lilypond
instBoxes = {
  s8 s1 \startBox \startFloor s4*15/2 \stopBox \stopFloor s1*2 \startBox \startFloor ... |
}
instLinks = {
  s4*9/2 s4*15/2 \startLink s1*2 \stopLink ... s4*13/2 \startArrow | s4*2 \stopLink |
}
% in the staff:  \new Voice \instBoxes  \new Voice \instLinks
```
- Post-events attach to the skip **before** them: `s1 \startBox` starts the box where that `s1` starts.
- The box is drawn around what it holds -- notes, rests, accidentals, flags, scripts, small text symbols, dynamics and hairpins whose moment is in [start, stop) -- with equal padding (`details.pad`, 1.0), so it is centred on the gesture however long the last note is. A dynamic exactly at the stop moment also counts (a hairpin's closing *n*); end the box after the next gesture's first dynamic if that is not wanted.
- `\startFloor`/`\stopFloor` alongside each box: an invisible outside-staff spanner placed after the dynamics; the box's bottom is drawn at the floor, so it sits just under the lowest dynamic, and the staff below clears it. The box itself takes no room (it would push dynamics outside it). Floor distance: `outside-staff-padding` 0.8 below contents, at least `staff-padding` 1.2 below the staff.
- Box top: fixed (`details.top` 5.5); raise one with `-\tweak details.top #10 \startBox` (a trill or high note). A tempo mark over a box: `\once \override Score.MetronomeMark.padding = #5`.
- Links/arrows meet the nearest box edges on their line (they find boxes through a registry). Minimum lengths push boxes apart (`minimum-length` 5, arrows 9, via spacing rods -- only when both ends are on the same line). An arrow running past a line break is drawn on the first line only.
- Ends are square (filled boxes, not round-capped lines) so nothing pokes past a box edge.

## Timed sections

`e'8 \timeField "improvise gradually growing" "30″" ... s4 \stopTextSpan` -- a line with hooks over the passage, the text at the left (`time-field-lead` sets how far in), the duration centred in a gap. Put it in an `\improvisation` (lilypond-supercollider) when the passage is rendered separately, and give the bar a `\playTempo` so it lasts the stated time in the MIDI.

## Techniques and symbols

| Command | Result |
|---|---|
| `c'4^\wind #0.75` | air circle centred over the note: white = air (1 open, 0.75 one black quarter, 0.5 left half black, 0 black) |
| `\slapOn ... \slapOff` | accent-shaped slap-tongue noteheads |
| `s4 \caes` / `s4 \caesTight` | `//` caesura before the barline (on a hidden-rest skip) / close after the note when little room |
| `fis''1 \shapedTrill "♮" #'(0.2 1 0.2)` ... `\stopTrillSpan` on the next note | trill with accidental whose wavy line goes slow-fast-slow (relative speeds along the note); `\midiTrills` (lilypond-supercollider) plays the same shape |
| `<>\niente\<` | *n* dynamic |
| `\featherOnce` / `\featherBackOnce` / `\featherOn ... \featherOff` | fanned beams (accel. / rit.) |

## Page-wide conventions (in score.ly's \layout)

```lilypond
\context { \Score
  \omit TimeSignature                         % meters hidden; keep \time for bar checks and MIDI
  measureBarType = #"'"                       % tick barlines
  \override TupletBracket.bracket-visibility = ##f   % numbers only; beam each tuplet separately
  \override Hairpin.minimum-length = #4
  \override Hairpin.springs-and-rods = #ly:spanner::set-spacing-rods }
```

## Gestures ending in a hold

A lyrical gesture ending on a long note: `e''1 ^\fermata s4 \caes` (the rest hidden). A fast gesture: `... s4 \caes`, no fermata. If the score drives audio, give each hold its length in the playback voice: `\playTempo 60 s4*4 \playTempo 30 s4` (whole note 4 s, caesura 2 s) -- and restore the tempo at the next bar unless a printed `\tempo` is there.

## Checking

Compile at `--loglevel=WARN` (no output) and look at every box system at 250 dpi: box edges vs. notes and dynamics, links touching both boxes, the arrow's length at a line end, the staff below clear of the box bottom, tempo marks clear of box tops.
