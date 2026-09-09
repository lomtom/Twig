#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
# Swift and Clang caches embed absolute paths and cannot survive a project move.
# Reset legacy caches too: older versions of this script did not record the path.
BUILD_PATH_FILE="$PROJECT_DIR/.build/.project-path"
if [[ -d "$PROJECT_DIR/.build" ]] && \
   { [[ ! -f "$BUILD_PATH_FILE" ]] || [[ "$(cat "$BUILD_PATH_FILE")" != "$PROJECT_DIR" ]]; }; then
    printf 'Project path changed or cache path unknown; clearing build caches.\n'
    rm -rf "$PROJECT_DIR/.build"
fi
mkdir -p "$PROJECT_DIR/.build"
printf '%s\n' "$PROJECT_DIR" > "$BUILD_PATH_FILE"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/ModuleCache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/ModuleCache"
# This package has no dependencies or build plugins. Keep all build caches local.
swift build -c release --disable-sandbox
BIN_DIR="$(swift build -c release --disable-sandbox --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/Twig.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BIN_DIR/Twig" "$APP_DIR/Contents/MacOS/Twig.new"
mv -f "$APP_DIR/Contents/MacOS/Twig.new" "$APP_DIR/Contents/MacOS/Twig"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleName</key><string>Twig</string>
    <key>CFBundleDisplayName</key><string>Twig</string>
    <key>CFBundleIdentifier</key><string>dev.twig.mac</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleExecutable</key><string>Twig</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
</dict></plist>
PLIST
swift scripts/make-icon.swift "$PROJECT_DIR/scripts/AppIcon.png" "$PROJECT_DIR/.build/Twig.iconset" "$APP_DIR/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_DIR"
printf '\nBuilt: %s\n' "$APP_DIR"
