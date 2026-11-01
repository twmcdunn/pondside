---
name: lilypond-electronics-staff
description: Notate an electronics part in a LilyPond 2.26 score next to acoustic instruments, from a ready-made library (assets/electronics.ily) -- numbered cue boxes with a hairline at the exact moment (\ecue), effect names on one line under the staff (\edesc), pitch collections / chords / scales the electronics use, written as stemless noteheads fanned out in parentheses from one rhythmic point so they don't distort the instruments' spacing (\collection), and a bass staff that appears only where it is needed. Use whenever someone adds or edits an electronics, tape, live-electronics or "Elec." staff in LilyPond, wants cue numbers or cue marks in the score, wants to show the harmonies/pitch sets of the electronics, or complains that the electronics staff spreads out or crowds the instrument's notes. For getting cue times and collections into SuperCollider, add lilypond-supercollider; for general LilyPond see lilypond.
---

# Electronics staff in LilyPond

Copy `assets/electronics.ily` into the project and `\include` it. The project's copy is the source from then on.

## Staff setup

```lilypond
\new PianoStaff \with {
  \remove Keep_alive_together_engraver     % the bass staff comes and goes on its own
  instrumentName = "Electronics" shortInstrumentName = "Elec."
} <<
  \new Staff = "elecUp" \with { \omit Stem \omit Flag \omit Beam } <<
    \new Voice \with { \collectionStyle } \elec      % the collections
    \new Voice \elecCues                             % cues and effect names (skips)
  >>
  \new Staff = "elecDown" \with {
    \RemoveAllEmptyStaves
    keepAliveInterfaces = #'(multi-measure-rest-interface rest-interface note-head-interface)
  } \elecBass                                        % spacers where hidden, R4*n where shown
>>
```
A single staff (no bass) works the same: a plain `\new Staff = "elecUp"`. The context id (`elecUp`) is what `pondside cues --format ec --staff elecUp` reads collections from.

## Cues and effect names

In the cues voice, at their exact moments: `s4*2 s4*0\ecue "3" \edesc "swells" s4*5 |`.
- `\ecue "12"` prints a bold boxed **12** above the staff with a hairline down to it; it carries `cue-label "12"`, which Pondside times as `cue 12` (`score.cues`, the Cue Inspector, handler `\cue12`). Number cues in score order; renumber by editing the labels.
- `\edesc "ocean, shimmer"` -- italic, below the treble staff (so above the bass staff), every one at the same height (`edesc-y`, just under middle C; lower it if the collections go below middle C).

## Pitch collections

```lilypond
elec = {
  \collection { c'32 d' e' fis' a' } s4*35/8 |
  \collection { cis'8 e' fis' gis' b' } s4*9/2 |
}
```
- One chord at the first note's moment, lasting as long as the notes together: the score spaces the instruments as if the collection were a single note. The heads are then fanned out left to right in written order (`collection-gap` 0.8 between heads, accidentals in front of their heads), filled, with parentheses around the group. Rhythm inside the braces only sets the total length.
- When two collections are close enough to collide, the hidden stem carries the fan's width, so spacing widens just that spot.
- Every note is still an event, inside `\startGroup`/`\stopGroup`, so Pondside's timing reads the collection's pitches.

## Checking

Look at the electronics staff at 250 dpi: parentheses clear of accidentals and the clef, fans not touching the next collection, cue boxes not touching anything above (aleatoric boxes, dynamics), effect names on one line and clear of the bass staff.
