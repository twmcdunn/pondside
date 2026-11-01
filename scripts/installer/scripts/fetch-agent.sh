#!/bin/sh
# Postinstall helper: installs a coding agent for the person logged in, with
# the vendor's own install script at a pinned version. Postinstall runs as
# root; the agent belongs in that person's home, so the script runs as them.
#   fetch-agent.sh CLAUDE|OPENCODE
# A failure never fails the whole installation; it is logged to
# /var/log/install.log, and Pondside's Settings show the agent as missing.
set -u
. "$(dirname "$0")/versions.env"
name="$1"
eval "url=\$${name}_INSTALL_URL sha=\$${name}_INSTALL_SHA256 args=\$${name}_ARGS bin=\$${name}_BIN"
log() { echo "pondside: $name: $*"; }

user="$(stat -f%Su /dev/console)"
if [ -z "$user" ] || [ "$user" = "root" ]; then log "no one is logged in; not installing"; exit 0; fi
home="$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
if [ -z "$home" ]; then log "no home for $user"; exit 0; fi
if [ -x "$home/$bin" ]; then log "already installed"; exit 0; fi

tmp="$(mktemp -d /tmp/pondside-agent.XXXXXX)"
trap 'rm -rf "$tmp"' EXIT
log "downloading $url"
if ! curl -fsSL --retry 3 --connect-timeout 20 -o "$tmp/install.sh" "$url"; then
  log "download failed"; exit 0
fi
if ! echo "$sha  $tmp/install.sh" | shasum -a 256 -c - >/dev/null 2>&1; then
  log "the vendor's install script has changed since this installer was made; not installing (install it yourself: curl -fsSL $url | bash)"
  exit 0
fi
chmod 755 "$tmp" "$tmp/install.sh"
# shellcheck disable=SC2086 # args are words by design
if sudo -u "$user" -H env HOME="$home" PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$tmp/install.sh" $args; then
  log "installed $home/$bin"
else
  log "the install script failed"
fi
exit 0
