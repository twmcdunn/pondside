# Spacing in LilyPond 2.26

NR 4 "Spacing issues" is the reference. What matters in practice:

## Vertical: tight systems, air between them

Within a system, staves sit as close as their contents (skylines) allow plus a padding, and never stretch; all leftover page space goes between systems, evenly, on every page:

```lilypond
\paper {
  system-system-spacing = #'((basic-distance . 12) (minimum-distance . 8) (padding . 2)
                             (stretchability . 100))
  ragged-bottom = ##f
  ragged-last-bottom = ##f        % the last page too
}
\layout {
  \context { \Staff
    \override VerticalAxisGroup.staff-staff-spacing =
      #'((basic-distance . 0) (minimum-distance . 0) (padding . 1.0) (stretchability . 0)) }
  \context { \PianoStaff            % or \StaffGroup, \GrandStaff: whatever groups staves
    \override StaffGrouper.staff-staff-spacing =
      #'((basic-distance . 0) (minimum-distance . 0) (padding . 1.0) (stretchability . 0))
    \override StaffGrouper.staffgroup-staff-spacing =
      #'((basic-distance . 0) (minimum-distance . 0) (padding . 1.0) (stretchability . 0)) }
}
```
- A staff followed by a group uses its own `VerticalAxisGroup.staff-staff-spacing`; staves inside a group use the `StaffGrouper` ones.
- Debug with `\paper { annotate-spacing = ##t }` (draws every distance). Compile a copy for that, not the real score.
- Per-system fixed distances (`\overrideProperty Score.NonMusicalPaperColumn.line-break-system-details #'((alignment-distances . (19 12)))`) are a last resort: they don't follow the content.
- Overfull pages print "compressing over-full page"; fix by lowering paddings, a smaller staff size (`#(set-global-staff-size 18)`), or moving a system.

## Something that must not take room

A grob takes vertical room through its **skylines**. To draw without pushing anything:
```scheme
#(define no-skylines
   (ly:make-unpure-pure-container
    (lambda (grob) (ly:skylines-for-stencil empty-stencil X))))
% -\tweak vertical-skylines #no-skylines -\tweak outside-staff-priority ##f
```
To *reserve* room but let other things (dynamics) sit inside it, see the "floor" pattern in lilypond-contemporary-notation (an invisible outside-staff spanner placed after everything else).

Outside-staff placement order: lower `outside-staff-priority` is placed first, closest to the staff; a grob with priority `##f` is part of the staff's own outline, which everything outside-staff then avoids -- so anything you make part of the staff outline (e.g. a box drawn around notes) pushes dynamics outside it.

## Horizontal

- Spacing is **score-wide**: every moment is one column across all staves. A staff with short notes widens the bars for everyone. To keep a staff from affecting others, give its events fewer moments (e.g. one chord instead of five notes, then position the heads yourself -- the `\collection` pattern in lilypond-electronics-staff).
- Skips (`s`) with no notes in any staff get almost no space. To force room at a moment, use a spanner with `minimum-length` and `springs-and-rods = #ly:spanner::set-spacing-rods` (rods only work when both ends are on the same line).
- `extra-spacing-width = #'(+inf.0 . -inf.0)` on a grob: spacing ignores it.
- `\override Score.SpacingSpanner.*` (`spacing-increment`, `shortest-duration-space`, `common-shortest-duration`, `uniform-stretching`), `\newSpacingSection`, `proportionalNotationDuration` (takes a rational, `#1/16`): global/sectional controls, never per staff.
- Narrower lines (bigger margins) just compress spacing; with fixed breaks LilyPond warns if a line can't fit.

## Margins and paper

```lilypond
\paper {
  #(set-paper-size "a4landscape")
  top-margin = 10\mm  bottom-margin = 18\mm  left-margin = 30\mm  right-margin = 28\mm
  print-first-page-number = ##f
}
\header { tagline = ##f }
```
A closing inscription (e.g. "SDG") right-aligned after the last system: a top-level `\markup \fill-line { "" \italic "SDG" }` after the printed `\score`.
