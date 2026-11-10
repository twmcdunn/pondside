---
name: lilypond-electronics-staff
description: Notate an electronics part in a LilyPond 2.26 score next to acoustic instruments, from a ready-made library (assets/electronics.ily) -- numbered cue boxes with a hairline at the exact moment (\ecue), effect names on one line under the staff (\edesc), pitch collections / chords / scales the electronics use (Pondside's built-in \collection: unmetered noteheads in parentheses from one moment, taking no time), and a bass staff that appears only where it is needed. Use whenever someone adds or edits an electronics, tape, live-electronics or "Elec." staff in LilyPond, wants cue numbers or cue marks in the score, wants to show the harmonies/pitch sets of the electronics, or complains that the electronics staff spreads out or crowds the instrument's notes. For getting cue times and collections into SuperCollider, add lilypond-supercollider; for general LilyPond see lilypond.
---

# Electronics staff in LilyPond

Copy `assets/electronics.ily` into the project and `\include` it. The project's copy is the source from then on. `\collection` is not in it: Pondside defines it (its `pondside-collections.ily` kit, written into the generated `lexicon.ily` in the project; the root needs `\include "lexicon.ily"`, which Pondside adds when a collection is inserted).

## Staff setup

```lilypond
\new PianoStaff \with {
  \remove Keep_alive_together_engraver     % the bass staff comes and goes on its own
  instrumentName = "Electronics" shortInstrumentName = "Elec."
} <<
  \new Staff = "elecUp" \with { \omit Stem \omit Flag \omit Beam } <<
    \new Voice \elec                                % the collections
    \new Voice \elecCues                             % cues and effect names (skips)
  >>
  \new Staff = "elecDown" \with {
    \RemoveAllEmptyStaves
    keepAliveInterfaces = #'(multi-measure-rest-interface rest-interface note-head-interface)
  } \elecBass                                        % spacers where hidden, R4*n where shown
>>
```
A single staff (no bass) works the same: a plain `\new Staff = "elecUp"`. The context id (`elecUp`) names the staff in the patch's `~collections` (`staff: 'elecUp'`) and is what `pondside cues --format ec --staff elecUp` reads.

## Cues and effect names

In the cues voice, at their exact moments: `s4*2 s4*0\ecue "3" \edesc "swells" s4*5 |`.
- `\ecue "12"` prints a bold boxed **12** above the staff with a hairline down to it; it carries `cue-label "12"`, which Pondside times as `cue 12` (`score.cues`, the Cue Inspector, handler `\cue12`). Number cues in score order; renumber by editing the labels.
- `\edesc "ocean, shimmer"` -- italic, below the treble staff (so above the bass staff), every one at the same height (`edesc-y`, just under middle C; lower it if the collections go below middle C).

## Pitch collections

```lilypond
elec = {
  \collection { c' d' e' fis' a' } s4*5 |
  s4*2 \collection { cis' e' fis' gis' b' } s4*3 |
}
```
- A collection takes no time: it stands at the moment where it is written (between two events, or splitting a skip) and the music around it keeps its timing. Its notes have no durations; any written are ignored.
- The kit lays the notes out a fixed distance apart, whatever the spacing around them; only the start is anchored. A collection beside a staff's own note at the same moment starts after that note.
- Accidentals come from the pitch alone: sharps and flats always shown, anything else natural. The key, earlier notes and the accidental style don't apply, and a collection leaves no accidental for later notes.
- Display is score-wide in Engraving Settings › Collections (or per staff): `\override NoteHead.details.collection-heads = #'hollow` (`filled`), `collection-enclosure` `parentheses` (note-head sized, level with the first and last notes; stacked: spanning the chord) / `brackets` (the staff's height) / `none`, `collection-layout` `row` / `stacked`, `collection-gap` (staff spaces).
- In `\relative` music the notes are read one after another and the music after continues from the last.
- Each note links to its own pitch (point-and-click). Collections are not in the MIDI. The timing dump reports them (`cnote` rows), so the patch gets them as `~collections` (lilypond-supercollider).
- In the app: `k` makes one at the start of the selected music, on the score's collections staff (the staff with the most collections, else one with `\collectionStyle`, else one named for electronics; else the selection's own), then a–g fill it in the lens; `r` repeats it (and `k` at a collection starts the next one) at the first note column clear of its engraving, `i` inverts it, `⌥←`/`⌥→` move it by the input duration, `⌥⇧↑`/`⌥⇧↓` move it to the staff above/below, ⌘C/⌘V copy it.
- The hidden stem carries the whole row's width, so spacing makes room for it (graphics can find collections the same way).

## Checking

Look at the electronics staff at 250 dpi: parentheses clear of accidentals and the clef, fans not touching the next collection, cue boxes not touching anything above (aleatoric boxes, dynamics), effect names on one line and clear of the bass staff.
