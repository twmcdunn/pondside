# LilyPond manual index

The agent has no web access and the installed LilyPond may not ship a
Documentation directory. These are the pages and snippets worth looking up
when a task needs them; prefer the smallest section.

- Learning Manual, “The stencil property”:
  <https://lilypond.org/doc/v2.26/Documentation/learning/the-stencil-property>
  The context of `BarLine`/`Staff.BarLine`, and why `\omit` and `\override`
  sometimes appear not to work.
- Internals, `BarLine`:
  <https://lilypond.org/doc/v2.26/Documentation/internals/barline>
  Properties, `ly:bar-line::print`, `bar-extent`, and the bar-line interface.
- Internals, Scheme functions:
  <https://lilypond.org/doc/v2.26/Documentation/internals/scheme-functions>
  `ly:bar-line::print`, `ly:staff-symbol::print`, `grob::when`, `ly:grob?`,
  `ly:grob-array?`, `make-line-stencil`, `ly:stencil-add`.
- Internals, `StaffSymbol`:
  <https://lilypond.org/doc/v2.26/Documentation/internals/staffsymbol>
  `line-positions`, `staff-space`, `stencil`, `transparent`.
- Snippet, “Adding indicators to staves which get split after a break”:
  <https://lilypond.org/doc/v2.26/Documentation/snippets/scheme-_002d-adding-indicators-to-staves-which-get-split-after-a-break>
  A real `Staff.BarLine.stencil` override around `ly:bar-line::print`.
- Notation Reference, “Bar lines” and “Line spanners”:
  <https://lilypond.org/doc/v2.26/Documentation/notation/bars>
  <https://lilypond.org/doc/v2.26/Documentation/notation/line-spanners>
  `\bar`, `\defineBarLine`, `\startTextSpan`/`\stopTextSpan`.

There is no official “wavy barline over a range” recipe. The staff-lines
reference in this skill is the tested combination of these primitives.
