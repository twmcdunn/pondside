#!/bin/sh
# Builds a self-contained, universal fluidsynth for the installer: FluidSynth
# and libsndfile linked statically, no glib or Homebrew libraries, only
# system frameworks. Homebrew's bottle targets the build machine's macOS
# (15 on current runners) and Pondside supports 14.
#   scripts/installer/build-fluidsynth.sh <work-dir> <out-dir>
#   → <out-dir>/bin/fluidsynth
set -eu
. "$(dirname "$0")/versions.env"
work="$1"; out="$2"
mkdir -p "$work" "$out/bin"
work="$(cd "$work" && pwd)"; out="$(cd "$out" && pwd)"
prefix="$work/prefix"

fetch() { # url file sha256
  [ -f "$work/$2" ] || curl -fsSL "$1" -o "$work/$2"
  echo "$3  $work/$2" | shasum -a 256 -c - >/dev/null || { echo "error: checksum mismatch for $2" >&2; exit 1; }
}
fetch "$LIBSNDFILE_URL" libsndfile.tar.xz "$LIBSNDFILE_SHA256"
fetch "$FLUIDSYNTH_URL" fluidsynth.tar.gz "$FLUIDSYNTH_SHA256"
rm -rf "$work/src" "$prefix"; mkdir -p "$work/src/sndfile" "$work/src/fluidsynth"
tar -xf "$work/libsndfile.tar.xz" -C "$work/src/sndfile" --strip-components 1
tar -xf "$work/fluidsynth.tar.gz" -C "$work/src/fluidsynth" --strip-components 1

# Only our prefix is searched, so nothing from Homebrew or MacPorts leaks in.
common="-DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0
  -DCMAKE_OSX_ARCHITECTURES=arm64;x86_64 -DBUILD_SHARED_LIBS=OFF
  -DCMAKE_INSTALL_PREFIX=$prefix -DCMAKE_PREFIX_PATH=$prefix
  -DCMAKE_IGNORE_PREFIX_PATH=/opt/homebrew;/usr/local;/opt/local
  -DCMAKE_FIND_FRAMEWORK=LAST -DCMAKE_POLICY_VERSION_MINIMUM=3.5"
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" PKG_CONFIG_PATH=""

# WAV is all Pondside writes, so libsndfile needs no codec libraries.
cmake -S "$work/src/sndfile" -B "$work/build-sndfile" $common \
  -DENABLE_EXTERNAL_LIBS=OFF -DENABLE_MPEG=OFF -DBUILD_PROGRAMS=OFF \
  -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DENABLE_CPACK=OFF \
  -DINSTALL_MANPAGES=OFF -DINSTALL_PKGCONFIG_MODULE=ON
cmake --build "$work/build-sndfile" --parallel >/dev/null
cmake --install "$work/build-sndfile" >/dev/null

# osal=cpp11 replaces glib; every optional driver but CoreAudio/CoreMIDI off.
cmake -S "$work/src/fluidsynth" -B "$work/build-fluidsynth" $common \
  -Dosal=cpp11 -Denable-libsndfile=ON -Denable-coreaudio=ON -Denable-coremidi=ON \
  -Denable-dbus=OFF -Denable-jack=OFF -Denable-pulseaudio=OFF -Denable-pipewire=OFF \
  -Denable-sdl3=OFF -Denable-portaudio=OFF -Denable-readline=OFF -Denable-ladspa=OFF \
  -Denable-openmp=OFF -Denable-libinstpatch=OFF -Denable-systemd=OFF \
  -Denable-framework=OFF -Denable-wasapi=OFF -Denable-waveout=OFF \
  -DFLUID_BUILD_DOC=OFF
cmake --build "$work/build-fluidsynth" --parallel >/dev/null

cp "$work/build-fluidsynth/src/fluidsynth" "$out/bin/fluidsynth"
cp "$work/src/fluidsynth/LICENSE" "$out/LICENSE-FluidSynth.txt"
cp "$work/src/sndfile/COPYING" "$out/LICENSE-libsndfile.txt"
codesign --force --sign - "$out/bin/fluidsynth" >/dev/null
# Refuse a binary that would not run on a clean Mac.
if otool -L "$out/bin/fluidsynth" | tail -n +2 | grep -v -e '/usr/lib/' -e '/System/Library/'; then
  echo "error: fluidsynth links a non-system library" >&2; exit 1
fi
echo "$out/bin/fluidsynth"
