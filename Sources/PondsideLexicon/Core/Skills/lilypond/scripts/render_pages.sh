#!/bin/bash
# Compile a LilyPond score (optional) and render pages to PNG for looking at them.
#
#   render_pages.sh score.pdf [FIRST [LAST]] [-r DPI] [-o OUTDIR] [-c]
#       -c          compile score.ly (next to the PDF) first, warnings only
#       -r DPI      resolution (default 100; 250-400 for collisions, with a crop below)
#       -o OUTDIR   where the PNGs go (default: a temp dir, printed)
#   CROP="-x 400 -y 1100 -W 900 -H 450"   pixel crop at the chosen DPI (pdftoppm options)
#
# Prints one PNG path per page. Needs poppler (brew install poppler).
set -eu
pdf=$1; shift
first=1; last=""; dpi=100; out=""; compile=0
while [ $# -gt 0 ]; do
    case $1 in
        -r) dpi=$2; shift 2 ;;
        -o) out=$2; shift 2 ;;
        -c) compile=1; shift ;;
        *) if [ -z "${got_first:-}" ]; then first=$1; got_first=1; else last=$1; fi; shift ;;
    esac
done
[ -n "$last" ] || last=$first
if [ $compile = 1 ]; then
    ( cd "$(dirname "$pdf")" && lilypond --loglevel=WARN "$(basename "$pdf" .pdf).ly" )
fi
out=${out:-$(mktemp -d)}
mkdir -p "$out"
name=$(basename "$pdf" .pdf)
for p in $(seq "$first" "$last"); do
    # shellcheck disable=SC2086
    pdftoppm -r "$dpi" -f "$p" -l "$p" ${CROP:-} -png "$pdf" "$out/$name-p$p"
    ls "$out/$name-p$p"*.png
done
