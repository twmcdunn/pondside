#!/bin/sh
# Removes Pondside from this Mac, keeping the score History
# (~/Library/Application Support/Pondside/History).
#
#   scripts/uninstall.sh               # dry run: lists what would be removed
#   scripts/uninstall.sh --yes         # removes it
#   scripts/uninstall.sh --yes --agent-configs ~/Documents/pondside_scores
#       also takes the `pondside` MCP server out of each score folder's
#       .mcp.json, opencode.json and .codex/config.toml under that folder
#
# It does not touch scores, and they need nothing from the app: lexicon.ily
# holds its own copy of the kits. One written by an older Pondside
# \includes them from inside Pondside.app and stops engraving once the app
# is gone; open the score in a current Pondside first, which rewrites it.
set -eu

doit=0
agent_dir=""
while [ $# -gt 0 ]; do
  case "$1" in
    --yes) doit=1 ;;
    --agent-configs) shift; agent_dir="${1:?--agent-configs needs a folder}" ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
  shift
done

[ $doit -eq 1 ] || echo "Dry run: nothing is removed. Run again with --yes to remove these."
echo

# remove <path>: deletes a file, folder or link if it exists
remove() {
  [ -e "$1" ] || [ -L "$1" ] || return 0
  echo "  remove $1"
  [ $doit -eq 1 ] && rm -rf "$1"
  return 0
}

# --- the app
if pgrep -xq Pondside; then
  echo "Pondside is running: it will be asked to quit."
  if [ $doit -eq 1 ]; then
    osascript -e 'tell application id "app.pondside.Pondside" to quit' >/dev/null 2>&1 || true
    i=0; while pgrep -xq Pondside && [ $i -lt 20 ]; do sleep 1; i=$((i + 1)); done
    if pgrep -xq Pondside; then
      echo "error: Pondside did not quit (unsaved changes?). Quit it and run again." >&2
      exit 1
    fi
  fi
fi

echo "App and command-line tool:"
remove /Applications/Pondside.app
remove "$HOME/Applications/Pondside.app"
# only the link into Pondside.app, never another program called pondside
for link in /usr/local/bin/pondside /opt/homebrew/bin/pondside; do
  if [ -L "$link" ]; then
    case "$(readlink "$link")" in */Pondside.app/*) remove "$link" ;; esac
  fi
done

# --- the installer's toolchain and package receipts (only if the .pkg was ever run)
toolchain="/Library/Application Support/Pondside"
receipts="$(pkgutil --pkgs 2>/dev/null | grep '^app\.pondside\.' || true)"
if [ -e "$toolchain" ] || [ -n "$receipts" ]; then
  echo "Installer files (needs your password):"
  [ -e "$toolchain" ] && echo "  remove $toolchain"
  for r in $receipts; do echo "  forget package receipt $r"; done
  if [ $doit -eq 1 ]; then
    [ -e "$toolchain" ] && sudo rm -rf "$toolchain"
    for r in $receipts; do sudo pkgutil --forget "$r" >/dev/null; done
  fi
fi

# --- support files: everything except History
support="$HOME/Library/Application Support/Pondside"
echo "Support files (History is kept):"
if [ -d "$support" ]; then
  for item in "$support"/* "$support"/.[!.]*; do
    [ -e "$item" ] || continue
    [ "$(basename "$item")" = History ] && continue
    remove "$item"
  done
  [ -d "$support/History" ] && echo "  keep   $support/History"
fi

echo "Caches and saved state:"
for base in Caches HTTPStorages WebKit "Saved Application State" Logs; do
  for item in "$HOME/Library/$base"/Pondside "$HOME/Library/$base"/PondsideApp \
              "$HOME/Library/$base"/app.pondside.Pondside*; do
    remove "$item"
  done
done

echo "Preferences:"
for plist in "$HOME/Library/Preferences/app.pondside.Pondside.plist" \
             "$HOME/Library/Preferences/PondsideApp.plist" \
             "$HOME/Library/Preferences"/pondside-*.plist; do
  [ -e "$plist" ] || continue
  # through cfprefsd first, so it does not write the file back from memory
  [ $doit -eq 1 ] && defaults delete "$(basename "$plist" .plist)" >/dev/null 2>&1 || true
  remove "$plist"
done

# --- agent configs in score folders (opt-in)
if [ -n "$agent_dir" ]; then
  echo "Agent configs under $agent_dir:"
  find "$agent_dir" \( -name .mcp.json -o -name opencode.json -o -path '*/.codex/config.toml' \) \
       -not -path '*/.git/*' -type f 2>/dev/null |
  while IFS= read -r f; do
    DOIT=$doit python3 - "$f" <<'PY'
import json, os, re, sys
path = sys.argv[1]
text = open(path, encoding="utf-8").read()
if path.endswith(".toml"):
    # drop [mcp_servers.pondside] and its sub-tables ([mcp_servers.pondside.tools.x]),
    # each up to the next table
    new = re.sub(r"(?ms)^\[mcp_servers\.pondside(?:\.[^\]\n]*)?\]\n.*?(?=^\[|\Z)", "", text)
else:
    data = json.loads(text)
    key = "mcp" if path.endswith("opencode.json") else "mcpServers"
    servers = data.get(key)
    if not isinstance(servers, dict) or "pondside" not in servers:
        sys.exit(0)
    del servers["pondside"]
    new = json.dumps(data, indent=2) + "\n"
if new != text:
    print(f"  edit   {path} (remove the pondside MCP server)")
    if os.environ["DOIT"] == "1":
        open(path, "w", encoding="utf-8").write(new)
PY
  done
fi

echo
if [ $doit -eq 1 ]; then echo "Pondside is removed."; else echo "Dry run done."; fi
