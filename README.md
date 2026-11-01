# Pondside

A native macOS notation environment on the LilyPond engine. The score is a
plain `.ly` file: diffable, git-versionable, and editable by any tool or
agent with no API at all. Pondside watches it, engraves it, and links every
glyph back to the characters that produced it.

> Zero lock-in: Pondside stores nothing but your LilyPond source. Stop using
> it tomorrow and you lose nothing.

The full plan, the schemas, and the parts of the brief I'd change are in
**[docs/DESIGN.md](docs/DESIGN.md)**.

## Status

Editing, multi-file scores, the interface, instant feedback (warm daemon, provisional marks, the Notation Lens,
the render cache), Engraving Settings, cue timing for SuperCollider, the CLI, MCP server and socket, and the
Lexicon with its graphics kit and agent workflow are built. CI builds and tests everything on Linux and macOS.
`docs/DESIGN.md` §9 lists what remains.

- **Open and engrave.** Open a `.ly` file. It is engraved by the LilyPond
  the installer put in place, or one you already have, detected on `PATH`,
  Homebrew, MacPorts or `/Applications`.
- **Point-and-click both ways.** Click a glyph to select its source; move
  the caret to highlight the glyph; drag a rectangle to select a span.
- **Multi-file scores just work.** Clicking a note that lives in an
  `\include`d file opens that file in the source pane. Every file in the
  include graph is watched, autosaved and undoable on its own. Pondside
  keeps point-and-click on even when a file says `\pointAndClickOff` (as
  musicxml2ly output does), and it never edits your file to do so.
- **Edit in the score.** Keyboard note entry turns into minimal text
  edits. Only the characters that must change do, and other notes keep
  their pitch and duration, even in `\relative`. ⌘Z undoes score and text
  edits alike, in order.
- **Never lose work.** Edits autosave after 250 ms and re-engrave. If
  another tool writes a file, the change is merged as a minimal diff so
  your caret stays put.
- **Instant Notation Lens.** The first keyboard edit opens a temporary,
  blurred overlay with a continuously scrolling staff strip around the
  cursor, engraved immediately from an in-memory MusicXML window. LilyPond
  still renders the authoritative page behind it; the lens closes when that
  render lands. Escape closes only the lens.
- **Two keys to everything.** Press Space in the score (⌥Space anywhere)
  and the hint bar lists what can follow: `g` go, `a` add, `e` edit, `v`
  view, `p` pane, `w` workspace, `f` file, `h` help. `␣ a s` slurs the
  selection, `␣ g e` jumps to the next error, `␣ ␣` opens the palette.
  `⌘K` is the fuzzy palette (every row shows its keys), `⌘/` lists what
  you can do right now, and holding `⌥` shows the keys on the controls.
  Remap anything in `~/Library/Application Support/Pondside/keymap.txt`
  (`go.error = x`). A test fails the build if any command lacks a key or
  two chords collide.
- **Panes are frames, content is cargo.** `⌃⇥` cycles the focused pane
  through score, source, compiler output and a terminal, and `⌃1`…`⌃0`
  jump straight to one. The frames never move. `⌘1`…`⌘5` switch layouts,
  `⌘⌥S` saves a workspace (⌘⇧S stays Save As), and `␣ w o` opens one.
- **Fast recompiles.** A warm LilyPond process stays loaded for each open
  score, so a recompile skips LilyPond's startup: 10–20× faster on slow
  machines. It falls back to a fresh process if anything goes wrong.
- **Electronics cues.** `pondside cues score.ly` times every `\ecue` exactly
  as the MIDI plays (hidden `\playTempo` included). `pondside handlers`
  keeps a SuperCollider file of cue handlers in step with the score
  without touching your code, and `sc/Pondside` is a quark that plays the
  mockup and fires them on SuperCollider's clock.
- **The Lexicon.** `\lexicon "timed-fermata" #'((seconds . 6)) { g'1 }`:
  reusable, parametric notation with typed, range-checked params, in
  three scopes (core, user, project). Entries can carry a sound, which
  places a cue. Agents browse it in tiers: `pondside lexicon list` or the
  MCP resources.
- **For agents.** `pondside mcp` is an MCP server: check, query (events
  with resolved absolute pitches), render, cues, Lexicon checks, and the
  Lexicon as resources. Opening a score writes `.mcp.json` and
  `opencode.json` beside it, so `claude` or `opencode` typed in the
  terminal pane finds the server with no setup. See [docs/API.md](docs/API.md).
- **Export.** `⌘E` exports a PDF with point-and-click disabled, then checks
  the output for local filesystem paths.
