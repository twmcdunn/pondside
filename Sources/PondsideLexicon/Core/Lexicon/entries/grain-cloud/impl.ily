% grain-cloud: seeded dots in a band; density, height and centre are envelopes over the span.
#(define-graphic! "grain-cloud"
  (lambda (g p)
    (let* ((rs (g-random g))
           (step 0.25)
           (avoid (g-clear-of g (map (lambda (s) (if (string? s) (string->symbol s) s)) (or (assq-ref p 'avoid) '())))))
      (append-map
       (lambda (k)
         (let* ((u (* k step)) (q (g-q g u))
                (h (max 0 (env-at (assq-ref p 'height) q)))
                (c (env-at (assq-ref p 'centre) q))
                (density (max 0 (env-at (assq-ref p 'density) q)))
                ; expected dots in this slice, made whole with a random rounding
                (expected (* 4 density step 2 h))
                (n (inexact->exact (floor (+ expected (random 1.0 rs))))))
           (filter-map
            (lambda (i)
              (let ((x (+ u (g-rand rs 0 step)))
                    (y (+ c (g-rand rs (- h) h)))
                    (r (* (assq-ref p 'size) (g-rand rs 0.45 1.0))))
                (and (not (g-inside? avoid x y 0.25)) (list 'dot x y r))))
            (iota n))))
       (iota (inexact->exact (ceiling (/ (g-width g) step))))))))
