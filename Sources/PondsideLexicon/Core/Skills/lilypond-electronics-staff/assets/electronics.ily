% electronics.ily -- notation for an electronics part in LilyPond 2.26
% (from the lilypond-electronics-staff skill; copy into the project and \include it).
%
%   \ecue "12"                  boxed cue number with a hairline to the staff at its moment
%   \edesc "ripples"            effect name, below the staff, all on one line
%   \collection { c'32 d' e' }  a pitch collection: one moment in the spacing, heads fanned out,
%                               in parentheses (needs \collectionStyle in that Voice)

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

% The pitch collections. \collection { c'32 d' e' fis' a' } is one chord at the first note's
% moment, as long as the notes together, so only that moment takes part in the score's
% spacing: the instruments are spaced as if the collection were one note. The heads are then laid out
% left to right in written order, each with its accidental, at fixed distances from the first
% (collection-gap staff spaces apart), in parentheses. Pondside's timing (pondside cues --format ec)
% still sees every note and the \startGroup/\stopGroup around them. Put \collectionStyle in the
% staff's Voice (\new Voice \with { \collectionStyle } ...) and omit Stem/Flag/Beam there.
#(define collection-gap 0.8)

collection =
#(define-music-function (music) (ly:music?)
   (let* ((notes (extract-typed-music music 'note-event))
          (len (ly:music-length music))
          (r (ly:moment-main len))
          (dur (ly:make-duration 0 0 (numerator r) (denominator r)))
          (n (length notes)))
     (make-music 'EventChord
                 'elements
                 (append
                  (map (lambda (note i)
                         (make-music 'NoteEvent
                                     'pitch (ly:music-property note 'pitch)
                                     'duration dur
                                     'collection-index i
                                     'collection-size n))
                       notes (iota n))
                  (list (make-music 'NoteGroupingEvent 'span-direction START)
                        (make-music 'NoteGroupingEvent 'span-direction STOP))))))

#(define (collection-index head)
   (ly:event-property (event-cause head) 'collection-index 0))

#(define (collection-accidental head)
   (let ((acc (ly:grob-object head 'accidental-grob #f)))
     (and acc (ly:accidental-interface::print acc))))

% the head's own glyph, its accidental to the left and the parenthesis, if it is first or last
#(define (collection-head-stencil head)
   (let* ((st (ly:note-head::print head))
          (acc (collection-accidental head))
          (i (collection-index head))
          (last? (= i (1- (ly:event-property (event-cause head) 'collection-size 1))))
          (paren (lambda (s) (ly:stencil-aligned-to
                              (grob-interpret-markup head (markup #:fontsize 1 s)) Y CENTER)))
          (with-acc (if acc (ly:stencil-combine-at-edge st X LEFT acc 0.2) st))
          (with-open (if (zero? i) (ly:stencil-combine-at-edge with-acc X LEFT (paren "(") 0.15) with-acc)))
     (if last? (ly:stencil-combine-at-edge with-open X RIGHT (paren ")") 0.15) with-open)))

% each head's place: after the heads (and accidentals) before it, the first at the chord's moment
#(define (collection-head-x head)
   (let* ((col (ly:grob-parent head X))
          (heads (sort (ly:grob-array->list (ly:grob-object col 'note-heads))
                       (lambda (a b) (< (collection-index a) (collection-index b)))))
          (width (lambda (h) (interval-length (ly:stencil-extent (ly:note-head::print h) X))))
          (acc-width (lambda (h) (let ((a (collection-accidental h)))
                                   (if a (+ 0.2 (interval-length (ly:stencil-extent a X))) 0)))))
     (let loop ((hs heads) (x 0) (first #t))
       (let* ((h (car hs))
              (hx (if first x (+ x (acc-width h)))))
         (if (eq? h head)
             hx
             (loop (cdr hs) (+ hx (width h) collection-gap) #f))))))

% the whole fan, parentheses included, relative to the chord's column: given to the (hidden)
% stem, so spacing keeps the next collection clear of it, and otherwise ignores the fan
#(define (collection-fan-extent stem)
   (let* ((col (ly:grob-parent stem X))
          (heads (ly:grob-array->list (ly:grob-object col 'note-heads))))
     (reduce interval-union '(0 . 0)
             (map (lambda (h) (coord-translate (ly:stencil-extent (collection-head-stencil h) X)
                                               (collection-head-x h)))
                  heads))))

collectionStyle = {
  \override Stem.X-offset = 0
  \override Stem.X-extent = #collection-fan-extent
  \override NoteHead.duration-log = 2                 % filled heads, whatever the chord's length
  \override NoteHead.stencil = #collection-head-stencil
  \override NoteHead.X-offset = #collection-head-x
  % spacing and ledger lines see only the head itself, not its accidental or parenthesis
  \override NoteHead.X-extent = #(lambda (head) (ly:stencil-extent (ly:note-head::print head) X))
  \override Accidental.stencil = ##f
  \override Accidental.X-extent = #'(0 . 0)
}

