# Staff lines over a range

The staff lines are one `StaffSymbol` per system. `StaffSymbol.transparent`,
`\stopStaff` and `\startStaff` affect the **whole staff segment/system**;
they cannot clip a line to a time range. For a marked range in the middle of a
system, keep the staff engraver and replace only `StaffSymbol.stencil`.

`score_context` gives, for every covered system:

- `ordinal`: 1-based system number across the score (the same order as the
  staff's `StaffSymbol` calls);
- `staff_x`: `[from, to]`, the selected range as fractions of the **staff
  line**, not of a graphic's piece;
- `x`: fractions of the graphic's broken piece, for drawing code.

Use `staff_x` and `ordinal`; do not use a fraction of the whole page.

## A window in `StaffSymbol.stencil`

Put this in the target staff's `\with` block (or its `\layout` `Staff`
context), not globally for every staff:

```scheme
#(define (staff-line-gap grob f0 f1)
   (let* ((sp (ly:grob-property grob 'staff-space 1))
          (th (ly:grob-property grob 'thickness 0.1))
          (positions (ly:grob-property grob 'line-positions '(-4 -2 0 2 4)))
          (xe (ly:stencil-extent (ly:staff-symbol::print grob) X))
          (xl (car xe)) (xr (cdr xe))
          (x0 (+ xl (* f0 (- xr xl))))
          (x1 (+ xl (* f1 (- xr xl)))))
     (apply ly:stencil-add empty-stencil
            (append-map
             (lambda (pos)
               (let ((y (* sp (/ pos 2))))
                 (cond ((and (<= x0 xl) (>= x1 xr))
                        (list (make-line-stencil th xl y xr y)))
                       ((<= x0 xl)
                        (list (make-line-stencil th x1 y xr y)))
                       ((>= x1 xr)
                        (list (make-line-stencil th xl y x0 y)))
                       (else
                        (list (make-line-stencil th xl y x0 y)
                              (make-line-stencil th x1 y xr y))))))
             positions))))

% windows: (ordinal from-fraction to-fraction), per system of this staff.
#(define (staff-line-windows windows)
   (let ((seen 0))
     (lambda (grob)
       (set! seen (1+ seen))
       (let ((w (assoc seen windows)))
         (if w
             (staff-line-gap grob (cadr w) (caddr w))
             (ly:staff-symbol::print grob))))))
```

Apply it to the staff that carries the range:

```lilypond
\new Staff = "flute" \with {
  \override StaffSymbol.stencil =
    #(staff-line-windows '((3 0.2635 0.8256)))
} <<
  % the flute's voices
>>
```

For a range across systems, pass one window per system:

```scheme
'((3 0.2635 0.9) (4 0.0 0.4))
```

The callback counts the staff's systems top to bottom; the numbers are the
`ordinal` values from `score_context.systems`, not page numbers.

## Pair it with the curly staff

The `staff-ripple` Lexicon entry draws the curly lines; it does **not** hide
the real staff. Hide the real lines with the window above over the same
`staff_x` range. The `staff-ripple` span ends at the source position at the
range's end; if `stop_moment` cannot be counted (tuplets, repeats, voices or
grace notes), pass the exact `stop_line`/`stop_character` at the note
boundary. Do **not** fall back to the end of the bar: that makes the curly and
hidden span longer than the selected range.

For a range entirely at system boundaries, `\stopStaff`/`\startStaff` can be
used, but it still hides a segment, not an arbitrary x window. Use the
`StaffSymbol` window whenever either edge is inside a system.
