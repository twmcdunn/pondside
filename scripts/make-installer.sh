#!/bin/sh
# Builds the Pondside installer package (macOS only): the app, a pinned
# LilyPond, a static fluidsynth with a SoundFont, the CLI link, and
# download-at-install components for SuperCollider and MuseScore.
#   scripts/make-installer.sh   → .build/Pondside-<version>-<arch>.pkg
# Downloads are cached in .build/installer/cache and checked against
# scripts/installer/versions.env. The package is unsigned; users open it
# once with System Settings → Privacy & Security → Open Anyway. Files
# Installer.app writes carry no quarantine flag, so the app itself opens
# without a second prompt.
set -eu
cd "$(dirname "$0")/.."
here=scripts/installer
. "$here/versions.env"
arch="$(uname -m)"
work=.build/installer
cache="$work/cache"
stage="$work/stage"
pkgs="$work/pkgs"
toolchain="/Library/Application Support/Pondside/Toolchain"
rm -rf "$stage" "$pkgs"
mkdir -p "$cache" "$stage" "$pkgs"

fetch() { # url file sha256
  [ -f "$cache/$2" ] || { echo "downloading $1"; curl -fsSL --retry 3 -o "$cache/$2" "$1"; }
  echo "$3  $cache/$2" | shasum -a 256 -c - >/dev/null \
    || { echo "error: checksum mismatch for $2 (delete it from $cache to refetch)" >&2; exit 1; }
}

# Each script-carrying package gets its postinstall, the shared helper and
# the pinned versions.
scripts_for() { # component
  dir="$stage/scripts-$1"
  mkdir -p "$dir"
  cp "$here/scripts/$1/postinstall" "$here/scripts/fetch-app.sh" "$here/scripts/fetch-agent.sh" "$here/versions.env" "$dir/"
  chmod +x "$dir/postinstall" "$dir/fetch-app.sh" "$dir/fetch-agent.sh"
  echo "$dir"
}

# --- Pondside.app
scripts/make-app.sh release >/dev/null
mkdir -p "$stage/app"
ditto .build/Pondside.app "$stage/app/Pondside.app"
version="$(plutil -extract CFBundleShortVersionString raw "$stage/app/Pondside.app/Contents/Info.plist")"
# Not relocatable: otherwise Installer "upgrades" any Pondside.app it finds
# with the same bundle ID, such as a developer build in .build/.
pkgbuild --analyze --root "$stage/app" "$stage/app.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$stage/app.plist"
pkgbuild --root "$stage/app" --component-plist "$stage/app.plist" --install-location /Applications \
  --identifier app.pondside.app --version "$version" --quiet "$pkgs/pondside.pkg"

# --- LilyPond
# Upstream's arm64 tarball needs macOS 26, so Apple silicon packages carry
# one built here by build-lilypond.sh (cached; about 30 minutes once per
# version). Intel packages use upstream's x86_64 tarball.
lily_tar="$work/lilypond-$LILYPOND_VERSION-darwin-$arch.tar.gz"
if [ "$arch" = arm64 ]; then
  [ -f "$lily_tar" ] || "$here/build-lilypond.sh" "$work/lilypond-build" "$lily_tar"
else
  fetch "$LILYPOND_URL_x86_64" "lilypond-$LILYPOND_VERSION-x86_64.tar.gz" "$LILYPOND_SHA256_x86_64"
  lily_tar="$cache/lilypond-$LILYPOND_VERSION-x86_64.tar.gz"
