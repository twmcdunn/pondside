% contemporary.ily -- contemporary / aleatoric notation for LilyPond 2.26
% (from the lilypond-contemporary-notation skill; copy into the project and \include it after
% \version, before the music). Everything is in staff spaces.
%
%   \startBox \startFloor ... \stopBox \stopFloor   aleatoric box around a gesture (boxes voice)
%   \startLink ... \stopLink                        heavy line from one box to the next
%   \startArrow ... \stopLink                       the same, ending in an arrowhead
%   \timeField "improvise ..." "30″" ... \stopTextSpan   timed bracket over the staff
%   ^\wind #0.75                                    wind-tone circle (white = air)
%   \slapOn ... \slapOff                            slap-tongue noteheads
%   \caes  \caesTight                              caesura (//) before the barline / close to a note
%   \shapedTrill "♮" #'(0.2 1 0.2) ... \stopTrillSpan   trill whose wavy line speeds up and slows
%   \niente                                         "n" dynamic: <>\niente\<
%   \featherOnce \featherBackOnce \featherOn \featherOff   fanned beams

%% ------------------------------------------------------------------ geometry helpers

% X extent of a spanner's bound (LEFT or RIGHT), relative to the spanner itself
#(define (bound-x-extent grob dir)
   (let* ((b (ly:spanner-bound grob dir))
          (common (ly:grob-common-refpoint grob b X)))
     (coord-translate (ly:grob-extent b common X)
                      (- (ly:grob-relative-coordinate grob common X)))))

% Y extent of a spanner's bound, relative to the spanner
#(define (bound-y-extent grob dir)
   (let* ((b (ly:spanner-bound grob dir))
          (common (ly:grob-common-refpoint grob b Y)))
     (coord-translate (ly:grob-extent b common Y)
                      (- (ly:grob-relative-coordinate grob common Y)))))

#(define (detail grob key default)
   (assoc-get key (ly:grob-property grob 'details '()) default))

% a grob that draws but takes no room: it neither pushes other things nor reserves space
#(define no-skylines
   (ly:make-unpure-pure-container
    (lambda (grob) (ly:skylines-for-stencil empty-stencil X))))

%% ------------------------------------------------------------------ aleatoric boxes

