#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING_DIR="$ROOT_DIR/packaging"
VENDOR_CREATE_DMG="$PACKAGING_DIR/create-dmg-vendor/create-dmg"
DEFAULT_ENV_FILE="$PACKAGING_DIR/.env"
ENV_FILE="${BUILD_ENV_FILE:-$DEFAULT_ENV_FILE}"
USER_APP_NAME="${APP_NAME-}"
USER_DMG_NAME="${DMG_NAME-}"
USER_DMG_VOLUME_NAME="${DMG_VOLUME_NAME-}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

if [[ -n "$USER_APP_NAME" ]]; then APP_NAME="$USER_APP_NAME"; fi
if [[ -n "$USER_DMG_NAME" ]]; then DMG_NAME="$USER_DMG_NAME"; fi
if [[ -n "$USER_DMG_VOLUME_NAME" ]]; then DMG_VOLUME_NAME="$USER_DMG_VOLUME_NAME"; fi

APP_NAME="${APP_NAME:-SixFingers}"
DIST_DIR="$ROOT_DIR/dist"
APP_PATH="$DIST_DIR/$APP_NAME.app"
DMG_NAME="${DMG_NAME:-$APP_NAME}"
VOLUME_NAME="${DMG_VOLUME_NAME:-$APP_NAME}"
FINAL_DMG_PATH="$DIST_DIR/$DMG_NAME.dmg"

# DMG background: Resources/dmg-background-1x.png by default; window size follows PNG via sips below.
# We can override with DMG_BACKGROUND_SOURCE in packaging/.env (sourced above).
BACKGROUND_SOURCE="${DMG_BACKGROUND_SOURCE:-$ROOT_DIR/Resources/dmg-background-1x.png}"
ENABLE_DMG_LAYOUT="1"
DMG_SYNC_WINDOW_TO_BACKGROUND="1"
DMG_AUTO_LAYOUT_ICONS="1"
DMG_ICON_HALF_SPREAD_PERCENT="14"
DMG_ICON_Y_PERCENT="42"
# create-dmg --window-pos uses the first two values; width/height come from the PNG when sync is on.
DMG_WINDOW_BOUNDS="100,100,1220,840"
DMG_APP_ICON_POSITION="310,270"
DMG_APPS_ICON_POSITION="810,270"
DMG_ICON_SIZE="128"
DMG_TEXT_SIZE="15"

if [[ -x "$VENDOR_CREATE_DMG" ]]; then
  CREATE_DMG="$VENDOR_CREATE_DMG"
  echo "Using vendored create-dmg (Finder background patch): $CREATE_DMG"
elif command -v create-dmg >/dev/null 2>&1; then
  CREATE_DMG="$(command -v create-dmg)"
  echo "Using PATH create-dmg: $CREATE_DMG"
else
  echo "create-dmg is required. Install with: brew install create-dmg" >&2
  exit 1
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at $APP_PATH. Building app bundle first..."
  "$PACKAGING_DIR/build-app-bundle.sh"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Missing app bundle: $APP_PATH" >&2
  exit 1
fi

if [[ ! -f "$BACKGROUND_SOURCE" ]]; then
  echo "Missing DMG background image: $BACKGROUND_SOURCE" >&2
  exit 1
fi
echo "DMG background file: $BACKGROUND_SOURCE"

IFS=',' read -r WINDOW_X1 WINDOW_Y1 WINDOW_X2 WINDOW_Y2 <<< "$DMG_WINDOW_BOUNDS"
IFS=',' read -r APP_X APP_Y <<< "$DMG_APP_ICON_POSITION"
IFS=',' read -r APPS_X APPS_Y <<< "$DMG_APPS_ICON_POSITION"
WINDOW_WIDTH=$((WINDOW_X2 - WINDOW_X1))
WINDOW_HEIGHT=$((WINDOW_Y2 - WINDOW_Y1))

if [[ "$DMG_SYNC_WINDOW_TO_BACKGROUND" == "1" ]]; then
  BG_W="$(sips -g pixelWidth "$BACKGROUND_SOURCE" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
  BG_H="$(sips -g pixelHeight "$BACKGROUND_SOURCE" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
  if [[ -n "$BG_W" && -n "$BG_H" && "$BG_W" -gt 0 && "$BG_H" -gt 0 ]]; then
    WINDOW_WIDTH="$BG_W"
    WINDOW_HEIGHT="$BG_H"
    echo "DMG window size synced to background: ${WINDOW_WIDTH}x${WINDOW_HEIGHT}px ($(basename "$BACKGROUND_SOURCE"))"
  else
    echo "Warning: could not read background dimensions with sips; using DMG_WINDOW_BOUNDS size." >&2
  fi
