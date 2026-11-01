% pondside-playback.ily -- the playback Pondside hears when a score has no
% \midi of its own (docs/API.md, "Playback"). Loaded with -dinclude-settings
% for the mockup and cue-time compiles only; the printed score never sees it.
%
% Each top-level \score is replaced by one made from the same music:
%   1. music tagged 'printed is silent but keeps its time and marks (the
%      lilypond-supercollider skill's convention: an improvisation is
%      printed, not played; a 'played version beside it, if any, plays)
%   2. every repeat is played out (volta, percent, and tremolos between notes)
%   3. staves named Electronics / Tape keep their timing but make no sound
%   4. trills become alternating notes: \trill, \startTrillSpan ... \stopTrillSpan
%      (over several notes), \pitchedTrill, trill-upper ("♯" "♭" "♮") and
%      \shapedTrill speeds (trill-shape); the upper note follows the key
%   5. single-note tremolos (c2:32) become repeated notes
%   6. \articulate (staccato, slurs, ornaments, fermatas)
% and gets the score's own \layout (so the timing engraver sees exactly this
% music) plus a \midi reading dynamics per staff over a wide range.
% midiInstrument comes from a staff's instrumentName when it has none.

\include "articulate.ly"

#(define (pb-posts m)
   (if (music-is-of-type? m 'event-chord)
       (append (ly:music-property m 'elements '()) (ly:music-property m 'articulations '()))
       (ly:music-property m 'articulations '())))

