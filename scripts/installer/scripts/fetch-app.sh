#!/bin/sh
# Postinstall helper: downloads a pinned app's disk image, checks its SHA-256
# and Developer ID team, and copies the app into /Applications.
#   fetch-app.sh SUPERCOLLIDER|MUSESCORE
# A failed download never fails the whole installation; it is logged to
# /var/log/install.log and Pondside reports the missing tool when needed.
set -u
. "$(dirname "$0")/versions.env"
name="$1"
eval "url=\$${name}_URL sha=\$${name}_SHA256 team=\$${name}_TEAM app=\$${name}_APP"
log() { echo "pondside: $name: $*"; }

if [ -d "/Applications/$app" ]; then log "already installed"; exit 0; fi
tmp="$(mktemp -d /tmp/pondside-fetch.XXXXXX)"
mnt="$tmp/mnt"
cleanup() { hdiutil detach -quiet "$mnt" 2>/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT

log "downloading $url"
if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp/image.dmg" "$url"; then
  log "download failed"; exit 0
fi
if ! echo "$sha  $tmp/image.dmg" | shasum -a 256 -c - >/dev/null 2>&1; then
  log "checksum mismatch; not installing"; exit 0
fi
mkdir -p "$mnt"
# `yes` accepts a licence agreement embedded in the image, if any.
if ! yes | hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$mnt" "$tmp/image.dmg" >/dev/null; then
  log "could not open the disk image"; exit 0
fi
found="$(find "$mnt" -maxdepth 2 -name '*.app' -type d 2>/dev/null | head -1)"
if [ -z "$found" ]; then log "no app in the disk image"; exit 0; fi
if ! codesign --verify --deep --strict "$found" 2>/dev/null \
   || [ "$(codesign -dv "$found" 2>&1 | sed -n 's/^TeamIdentifier=//p')" != "$team" ]; then
  log "signature is not from team $team; not installing"; exit 0
fi
dest="/Applications/$(basename "$found")"
ditto "$found" "$dest" && log "installed $dest"
exit 0
