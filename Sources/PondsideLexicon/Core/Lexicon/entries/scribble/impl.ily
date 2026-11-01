% scribble: short strokes at random angles in a band.
#(define-graphic! "scribble"
  (lambda (g p)
    (let* ((rs (g-random g)) (step 0.5) (len (assq-ref p 'length))
           (spread (* (assq-ref p 'spread) (/ 3.141592653589793 180))))
      (append-map
       (lambda (k)
         (let* ((u (* k step)) (q (g-q g u))
                (h (max 0 (env-at (assq-ref p 'height) q)))
                (c (env-at (assq-ref p 'centre) q))
                (n (inexact->exact (floor (+ (* (max 0 (env-at (assq-ref p 'density) q)) step 2 h) (random 1.0 rs))))))
           (map (lambda (i)
                  (let* ((x (+ u (g-rand rs 0 step))) (y (+ c (g-rand rs (- h) h)))
                         (a (g-rand rs (- spread) spread))
                         (dx (* 0.5 len (cos a))) (dy (* 0.5 len (sin a))))
                    (list 'stroke (list (cons (- x dx) (- y dy)) (cons (+ x dx) (+ y dy))) (assq-ref p 'thickness))))
                (iota n))))
       (iota (inexact->exact (ceiling (/ (g-width g) step))))))))