fi

# Finder icon positions (create-dmg): symmetric around window center so the pair reads as one install cluster.
if [[ "${DMG_AUTO_LAYOUT_ICONS:-1}" == "1" ]]; then
  CENTER_X=$(( WINDOW_WIDTH / 2 ))
  HALF_SPREAD=$(( WINDOW_WIDTH * DMG_ICON_HALF_SPREAD_PERCENT / 100 ))
  APP_X=$(( CENTER_X - HALF_SPREAD ))
  APPS_X=$(( CENTER_X + HALF_SPREAD ))
  ICON_Y=$(( WINDOW_HEIGHT * DMG_ICON_Y_PERCENT / 100 ))
  APP_Y="$ICON_Y"
  APPS_Y="$ICON_Y"
  echo "DMG icon layout (auto): center x=${CENTER_X}, half-spread=${HALF_SPREAD}px (${DMG_ICON_HALF_SPREAD_PERCENT}% of width) → app @ ${APP_X},${APP_Y} · Applications @ ${APPS_X},${APPS_Y}"
fi

rm -f "$FINAL_DMG_PATH"

if [[ "$ENABLE_DMG_LAYOUT" == "1" ]]; then
  echo "Creating styled DMG with create-dmg..."
  "$CREATE_DMG" \
    --volname "$VOLUME_NAME" \
    --window-pos "$WINDOW_X1" "$WINDOW_Y1" \
    --window-size "$WINDOW_WIDTH" "$WINDOW_HEIGHT" \
    --icon-size "$DMG_ICON_SIZE" \
    --text-size "$DMG_TEXT_SIZE" \
    --icon "$APP_NAME.app" "$APP_X" "$APP_Y" \
    --app-drop-link "$APPS_X" "$APPS_Y" \
    --background "$BACKGROUND_SOURCE" \
    "$FINAL_DMG_PATH" \
    "$APP_PATH"
else
  echo "Creating plain DMG with create-dmg..."
  "$CREATE_DMG" \
    --volname "$VOLUME_NAME" \
    --window-pos "$WINDOW_X1" "$WINDOW_Y1" \
    --window-size "$WINDOW_WIDTH" "$WINDOW_HEIGHT" \
    --icon-size "$DMG_ICON_SIZE" \
    --text-size "$DMG_TEXT_SIZE" \
    --icon "$APP_NAME.app" "$APP_X" "$APP_Y" \
    --app-drop-link "$APPS_X" "$APPS_Y" \
    "$FINAL_DMG_PATH" \
    "$APP_PATH"
fi

# create-dmg uses a temp read-write file rw.<pid>.<outputBasename> then deletes it; stale copies stay if a run was interrupted.
find "$DIST_DIR" -maxdepth 1 -name "rw.*.$(basename "$FINAL_DMG_PATH")" -delete 2>/dev/null || true

# Sign the DMG container itself before notarization. Must happen before notarize+staple — running
# codesign on an already-stapled DMG strips the ticket and forces a re-notarization.
if [[ "${ENABLE_CODESIGN:-0}" == "1" ]]; then
  if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
    echo "ENABLE_CODESIGN=1 requires CODESIGN_IDENTITY to be set." >&2
    exit 1
  fi
  echo "Signing DMG with Developer ID..."
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$FINAL_DMG_PATH"
fi

# Notarize + staple. Without this, a freshly downloaded (quarantined) DMG is rejected by
# Gatekeeper with "not safe / move to Trash" even though it is Developer ID signed.
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials "<profile>" --apple-id you@example.com \
#     --team-id P4HYHYKX7H --password <app-specific-password>
if [[ "${ENABLE_NOTARIZE:-0}" == "1" ]]; then
  if [[ "${ENABLE_CODESIGN:-0}" != "1" ]]; then
    echo "ENABLE_NOTARIZE=1 requires ENABLE_CODESIGN=1 (notarization needs a Developer ID signature)." >&2
    exit 1
  fi
  if [[ -z "${NOTARY_PROFILE:-}" ]]; then
    echo "ENABLE_NOTARIZE=1 requires NOTARY_PROFILE (a notarytool keychain profile name)." >&2
    exit 1
  fi
  echo "Submitting DMG to Apple notary service (this can take a few minutes)..."
  xcrun notarytool submit "$FINAL_DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "Stapling notarization ticket to DMG..."
  xcrun stapler staple "$FINAL_DMG_PATH"
  echo "Verifying Gatekeeper acceptance..."
  spctl -a -vvv -t install "$FINAL_DMG_PATH"
fi

echo "Built DMG:"
echo "  $FINAL_DMG_PATH"
