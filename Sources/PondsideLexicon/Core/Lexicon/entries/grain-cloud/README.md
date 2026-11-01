# grain-cloud

A grainy texture: seeded dots in a band. The band's half-height and centre
are envelopes over the span, so it can swell, pulse or drift. Generalized
from the grains in bars 4–31 of *…as the wind whispers sweet nothings*.

- "Expanding and contracting three times": `(height . (swell 3 0.5 4))`.
- "Thinning out": `(density . 0.2)`; "gradually denser": `(density . (linear 0.1 1.5))`.
- Keep clear of the music on the staff: `(avoid . (note-head-interface accidental-interface))`.
- Change `seed` for another drawing with the same character.

Pitfall: density is per square staff space, so a tall band has many more dots
than a thin one at the same density.
