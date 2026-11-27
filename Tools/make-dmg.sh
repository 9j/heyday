#!/usr/bin/env bash
# Packages a polished Universal macOS disk image (`Heyday-<version>.dmg`) with a
# custom Retina Finder background, volume icon, and drag-to-Applications layout.
#
# Usage:
#   Tools/make-dmg.sh
#
# Optional environment variables for signed & notarized public releases:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
#   NOTARY_PROFILE="heyday-notary"   # keychain profile created via `xcrun notarytool store-credentials`
#   SKIP_BUILD=1                     # reuse existing build/Release/Build/Products/Release/Heyday.app
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

APP_NAME="Heyday"
DERIVED_DATA="${DERIVED_DATA:-build/Release}"
APP_PATH="$DERIVED_DATA/Build/Products/Release/$APP_NAME.app"
OUT_DIR="${OUT_DIR:-build/dmg}"

if [[ "${SKIP_BUILD:-0}" != "1" ]]; then
  echo "==> Generating Xcode project and building Universal Release $APP_NAME.app..."
  xcodegen generate
  BUILD_ARGS=(
    -project Heyday.xcodeproj
    -scheme "$APP_NAME"
    -configuration Release
    -destination 'generic/platform=macOS'
    -derivedDataPath "$DERIVED_DATA"
    ARCHS="arm64 x86_64"
    ONLY_ACTIVE_ARCH=NO
  )
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    BUILD_ARGS+=(
      CODE_SIGN_STYLE=Manual
      "CODE_SIGN_IDENTITY=$SIGN_IDENTITY"
      OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime"
    )
  fi
  xcodebuild "${BUILD_ARGS[@]}" build
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "error: $APP_PATH not found" >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_PATH/Contents/Info.plist")"
DMG_NAME="$APP_NAME-$VERSION.dmg"
FINAL_DMG="$OUT_DIR/$DMG_NAME"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/heyday-dmg.XXXXXX")"
STAGE_DIR="$WORK_DIR/stage"
BG_DIR="$WORK_DIR/bg"
ICONSET_DIR="$WORK_DIR/VolumeIcon.iconset"
RW_DMG="$WORK_DIR/rw.dmg"
MOUNT_DIR=""

cleanup() {
  if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
    hdiutil detach "$MOUNT_DIR" -force >/dev/null 2>&1 || true
  fi
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT

mkdir -p "$OUT_DIR" "$STAGE_DIR/.background" "$BG_DIR" "$ICONSET_DIR"

echo "==> Copying $APP_NAME.app ($VERSION) into staging folder..."
ditto "$APP_PATH" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Re-signing $APP_NAME.app with $SIGN_IDENTITY..."
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$STAGE_DIR/$APP_NAME.app"
fi
codesign --verify --deep --strict "$STAGE_DIR/$APP_NAME.app"

echo "==> Rendering Retina DMG background..."
swift Tools/make-dmg-background.swift "$BG_DIR" "$VERSION"
tiffutil -cathidpicheck "$BG_DIR/background-1x.png" "$BG_DIR/background-2x.png" -out "$STAGE_DIR/.background/background.tiff"

echo "==> Building custom volume icon (.VolumeIcon.icns)..."
ICON_SRC="App/Resources/Assets.xcassets/AppIcon.appiconset"
cp "$ICON_SRC/mac-16.png"   "$ICONSET_DIR/icon_16x16.png"
cp "$ICON_SRC/mac-32.png"   "$ICONSET_DIR/icon_16x16@2x.png"
cp "$ICON_SRC/mac-32.png"   "$ICONSET_DIR/icon_32x32.png"
cp "$ICON_SRC/mac-64.png"   "$ICONSET_DIR/icon_32x32@2x.png"
cp "$ICON_SRC/mac-128.png"  "$ICONSET_DIR/icon_128x128.png"
cp "$ICON_SRC/mac-256.png"  "$ICONSET_DIR/icon_128x128@2x.png"
cp "$ICON_SRC/mac-256.png"  "$ICONSET_DIR/icon_256x256.png"
cp "$ICON_SRC/mac-512.png"  "$ICONSET_DIR/icon_256x256@2x.png"
cp "$ICON_SRC/mac-512.png"  "$ICONSET_DIR/icon_512x512.png"
cp "$ICON_SRC/mac-1024.png" "$ICONSET_DIR/icon_512x512@2x.png"
iconutil -c icns "$ICONSET_DIR" -o "$WORK_DIR/VolumeIcon.icns"

STAGE_KB="$(du -sk "$STAGE_DIR" | awk '{print $1}')"
DMG_MB="$(( (STAGE_KB / 1024) + 20 ))"

echo "==> Creating read-write disk image (${DMG_MB} MB)..."
hdiutil create \
  -srcfolder "$STAGE_DIR" \
  -volname "$APP_NAME" \
  -fs HFS+ \
  -fsargs "-c c=64,a=16,e=16" \
  -size "${DMG_MB}m" \
  -format UDRW \
  -ov \
  "$RW_DMG" >/dev/null

ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
MOUNT_DIR="$(echo "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
  echo "error: failed to mount read-write DMG" >&2
  exit 1
fi
VOL_NAME="$(basename "$MOUNT_DIR")"

SetFile -a V "$MOUNT_DIR/.background"
SetFile -a E "$MOUNT_DIR/$APP_NAME.app"

echo "==> Configuring Finder window layout for $VOL_NAME..."
osascript <<EOF
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    delay 0.8
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    try
      set pathbar visible of container window to false
    end try
    set the bounds of container window to {180, 140, 840, 592}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 128
    set text size of viewOptions to 13
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "$APP_NAME.app" of container window to {178, 222}
    set position of item "Applications" of container window to {482, 222}
    close
    open
    update without registering applications
    delay 1.5
    close
  end tell
end tell
EOF

# Install `.VolumeIcon.icns` and set the custom-icon attribute after Finder finishes
# updating the volume, because Finder removes an unflagged `.VolumeIcon.icns` on update.
cp "$WORK_DIR/VolumeIcon.icns" "$MOUNT_DIR/.VolumeIcon.icns"
SetFile -a C "$MOUNT_DIR"
sync
hdiutil detach "$MOUNT_DIR" >/dev/null
MOUNT_DIR=""

echo "==> Compressing final disk image -> $FINAL_DMG..."
rm -f "$FINAL_DMG"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$FINAL_DMG" >/dev/null

if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  echo "==> Signing $FINAL_DMG with $SIGN_IDENTITY..."
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$FINAL_DMG"
fi

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  echo "==> Submitting $FINAL_DMG for Apple notarization (profile: $NOTARY_PROFILE)..."
  xcrun notarytool submit "$FINAL_DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$FINAL_DMG"
  xcrun stapler validate "$FINAL_DMG"
fi

SIZE_HR="$(du -h "$FINAL_DMG" | awk '{print $1}')"
SHA256="$(shasum -a 256 "$FINAL_DMG" | awk '{print $1}')"
echo "==> Done: $FINAL_DMG ($SIZE_HR)"
echo "    SHA-256: $SHA256"
