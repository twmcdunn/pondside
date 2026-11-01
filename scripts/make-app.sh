#!/bin/sh
# Builds Pondside.app from the SwiftPM products (macOS only).
#   scripts/make-app.sh [debug|release]   → .build/Pondside.app
set -eu
cd "$(dirname "$0")/.."
config="${1:-release}"

# swift-sheet-music needs Swift 6.2+; Xcode 16 and the Command Line Tools
# ship 6.0. Prefer a swiftly toolchain even in a shell opened before swiftly
# was installed. Override with SWIFT=/path/to/swift.
if [ -z "${SWIFT:-}" ]; then
  SWIFT=swift
  [ -x "$HOME/.swiftly/bin/swift" ] && SWIFT="$HOME/.swiftly/bin/swift"
fi
version="$("$SWIFT" --version 2>/dev/null | sed -n 's/.*Swift version \([0-9]*\)\.\([0-9]*\).*/\1 \2/p' | head -1)"
set -- $version
if [ "${1:-0}" -lt 6 ] || { [ "${1:-0}" -eq 6 ] && [ "${2:-0}" -lt 2 ]; }; then
  echo "error: $SWIFT is Swift ${1:-?}.${2:-?}; Pondside needs 6.2 or later (swiftly install 6.4.1)" >&2
  exit 1
fi

"$SWIFT" build -c "$config" --product PondsideApp
"$SWIFT" build -c "$config" --product pondside
bin="$("$SWIFT" build -c "$config" --show-bin-path)"
app=".build/Pondside.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/PondsideApp" "$app/Contents/MacOS/Pondside"
cp "$bin/pondside" "$app/Contents/Resources/pondside"
# SwiftPM resource bundles (the Lexicon, the Bravura font). Bundle.module
# looks beside the app's resources, and beside the CLI, which lives there
# too; newer toolchains no longer fall back to the build directory.
for bundle in "$bin"/*.bundle; do
  case "$bundle" in *Tests.bundle) continue ;; esac
  [ -d "$bundle" ] && cp -R "$bundle" "$app/Contents/Resources/"
done
# icons/AppIcon.png is the finished 1024 px icon with a transparent
# background; macOS shows it as drawn and does not mask it.
iconset=".build/AppIcon.iconset"
rm -rf "$iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" icons/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" icons/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Pondside</string>
  <key>CFBundleDisplayName</key><string>Pondside</string>
  <key>CFBundleIdentifier</key><string>app.pondside.Pondside</string>
  <key>CFBundleExecutable</key><string>Pondside</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSArchitecturePriority</key><array><string>arm64</string></array>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key><string>LilyPond Source</string>
      <key>CFBundleTypeRole</key><string>Editor</string>
      <key>LSHandlerRank</key><string>Alternate</string>
      <key>CFBundleTypeExtensions</key><array><string>ly</string><string>ily</string></array>
    </dict>
  </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$app" >/dev/null 2>&1 || true
echo "$app"
