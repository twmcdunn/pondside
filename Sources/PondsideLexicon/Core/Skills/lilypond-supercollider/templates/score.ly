\version "2.26.0"
% Score for an acoustic instrument and electronics, set up for the LilyPond -> SuperCollider
% workflow. Copy contemporary.ily, electronics.ily and playback.ily next to it. Pondside times
% the cues itself: no timing engraver is needed.

\include "contemporary.ily"
\include "electronics.ily"
\include "playback.ily"

% ---------------------------------------------------------------- music (usually in its own files)
% Every variable runs the whole piece; skips where it has nothing; a bar check at every bar.
% Post-events attach to the note/skip before them: "s1 \startBox" starts the box at that skip.
inst = {
  \clef treble
  \improvisation 1 { e'2 \timeField "impr." "20″" g'2 \stopTextSpan } | % 1
  \tempo 4 = 72 c''4 d''4 e''4 s4 \caes | % 2
  g'1 \fermata <>\timingMark "end" | % 3
}
% (a dynamic exactly at a box's last moment counts as inside it: end the box after it)
instDynamics = { <>\p\< s2 <>\! s2 | s4 <>\mf s2. | <>\p s1 | }
instBoxes = { s1 \startBox \startFloor | s1 \stopBox \stopFloor | s1 | }
% hidden tempos: bar 1 (4 beats) lasts 20 s, the caesura 2 s, the fermata 4 s at 60. Never at
% the same moment as a printed \tempo (bar 2).
instPlayback = { \playTempo 12 s1 | s2. \playTempo 30 s4 | \playTempo 60 s1 | }

elec = {
  \clef treble
  \collection { c'16 d' e' g' a' } s16*11 | % 1
  s1 | % 2
  s2 \collection { cis'16 e' fis' gis' b' } s16*3 | % 3
}
elecCues = { s4*0\ecue "1" \edesc "ripples" s1 | s2 s4*0\ecue "2" s2 | s2 s4*0\ecue "3" s2 | }

structure = { \autoLineBreaksOff s1 | s1 | s1 | }

% ---------------------------------------------------------------- printed score
\header { title = "Untitled" composer = "" tagline = ##f }
\paper {
  #(set-paper-size "a4landscape")
  top-margin = 10\mm bottom-margin = 18\mm left-margin = 30\mm right-margin = 28\mm
  system-system-spacing = #'((basic-distance . 12) (minimum-distance . 8) (padding . 2)
                             (stretchability . 100))
  ragged-bottom = ##f ragged-last-bottom = ##f
}

\score {
  <<
    \new Staff = "inst" \with { instrumentName = "Flute" shortInstrumentName = "Fl." } <<
      \new Voice = "inst" \removeWithTag #'played \inst
      \context Voice = "inst" \instDynamics      % same Voice: dynamics sit under their notes
      \new Voice \instBoxes
      \new Voice \instPlayback
      \new Devnull \structure
    >>
    \new Staff = "elecUp" \with {
      instrumentName = "Electronics" shortInstrumentName = "Elec."
      \omit Stem \omit Flag \omit Beam
    } <<
      \new Voice \with { \collectionStyle } \elec
      \new Voice \elecCues
    >>
  >>
  \layout {
    \context { \Score
      \omit TimeSignature
      measureBarType = #"'"
      \override TupletBracket.bracket-visibility = ##f
      \override Hairpin.minimum-length = #4
      \override Hairpin.springs-and-rods = #ly:spanner::set-spacing-rods }
    \context { \Staff
      \override VerticalAxisGroup.staff-staff-spacing =
        #'((basic-distance . 0) (minimum-distance . 0) (padding . 1.0) (stretchability . 0)) }
  }
}

% ---------------------------------------------------------------- MIDI for the audio render
% Only what the render should play (the electronics are the patch's job); same tempos.
\score {
  \new Staff \with { midiInstrument = "flute" } <<
    \new Voice \midiTrills \removeWithTag #'printed \inst
    \new Voice \instDynamics
    \new Voice \instPlayback
  >>
  \midi { }
}