fi
mkdir -p "$stage/lilypond"
tar -xzf "$lily_tar" -C "$stage/lilypond"
lily="$stage/lilypond/lilypond-$LILYPOND_VERSION"
# Refuse a build that would not run on Pondside's oldest macOS.
for f in "$lily"/bin/* "$lily"/libexec/*; do
  min="$(otool -l "$f" 2>/dev/null | awk '/LC_BUILD_VERSION/ { b = 1 } b && /minos/ { print $2; exit }')"
  [ "${min%%.*}" -le 14 ] 2>/dev/null || [ -z "$min" ] \
    || { echo "error: $f needs macOS $min; Pondside supports 14" >&2; exit 1; }
done
"$lily/bin/lilypond" --version | sed -n 1p
pkgbuild --root "$stage/lilypond" --install-location "$toolchain" --scripts "$(scripts_for lilypond)" \
  --identifier app.pondside.lilypond --version "$LILYPOND_VERSION" --quiet "$pkgs/lilypond.pkg"

# --- FluidSynth + SoundFont
fs_bin="$work/fluidsynth-$FLUIDSYNTH_VERSION"
[ -x "$fs_bin/bin/fluidsynth" ] || "$here/build-fluidsynth.sh" "$work/fluidsynth-work" "$fs_bin" >/dev/null
fetch "$SOUNDFONT_URL" GeneralUser-GS.sf2 "$SOUNDFONT_SHA256"
[ -f "$cache/GeneralUser-GS-LICENSE.txt" ] || curl -fsSL -o "$cache/GeneralUser-GS-LICENSE.txt" "$SOUNDFONT_LICENSE_URL"
mkdir -p "$stage/fluidsynth/soundfonts"
ditto "$fs_bin" "$stage/fluidsynth/fluidsynth"
cp "$cache/GeneralUser-GS.sf2" "$stage/fluidsynth/soundfonts/"
cp "$cache/GeneralUser-GS-LICENSE.txt" "$stage/fluidsynth/soundfonts/LICENSE-GeneralUser-GS.txt"
pkgbuild --root "$stage/fluidsynth" --install-location "$toolchain" \
  --identifier app.pondside.fluidsynth --version "$FLUIDSYNTH_VERSION" --quiet "$pkgs/fluidsynth.pkg"

# --- Headless SuperCollider: sclang and scsynth without Qt (about 16 MB),
# so live electronics work without installing SuperCollider.app.
sc_dir="$work/supercollider-$SUPERCOLLIDER_VERSION"
[ -x "$sc_dir/SuperCollider.app/Contents/MacOS/sclang" ] \
  || "$here/build-supercollider.sh" "$work/supercollider-work" "$sc_dir" >/dev/null
mkdir -p "$stage/sclang"
ditto "$sc_dir" "$stage/sclang/supercollider"
pkgbuild --root "$stage/sclang" --install-location "$toolchain" \
  --identifier app.pondside.sclang --version "$SUPERCOLLIDER_VERSION" --quiet "$pkgs/sclang.pkg"

# --- Payload-free components
pkgbuild --nopayload --install-location /Applications --scripts "$(scripts_for cli)" \
  --identifier app.pondside.cli --version "$version" --quiet "$pkgs/cli.pkg"
pkgbuild --nopayload --scripts "$(scripts_for supercollider)" \
  --identifier app.pondside.supercollider --version "$SUPERCOLLIDER_VERSION" --quiet "$pkgs/supercollider.pkg"
pkgbuild --nopayload --scripts "$(scripts_for musescore)" \
  --identifier app.pondside.musescore --version "$MUSESCORE_VERSION" --quiet "$pkgs/musescore.pkg"
pkgbuild --nopayload --scripts "$(scripts_for claude)" \
  --identifier app.pondside.claude --version "$CLAUDE_VERSION" --quiet "$pkgs/claude.pkg"
pkgbuild --nopayload --scripts "$(scripts_for opencode)" \
  --identifier app.pondside.opencode --version "$OPENCODE_VERSION" --quiet "$pkgs/opencode.pkg"

# --- Resources and the product archive
res="$stage/resources"
mkdir -p "$res"
case "$arch" in arm64) arch_label="Apple silicon" ;; *) arch_label="Intel" ;; esac
fill() { # file → stdout, placeholders replaced
  sed -e "/@STYLE@/r $here/resources/style.css.inc" -e '/@STYLE@/d' \
    -e "s|@PONDSIDE_VERSION@|$version|g" -e "s|@LILYPOND_VERSION@|$LILYPOND_VERSION|g" \
    -e "s|@FLUIDSYNTH_VERSION@|$FLUIDSYNTH_VERSION|g" -e "s|@SUPERCOLLIDER_VERSION@|$SUPERCOLLIDER_VERSION|g" \
    -e "s|@SUPERCOLLIDER_APP@|$SUPERCOLLIDER_APP|g" -e "s|@MUSESCORE_VERSION@|$MUSESCORE_VERSION|g" \
    -e "s|@CLAUDE_VERSION@|$CLAUDE_VERSION|g" -e "s|@OPENCODE_VERSION@|$OPENCODE_VERSION|g" \
    -e "s|@ARCH_LABEL@|$arch_label|g" -e "s|@HOST_ARCHS@|$arch|g" "$1"
}
fill "$here/resources/welcome.html" > "$res/welcome.html"
fill "$here/resources/conclusion.html" > "$res/conclusion.html"
fill "$here/distribution.xml" > "$stage/distribution.xml"
esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' "$1"; }
{
  echo '<!doctype html><html><head><meta charset="utf-8">'
  cat "$here/resources/style.css.inc"
  echo '</head><body><h1>Licences</h1><h2>Pondside</h2>'
  if [ -f LICENSE ]; then echo '<pre>'; esc LICENSE; echo '</pre>'
  else echo '<p>Pondside is open-source research software. See its source repository for its licence.</p>'; fi
  cat <<HTML
<h2>Bundled components</h2>
<ul>
<li><b>GNU LilyPond $LILYPOND_VERSION</b> — GNU GPL v3 or later, with the
licences of the libraries it bundles in <code>$toolchain/lilypond-$LILYPOND_VERSION/licenses</code>.
Source: <code>https://lilypond.org/download.html</code> (tag v$LILYPOND_VERSION).</li>
<li><b>FluidSynth $FLUIDSYNTH_VERSION</b> and <b>libsndfile</b> — GNU LGPL v2.1 or later,
statically linked into <code>fluidsynth</code>; texts in <code>$toolchain/fluidsynth</code>.
Source: <code>$FLUIDSYNTH_URL</code> and <code>$LIBSNDFILE_URL</code>.</li>
<li><b>SuperCollider $SUPERCOLLIDER_VERSION</b> (sclang and scsynth, headless) — GNU GPL v3 or
later, with <b>libsndfile</b> (GNU LGPL v2.1 or later) linked statically; texts in
<code>$toolchain/supercollider</code>. Source: <code>$SUPERCOLLIDER_SOURCE_URL</code>.</li>
<li><b>GeneralUser GS</b> SoundFont by S. Christian Collins — licence below.</li>
</ul>
<h2>Downloaded if chosen</h2>
<p>The SuperCollider app (with its IDE) and MuseScore Studio are downloaded from their projects and
are distributed under the GNU GPL v3 by their authors.</p>
<p>Claude Code (Anthropic) and opencode are installed by their vendors' own
install scripts into your home folder, under their own terms; Claude Code
needs an Anthropic account or API key, opencode a model provider.</p>
<h2>GeneralUser GS</h2><pre>
HTML
  esc "$cache/GeneralUser-GS-LICENSE.txt"
  echo '</pre><h2>GNU LilyPond</h2><pre>'
  esc "$lily/licenses/lilypond-$LILYPOND_VERSION.COPYING"
  echo '</pre></body></html>'
} > "$res/license.html"

out=".build/Pondside-$version-$arch.pkg"
productbuild --distribution "$stage/distribution.xml" --resources "$res" --package-path "$pkgs" --quiet "$out"
echo "$out ($(du -h "$out" | cut -f1 | tr -d ' '))"
