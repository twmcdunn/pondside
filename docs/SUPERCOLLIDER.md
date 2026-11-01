# SuperCollider in Pondside

This document covers everything Pondside writes into, or expects from, a
piece's SuperCollider code:

- the patch it starts;
- how that patch is played live and rendered offline;
- the older quark file;
- what it takes to bring a patch written elsewhere into this shape: what
  Pondside migrates by itself, and what a person or an agent has to do.

CLI, MCP and file formats are in docs/API.md.

## Files

```
score.ly, *.ily             the score (the project's root)
renders/score.wav           the mockup: `pondside mockup`, after every good engraving (⌘⇧P plays it)
renders/score.cues          its cue times: seconds<TAB>bar<TAB>cue N
renders/score.mix.wav       the patch rendered against the mockup: `pondside mix`, after each mockup (⌘⌥P)
patch/score.scd             the patch: the composer's
patch/dependencies/pondside.scd   the engine: Pondside writes it and keeps it current
patch/dependencies/sc-lexicon.scd the SuperCollider Lexicon entries the patch uses: Pondside writes it (sc_lexicon_add)
patch/score.patch.md        the patch doc: outline rebuilt from the code, and notes on intent (the patch agent's memory)
patch/dependencies/…        the patch's own dependencies; resources it uses sit beside it in patch/
```

Names follow the score's root file (`quartet.ly` gives `patch/quartet.scd`,
`renders/quartet.wav`, …). `[supercollider] handlers = "path.scd"` in
`pondside.toml` names another patch.

## The patch

A patch is the composer's code with three things from Pondside. Its first
line contains `// @pondside patch`.

```supercollider
// @pondside patch for score.ly. Run each ( … ) block with ⌘↩, a line with ⇧↩.
(
~mode = \mockup;   // \mockup: the mockup plays and the cues fire on time; \live: the mic, you fire each cue
"dependencies/pondside.scd".loadRelative;
)

… the composer's code: SynthDefs, buffers, effects (on the performer: In.ar(~live)) …

// Cues: ~cue[\cueN] runs at cue N, as a routine (wait, fork and patterns work).
(
// @pondside cues
// @pondside cue cue-12 · bar 42 beat 1 · 133.333 s
~cue[\cue12] = { |cue|
	… the composer's code …
};
// @pondside end cue-12
)

// Run
~triggerCue.();      // cue 1 starts the piece; after that, each call is the next cue
~triggerCue.(12);    // start at (or jump to) cue 12: the cues before it run at once
~stop.();
```

**Running it.**
- **Mockup:** with `~mode = \mockup`, run the first block (it also loads the engine), your setup, and the cue block. Then `~triggerCue.()` starts the piece: the mockup plays, and every cue fires at its time. `~triggerCue.(12)` starts at cue 12 instead, with the cues before it run at once, so the music is in the right state.
- **Live:** `~mode = \live`. The first `~triggerCue.()` starts the piece at cue 1 (the mic becomes the live signal), and each call after that fires the next cue, typically from a pedal in a live-only block:
  ```supercollider
  (
  // @pondside live
  MIDIdef.noteOn(\pedal, { ~triggerCue.() });
  )
  ```
  `~triggerCue.(12)` catches up to cue 12.
- `~stop.()` ends the piece, and the routines and patterns its cues started. ⌘. does too.
- **⌘⌥P** in the score plays the rendered mix without running anything.

A block whose first line is `// @pondside live` runs live only; Pondside's
mix skips it. That is where windows, MIDI/OSC triggers and recording go.

After each mockup Pondside adds a stub for every new cue, unless the
composer has already written that cue's handler outside the markers. It
also updates each header line, and comments out (`//~ `) the handlers whose
cue has left the score; if the cue comes back, the handler is restored
exactly. Pondside never changes code between the markers.

## The engine (`patch/dependencies/pondside.scd`)

Pondside writes the engine and rewrites it whenever it changes; don't edit
it. Its names are few, so it doesn't collide with a patch's own:

