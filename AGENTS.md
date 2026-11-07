# AGENTS.md

Pondside is a macOS LilyPond notation app with a portable core, CLI and MCP
server. The `.ly` file is the only source of truth: the app watches and
rewrites it, and stores no score state elsewhere. The one thing it keeps
is a disposable cache of each score's latest engraving
(`PondsideEngrave/RenderCache`, in `~/Library/Caches/Pondside/Renders`),
shown on reopen while LilyPond engraves afresh.

Read `docs/DESIGN.md` before planning work: §0 has the principles, §7–8
the graphics kit and the agent workflow, §9 what remains, §11 Score
Setup (staves, and the cover/notes/legend in `front-matter.ily`), §13 pitch
collections (`\collection`, its kit `pondside-collections.ily`). CLI, MCP,
`cues.json`, `pondside.toml` and the RPC socket are documented in
`docs/API.md`; test coverage, gaps and the planned agent smoke test in
`docs/TESTING.md`; the SuperCollider patch, its offline render and patch
migration in `docs/SUPERCOLLIDER.md`. Pondside also keeps checkpoints of a score's files in a git
repository of its own under `~/Library/Application Support/Pondside/History`
(never the user's repo).

Graphic notation is Lexicon entries on the graphics kit
(`Sources/PondsideLexicon/Core/Lexicon/kit/pondside-graphics.ily`); the
skills agents follow are in `Sources/PondsideLexicon/Core/Skills/` and are
served by `pondside mcp`. A new graphic entry needs a compile check: render
it (the lexicon engraving tests do) and look at it. The SuperCollider
Lexicon (effects and pattern parts for the patch agent) is
`Sources/PondsideLexicon/Core/SCLexicon/entries/<id>/` (`entry.toml`,
`impl.scd`, `README.md`); `SCLexiconTests` compiles every entry in sclang.
The lens has two agents, the score's and the patch's, each with its own
MCP role (`pondside mcp --role graphics|patch`, docs/API.md). Skills must describe the
files Pondside writes (cue file, mockup, handlers, `lexicon.ily`), never a
parallel pipeline: change both together (docs/API.md, "Skills and the files
Pondside writes"; `SkillConsistencyTests`).

## Commands

```sh
./scripts/check-seam.sh          # after touching any portable source
swift build                      # portable modules; on macOS also UI/app
swift build --build-tests
swift test                       # engraving tests skip without LilyPond
swift test --filter PondsideCoreTests/KeyboardAuditTests
swift run pondside check score.ly
scripts/make-app.sh debug        # .build/Pondside.app (macOS only)
scripts/make-installer.sh        # .build/Pondside-<v>-<arch>.pkg; pins in scripts/installer/versions.env
open .build/Pondside.app --args "$PWD/path/to/score.ly"   # open runs the app from /
```

CI order is seam check → `swift build --build-tests` → `swift test
--skip-build`. There is no linter, formatter or codegen step.

## Prerequisites and platform

- Swift 6; macOS 14+ and Xcode 16+ for the app. On macOS the app's
  `swift-sheet-music` dependency needs Swift 6.2+ (CI and local builds use
  6.4.1 via `swiftly`); Xcode 16's and the Command Line Tools' 6.0 cannot
  resolve the package. `scripts/make-app.sh` picks `~/.swiftly/bin/swift`
  when present. Don't alternate toolchains on one `.build`: 6.0 cannot read
  the workspace state 6.4.1 writes.
- `swift test` on macOS needs a full Xcode toolchain. With Command Line
  Tools only it fails with `no such module 'XCTest'`.
- LilyPond must be installed for real engraving tests (PATH, Homebrew,
  MacPorts, `/Applications`, or `PONDSIDE_LILYPOND`).
- Linux CI builds and tests only the portable targets; UI/app compile
  errors are caught by the macOS job.

## Architecture and the portability seam

`Package.swift` is authoritative for the target graph.

- `PondsideCore` — lossless LilyPond CST/parser, music model, minimal-diff
  `ScoreEditor`, note input. **Swift stdlib only, not even Foundation.**
- `PondsideEngrave` — toolchain detection, LilyPond driver and warm
  daemon, include graph, SVG scene/geometry, diagnostics, watcher, timing.
- `PondsideTiming`, `PondsideLexicon`, `PondsideBridge` — tempo/cues,
  Lexicon, MCP and Unix-socket JSON-RPC.
- `PondsideCLI` — the `pondside` executable.
- `PondsideUI` / `PondsideApp` — AppKit front end; macOS-only and treated
  as the disposable shell.

Everything below `PondsideUI` must build on Linux. `scripts/check-seam.sh`
rejects Apple-only imports there and any `import Foundation` in
`PondsideCore`. Keep hit-testing, geometry and other logic in `Engrave` so
it stays portable and testable.

## Editing conventions

- Score edits are minimal `TextEdit`s over byte ranges. Do not re-print or
  re-emit the CST: tests assert `tree.reconstructed == text` and that
  inverse edits restore the file byte for byte.
- New user commands go in `Sources/PondsideCore/Commands/Catalog.swift`.
  `KeyboardAuditTests` fails if a command lacks a key/chord or two chords
  collide.
- Core Lexicon entries live in
  `Sources/PondsideLexicon/Core/Lexicon/entries/<id>/` as `entry.toml`,
  `impl.ily` and `README.md`. The folder name must equal `id`; the whole
  `Core` directory is a SwiftPM resource and is scanned at runtime, so new
  entries need no registry update.

## Testing quirks

- LilyPond integration tests use `XCTSkip` when it is absent, so a green
  run may have tested nothing about engraving. Check skipped tests before
  claiming success.
- `PONDSIDE_CORPUS=/path/to/lilypond/sources` enables the corpus
  round-trip/fuzz test (CI uses the 2.24.3 regression suite and snippets);
  it skips locally by default.
- `PONDSIDE_ORACLE_SEED` seeds the engraving oracle fuzz test; the default
  is deterministic.
- `Tests/Scores` is shared by path relative to `#filePath`, not through a
  test bundle. `Tests/PondsideEngraveTests/Fixtures` is copied via
  `.copy("Fixtures")` in `Package.swift`.
- CI runs against LilyPond 2.24.3 and 2.26.0; daemon/settings/SVG behavior
  differs between them, so don't assume one version.
- There are no UI tests; `PondsideUI` is only compile-checked on macOS.
