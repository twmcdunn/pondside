#!/bin/sh
# Builds LilyPond's binary tarball for Apple silicon with a macOS 14
# minimum, using upstream's own release scripts (release/binaries). The
# official arm64 tarball is built on macOS 26 and needs it.
#   scripts/installer/build-lilypond.sh <work-dir> <out-tarball>
# Needs Homebrew's bison, flex, make, meson, ninja, fontforge, t1utils and
# Python's `packaging`. About 30 minutes; run once per LilyPond version.
set -eu
. "$(dirname "$0")/versions.env"
work="$1"; out="$2"
mkdir -p "$work/build"
work="$(cd "$work" && pwd)"
brew="$(brew --prefix)"
for tool in bison flex make meson ninja fontforge t1utils; do
  [ -d "$brew/opt/$tool" ] || { echo "error: brew install $tool" >&2; exit 1; }
done

src="lilypond-$LILYPOND_VERSION.tar.gz"
[ -f "$work/$src" ] || curl -fsSL -o "$work/$src" "$LILYPOND_SOURCE_URL"
echo "$LILYPOND_SOURCE_SHA256  $work/$src" | shasum -a 256 -c - >/dev/null \
  || { echo "error: checksum mismatch for $src" >&2; exit 1; }
rm -rf "$work/lilypond-$LILYPOND_VERSION"
tar -xzf "$work/$src" -C "$work"
scripts="$work/lilypond-$LILYPOND_VERSION/release/binaries"

# clang searches /usr/local/include by default, and a leftover Intel
# Homebrew there leaves a libintl.h whose library cannot link for arm64.
python3 - "$scripts/lib/dependencies.py" <<'PY'
import sys
p = sys.argv[1]; s = open(p).read()
old = '            "ac_cv_search_crypt_r=no",\n        ]'
assert s.count(old) == 1, "dependencies.py changed; review this patch"
new = '            "ac_cv_search_crypt_r=no",\n            "ac_cv_header_libintl_h=no",\n        ]'
open(p, "w").write(s.replace(old, new))
PY

export PATH="$brew/opt/bison/bin:$brew/opt/flex/bin:$brew/opt/make/libexec/gnubin:$PATH"
export CPPFLAGS="-I$brew/opt/flex/include"
export LDFLAGS="-L$brew/opt/bison/lib -L$brew/opt/flex/lib"
export MACOSX_DEPLOYMENT_TARGET=14.0
cd "$work/build"
python3 "$scripts/build-dependencies" > "$work/dependencies.log" 2>&1 \
  || { echo "error: see $work/dependencies.log" >&2; exit 1; }
python3 "$scripts/build-lilypond" "$work/$src" > "$work/lilypond.log" 2>&1 \
  || { echo "error: see $work/lilypond.log" >&2; exit 1; }

# Refuse a build that needs a newer macOS or a non-system library.
check="$work/check"
rm -rf "$check"; mkdir -p "$check"
tar -xzf "lilypond-$LILYPOND_VERSION-darwin-arm64.tar.gz" -C "$check"
for f in "$check/lilypond-$LILYPOND_VERSION"/bin/* "$check/lilypond-$LILYPOND_VERSION"/libexec/*; do
  file "$f" | grep -q Mach-O || continue
  min="$(otool -l "$f" | awk '/LC_BUILD_VERSION/ { b = 1 } b && /minos/ { print $2; exit }')"
  [ "$min" = 14.0 ] || { echo "error: $f needs macOS $min" >&2; exit 1; }
  if otool -L "$f" | tail -n +2 | grep -v -e '/usr/lib/' -e '/System/Library/'; then
    echo "error: $f links a non-system library" >&2; exit 1
  fi
done
"$check/lilypond-$LILYPOND_VERSION/bin/lilypond" --version | sed -n 1p
mkdir -p "$(dirname "$out")"
cp "lilypond-$LILYPOND_VERSION-darwin-arm64.tar.gz" "$out"
echo "$out $(shasum -a 256 "$out" | cut -d' ' -f1)"