| Name | What |
|---|---|
| `~mode` | `\mockup` or `\live` |
| `~cue` | the handlers, by name: `~cue[\cue12]` (`"12"` → `\cue12`, `"FxSwell"` → `\fxSwell`) |
| `~live` | a mono audio bus, the live signal: the mockup (both channels summed, ×0.5) in mockup mode, `SoundIn.ar(0)` live. Effects read `In.ar(~live)` |
| `~triggerCue.(cue)` | no argument: cue 1 if the piece isn't playing, else the next cue. With a cue (`12`, `"12"`, `\cue12`): start there, or jump there. In mockup mode it restarts from that cue; live, it catches up through the cues not run since the last one. Going back fires just that cue |
| `~stop.()` | stops the clock (and with it every routine and pattern a cue started), puts the old default clock back, frees the source |
| `~pondside` | the engine's own state and functions, read by key (`~pondside[\play]`): the cue list (read from `../renders/<name>.cues`), the mockup buffer, the score's clock (a `TempoClock` whose beats are the score's seconds; it is `TempoClock.default` while playing), the source synth (`\pondsideMockup` or `\pondsideMic`) |

## The offline render (`pondside mix`)

After each mockup the app runs `pondside mix score.ly`, which writes an
sclang script (never saved) that does the following:

1. Replaces the server's address with a recorder. Every message is kept
   with the score time it was sent at: a bundle's latency is added, and
   anything not sent from the score's clock is placed at the last score
   time. The recorder answers `/sync`, `/done` and `/b_query` (from the
   sound file) as scsynth would, so `s.sync`, `Buffer.read(…, action:)` and
   `b.numFrames` work.
2. Marks the server as booted, with the mockup's sample rate
   (`s.sampleRate`). `s.boot` does nothing and `s.waitForBoot` runs its
   function. Like a remote server, `s.reboot` and `s.quit` only post a
   line.
3. Sets `thisProcess.nowExecutingPath` to the patch, so `"x.wav".resolveRelative`
   finds files beside it.
4. Runs the top-level blocks one at a time, as a person runs them, except
   `// @pondside live` ones. After each block it pauses, so the block's
   deferred work (a `waitForBoot` body, a fork) happens before the next one,
   and it sets `~mode = \mockup`. During setup, `s.sync` returns once setup
   goes quiet, as a real sync returns only after the server has done
   everything sent before it (so a buffer loader's `onComplete` has run).
   The piece starts (`~triggerCue.()`) only when no sync is waiting and nothing
   has been sent for 0.2 s.
5. Plays the score on the render's own clock (`PondsideRenderClock`,
   loaded from the render's own include path, alongside the user's). Its
   beats are seconds (tempo 1), and it runs every scheduled task in time
   order, same-time ones in the order they were scheduled, as fast as it
   can. So `wait`, patterns, and code timed by `thisThread.seconds` (glides,
   swells, LFOs) all follow score time, and the piece renders in seconds.
   The engine takes it with `~clock = ~renderClock ?? { TempoClock(…) }`. An
   older engine without that line gets its TempoClock run a million times
   faster instead; there `thisThread.seconds` barely moves, so code timed by
   it stays at its start. `pondside patch --fix` replaces such an engine.
6. At the mockup's end + 5 s, writes the recorded messages to an OSC
   score, in the order they were sent. Every SynthDef goes to a
   `.scsyndef` file loaded with `d_loadDir`, and a `d_recv` the patch sent
   itself is loaded from a file with `d_load`, because a def's bytes in a
   bundle can exceed sclang's packet limit. Bundles that share a time are
   split at about 8 KB. scsynth then renders the score in non-real time
   against the mockup into `score.mix.wav`. A score that can't be written
   fails the render, and the last good mix is kept; the output replaces the
   old mix only when the render finishes.

What the render does about errors and what it can't hear:

- **An error before playback starts** (in setup) fails the render, and the
  last good mix stays.
- **An error in a cue** stops that cue only, as it would live; `pondside
  mix` and the MCP `mix` tool list these errors.
- **A cue that calls `~stop.()`** ends the electronics there.
- **Not heard in the mix:**
  - code timed by `SystemClock` or `AppClock`;
  - raw OSC (`sendRaw`);
  - `// @pondside live` blocks;
  - loose lines.

A render of a few minutes of score takes a few seconds, most of which is
starting sclang and scsynth.

## Parts the MIDI can't play (improvisations)

`\improvisation 1 { … }` (playback.ily, or the older workflow's own
`\improvMark`) is silent in the MIDI and marks `improv 1` and `improv end`.
`pondside mockup` (the app runs it after every engraving) fills those
passages in one of two ways:
- **Recordings:** for "improv 1" it uses `improv1.wav` (also `improv 1.wav` or
  `improv-1.wav`). It looks in `[audio] parts`, else in `improv/`,
  `resources/improv/`, `parts/` or `resources/parts/` beside the score (or the
  same folders in `patch/`). The
  recording starts at the mark. If it runs on, it fades out 0.3 s before the
  next mark of its kind ("improv end", "improv 2"). It is resampled if its
  rate differs, and a mono file plays in both channels. With parts, the
  mockup is written as 32-bit float.
- **A script:** `[audio] hook = "improv/render_improvs.scd"`. Pondside runs
  `sclang hook score.wav marks.txt out.wav partsDir` (the `export_piece.sh`
  convention), where `marks.txt` holds the `[audio] hook-marks` marks
  (default `improv`) as `seconds<TAB>bar<TAB>text`. The script writes the
  mockup with the parts in it to `out.wav` and may write each part to
  `partsDir`. If it fails, the mockup command fails with the script's last
  output.

Either way, the patch's mix (`score.mix.wav`) and ⌘⇧P hear them, because
both play the mockup.

## The patch agent

A request at a point in the score about the electronics goes to the patch
agent: ⇥ from the lens's request line (lens → score request → patch
request → lens), or Edit › Ask the Patch Agent… (␣ e p). It runs like the
score's agent (Claude Code or opencode, chosen in Settings), in a
conversation of its own kept between requests (␣ e N starts a new one), with
its MCP server in the patch role (`pondside mcp --role patch`): it sees the
patch tools only and can edit only the patch's `.scd` files.