% Boxes, the heavy links between them and the arrow out of the last one are spanners in a voice
% of their own made of skips (e.g. fluteBoxes, in the instrument's staff), so each starts and
% ends at an exact moment: a box from its gesture's first moment to the moment after it, a link
% from there to the next box. The box is then drawn around what it holds (centred, equal
% padding), the links meet the boxes' edges, and an invisible floor makes the staff below
% clear the box while the dynamics stay inside it.
%   s4*2 \startBox s4*4 \stopBox \startLink s4*2 \stopLink \startBox ...
% Tweaks (staff spaces): \tweak details.top #9 \startBox (also bottom, pad); the bottom is
% otherwise just below the box's contents (its floor).

% X of a line spanner's bound (LEFT/RIGHT), relative to the spanner
#(define (span-x grob dir)
   (let* ((info (ly:grob-property grob (if (= dir LEFT) 'left-bound-info 'right-bound-info)))
          (sys (ly:grob-system grob)))
     (- (assoc-get 'X info) (ly:grob-relative-coordinate grob sys X))))

% What a box holds: the notes, rests, accidentals, flags, dots, scripts (trills,
% fermatas, wind circles) and dynamics between its moments, on its staff
#(define box-content-interfaces
   '(note-head-interface rest-interface accidental-interface flag-interface dots-interface
     script-interface text-script-interface dynamic-interface hairpin-interface
     trill-spanner-interface))

% the moment a grob belongs to (a spanner: its start)
#(define (grob-when g)
   (let ((col (if (ly:spanner? g)
                  (ly:item-get-column (ly:spanner-bound g LEFT))
                  (ly:item-get-column g))))
     (and col (ly:grob-property col 'when #f))))

% a grob's X extent on its system; line spanners report none, so measure their drawing
#(define (grob-x-extent g sys)
   (if (grob::has-interface g 'line-spanner-interface)
       (let ((st (ly:grob-property g 'stencil #f)))
         (if (ly:stencil? st)
             (coord-translate (ly:stencil-extent st X) (ly:grob-relative-coordinate g sys X))
             '(+inf.0 . -inf.0)))
       (ly:grob-extent g sys X)))

% every shaped trill, as laid out (a box holds the trills in it)
#(define laid-out-trills '())
#(define (register-trill grob) (set! laid-out-trills (cons grob laid-out-trills)))

% every box, as laid out on its line (for the links to find)
#(define laid-out-boxes '())
#(define (register-box grob) (set! laid-out-boxes (cons grob laid-out-boxes)))

% The box's left and right edges, relative to it: around what it holds, padded the same on both
% sides (details.pad), so it is centred on its gesture however long the last note is. Without
% contents: from its first moment to its last.
#(define (box-edges grob)
   (let* ((sys (ly:grob-system grob))
          (x0 (ly:grob-relative-coordinate grob sys X))
          (lx (span-x grob LEFT)) (rx (span-x grob RIGHT))
          (pad (detail grob 'pad 1.0))
          (from (ly:grob-property (ly:spanner-bound grob LEFT) 'when))
          (to (ly:grob-property (ly:spanner-bound grob RIGHT) 'when))
          (inside
           (filter-map
            (lambda (g)
              (and (any (lambda (i) (grob::has-interface g i)) box-content-interfaces)
                   (not (memq g laid-out-floors))                      ; not the box's floor
                   (not (eq? (ly:grob-common-refpoint g grob Y) sys))   ; this staff
                   (let ((w (grob-when g))
                         (e (coord-translate (grob-x-extent g sys) (- x0))))
                     (and w (not (ly:moment<? w from))
                          ; up to its last moment, and a dynamic ending there (a hairpin's n)
                          (or (ly:moment<? w to)
                              (and (equal? w to) (grob::has-interface g 'dynamic-text-interface)))
                          (not (interval-empty? e))
                          ; texts: only symbols (wind circles), not words such as the
                          ; time field's label
                          (or (not (grob::has-interface g 'text-script-interface))
                              (< (interval-length e) 3))
                          e))))
            (append (ly:grob-array->list (ly:grob-object sys 'all-elements))
                    ; spanners are not among a system's elements: those registered
                    (filter (lambda (t) (eq? (ly:grob-system t) sys)) laid-out-trills)))))
     (if (null? inside)
         (cons (- lx pad) (+ rx 0.4))
         (cons (- (apply min (map car inside)) pad)
               ; no further than the box's last moment (hairpins run to it), or than
               ; a dynamic there
               (max (min (+ (apply max (map cdr inside)) pad) (+ rx 0.4))
                    (+ (apply max (cons -inf.0 (map cdr (filter (lambda (e) (> (cdr e) rx)) inside))))
                       pad))))))

% The box's bottom, relative to it: its floor's top (see \startFloor), i.e. just below what
% it holds; -7.5 if it has no floor
#(define (box-bottom grob)
   (let* ((sys (ly:grob-system grob))
          (floor (find (lambda (f) (and (eq? (ly:grob-system f) sys)
                                        (eq? (ly:spanner-bound f LEFT) (ly:spanner-bound grob LEFT))))
                       laid-out-floors)))
     (if floor
         (let ((common (ly:grob-common-refpoint floor grob Y)))
           (- (cdr (ly:grob-extent floor common Y)) (ly:grob-relative-coordinate grob common Y)))
         -7.5)))

#(define (aleatoric-box grob)
   (let* ((x (box-edges grob))
          (l (car x)) (r (cdr x))
          (top (detail grob 'top 5.5))
          (bottom (detail grob 'bottom (box-bottom grob)))
          (th (detail grob 'thickness 0.22)))
     (make-path-stencil
      (list 'moveto l bottom 'lineto r bottom 'lineto r top 'lineto l top 'closepath)
      th 1 1 #f)))

% the edge of the box a link comes from (dir LEFT: the nearest box ending at or before the
% link's start) or goes to (RIGHT: the nearest starting at or after its end), relative to the
% link; #f if there is none on this line
#(define (linked-box-edge grob dir)
   (let* ((sys (ly:grob-system grob))
          (at (ly:grob-property (ly:spanner-bound grob dir) 'when))
          (when-of (lambda (b) (ly:grob-property (ly:spanner-bound b (- dir)) 'when)))
          (boxes (filter (lambda (g) (and (eq? (ly:grob-system g) sys)
                                          (let ((w (when-of g)))
                                            (if (= dir LEFT)
                                                (not (ly:moment<? at w))
                                                (not (ly:moment<? w at))))))
                         laid-out-boxes))
          (box (and (pair? boxes)
                    (car (sort boxes (lambda (a b) (if (= dir LEFT)
                                                       (ly:moment<? (when-of b) (when-of a))
                                                       (ly:moment<? (when-of a) (when-of b)))))))))
     (and box
          (let ((e (box-edges box)))
            (+ (if (= dir LEFT) (cdr e) (car e))
               (- (ly:grob-relative-coordinate box sys X)
                  (ly:grob-relative-coordinate grob sys X)))))))

% a link or arrow broken at a line end is drawn on the first line only (an arrow out of the last
% box of a line ends there)
#(define (continuation? grob)
   (let ((orig (ly:grob-original grob)))
     (and orig
          (pair? (ly:spanner-broken-into orig))
          (not (eq? grob (car (ly:spanner-broken-into orig)))))))

#(define (box-link grob)
  (if (continuation? grob) empty-stencil (box-link-stencil grob)))

#(define (box-link-stencil grob)
   (let* ((l (or (linked-box-edge grob LEFT) (+ (span-x grob LEFT) (detail grob 'pad-left 0.4))))
          (r (or (linked-box-edge grob RIGHT) (- (span-x grob RIGHT) (detail grob 'pad-right 1.0))))
          (th (detail grob 'thickness 0.75))
          (arrow (detail grob 'arrow #f))
          (head-l 1.5) (head-w 0.7)
          (line-end (if arrow (- r head-l) r)))
     (ly:stencil-add
      (make-filled-box-stencil (cons l line-end) (cons (* -0.5 th) (* 0.5 th))) ; square ends
      (if arrow
          (make-path-stencil
           (list 'moveto line-end (- head-w) 'lineto r 0 'lineto line-end head-w 'closepath)
           0.1 1 1 #t)
          empty-stencil))))

#(define (fixed-span stencil)
   (lambda (music)
     #{ -\tweak stencil #stencil
        -\tweak Y-offset #0
        -\tweak outside-staff-priority ##f
        -\tweak vertical-skylines #no-skylines
        -\tweak bound-details.left.attach-dir #LEFT
        -\tweak bound-details.right.attach-dir #LEFT
        #music #}))

% (X-extent: so the box is drawn only once everything below the staff is placed, its floor too)
startBox = #((fixed-span aleatoric-box)
             #{ -\tweak X-extent #'(0 . 0) -\tweak after-line-breaking #register-box \startTextSpan #})
stopBox = \stopTextSpan
% links and arrows push their boxes apart to at least this length
% (X-extent: so the link is drawn only once the lines are laid out, when it can find its boxes)
startLink = #((fixed-span box-link)
              #{ -\tweak X-extent #'(0 . 0) -\tweak minimum-length #5 -\tweak springs-and-rods #ly:spanner::set-spacing-rods
                 \startTextSpan #})
startArrow = #((fixed-span box-link)
               #{ -\tweak X-extent #'(0 . 0) -\tweak details.arrow ##t -\tweak minimum-length #9
                  -\tweak springs-and-rods #ly:spanner::set-spacing-rods \startTextSpan #})
stopLink = \stopTextSpan

% The room a box needs below the staff, so the staff below clears it -- without the box itself
% taking room, which would push the dynamics out of it. An invisible floor along the box's
% bottom edge, placed after everything else below the staff (dynamics included), a little
% below the lowest of them (outside-staff-padding) and at least staff-padding below the staff;
% the box's bottom is drawn at the floor. Alongside each box:
%   \startBox \startFloor ... \stopBox \stopFloor
#(define laid-out-floors '())
#(define (register-floor grob) (set! laid-out-floors (cons grob laid-out-floors)))

#(define (box-floor grob)
   (let ((l (- (span-x grob LEFT) 1.0))
         (r (+ (span-x grob RIGHT) 0.4)))
     (ly:stencil-outline empty-stencil (make-filled-box-stencil (cons l r) '(-0.2 . 0)))))

startFloor = -\tweak stencil #box-floor
             -\tweak after-line-breaking #register-floor
             -\tweak direction #DOWN
             -\tweak staff-padding #1.2
             -\tweak outside-staff-priority #5000
             -\tweak outside-staff-padding #0.8
             -\tweak bound-details.left.attach-dir #LEFT
             -\tweak bound-details.right.attach-dir #LEFT
             \startTrillSpan
stopFloor = \stopTrillSpan

%% ------------------------------------------------------------------ time fields

% Time fields (improvisation / timed-section brackets): "improvise ..." on a line with a hook at
% each end, its duration in a gap at the middle, above the staff. \timeField "improvise gradually more pitch" "30″" on the first note,
% \stopTextSpan on the last.
% how far the text starts after the left hook (the line runs on before it)
#(define time-field-lead 2.5)

#(define (time-field-stencil label)
   (lambda (grob)
     (let* ((st (ly:line-spanner::print grob))
            (x (ly:stencil-extent st X))
            (left-text (ly:grob-property grob 'left-bound-info))
            (text-st (assoc-get 'stencil left-text empty-stencil))
            (text-w (if (ly:stencil-empty? text-st X) 0 (interval-length (ly:stencil-extent text-st X))))
            (mid (* 0.5 (+ (car x) text-w (cdr x))))
            (txt (grob-interpret-markup grob (markup #:fontsize -1 #:whiteout #:pad-x 0.6 label)))
            (line-th (* (ly:grob-property grob 'thickness 1) (ly:staff-symbol-line-thickness grob))))
       (ly:stencil-add
        st
        (make-line-stencil line-th (car x) 0 (+ (car x) time-field-lead -0.6) 0) ; line before the text
        (make-line-stencil 0.12 (car x) 0 (car x) -1.2)            ; the hooks
        (make-line-stencil 0.12 (cdr x) 0 (cdr x) -1.2)
        (ly:stencil-translate
         (ly:stencil-aligned-to (ly:stencil-aligned-to txt X CENTER) Y CENTER)
         (cons mid 0))))))

timeField =
#(define-event-function (text duration) (markup? markup?)
   #{ -\tweak bound-details.left.text \markup \concat { \hspace #time-field-lead #text \hspace #0.6 }
      -\tweak bound-details.left.stencil-align-dir-y #CENTER
      -\tweak bound-details.left.padding #-1.2
      -\tweak bound-details.right.padding #-1.6
      -\tweak staff-padding #5
      -\tweak style #'line
      -\tweak font-shape #'upright
      -\tweak thickness #0.8
      -\tweak stencil #(time-field-stencil duration)
      -\tweak outside-staff-priority #1000
      \startTextSpan #})

%% ------------------------------------------------------------------ wind tone

% Air in the tone: a circle, white for the air and black for the rest (1 = all air, an open
% circle; 0.75 = a black quarter; 0.5 = left half black). Above the note: c'1^\wind #0.75
#(define-markup-command (wind-circle layout props fraction) (number?)
   (let* ((r 0.48) (k 0.5523) (th 0.13)
          (ring (make-circle-stencil r th #f))
          (q (lambda (a) ; quarter arc from angle a (multiples of 90 deg, clockwise from top)
               (let* ((pts '((0 . 1) (1 . 0) (0 . -1) (-1 . 0) (0 . 1)))
                      (p0 (list-ref pts a)) (p1 (list-ref pts (+ a 1))))
                 (list 'curveto
                       (* r (+ (car p0) (* k (car p1)))) (* r (+ (cdr p0) (* k (cdr p1))))
                       (* r (+ (car p1) (* k (car p0)))) (* r (+ (cdr p1) (* k (cdr p0))))
                       (* r (car p1)) (* r (cdr p1))))))
          ; the air is the white part, the tone the black: fill what is not air, starting
          ; where the air ends (clockwise from the top)
          (n (inexact->exact (round (* 4 fraction))))
          (start (list-ref '((0 . 1) (1 . 0) (0 . -1) (-1 . 0) (0 . 1)) (min n 4)))
          (fill (cond ((>= n 4) empty-stencil)
                      ((<= n 0) (make-circle-stencil r 0 #t))
                      (else
                       (make-path-stencil
                        (append (list 'moveto 0 0 'lineto (* r (car start)) (* r (cdr start)))
                                (apply append (map q (iota (- 4 n) n))) '(closepath))
                        0 1 1 #t)))))
     (ly:stencil-add ring fill)))

% centred over its note
wind =
#(define-event-function (fraction) (number?)
   #{ -\tweak parent-alignment-X #CENTER -\tweak self-alignment-X #CENTER
      ^\markup \wind-circle #fraction #})

%% ------------------------------------------------------------------ slap tongue

% Slap tongue: an accent-shaped notehead. \slapOn ... \slapOff
slapOn = {
  \override NoteHead.stencil = #ly:text-interface::print
  \override NoteHead.text = \markup \musicglyph "scripts.sforzato"
  \override NoteHead.stem-attachment = #'(1.0 . 0.0)
}
slapOff = {
  \revert NoteHead.stencil
  \revert NoteHead.text
  \revert NoteHead.stem-attachment
}

%% ------------------------------------------------------------------ caesura, niente

% "//" before the barline
caes = {
  \once \override BreathingSign.text = \markup \musicglyph "scripts.caesura.straight"
  \once \override BreathingSign.Y-offset = 2.5
  \once \override BreathingSign.extra-offset = #'(-1.6 . 0)   % clear of the barline
  \breathe
}

% the same where the gesture is followed closely (little room before the next note)
caesTight = {
  \once \override BreathingSign.text = \markup \musicglyph "scripts.caesura.straight"
  \once \override BreathingSign.Y-offset = 2.5
  \once \override BreathingSign.extra-offset = #'(-0.4 . 0)
  \breathe
}

niente = #(make-dynamic-script (markup #:normal-text #:bold #:italic "n"))

%% ------------------------------------------------------------------ shaped trills

% A trill whose speed changes: "tr" (with its upper note's accidental) and a wavy line whose
% waves are long where the trill is slow and short where it is fast.
%   fis''1 \shapedTrill "♮" #'(0.25 1 0.25) ... (next note) \stopTrillSpan
% speeds: relative speeds at evenly spaced points along the note (1 = fastest), interpolated;
% '(0.25 1 0.25) starts slow, gets fast, ends slow. "" for no accidental. \midiTrills plays it.

% the speed (0..1) at fraction t (0..1) of the way through
#(define (shape-speed speeds t)
   (let* ((n (1- (length speeds)))
          (x (* t n))
          (i (min (inexact->exact (floor x)) (max 0 (1- n))))
          (f (- x i)))
     (if (zero? n)
         (car speeds)
         (+ (* (- 1 f) (list-ref speeds i)) (* f (list-ref speeds (1+ i)))))))

#(define (shaped-trill-stencil grob)
   (let* ((speeds (detail grob 'speeds '(1)))
          (label (detail grob 'label (markup #:musicglyph "scripts.trill")))
          (txt (ly:stencil-aligned-to (grob-interpret-markup grob label) Y CENTER))
          (x0 (span-x grob LEFT))
          (x1 (- (span-x grob RIGHT) 0.6))
          (start (+ x0 (cdr (ly:stencil-extent txt X)) 0.3))
          (amp 0.3)
          (long 3.4) (short 0.45)           ; wavelengths at speed 0 and 1
          (dx 0.04))
     (let loop ((x start) (phase 0) (pts '()))
       (if (> x x1)
           (ly:stencil-add
            (ly:stencil-translate-axis txt x0 X)
            (make-path-stencil
             (append (list 'moveto start 0)
                     (apply append (map (lambda (p) (list 'lineto (car p) (cdr p))) (reverse pts))))
             0.16 1 1 #f))
           (let* ((t (/ (- x start) (max 0.01 (- x1 start))))
                  (wl (- long (* (- long short) (shape-speed speeds t))))
                  (ph (+ phase (/ (* 2 3.14159265 dx) wl))))
             (loop (+ x dx) ph (cons (cons x (* amp (sin phase))) pts)))))))

shapedTrill =
#(define-event-function (acc speeds) (string? list?)
   (let ((ev #{ -\tweak stencil #shaped-trill-stencil
                -\tweak after-line-breaking #register-trill
                -\tweak details.speeds #speeds
                -\tweak details.label
                  \markup \concat { \musicglyph "scripts.trill"
                    \raise #1.2 \fontsize #-4 #acc }
                -\tweak bound-details.left.attach-dir #LEFT
                -\tweak bound-details.right.attach-dir #LEFT
                \startTrillSpan #}))
     (if (not (string-null? acc)) (ly:music-set-property! ev 'trill-upper acc))
     (ly:music-set-property! ev 'trill-shape speeds)
     ev))

%% ------------------------------------------------------------------ fanned beams

% Feathered beams: \featherOnce before a beamed group (accelerando: the beams fan out to the
% right), \featherBackOnce (ritardando); \featherOn ... \featherOff for several groups
featherOnce = \once \override Beam.grow-direction = #RIGHT
featherBackOnce = \once \override Beam.grow-direction = #LEFT
featherOn = \override Beam.grow-direction = #RIGHT
featherOff = \revert Beam.grow-direction

