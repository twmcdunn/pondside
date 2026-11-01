# with-fx

Put a chain of effects on a pattern, on its own bus, with tails that ring after it stops.

Each effect is a `Pfxb` of the entry's insert SynthDef (`\lx_<name>`), so it processes only this pattern. Add each effect's entry too (sc_lexicon_add).
