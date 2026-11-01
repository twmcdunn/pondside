#!/bin/sh
# Builds a headless SuperCollider for the installer: sclang (no Qt, no IDE,
# no GUI classes) and scsynth with its plugins and the class library, as a
# small universal folder linking only system libraries. libsndfile is
# static (WAV and AIFF only, no codecs); FFT is Apple's vDSP, so no fftw;
# no supernova, Ableton Link, HID or readline. Help files are left out.
#   scripts/installer/build-supercollider.sh <work-dir> <out-dir>
#   → <out-dir>/SuperCollider.app/Contents/{MacOS/sclang, Resources/{scsynth,plugins,SCClassLibrary}}
# (sclang finds its class library and scsynth only inside an app bundle's
# layout). Pondside runs it with a config that leaves out the user's
# Extensions, which may need Qt: SuperColliderToolchain.headlessConfig.
# Needs cmake and ninja. About 10 minutes; run once per version.
set -eu
. "$(dirname "$0")/versions.env"
work="$1"; out="$2"
mkdir -p "$work" "$out"
work="$(cd "$work" && pwd)"; out="$(cd "$out" && pwd)"
prefix="$work/prefix"

fetch() { # url file sha256
  [ -f "$work/$2" ] || curl -fsSL "$1" -o "$work/$2"
  echo "$3  $work/$2" | shasum -a 256 -c - >/dev/null || { echo "error: checksum mismatch for $2" >&2; exit 1; }
}
fetch "$LIBSNDFILE_URL" libsndfile.tar.xz "$LIBSNDFILE_SHA256"
fetch "$SUPERCOLLIDER_SOURCE_URL" supercollider.tar.bz2 "$SUPERCOLLIDER_SOURCE_SHA256"
rm -rf "$work/src" "$prefix" "$work/build-sc"; mkdir -p "$work/src/sndfile" "$work/src/sc"
tar -xf "$work/libsndfile.tar.xz" -C "$work/src/sndfile" --strip-components 1
tar -xjf "$work/supercollider.tar.bz2" -C "$work/src/sc" --strip-components 1

# Only our prefix is searched, so nothing from Homebrew or MacPorts leaks in.
common="-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DCMAKE_OSX_ARCHITECTURES=arm64;x86_64 -DCMAKE_INSTALL_PREFIX=$prefix -DCMAKE_PREFIX_PATH=$prefix
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local;/opt/local
  -DCMAKE_FIND_FRAMEWORK=LAST -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=""

cmake -S "$work/src/sndfile" -B "$work/build-sndfile" $common -DBUILD_SHARED_LIBS=OFF \
  -DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DBUILD_PROGRAMS=OFF \
  -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DENABLE_CPACK=OFF \
  -DINSTALL_MANPAGES=OFF -DINSTALL_PKGCONFIG_MODULE=ON >/dev/null
cmake --build "$work/build-sndfile" --parallel >/dev/null
cmake --install "$work/build-sndfile" >/dev/null

cmake -S "$work/src/sc" -B "$work/build-sc" -G Ninja $common \
  -DSC_QT=OFF -DSC_IDE=OFF -DSC_ED=OFF -DSC_EL=OFF -DSC_VIM=OFF -DSUPERNOVA=OFF \
  -DSC_ABLETON_LINK=OFF -DSC_HIDAPI=OFF -DNO_X11=ON -DINSTALL_HELP=OFF -DENABLE_TESTSUITE=OFF \
  -DSYSTEM_BOOST=OFF -DSYSTEM_YAMLCPP=OFF -DUSE_CCACHE=OFF -DNATIVE=OFF \
  -DSC_CODESIGN_AFTER_DEPLOY=OFF -DSC_VERIFY_APP=OFF \
  -DCMAKE_DISABLE_FIND_PACKAGE_Readline=ON -DCMAKE_DISABLE_FIND_PACKAGE_FFTW3f=ON -DCMAKE_DISABLE_FIND_PACKAGE_Jack=ON \
  -DSNDFILE_INCLUDE_DIR="$prefix/include" -DSNDFILE_LIBRARY="$prefix/lib/libsndfile.a" \
  > "$work/configure.log" 2>&1 || { echo "error: see $work/configure.log" >&2; exit 1; }
cmake --build "$work/build-sc" --parallel > "$work/build.log" 2>&1 \
  || { echo "error: see $work/build.log" >&2; exit 1; }
cmake --install "$work/build-sc" > "$work/install.log" 2>&1 \
  || { echo "error: see $work/install.log" >&2; exit 1; }

# The install is an app bundle; keep its programs, plugins and class
# library in the same layout (sclang finds Resources/ beside it).
app="$(find "$prefix" -maxdepth 2 -name 'SuperCollider.app' -type d | head -1)"
[ -n "$app" ] || { echo "error: no SuperCollider.app under $prefix" >&2; exit 1; }
rm -rf "$out"/*
licences="$out"; out="$out/SuperCollider.app/Contents"
mkdir -p "$out/MacOS" "$out/Resources"
cp "$app/Contents/MacOS/sclang" "$out/MacOS/"
for r in scsynth plugins; do cp -R "$app/Contents/Resources/$r" "$out/Resources/"; done
# Pondside's mark: run with the headless config.
echo "SuperCollider $SUPERCOLLIDER_VERSION, headless (Pondside)" > "$out/Resources/pondside-headless"
# On macOS the IDE's bundle step copies the class library; without it, copy
# it as SuperCollider's own headless install does: no GUI or Ableton Link
# classes (they need Qt or Link), and no IDE classes.
rsync -a --exclude 'GUI/' --exclude 'Ableton/' --exclude 'scide_scqt/' --exclude '*~' \
  "$work/src/sc/SCClassLibrary" "$out/Resources/"
cp "$work/src/sc/COPYING" "$licences/LICENSE-SuperCollider.txt"
cp "$work/src/sndfile/COPYING" "$licences/LICENSE-libsndfile.txt"
find "$out" -type f \( -name '*.scx' -o -name sclang -o -name scsynth \) -exec strip -x {} \; 2>/dev/null || true
find "$out" -type f \( -name '*.scx' -o -name sclang -o -name scsynth \) -exec codesign --force --sign - {} \; >/dev/null

# Refuse a build that needs a newer macOS or a non-system library.
for f in "$out/MacOS/sclang" "$out/Resources/scsynth" "$out"/Resources/plugins/*.scx; do
  if otool -L "$f" | tail -n +2 | grep -v -e '/usr/lib/' -e '/System/Library/' -e ':$'; then
    echo "error: $f links a non-system library" >&2; exit 1
  fi
  min="$(otool -l "$f" | awk '/LC_BUILD_VERSION/ { b = 1 } b && /minos/ { print $2; exit }')"
  [ "$min" = 14.0 ] || { echo "error: $f needs macOS $min" >&2; exit 1; }
done
du -sh "$licences"
