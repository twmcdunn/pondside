\version "2.26.0"
\paper { #(set-paper-size "a5") }

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

#(define (staff-line-windows windows)
   (let ((seen 0))
     (lambda (grob)
       (set! seen (1+ seen))
       (let ((w (assoc seen windows)))
         (if w
             (staff-line-gap grob (cadr w) (caddr w))
             (ly:staff-symbol::print grob))))))

\new Staff \with {
  \override StaffSymbol.stencil = #(staff-line-windows '((2 0.25 0.75)))
} {
  \time 4/4 c'1 d'1 \break e'1 f'1
}
