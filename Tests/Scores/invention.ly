\version "2.24.0"
\include "lexicon.ily"
% A two-part invention in the style of the 18th century.
% Exercises \relative chaining across voices, chords, ties and grace notes.

\header {
  title = "Invention"
  composer = "Anonymous"
  tagline = ##f
}

global = {
  \key d \minor
  \time 4/4
}

upper = \relative c'' {
  \global
  \clef treble
  r16 d e f g e f d  cis8 a' d, bes' |   % subject
  bes16 a g f e g f e  d4~ d16 e f g |
  a8.( bes16) a8 g  <f a>4 <e g>8 r |
  \tuplet 3/2 { f8 g a } \tuplet 3/2 { bes c d }  cis4\trill d |
  \grace { e16 } d8-. c-. bes-. a-.  g4.\fermata f8 |
  << { a2 g } \\ { f4 e d cis } >> |
  d1 \bar "|."
}

lower = \relative c {
  \global
  \clef bass
  d4 r r16 a' b cis  d e f d |
  e,8 cis' d,4 r16 d e f g e f d |
  c!4 bes8 a d bes a4 |
  bes8( a--( g f  e4->)
 a,8 d e\startGraphic "scribble" #'() d bes cis  d2\stopGraphic |
  a1~ |
  a2 d, \bar "|."
}

\paper {
}

\score {
  \new PianoStaff <<
    \new Staff = "up" \upper
    \new Staff = "down" <<
      \lower
      \new Voice {
        s1*4
        \stopStaff \override Staff.StaffSymbol.transparent = ##t \startStaff
        s1\startGraphic "staff-ripple" #'((amplitude . (swell 1 0 0.5)) (curl . 0) (wavelength . 2) (seed . 1))
        \stopStaff \revert Staff.StaffSymbol.transparent \startStaff
        s1\stopGraphic
      }
    >>
  >>
  \layout {
    \context {
      \Score
      \override SpacingSpanner.spacing-increment = #1.2
    }
   }
}
