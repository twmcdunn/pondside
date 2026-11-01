% playback.ily -- what the score tells the MIDI render and the patch, without printing it
% (lilypond-supercollider skill). Include after \version, before the music; Pondside's timing
% reads the marks (cue-label, timing-label) and tempos.
%
%   \playTempo 60                      hidden tempo change (fermata holds, caesuras, timed
%                                      sections): shapes the MIDI and every time after it
%   <>\timingMark "end"                an invisible mark the timing log writes as its text
%   \improvisation 1 { ... }           a passage rendered in SuperCollider instead of the MIDI:
%                                      marks "improv 1" at its start and "improv end" at its
%                                      end, prints its music, and is silent in the MIDI
%
%   \midiTrills { ... }                (MIDI score only) plays ^\trill notes, and notes with a
%                                      post-event carrying trill-upper "♯"/"♭"/"♮", as trills
%
% The MIDI score must use \removeWithTag #'printed, the printed score \removeWithTag #'played.
% LilyPond's MIDI plays \repeat tremolo but ignores trills and other ornaments.

% An invisible text Pondside's timing reads (its timing-label), e.g. "improv 1", "end"
timingMark =
#(define-event-function (text) (string?)
   (let ((ev #{ -\tweak stencil ##f ^\markup #text #}))
     (ly:music-set-property! ev 'timing-label text)
     ev))

improvisation =
#(define-music-function (n music) (index? ly:music?)
   (let* ((len (ly:moment-main (ly:music-length music))))
     #{ <>\timingMark #(format #f "improv ~a" n)
        << \tag #'printed #music
           \tag #'played #(make-music 'SkipMusic
                                      'duration (ly:make-duration 0 0 (numerator len)
                                                                  (denominator len))) >>
        <>\timingMark "improv end" #}))

% Silent in the MIDI but printed (a part the patch plays, or one muted in the test render)
silentInMidi =
#(define-music-function (music) (ly:music?)
   (let* ((len (ly:moment-main (ly:music-length music))))
     #{ << \tag #'printed #music
           \tag #'played #(make-music 'SkipMusic
                                      'duration (ly:make-duration 0 0 (numerator len)
                                                                  (denominator len))) >> #}))

% A tempo change for playback only (MIDI and cue times), not printed: \playTempo 60.
% Never at the same moment as a printed \tempo (it would hide it).
playTempo =
#(define-music-function (bpm) (number?)
   #{ \once \omit Score.MetronomeMark \tempo 4 = #bpm #})

% Trills in the MIDI: \midiTrills { ... } (in the MIDI score only) plays every note marked
% ^\trill, or with a post-event carrying trill-upper ("♯" "♭" "♮", as \accTrill does), as 32nds
% alternating with its upper neighbour (a diatonic step; natural unless trill-upper says
% otherwise), starting on the written note. A \shapedTrill follows its speeds: 32nds at speed
% 1, eighths at speed 0.
#(define (trill-upper-alteration note)
   (let loop ((arts (ly:music-property note 'articulations '())))
     (cond ((null? arts) #f)
           ((let ((t (ly:music-property (car arts) 'articulation-type #f)))
              (and t (equal? (if (symbol? t) (symbol->string t) t) "trill")))
            0)
           ((ly:music-property (car arts) 'trill-upper #f)
            => (lambda (a) (cond ((string=? a "♯") 1/2) ((string=? a "♭") -1/2) (else 0))))
           ((ly:music-property (car arts) 'trill-shape #f) 0)
           (else (loop (cdr arts))))))

% the trill's speed shape (\shapedTrill, contemporary.ily), or #f for an even trill
% the speed (0..1) at fraction t (0..1) through a shape (as in contemporary.ily's shape-speed)
#(define (playback-shape-speed speeds t)
   (let* ((n (1- (length speeds))) (x (* t n))
          (i (min (inexact->exact (floor x)) (max 0 (1- n)))) (f (- x i)))
     (if (zero? n) (car speeds)
         (+ (* (- 1 f) (list-ref speeds i)) (* f (list-ref speeds (1+ i)))))))

#(define (trill-shape note)
   (any (lambda (a) (ly:music-property a 'trill-shape #f))
        (ly:music-property note 'articulations '())))

% note lengths (whole notes) filling len: 1/32 at speed 1, 1/8 at speed 0, following shape
#(define (trill-lengths len shape)
   (let loop ((at 0) (out '()))
     (let* ((sp (if shape (playback-shape-speed shape (/ at len)) 1))
            (d (/ (inexact->exact (round (* 128 (+ 1/32 (* (- 1/8 1/32) (- 1 sp)))))) 128)))
       (if (>= (+ at d) len)
           (reverse (cons (- len at) out))
           (loop (+ at d) (cons d out))))))

#(define (upper-neighbour p alt)
   (let* ((n (1+ (ly:pitch-notename p)))
          (o (+ (ly:pitch-octave p) (if (> n 6) 1 0))))
     (ly:make-pitch o (modulo n 7) alt)))

midiTrills =
#(define-music-function (music) (ly:music?)
   (map-some-music
    (lambda (m)
      (and (music-is-of-type? m 'note-event)
           (let ((alt (trill-upper-alteration m)))
             (and alt
                  (let* ((p (ly:music-property m 'pitch))
                         (len (ly:moment-main (ly:music-length m)))
                         (lens (trill-lengths len (trill-shape m)))
                         (dur (lambda (r) (ly:make-duration 0 0 (numerator r) (denominator r)))))
                    (make-sequential-music
                     (map (lambda (d i)
                            (make-music 'NoteEvent
                                        'pitch (if (even? i) p (upper-neighbour p alt))
                                        'duration (dur d)))
                          lens (iota (length lens)))))))))
    music))

