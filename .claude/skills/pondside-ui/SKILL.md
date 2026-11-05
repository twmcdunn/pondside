---
name: pondside-ui
description: Design and review guidance for Pondside's macOS front end (PondsideUI, AppKit/SwiftUI) grounded in Apple's Human Interface Guidelines — overlays, panels, popovers, the Notation Lens, palettes, inspectors, status bar, colours, materials, motion, focus, keyboard and accessibility. Use this whenever you design, revise, critique or implement anything people see or touch in the Pondside app — look and feel, layout, animation, a new view, panel or overlay, colours or Theme.swift, dark mode, Escape/focus behaviour, or "does this follow best practices / the HIG" — even if the request only says "make the lens look better" or "tweak the overlay".
---

# Pondside UI design

Pondside is a keyboard-first notation editor: the user types LilyPond-style
note input and watches the page re-engrave. Good UI here is UI that never
interrupts that loop. Apple's HIG is the baseline; this file says how it
applies to Pondside, and `references/hig-macos.md` is the page-by-page digest
(read the relevant section when a decision depends on a specific rule).

## Working method

1. **Name the pattern first.** Decide what the thing *is* in HIG terms —
   popover, panel, HUD, sheet, inline status, content view — before
   choosing materials or sizes. Most look-and-feel problems are a wrong
   pattern (a modal look on a transient thing), not a wrong colour.
2. **Check the editing loop.** Ask: does it steal key focus? cover the
   caret or the music being edited? make the user wait on an animation,
   or on work done before the frame that shows the change? force a
   dismissal? Any "yes" needs a strong reason.
3. **Check the system settings matrix** before calling it done: light and
   dark appearance (see the Theme note below), Reduce Motion, Reduce
   Transparency, Increase Contrast, and a non-default accent colour.
4. **Verify visually.** UI has no tests here. Render offscreen to PNG or run
   the app (`scripts/make-app.sh debug`, then
   `open .build/Pondside.app --args "$PWD/Tests/Scores/invention.ly"`, after
   `pkill Pondside` so a stale instance isn't reused) and look at it. Never
   send synthetic keystrokes unless the Pondside window is confirmed
   frontmost — they land in whatever app has focus.
5. **Write down the decision** (DESIGN.md section for the feature) with the
   HIG rule it follows or knowingly departs from.

## Principles as they apply to Pondside

**All UI is instant** (DESIGN.md §0). A key, click or control shows its
result in the same frame. Nothing it triggers may wait on LilyPond, the
disk, a whole-project check or re-reading every file on the main thread:
show the expected outcome first (flip the toggle, apply the edit, stop
the progress the moment the outcome is known), do the slow work after
that frame or off the main thread, and if it disagrees take the change
back with the red edit-rejection notice (`EditRejectionFeedback`, or
`showRejection` in the lens), never a dialog. A wait the user must see is
a status activity (`statusBar.setActivities`), which only animates after
300 ms and ends when nothing is pending. Measure suspect work on a real
score in a release build before calling it cheap; tens of milliseconds
per keystroke is already too slow.

**Focus stays in the editor.** Overlays, previews and status views must not
become key or first responder unless the user clicks into a control that
needs typing. HIG: "Avoid changing focus without people's interaction."
Use non-activating views/panels; route Escape through the window's key
monitor.

**Transient means non-modal-looking.** Dimming and blurring the whole window
is the sheet idiom — it says "you must deal with this". A view that comes
and goes on its own (the lens, hover previews, provisional feedback) should
look like a popover or inline status: small, near what it describes, not
covering the caret or the passage being edited, the rest of the window
still readable.

**Frequent interactions get little or no motion.** Anything triggered per
keystroke should appear instantly or with a very short fade (≲ 0.1 s); no
slides, scales or blur-in. Exit fades can be a little longer when they
carry meaning (the render "settling" out of the lens), but must never block
input. Under `NSWorkspace.shared.accessibilityDisplayShouldReduceMotion`,
replace movement (e.g. scroll-to-centre animation) with an instant jump or
a fade.

**Materials by layer.** Engraved music is content with fine detail: put it
on an opaque surface, not glass. Materials/vibrancy belong to chrome that
floats over content. Under
`accessibilityDisplayShouldReduceTransparency`, swap any blur for a solid
fill; under `accessibilityDisplayShouldIncreaseContrast`, strengthen
borders/separators and use higher-contrast colours. Observe
`NSWorkspace.accessibilityDisplayOptionsDidChangeNotification`.

**Colour carries one meaning each, never alone.** In Pondside: accent =
selection/target, warning = unsupported/degraded, error = failure. Pair
colour with shape or text (a caret, halo, badge label). Selection should
respect the user's system accent where practical
(`NSColor.controlAccentColor`, `selectedContentBackgroundColor`,
`unemphasizedSelectedContentBackgroundColor` when not key).

**White paper in a dark app glows.** The page and lens paper sit in a dark
chrome; soften or slightly dim white paper so it doesn't dominate (HIG Dark
Mode: "Soften the color of white backgrounds").

**Passive status, near the thing.** Unsupported-feature notices, render
state and similar are passive feedback: show them small and close to the
content they describe, in words, not as alerts. Avoid critical information
at the very bottom edge of the window.

**Text.** System font, 13 pt body, 11–12 pt secondary, never below 10 pt,
no light weights. Use `Theme.bodyFont` / `Theme.secondaryFont`.

**Keyboard.** Esc cancels/dismisses the current transient thing. New
commands go in `Sources/PondsideCore/Commands/Catalog.swift` (the keyboard
audit test enforces unique chords). Don't repurpose standard macOS
shortcuts; Command is the main modifier.

**Accessibility.** Give custom views an accessibility role and label (e.g.
the lens: "Notation preview, bars 3–7, upper"). Contrast ≥ 4.5:1 for text,
7:1 for small custom text.

## Pondside specifics

- `Sources/PondsideUI/Theme.swift` defines a fixed dark palette
  (background, chrome, text, secondaryText, accent, warning, error, paper).
  The HIG prefers following the system appearance and semantic colours;
  this is a known, deliberate departure. Don't silently switch the app to
  dynamic colours — raise it with the user if a design depends on it. New
  colours go in Theme, with an increased-contrast variant if they carry
  meaning.
- `PondsideUI` is the disposable shell: keep logic (geometry, hit-testing,
  what to show) in portable modules, and only presentation in UI.
- The Notation Lens (`Sources/PondsideUI/Lens/`, DESIGN.md "Instant
  Notation Lens") is a *loading placeholder* in HIG terms: "Show something
  as soon as possible", replaced when the real render arrives. Judge its
  design against Loading + Popovers + Motion, not Sheets. It also has an
  explicit-open mode (view.lens), which must dismiss on Esc, not a timer.

## Review checklist

- [ ] Instant: the result shows in the same frame; slow work is after it or
      off the main thread, with optimistic display and a red take-back

- [ ] Pattern named (popover / panel / inline / sheet) and its HIG rules met
- [ ] Key focus and caret untouched; typing never waits on it
- [ ] Doesn't cover the caret or the passage being edited
- [ ] Motion minimal for frequent triggers; Reduce Motion handled
- [ ] Reduce Transparency and Increase Contrast handled
- [ ] Colours from Theme, one meaning each, paired with shape/text
- [ ] Text sizes/weights within the macOS ranges
- [ ] Esc behaviour defined; no timer-only dismissal for explicit opens
- [ ] VoiceOver label set
- [ ] Looked at in the running app or an offscreen render
