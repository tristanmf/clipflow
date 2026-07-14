#!/bin/bash
#
# construire-app.sh — compile l'app « ClipFlow » et l'installe dans ~/Applications.
# Prompté par Tristan Mendès France — https://tristan.pro
#
# Prérequis : les outils en ligne de commande Xcode (une seule fois) :
#   xcode-select --install
# Puis :
#   bash construire-app.sh
#
set -e
cd "$(dirname "$0")"

if ! command -v swift >/dev/null 2>&1; then
  echo "⚠️  Le compilateur Swift est absent."
  echo "    Terminal :  xcode-select --install   (puis relancer ce script)"
  exit 1
fi

echo ">>> Compilation (peut prendre 1 à 2 minutes la première fois)…"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/Video"
APP_DIR="$HOME/Applications"
APP="$APP_DIR/ClipFlow.app"
mkdir -p "$APP_DIR"

echo ">>> Assemblage de l'app…"
rm -rf "$APP"
rm -rf "$APP_DIR/Vidéo.app"   # nettoie l'ancien nom (avant renommage en ClipFlow)
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Video"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>Video</string>
    <key>CFBundleIdentifier</key>
    <string>pro.tristan.clipflow</string>
    <key>CFBundleName</key>
    <string>ClipFlow</string>
    <key>CFBundleDisplayName</key>
    <string>ClipFlow</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Tristan Mendès France</string>
</dict>
</plist>
PLIST

# Icône de l'app : si AppIcon.png est présent (idéalement 1024×1024), on génère
# AppIcon.icns aux tailles standard via les outils natifs macOS (sips + iconutil).
# Absent → l'app s'installe sans icône personnalisée (rien ne casse).
if [ -f "AppIcon.png" ]; then
  echo ">>> Génération de l'icône…"
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for taille in 16 32 128 256 512; do
    double=$((taille * 2))
    sips -z "$taille" "$taille" AppIcon.png --out "$ICONSET/icon_${taille}x${taille}.png"    >/dev/null 2>&1
    sips -z "$double" "$double" AppIcon.png --out "$ICONSET/icon_${taille}x${taille}@2x.png"  >/dev/null 2>&1
  done
  if iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
    echo "    Icône intégrée."
  else
    echo "    ⚠️  Conversion de l'icône impossible (iconutil) — app installée sans icône."
  fi
  rm -rf "$(dirname "$ICONSET")"
fi

# Signature ad hoc (suffisante pour un usage local, aucun compte développeur requis).
# PAS de sandbox : l'app doit lancer les binaires Homebrew et écrire dans ~/Movies.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

echo ""
echo "============================================================"
echo " ✅ App installée :  $APP"
echo "    Lance-la depuis le Finder (~/Applications) ou Spotlight."
echo "    Pour la mettre à jour après un git pull : relancer ce script."
echo "============================================================"
open -R "$APP" 2>/dev/null || true
