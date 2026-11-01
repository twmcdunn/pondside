# Scheme in LilyPond 2.26 (Guile 3)

Extending manual: https://lilypond.org/doc/v2.26/Documentation/extending/ . IR "Scheme functions" lists every `ly:` function with its signature -- check it before guessing arguments.

## Gotchas (each cost real time)

| Symptom | Cause / fix |
|---|---|
| `Unbound variable: string-match` | Guile 3 needs `(use-modules (ice-9 regex))`; usually `string-prefix?`, `string-contains`, `string-split` do. |
| `extract-typed-music` returns `()` | It takes the music **type** in lowercase-hyphen form: `'note-event`, `'rest-event` -- not the music name `'NoteEvent`. |
| bar check fails right after a music function that sets a duration | `ly:make-duration log dots num den` -- the factor is *two integers*: `(ly:make-duration 0 0 (numerator r) (denominator r))` for a whole note scaled by rational `r`. |
| `ly:skylines-for-stencil` wrong-arg error | `(ly:skylines-for-stencil stencil axis)` -- axis is `X` for vertical skylines. |
| `grob ... is an invalid refpoint` | Use the system (`ly:grob-system`) or `ly:grob-common-refpoint` of the two grobs as the common reference. |
| A callback sees no other grobs / stale positions, and its result never updates | It ran before line breaking (e.g. something asked for its X-extent during spacing) and the stencil was cached. Give the grob `-\tweak X-extent #'(0 . 0)` so nothing needs its stencil early; it is then drawn after layout. |
| `(ly:grob-object system 'all-elements)` has no spanners in it | Keep a registry: `-\tweak after-line-breaking #register` appends each broken piece to a global list; filter it by `(eq? (ly:grob-system g) sys)`. |
| `ly:grob-property` on a callback property calls it | Use `ly:grob-property-data` to see the raw value. Comparing stencil procedures with `eq?` is unreliable; mark grobs with `details` or a registry instead. |
| A post-event function must also carry data | `(ly:music-set-property! ev 'my-key value)` on the event, read back in an engraver with `(ly:event-property event 'my-key #f)` (arbitrary keys survive). |
| `ly:message` prints nothing | It is INFO level; with `--loglevel=WARN` use `ly:warning` for debug output (and remove it after). |

## Patterns

**Grob-relative geometry of a line spanner's ends** (TextSpanner, TrillSpanner, ...):
```scheme
#(define (span-x grob dir)    ; X of the LEFT/RIGHT bound, relative to the spanner
   (let* ((info (ly:grob-property grob (if (= dir LEFT) 'left-bound-info 'right-bound-info)))
          (sys (ly:grob-system grob)))
     (- (assoc-get 'X info) (ly:grob-relative-coordinate grob sys X))))
```
With `bound-details.left.attach-dir #LEFT` / `right.attach-dir #LEFT`, both ends are at the left edges of their moments' columns.

**The moment a grob belongs to:** `(ly:grob-property (ly:item-get-column g) 'when)`; for a spanner use its left bound's column. Compare with `ly:moment<?` / `equal?`. Selecting grobs by moment is far more robust than by X position.

**Per-grob settings without new properties:** `details` alist -- `-\tweak details.top #9`, read with
`(assoc-get key (ly:grob-property grob 'details '()) default)`.

**Drawing:** `make-path-stencil (list 'moveto x y 'lineto ... 'closepath) thickness 1 1 filled?`; `make-filled-box-stencil xext yext` (square ends -- `make-line-stencil` has round caps that poke past edges); `make-circle-stencil r th filled?`; `ly:stencil-outline empty-stencil shape` (invisible but with an outline for skylines); `grob-interpret-markup grob markup`; `ly:stencil-aligned-to st X CENTER`; `ly:stencil-combine-at-edge st X LEFT other padding`.

**A broken spanner drawn on its first line only:**
```scheme
#(define (continuation? grob)
   (let ((orig (ly:grob-original grob)))
     (and orig (pair? (ly:spanner-broken-into orig))
          (not (eq? grob (car (ly:spanner-broken-into orig)))))))
```

**Music function building a chord** (e.g. several notes at one moment, with custom data per note):
```scheme
(make-music 'EventChord 'elements
  (append (map (lambda (p i) (make-music 'NoteEvent 'pitch p 'duration dur 'my-index i)) pitches (iota n))
          (list (make-music 'NoteGroupingEvent 'span-direction START))))
```

**Engraver in Scheme** (logging, custom behaviour), in `\layout { \context { \Voice \consists #My_engraver } }`:
```scheme
#(define (My_engraver context)
   (make-engraver
    (listeners
     ((note-event engraver event) ...)
     ((text-script-event engraver event) ...))))
```
`(ly:context-current-moment context)`, `(ly:context-property context 'currentBarNumber)`, `(ly:context-find context 'Staff)` + `ly:context-id`. Tempo changes reach Voice-level listeners as `tempo-change-event` (`metronome-count`, `tempo-unit`).

**Tags for print vs. MIDI:** `\tag #'printed {...}` / `\tag #'played {...}`; the printed score uses `\removeWithTag #'played`, the MIDI score `\removeWithTag #'printed`.

**Event functions with tweaks:** `#(define-event-function (x) (number?) #{ -\tweak parent-alignment-X #CENTER ^\markup ... #})`; a variable can hold a tweaked post-event: `foo = -\tweak ... \startTextSpan`.