#(define (pb-trill-span? ev dir)
   (and (music-is-of-type? ev 'trill-span-event)
        (eqv? (ly:music-property ev 'span-direction 0) dir)))

#(define (pb-trill-mark? ev)
   (let ((t (ly:music-property ev 'articulation-type #f)))
     (or (and t (equal? (if (symbol? t) (symbol->string t) t) "trill"))
         (ly:music-property ev 'trill-upper #f)
         (ly:music-property ev 'trill-shape #f))))

#(define (pb-start-span m) (find (lambda (e) (pb-trill-span? e START)) (pb-posts m)))
#(define (pb-stops-span? m) (any (lambda (e) (pb-trill-span? e STOP)) (pb-posts m)))
#(define (pb-trill-start? m)
   (or (pb-start-span m) (any pb-trill-mark? (pb-posts m))))

% Alterations written as text ("♯" in \accTrill, \shapedTrill)
#(define (pb-alteration s)
   (cond ((not (string? s)) #f)
         ((or (string=? s "♯") (string=? s "#") (string=? s "sharp")) 1/2)
         ((or (string=? s "♭") (string=? s "b") (string=? s "flat")) -1/2)
         ((or (string=? s "♮") (string=? s "natural")) 0)
         (else #f)))

% The trill's upper note: a \pitchedTrill's pitch; else the next step up,
% altered as the trill's sign says, or as the key has it.
#(define (pb-upper note posts key)
   (let ((p (ly:music-property note 'pitch))
         (pitched (any (lambda (e) (and (pb-trill-span? e START)
                                        (ly:pitch? (ly:music-property e 'pitch #f))
                                        (ly:music-property e 'pitch)))
                       posts)))
     (or pitched
         (let* ((n (1+ (ly:pitch-notename p)))
                (o (+ (ly:pitch-octave p) (if (> n 6) 1 0)))
                (step (modulo n 7))
                (sign (any (lambda (e) (pb-alteration (ly:music-property e 'trill-upper #f))) posts))
                (alt (or sign (let ((k (assv step key))) (if k (cdr k) 0)))))
           (ly:make-pitch o step alt)))))

#(define (pb-shape posts)
   (any (lambda (e) (ly:music-property e 'trill-shape #f)) posts))

% the speed (0..1) at fraction t of the way through a shape
#(define (pb-speed speeds t)
   (let* ((n (1- (length speeds)))
          (x (* t n))
          (i (min (inexact->exact (floor x)) (max 0 (1- n))))
          (f (- x i)))
     (if (zero? n)
         (car speeds)
         (+ (* (- 1 f) (list-ref speeds i)) (* f (list-ref speeds (1+ i)))))))

#(define (pb-duration r)
   (ly:make-duration 0 0 (numerator r) (denominator r)))

% Articulations a replacement note keeps (dynamics, slurs...): not the trill,
% the tremolo or the tie, which the notes now play.
#(define (pb-kept posts)
   (filter (lambda (e) (not (or (music-is-of-type? e 'trill-span-event) (pb-trill-mark? e)
                                (music-is-of-type? e 'tremolo-event) (music-is-of-type? e 'tie-event))))
           posts))

% The notes a trill on `note` plays: from `from` (whole notes into a run of
% `total`), alternating with `upper`; 32nds at speed 1, eighths at speed 0.
% Returns (notes . next-index) so a tied run keeps alternating.
#(define (pb-trill-notes note upper from total shape index)
   (let ((len (ly:moment-main (ly:music-length note)))
         (p (ly:music-property note 'pitch)))
     (let loop ((at 0) (i index) (out '()))
       (if (>= at len)
           (cons (reverse out) i)
           (let* ((sp (if shape (pb-speed shape (/ (+ from at) (max total 1/1024))) 1))
                  (d (/ (inexact->exact (round (* 128 (+ 1/32 (* (- 1/8 1/32) (- 1 sp)))))) 128))
                  (d (min d (- len at)))
                  (ev (make-music 'NoteEvent 'pitch (if (even? i) p upper) 'duration (pb-duration d))))
             (if (null? out) (ly:music-set-property! ev 'articulations (pb-kept (pb-posts note))))
             (loop (+ at d) (1+ i) (cons ev out)))))))

% c2:32 and the like: repeated notes
#(define (pb-tremolo note)
   (let* ((ev (find (lambda (e) (music-is-of-type? e 'tremolo-event)) (pb-posts note)))
          (type (and ev (ly:music-property ev 'tremolo-type 0)))
          (len (ly:moment-main (ly:music-length note))))
     (and ev (music-is-of-type? note 'note-event) (> len 0)
          (let* ((d (/ 1 (if (and (integer? type) (>= type 8)) type 32)))
                 (n (max 1 (inexact->exact (floor (/ len d))))))
            ; new events: a copy would keep the 'length the parser cached
            (map (lambda (i)
                   (make-music 'NoteEvent 'pitch (ly:music-property note 'pitch)
                               'duration (pb-duration (if (= i (1- n)) (- len (* d i)) d))
                               'articulations (if (zero? i) (pb-kept (pb-posts note)) '())))
                 (iota n))))))

% A run of elements under one trill: from a start (a trill mark, or
% \startTrillSpan) to the element that stops it, or the end of the list.
#(define (pb-run elements)
   (let* ((first (car elements))
          (spanned (pb-start-span first)))
     (if (not spanned)
         (list first)
         (let loop ((rest (cdr elements)) (out (list first)))
           (if (or (null? rest)
                   (pb-stops-span? (car rest))
                   (not (or (music-is-of-type? (car rest) 'note-event)
                            (zero? (ly:moment-main (ly:music-length (car rest)))))))
               (reverse out)
               (loop (cdr rest) (cons (car rest) out)))))))

#(define (pb-trill-run run key)
   (let* ((head (car run))
          (posts (pb-posts head))
          (upper (pb-upper head posts key))
          (shape (pb-shape posts))
          (total (apply + (map (lambda (m) (ly:moment-main (ly:music-length m))) run))))
     (let loop ((run run) (from 0) (index 0) (out '()))
       (if (null? run)
           out
           (let ((m (car run)))
             (if (music-is-of-type? m 'note-event)
                 (let ((r (pb-trill-notes m upper from total shape index)))
                   (loop (cdr run) (+ from (ly:moment-main (ly:music-length m))) (cdr r) (append out (car r))))
                 (loop (cdr run) from index (append out (list m)))))))))

% Walks the music in time order, so the key is known at every trill.
% Returns (music . key).
#(define (pb-walk m key)
   (cond
    ((music-is-of-type? m 'key-change-event)
     (cons m (ly:music-property m 'pitch-alist '())))
    ((music-is-of-type? m 'sequential-music)
     (let loop ((elements (ly:music-property m 'elements '())) (key key) (out '()))
       (if (null? elements)
           (begin (ly:music-set-property! m 'elements out) (cons m key))
           (let ((e (car elements)))
             (cond
              ((and (music-is-of-type? e 'note-event) (pb-trill-start? e))
               (let ((run (pb-run elements)))
                 (loop (list-tail elements (length run)) key (append out (pb-trill-run run key)))))
              ((pb-tremolo e)
               => (lambda (notes) (loop (cdr elements) key (append out notes))))
              (else
               (let ((r (pb-walk e key)))
                 (loop (cdr elements) (cdr r) (append out (list (car r)))))))))))
    ((music-is-of-type? m 'simultaneous-music)
     (ly:music-set-property! m 'elements
       (map (lambda (e) (car (pb-walk e key))) (ly:music-property m 'elements '())))
     (cons m key))
    ((ly:music? (ly:music-property m 'element #f))
     (let ((r (pb-walk (ly:music-property m 'element) key)))
       (ly:music-set-property! m 'element (car r))
       (cons m (cdr r))))
    ((and (music-is-of-type? m 'note-event) (pb-trill-start? m))
     (cons (make-sequential-music (pb-trill-run (list m) key)) key))
    ((pb-tremolo m) => (lambda (notes) (cons (make-sequential-music notes) key)))
    (else (cons m key))))

%% ---------------------------------------------------------------- staves

#(define (pb-name-string v)
   (string-downcase (if (string? v) v (if (markup? v) (markup->string v) ""))))

#(define pb-instruments
   ; (words in the name . General MIDI instrument), first match wins
   '((("electronic" "elec." "tape") . #f)
     (("piccolo") . "piccolo") (("flute" "flauto" "flöte") . "flute") (("oboe") . "oboe")
     (("english horn" "cor anglais") . "english horn") (("clarinet" "clarinetto") . "clarinet")
     (("bassoon" "fagott") . "bassoon") (("soprano sax") . "soprano sax") (("alto sax") . "alto sax")
     (("tenor sax") . "tenor sax") (("baritone sax" "bari sax") . "baritone sax") (("sax") . "alto sax")
     (("horn" "corno") . "french horn") (("trumpet" "tromba") . "trumpet") (("trombone") . "trombone")
     (("tuba") . "tuba") (("violin" "violino") . "violin") (("viola") . "viola")
     (("cello" "violoncello") . "cello") (("double bass" "contrabass" "kontrabass") . "contrabass")
     (("harp" "arpa") . "orchestral harp") (("piano" "pianoforte") . "acoustic grand")
     (("celesta") . "celesta") (("vibraphone") . "vibraphone") (("marimba") . "marimba")
     (("xylophone") . "xylophone") (("glockenspiel") . "glockenspiel") (("guitar") . "acoustic guitar (nylon)")
     (("organ") . "church organ")
     (("soprano" "mezzo" "alto" "tenor" "baritone" "bass" "voice" "voix") . "choir aahs")))

#(define (pb-instrument name)
   (let ((hit (find (lambda (entry) (any (lambda (w) (string-contains name w)) (car entry))) pb-instruments)))
     (if hit (cdr hit) 'none)))

% Notes in an electronics part keep their time (and their cues) as skips.
#(define (pb-silence music)
   (music-map
    (lambda (m)
      (cond ((music-is-of-type? m 'note-event)
             (make-music 'SkipEvent 'duration (ly:music-property m 'duration)
                         'articulations (ly:music-property m 'articulations '())))
            ((music-is-of-type? m 'event-chord)
             (let* ((els (ly:music-property m 'elements '()))
                    (notes (filter (lambda (e) (music-is-of-type? e 'note-event)) els)))
               (if (null? notes)
                   m
                   (begin
                     (ly:music-set-property! m 'elements
                       (cons (make-music 'SkipEvent 'duration (ly:music-property (car notes) 'duration))
                             (filter (lambda (e) (not (music-is-of-type? e 'note-event))) els)))
                     m))))
            (else m)))
    music))

#(define (pb-printed-only music)
   (music-map (lambda (m) (if (memq 'printed (ly:music-property m 'tags '())) (pb-silence m) m)) music))

#(define (pb-staves music)
   (music-map
    (lambda (m)
      (if (music-is-of-type? m 'context-specification)
          (let* ((ops (ly:music-property m 'property-operations '()))
                 (named (find (lambda (op) (and (pair? op) (eq? (car op) 'assign) (eq? (cadr op) 'instrumentName))) ops))
                 (midi (find (lambda (op) (and (pair? op) (eq? (car op) 'assign) (eq? (cadr op) 'midiInstrument))) ops))
                 (gm (if named (pb-instrument (pb-name-string (caddr named))) 'none)))
            (cond ((not gm) (ly:music-set-property! m 'element (pb-silence (ly:music-property m 'element))))
                  ((and (string? gm) (not midi))
                   (ly:music-set-property! m 'property-operations (cons (list 'assign 'midiInstrument gm) ops))))
            m)
          m))
    music))

%% ---------------------------------------------------------------- the score

#(define (pb-unfold music)
   (if (defined? 'unfold-repeats-fully) (unfold-repeats-fully music) (unfold-repeats '() music)))

% The parser caches each expression's 'length; music rebuilt from copies
% (unfolded repeats, \articulate's shortened notes) would keep stale ones.
#(define (pb-forget-lengths music)
   (music-map (lambda (m) (ly:music-set-property! m 'length '()) m) music))

#(define (pb-any? pred m)
   (let ((found #f))
     (for-some-music (lambda (x) (if (pred x) (begin (set! found #t) #t) #f)) m)
     found))

% \articulate, one voice at a time, each on its own copy: it changes music in
% place and some voices defeat it (skips carrying text spans can divide by
% zero), so a voice it fails on plays as written and the others still get it.
#(define (pb-safe-articulate m)
   (if (not (pb-any? (lambda (x) (music-is-of-type? x 'note-event)) m))
       m   ; nothing to play (skips, graphics, a silenced part)
   (catch #t
     (lambda () (articulate (ly:music-deep-copy m)))
     (lambda (key . args)
       (ly:input-warning (or (ly:music-property m 'origin #f) (*location*))
                         "pondside playback: \\articulate failed (~a) on this voice; it plays as written" key)
       m))))

#(define (pb-has-voice? m)
   (pb-any? (lambda (x) (and (music-is-of-type? x 'context-specification)
                             (eq? (ly:music-property x 'context-type) 'Voice)))
            m))

#(define (pb-articulate m)
   (cond ((and (music-is-of-type? m 'context-specification)
               (or (eq? (ly:music-property m 'context-type) 'Voice)
                   (not (pb-has-voice? (ly:music-property m 'element)))))
          (ly:music-set-property! m 'element (pb-safe-articulate (ly:music-property m 'element)))
          m)
         ((ly:music? (ly:music-property m 'element #f))
          (ly:music-set-property! m 'element (pb-articulate (ly:music-property m 'element)))
          m)
         ((pair? (ly:music-property m 'elements '()))
          (if (pb-has-voice? m)
              (begin (ly:music-set-property! m 'elements (map pb-articulate (ly:music-property m 'elements)))
                     m)
              (pb-safe-articulate m)))
         (else m)))

#(define (pondside-playback-music music)
   (let* ((m (pb-forget-lengths (ly:music-deep-copy music)))
          (m (pb-printed-only m))
          (m (pb-unfold m))
          (m (pb-staves m))
          (m (car (pb-walk m '()))))
     (pb-articulate m)))

#(define (pondside-playback-score score)
   (let* ((s (ly:make-score (pondside-playback-music (ly:score-music score))))
          (layouts (filter (lambda (d) (not (ly:output-def-lookup d 'is-midi #f))) (ly:score-output-defs score))))
     (for-each (lambda (d) (ly:score-add-output-def! s (ly:output-def-clone d)))
               (if (null? layouts) (list $defaultlayout) layouts))
     (ly:score-add-output-def! s
       #{ \midi {
            \context { \Voice \remove "Dynamic_performer" }
            \context { \Staff \consists "Dynamic_performer"
                       midiMinimumVolume = #0.15 midiMaximumVolume = #1 }
          } #})
     s))

#(set! toplevel-score-handler
   (lambda (score) (collect-scores-for-book (pondside-playback-score score))))