What it is given, in the first message (`patch_context`):
- the cue at or before the point, its handler (`~cue[\cueN]`) numbered
  as in the file, and the cue's window until the next cue;
- what the handler touches: the SynthDefs, patterns, buses and functions
  it names, with their code when short;
- the pitch collections around the point (pitch classes and MIDI notes);
- the patch doc, every cue, and the SuperCollider Lexicon, one line per entry.

What it does (skill `sc-patch-editing`): one `edit` of the handler (no
reading first), `sc_lexicon_add` when it needs an entry, `patch_check` with
the cue (renders the mix: errors, and the window's levels of the mix and of
the electronics alone, before and after), then `patch_note` on what it
changed. Its reply is one line. ⌘Z (␣ e z) restores the patch files the
request changed; the mix re-renders either way.

**The patch doc** (`patch/score.patch.md`) is its memory: an outline of
every SynthDef, pattern, proxy, bus, buffer, function, cue handler and live
block with `file:lines`, rebuilt from the code whenever it is read, and a
note on intent under each, kept across rebuilds. A note records its code's
hash and is flagged stale when that code changes. It is plain Markdown:
read it, and edit the notes, as you like. The format is in docs/API.md.

## The SuperCollider Lexicon

Effects and pattern parts a patch can use, in
`Sources/PondsideLexicon/Core/SCLexicon/entries/<id>/` (`entry.toml`,
`impl.scd`, `README.md`); a project adds its own in `SCLexicon/entries/`
beside the score. `sc_lexicon_add` writes the entries a patch uses, and what
they require, into `patch/dependencies/sc-lexicon.scd` (its second line
lists them: `// @pondside sc-lexicon reverb cloud …`) and loads it after
the engine. Don't edit that file: copy an entry into the patch to change it.

