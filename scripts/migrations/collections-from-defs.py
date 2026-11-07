#!/usr/bin/env python3
"""One-time migration: a score's own \\collection (defs.ily, from the
lilypond-electronics-staff skill) to Pondside's built-in collections.

The old \\collection lasted as long as its notes together (c'32 d'32 ... took
five 32nds); Pondside's takes no time and its notes have no durations. Each
collection's old length moves into the skip after it (or a new skip), so every
later event keeps its moment. Only the files named are changed; a copy of each
is kept as <file>.before-collections.

    python3 collections-from-defs.py electronics.ly [more.ly ...]
"""
import re, sys
from fractions import Fraction

NOTE = re.compile(r"([a-z]+(?:[',]*))(\d+\.*(?:\*\d+(?:/\d+)?)?)?")

def duration(text):
    m = re.fullmatch(r"(\d+)(\.*)(?:\*(\d+)(?:/(\d+))?)?", text)
    base = Fraction(1, int(m.group(1)))
    dotted = base * (2 - Fraction(1, 2 ** len(m.group(2))))
    factor = Fraction(int(m.group(3) or 1), int(m.group(4) or 1))
    return dotted * factor

def written(f):
    q = f * 4
    return "4" if q == 1 else (f"4*{q.numerator}" if q.denominator == 1 else f"4*{q.numerator}/{q.denominator}")

def migrate(text):
    out, i, changed = [], 0, 0
    pattern = re.compile(r"\\collection\s*\{([^{}]*)\}")
    while True:
        m = pattern.search(text, i)
        if not m:
            out.append(text[i:]); break
        out.append(text[i:m.start()])
        notes, length, last = [], Fraction(0), None
        for word in m.group(1).split():
            n = NOTE.fullmatch(word)
            if not n:
                raise SystemExit(f"can't read '{word}' in {m.group(0)}")
            if n.group(2): last = duration(n.group(2))
            if last is None: raise SystemExit(f"no duration for the first note of {m.group(0)}")
            length += last
            notes.append(n.group(1))
        out.append("\\collection { " + " ".join(notes) + " }")
        j = m.end()
        skip = re.match(r"(\s+)s(\d+\.*(?:\*\d+(?:/\d+)?)?)", text[j:])
        if skip:
            out.append(skip.group(1) + "s" + written(duration(skip.group(2)) + length))
            j += skip.end()
        else:
            out.append(" s" + written(length))
        i, changed = j, changed + 1
    return "".join(out), changed

for path in sys.argv[1:]:
    text = open(path, encoding="utf-8").read()
    new, n = migrate(text)
    if n:
        open(path + ".before-collections", "w", encoding="utf-8").write(text)
        open(path, "w", encoding="utf-8").write(new)
    print(f"{path}: {n} collections")
