# Acknowledgements

Pondside stands on the work of these projects. Pondside's own code is
under the Apache License 2.0 (LICENSE, NOTICE); the projects below keep
their own licences.

## Programs Pondside runs

Pondside starts these as separate programs and talks to them through files,
pipes and OSC. It does not link them, so their licences cover them, not
Pondside. Where the installer bundles one, it ships that program's licence
and says where its source is (the installer's Licences page); the pinned
versions are in `scripts/installer/versions.env`.

| Project | What Pondside uses it for | Licence | Bundled by the installer |
|---|---|---|---|
| [GNU LilyPond](https://lilypond.org) | engraving every score; the timing and MIDI behind cues and the mockup | GPL v3 or later | yes (built from source on Apple silicon) |
| [SuperCollider](https://supercollider.github.io) (sclang, scsynth) | the patch, live electronics, the offline mix | GPL v3 or later | yes: a headless build (sclang and scsynth, no Qt); the full app with its IDE is optional |
| [FluidSynth](https://www.fluidsynth.org) | the mockup when MuseScore isn't installed | LGPL v2.1 or later | yes (static build) |
| [libsndfile](https://libsndfile.github.io/libsndfile/) | sound files, inside FluidSynth | LGPL v2.1 or later | yes |
| [GeneralUser GS](https://github.com/mrbumpy409/GeneralUser-GS) by S. Christian Collins | FluidSynth's instruments | its own licence (free use; shipped with it) | yes |
| [MuseScore Studio](https://musescore.org) (Muse Sounds) | the mockup's instruments | GPL v3 | optional (downloaded when ticked) |
| [Claude Code](https://claude.com/claude-code), [opencode](https://opencode.ai) | the agents that carry out lens requests | their vendors' terms | optional (installed by the vendors' scripts) |

## Libraries Pondside is built with

| Library | Licence |
|---|---|
| [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) by Miguel de Icaza (and the xterm.js authors) | MIT |
| [swift-sheet-music](https://github.com/jiyimeta/swift-sheet-music) by Kiichi Ito, with its dependencies swiftysynth (MeltySynth, MIT), swift-wirelet, swift-java-jni-core, swift-syntax and swift-argument-parser | MIT; Apache 2.0 |

## Ideas and code

- The SuperCollider Lexicon's effects are adapted from the sc-pattern-fx
  skill's effects library.
- The Lexicon's graphic entries generalize the graphics of *…as the wind
  whispers sweet nothings*.