| Kind | In SuperCollider | Entries |
|---|---|---|
| effect | `\lx_<name>`: an insert on a pattern's bus (`Pfx`, `Pfxb`, `~lx[\withFx]`), reads and replaces `out`; `\lx_<name>_mono`: reads a mono bus `in` (`~live`), writes stereo to `out`. Both take `mix`, `amp`, `gate`, `release` (tails ring on after `gate 0`) and the effect's params | `lpf`, `drive`, `ring-mod`, `decimate`, `feedback-delay`, `fdn-tail`, `reverb`, `granulator` |
| synth | `\lx_<name>` | `grain` |
| pattern | `~lx[\<name>]`, a function | `pitches` (a collection's notes in a range), `glide` (a value over seconds, then held), `density` (`\dur` from one rate to another), `cloud` (a grain Pbind on a collection), `with-fx` (a chain of effects on a pattern) |

```supercollider
// cue 12: the flute through a reverb, a cloud on the chord thickening over 20 s
~verb = Synth(\lx_reverb_mono, [\in, ~live, \mix, 1, \room, 0.9], addAction: \addToTail);
~cloud = ~lx[\withFx].(~lx[\cloud].([0, 3, 7], ~lx[\glide].(2, 30, 20)), [[\reverb, (mix: 0.4)]], 6).play;
// cue 14
~cloud.stop; ~verb.release(4);
```

## Opening a patch in the SuperCollider IDE

Every `sclang` started from SuperCollider.app registers with macOS as
SuperCollider.app. That includes the SuperCollider pane's interpreter, each
mix render, and any stuck one. While one runs, a double-clicked `.scd` goes
to it and fails ("SuperCollider cannot open files in the Plain Text
format"). SuperCollider ▸ Open in SuperCollider IDE (␣ s v) launches the IDE
itself with the pane's file (else the patch), which works either way. A
second IDE hands the file to one already running. From the Finder, quit the
pane's interpreter first, or use the IDE's File ▸ Open.

## The quark file (older)

Before patches, Pondside wrote a handler file for the Pondside quark
(`sc/Pondside`):

```supercollider
p = Pondside("/path/to/folder", "score");
p.on(\cue12, { |cue| … });   // between the same // @pondside markers
p.play;
```

`pondside handlers` still keeps such a file in step: `p.on` stubs, and the
`p = Pondside(…)` line if it's missing. It isn't rendered into a mix, and
`pondside patch --fix` converts it.

## Migrating an existing patch

Pondside's standards for a patch:

1. Its first line has `// @pondside patch`, and it is `patch/score.scd` (or the
   file `pondside.toml` names).
2. It has the mode, engine (current), cue and play sections.
3. Its own names don't collide with the engine's.
4. The performer's sound comes from `In.ar(~live)`, not a hardware input.
5. Everything the piece needs is in `( … )` blocks; nothing that matters is
   in loose lines.
6. What happens at a moment of the piece happens in that cue's handler, not
   in a timeline started at setup or by `SystemClock`/`AppClock`.
7. Cues are fired by the engine (in mockup mode) or by `~triggerCue`
   (live), whatever the trigger: a MIDI pedal, OSC, a key or a button.
8. Windows, triggers' setup and recording are in `// @pondside live`
   blocks.
9. There is no second timing pipeline: no `piece.cues`, `export_piece.sh`
   or `lily_timing.py`. Pondside writes the cue times, and the engine fires
   the handlers.

These rules also apply to the files the patch loads (`"x.scd".resolveRelative.load`,
`loadRelative`, `load("…")`, followed recursively, outside live-only
blocks), because their code runs in the mix too. The audit reports their
lines as `dependencies/x.scd:12`. Migration puts its marks in them, as
comments only, and keeps each one first as `.before-pondside.scd`.

### What Pondside does by itself

`pondside patch --fix`, the MCP tool `patch_migrate`, and the app's
refactor dialog (`PatchMigration.migrate`) do the following:

| Standard | Change | Safe because |
|---|---|---|
| 1 | The patch moves to `patch/<name>.scd`, with every file and folder it refers to by a relative path (`"dependencies/x.scd".loadRelative`, `"resources/y.wav".resolveRelative`); a folder that is already there is merged. Paths to what stays (the score's own files, anything outside the folder) gain a `../`. The original is kept as `patch/<its name>.before-pondside.scd` and leaves the root; old renders beside the score (`<name>.wav`, `.cues`, `.mix.wav`) move into `renders/`. | Every path still points where it did. |
| 1, 2 | The composer's code stays as it is. Pondside adds a header, a first block (`~mode`, and the engine's load line) on top, and the cue block (a stub per cue) and run lines at the end, and writes the engine to `patch/dependencies/pondside.scd`. | Nothing is removed; the code runs after the engine is loaded, as it would have run alone. |
| 1, 6 | Quark handlers (`p.on(\x, { … })`) become `~cue[\x] = { … }` and move into the cue block. `p = Pondside(…)`, `p.play` and `p.stop` lines are commented out. | The handler function is the same. |
| 3 | The composer's environment variables with the engine's few names (`~mode`, `~cue`, `~live`, `~triggerCue`, `~stop`, `~pondside`) are renamed (`~stop` → `~myStop`). The renames are listed. | It is a whole-token rename. |
| 4 | `SoundIn.ar(0)` becomes `In.ar(~live)`. | Live, `~live` is input 0, so nothing changes; in mockup mode it hears the mockup. |

The render itself takes care of `s.boot`, `s.waitForBoot`, `s.sync`,
buffer actions and relative paths (above), so none of these needs
migrating.

### What a person or an agent does

`migrate` puts a `// pondside: …` comment on each line it can't fix, and
the audit doesn't report a marked line again. The `sc-patch-migration`
skill (MCP prompt; `/mcp__pondside__sc-patch-migration` in Claude Code)
covers each kind:

| Mark | Why it can't be automatic |
|---|---|
| defines something but only runs by hand (a loose `SynthDef`, buffer, `~x = …`, `.load`) | Whether it's setup or a leftover is the composer's intent. Loose test lines that only call or set things (`~pb1.set(…)`) are fine and aren't reported. |
| assigns an engine name (in a patch or a loaded file) | Renaming inside loaded files touches code shared beyond the patch, so it's left to the agent. |
| a second timing pipeline | What depends on the old cue file has to move to the handlers. |
| starts when its block runs (`.play`, `fork` at setup) | A drone meant to sound from the start is right as it is. A timeline has to be split at the score's cues, which means knowing which event belongs to which cue. |
| timed by `SystemClock`/`AppClock` | Absolute times have to become cue-relative waits, so a time must be mapped to a cue. |
| a trigger (MIDI, OSC, keys, buttons) | What the trigger did (its own cue counter, a `switch`, a list of functions) must be mapped onto the score's cues. Usually this is most of the thinking, but only a few lines of code. |
| opens a window; records to disk | Moving code between blocks changes when it runs live. |
| reads another hardware input | Which input feeds `~live` is the composer's decision. |

### How much is automatic

The automatic part is the structure: where code lives, what it's called,
how the patch is played, rendered and kept in step with the score. That
covers the following patches completely, or almost:

- **A Pondside quark file:** all of it.
- **A patch already organised as setup blocks plus cue functions, with no
  timing of its own:** all of it apart from the cue mapping, which is
  usually re-pointing a list of functions to `~cue[…]`.

The manual part is timing: deciding when things happen relative to the
score. For the common kinds of hand-written patch:

| Kind of patch | Automatic | Left |
|---|---|---|
| Quark handler file | 100% | — |
| Setup blocks + cue functions fired by MIDI/GUI | structure, names, inputs: most lines | mapping the trigger to `~triggerCue`/`~cue[…]`, moving GUI/MIDI into live blocks: few lines, some thought |
| One big timeline (`Routine { … 10.wait; … }`) | structure, names, inputs | splitting the timeline at the score's cues: most of the musical work |
| Fixed media plus a few live effects | structure, inputs | the playback start, as a cue |

An agent with the skill does the manual part in one pass. It asks only
when the score has fewer cues than the patch, or when a time could belong
to two cues.

### In the app

When a score opens, Pondside checks its patch, or, if there isn't one, the
folder's likeliest `.scd` (the most `SynthDef`, `Synth`, `.play`, `p.on`,
`Buffer.` and `waitForBoot`). A starter nobody has edited yet doesn't hide
a custom patch. If anything isn't to standard, a dialog lists what
Pondside does itself and what needs an agent:

- **Refactor with Claude Code** (or opencode) migrates the patch, then runs
  the agent unattended in the score's folder. The status bar shows that it
  is working; ␣ f m stops it. When it finishes, a sheet shows the agent's
  summary, the time, the cost (Claude reports it), and the marks left;
  **Undo Refactor** puts the patch back as it was. The mix re-renders
  either way.
- **Refactor Only** does the automatic part. The command for finishing
  in the terminal (`/mcp__pondside__sc-patch-migration`) goes to the
  clipboard.
- **Not Now** stays quiet until the file changes. File ▸ Make Patch
  Pondside-Ready… (␣ f m) asks again at any time.

Pondside ▸ Settings… (⌘,) chooses the agent:
Automatic (the first one installed: Claude Code, then opencode), Claude
Code, opencode, or Off. It looks for them on the login shell's PATH and in
their installers' usual places.

The unattended run (`AgentRun`; also `pondside patch score.ly --fix --agent
auto|claude|opencode`):

| | Claude Code | opencode |
|---|---|---|
| Command | `claude -p <prompt> --output-format json --permission-mode dontAsk --allowedTools "Read Edit Write Glob Grep mcp__pondside" --mcp-config <pondside> --strict-mcp-config` | `opencode run --format json --dir <folder> --auto <prompt>` |
| May | read and edit files in the folder, use Pondside's MCP tools; anything else is denied without asking | anything not explicitly denied (`--auto`): opencode can't be limited more narrowly from the command line |
| Result | the JSON's `result` and `total_cost_usd` | the text of the last step's events |

The prompt contains the sc-patch-migration skill itself, so nothing
depends on slash commands working without a person. It tells the agent not
to ask questions, to keep the code and the mark when something is the
composer's call, and to loop: `patch_audit` lists what is left (findings
and marked lines, loaded files included), and the MCP `mix` tool renders
the patch and returns its errors. The agent is done when both are clean.
Its final reply is at most three short lines.

The skill steers cue mapping towards one place per cue. Each old cue's
body moves into its `~cue[\cueN]` handler, and the old cue list, its
runner and its cue-time loading are deleted, rather than left behind a
dispatcher (`~cue[\cue3] = { ~myCue.(\cue3) }`). The agent's MCP server is the app's
own `pondside`, given by absolute path. For opencode, which reads
`opencode.json`, the app puts that `pondside` first on the agent's PATH.

On the custom patch in the tests (a waitForBoot setup, a timeline started
by hand, a cue window, a MIDI pedal, a SystemClock call, `s.record`),
Claude Code took 66 s and $0.51. It folded the setup into a block, moved
the timeline into cue 1 as waits, pointed the window and the pedal at
`~triggerCue.()` (then called `~next.()`), and moved them, the second input and recording into a live
block. The patch rendered with no marks left.

An MCP server can't make an agent run a skill. It offers the skill as a
prompt, which Claude Code shows as the slash command above, and its
instructions point agents at the skill when they see `// pondside:` marks.
