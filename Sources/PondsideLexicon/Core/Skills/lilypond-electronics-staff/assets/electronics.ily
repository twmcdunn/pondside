% electronics.ily -- notation for an electronics part in LilyPond 2.26
% (from the lilypond-electronics-staff skill; copy into the project and \include it).
%
%   \ecue "12"                  boxed cue number with a hairline to the staff at its moment
%   \edesc "ripples"            effect name, below the staff, all on one line
%
% Pitch collections are Pondside's own: \collection { c' d' fis' } comes from
% pondside-collections.ily, which the generated lexicon.ily includes. Don't define one here.

%% ------------------------------------------------------------------ electronics

% A cue for the electronics at its rhythmic position: \ecue "12" -> a boxed "12" with a
% hairline down to the staff, marking the exact moment. The event carries cue-label "12", which
% Pondside's timing reads as "cue 12" (score.cues, cues.json, handler \cue12); keep the
% label a number (or a short name without spaces).
ecue =
#(define-event-function (label) (string?)
   (let ((ev #{ -\tweak outside-staff-priority ##f
                -\tweak Y-offset #4.2
                -\tweak X-offset #-0.1
                -\tweak self-alignment-X #LEFT
                ^\markup \combine
                  \translate #'(0 . -2.2) \with-dimensions #'(0 . 0) #'(0 . 0)
                    \draw-line #'(0 . 2.2)
                  \box \pad-x #0.2 \fontsize #2 \bold #label #}))
     (ly:music-set-property! ev 'cue-label label)
     ev))

% An electronics effect, in a word or two, under the treble staff (above the bass staff when
% there is one), every one on the same line just clear of middle C. If the staff's notes go
% lower, lower edesc-y.
#(define edesc-y -5.6)
edesc = #(define-event-function (text) (markup?)
           #{ -\tweak outside-staff-priority ##f
              -\tweak Y-offset #edesc-y
              _\markup \italic #text #})

