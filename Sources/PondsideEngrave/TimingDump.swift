import Foundation
import PondsideCore
import PondsideTiming

/// Asks LilyPond when everything happens: tempos (printed or hidden),
/// cues (`\ecue`, read from the event's `cue-label`), timing marks
/// (`timing-label`), notes and groups, each at its exact moment with its
/// bar and position in the bar.
///
/// The rows are timing.ily's (the lilypond-supercollider workflow), plus
/// the position in the bar and `meter` rows, so Pondside and an existing
/// patch's scripts compute identical seconds from the same score.
public enum TimingDump {
    public static let marker = "PONDSIDE-TIMING\t"

    public static let listener = """
    #(define pondside-timing-last-meter #f)
    % front-matter.ily sets it while it draws a legend example (a \\score
    % in markup), which is not part of the piece's time.
    #(define pondside-in-example #f)

    % ly:duration-length in 2.24, ly:duration->moment later.
    #(define pondside-duration-moment
       (primitive-eval (if (defined? 'ly:duration->moment) 'ly:duration->moment 'ly:duration-length)))

    #(define (pondside-timing-row context kind . values)
       (let ((m (ly:context-current-moment context)))
         (if (and (zero? (ly:moment-grace m)) (not pondside-in-example))
             (let* ((bar (ly:context-property context 'currentBarNumber 1))
                    (pos (ly:context-property context 'measurePosition (ly:make-moment 0)))
                    ; 2.26 renamed timeSignatureFraction to timeSignature (and warns on the old name)
                    (meter (let ((ts (ly:context-property context 'timeSignature #f)))
                             (if (pair? ts) ts (ly:context-property context 'timeSignatureFraction '(4 . 4)))))
                    (row (lambda (k vs)
                           (display (string-join
                                     (append (list "PONDSIDE-TIMING"
                                                   (number->string (ly:moment-main m))
                                                   (number->string bar)
                                                   (string-append "@" (number->string (ly:moment-main pos)))
                                                   k)
                                             (map (lambda (v) (format #f "~a" v)) vs))
                                     "\\t"))
                           (newline))))
               (if (and (pair? meter) (not (equal? meter pondside-timing-last-meter)))
                   (begin
                     (set! pondside-timing-last-meter meter)
                     (row "meter" (list (format #f "~a/~a" (car meter) (cdr meter))))))
               (row kind values)))))

    #(define (pondside-timing-staff context)
       (let ((staff (ly:context-find context 'Staff)))
         (if staff (ly:context-id staff) "")))

    #(define (pondside-timing-rest context event)
       (let* ((loc (ly:event-property event 'origin #f))
              (where (if (ly:input-location? loc)
                         (let ((o (ly:input-file-line-char-column loc)))
                           (list (car o) (cadr o) (caddr o))) '())))
         (apply pondside-timing-row context "rest" (pondside-timing-staff context) where)))

    #(define (Pondside_timing_engraver context)
       (make-engraver
        (listeners
         ((tempo-change-event engraver event)
          (let ((count (ly:event-property event 'metronome-count #f))
                (unit (ly:event-property event 'tempo-unit #f)))
            (if (and (number? count) unit)
                (pondside-timing-row context "tempo"
                  (exact->inexact (* count (/ (ly:moment-main (pondside-duration-moment unit)) 1/4)))))))
         ((text-script-event engraver event)
          (let ((cue (ly:event-property event 'cue-label #f))
                (mark (ly:event-property event 'timing-label #f)))
            ; Where the event was written, when it has a place (a Lexicon
            ; cue is generated and has none): file, line, character.
            (let* ((loc (ly:event-property event 'origin #f))
                   (where (if (ly:input-location? loc)
                              (let ((o (ly:input-file-line-char-column loc)))
                                (list (car o) (cadr o) (caddr o)))
                              '())))
              (cond (cue
                     (apply pondside-timing-row context "text" (string-append "cue " cue) where)
                     ; a Lexicon entry's cue also says which entry, its length and params
                     (let ((lex (ly:event-property event 'pondside-lexicon #f)))
                       (if (pair? lex)
                           (pondside-timing-row context "lexicon" cue (car lex) (cadr lex) (caddr lex)))))
                    (mark (apply pondside-timing-row context "text" mark where))
                    ; the older workflow's marks (its timing.ily): a hidden text
                    ; "improv 1", "improv end" or "end"
                    (else
                     (let ((s (string-delete (string->char-set "[]")
                                             (markup->string (ly:event-property event 'text)))))
                       (if (or (string-prefix? "improv " s) (string=? s "end"))
                           (apply pondside-timing-row context "text" s where))))))))
         ((note-event engraver event)
          (let ((p (ly:event-property event 'pitch #f))
                (loc (ly:event-property event 'origin #f)))
            (if (ly:pitch? p)
                ; Also where the note was written: the playhead follows the
                ; audio through the printed score by these positions.
                (let ((where (if (ly:input-location? loc)
                                 (let ((o (ly:input-file-line-char-column loc)))
                                   (list (car o) (cadr o) (caddr o)))
                                 '())))
                  (apply pondside-timing-row context "note"
                         (pondside-timing-staff context) (+ 60 (ly:pitch-semitones p)) where)))))
         ((rest-event engraver event) (pondside-timing-rest context event))
         ((multi-measure-rest-event engraver event) (pondside-timing-rest context event))
         ((note-grouping-event engraver event)
          (pondside-timing-row context "group" (pondside-timing-staff context)
            (if (= (ly:event-property event 'span-direction) START) "start" "stop"))))))

    \\layout {
      \\context { \\Voice \\consists #Pondside_timing_engraver }
    }

    """

    /// Interprets `source` (no pages are written) and returns its timing
    /// log: the playback's, so cue times agree with the mockup (PlaybackScore).
    public static func run(_ installation: LilyPondInstallation, source: URL) async throws -> TimingLog {
        try await PlaybackScore.compile(installation, source: source).timing
    }
}