- **Mockup audio.** After each good engraving the app renders `score.wav`
  beside it in a separate process (`pondside mockup`: MuseScore with Muse
  Sounds when installed, else fluidsynth), for in-app audition and the
  SuperCollider quark. No `\midi` block needed: Pondside generates the
  playback (repeats, tremolos and trills played out, `\articulate`,
  instruments from staff names), and cue times follow the same music
  ([docs/API.md](docs/API.md#playback)).

### Score keys

Keys are LilyPond wherever LilyPond has an answer.

| Keys | Effect |
|---|---|
| `a`–`g` (`h`) | insert that note after the selection: nearest octave, the key's accidental |
| `r` | insert a rest |
| `1 2 4 8 16 32 64 128` | duration, as in LilyPond; changes the selection and arms the next note |
| `.` | toggle dot |
| `↑` `↓` | diatonic step · `⇧` octave · `⌥` chromatic |
| `←` `→` | previous / next object · `⇧` extends |
| `( ) ~ [ ]` | slur, tie, beam: toggled on the selection |
| `-.` `->` `^-` `_1` … | articulations and fingerings, exactly as typed in LilyPond |
| `\trill` `⏎` | any post-event command, typed as in LilyPond |
| `⌫` | delete |
| `⎋` | cancel / deselect / disarm |
| `⌘L` / `Space v y` | open the Notation Lens around the selection |
| `Space` | leader: chords such as `␣ a s` (slur), `␣ g e` (next error), `␣ g c` (go to cue), `␣ ␣` (palette) |
| `⏎` | edit in source |
| `⌘J` | switch between score and source |
| `⌘⇧]` `⌘⇧[` | next / previous file |

## Install

Download `Pondside-<version>-arm64.pkg` and double-click it. The first
time, macOS refuses to open it because it is not notarized: open
**System Settings → Privacy & Security**, click **Open Anyway** beside the
Pondside message, and confirm. The installer then puts Pondside in
Applications with LilyPond, FluidSynth and a SoundFont. Its
**Customize** page has checkboxes for the command-line tool, FluidSynth,
SuperCollider and MuseScore Studio; the last two are downloaded from their
projects during installation. Pondside opens without a further prompt.

## Build

Requires Swift 6 (Xcode 16+) and macOS 14+ on Apple Silicon for the app.
The portable modules and the CLI also build on Linux.

```sh
swift build                      # everything (the app only on macOS)
swift test                       # integration tests run if LilyPond is installed
scripts/make-app.sh              # → .build/Pondside.app
scripts/make-installer.sh        # → .build/Pondside-<version>-<arch>.pkg (app + LilyPond + FluidSynth)
open .build/Pondside.app --args "$PWD/path/to/score.ly"   # open runs the app from /
```

## CLI

```sh
pondside doctor                  # every LilyPond found, with version and origin
pondside check score.ly --json   # compile, report diagnostics
pondside render score.ly --format pdf --out build/
pondside links score.svg --json  # point-and-click map of a canvas SVG
pondside watch score.ly --on-change 'pondside render score.ly'
pondside cues score.ly --format cues     # seconds<TAB>bar<TAB>cue N, for SuperCollider
pondside handlers score.ly --scd cues.scd
pondside lexicon list                    # tier 0 of the Lexicon
pondside mcp                             # MCP server on stdio (claude mcp add pondside -- pondside mcp)
pondside agents                          # .mcp.json + opencode.json here, for agents started in this folder
```

Everything the CLI and MCP server offer is documented in [docs/API.md](docs/API.md).

## Layout

| Module | Platform | Role |
|---|---|---|
| `PondsideCore` | portable, stdlib only | lossless LilyPond CST, music model (pitches, durations, relative octaves), minimal-diff score editor, note input |
| `PondsideEngrave` | portable | toolchain detection, LilyPond driver, include graph, SVG scene, diagnostics, watcher, event oracle |
| `PondsideTiming` | portable | timing dump → stepped tempo map → cue times (cues.json), `.scd` handler sync |
| `PondsideLexicon` | portable | Lexicon entries and scopes, the graphics kit, skills, `pondside.toml` |
| `PondsideBridge` | portable | MCP server, app socket, score context, graphic edits |
| `PondsideCLI` | portable | `pondside` |
| `PondsideUI`, `PondsideApp` | macOS | AppKit front end |

CI builds and tests the portable modules on Linux and everything on macOS.
`scripts/check-seam.sh` rejects Apple-only imports below the seam.

## Licence

Pondside is free software under the [Apache License 2.0](LICENSE): use,
change and redistribute it however you like, commercially or not. Keep the
[NOTICE](NOTICE) with any copy or derived work, and please acknowledge the
project ("Made with Pondside"); [CITATION.cff](CITATION.cff) has a citation.
GNU LilyPond, SuperCollider and the other programs Pondside runs or bundles
keep their own licences: see [ACKNOWLEDGEMENTS.md](ACKNOWLEDGEMENTS.md).
