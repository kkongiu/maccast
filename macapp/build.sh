#!/usr/bin/env bash
# Compila l'app nativa Maccast (SwiftUI) senza Xcode.
# Output: <root>/Maccast.app
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
APP="$ROOT/Maccast.app"
SRC="$HERE/Sources/MaccastApp.swift"

echo "Progetto: $ROOT"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "Generazione icona..."
ICONSET="$(mktemp -d)/Maccast.iconset"
mkdir -p "$ICONSET"
swiftc -O -o "$HERE/.makeicon" "$HERE/makeicon.swift"
"$HERE/.makeicon" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET" "$HERE/.makeicon"

echo "Compilazione Swift..."
swiftc -O -parse-as-library \
  -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/Maccast" \
  "$SRC"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Maccast</string>
  <key>CFBundleDisplayName</key><string>Maccast</string>
  <key>CFBundleIdentifier</key><string>com.kkongiu.maccast</string>
  <key>CFBundleExecutable</key><string>Maccast</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>MaccastProjectDir</key><string>$ROOT</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Firma ad-hoc (necessaria per l'attribuzione dei permessi TCC).
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

# Aggiorna la cache delle icone di LaunchServices.
touch "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "Creato: $APP"
