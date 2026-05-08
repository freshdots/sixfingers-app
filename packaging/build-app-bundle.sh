#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PACKAGING_DIR="$ROOT_DIR/packaging"
DEFAULT_ENV_FILE="$PACKAGING_DIR/.env"
ENV_FILE="${BUILD_ENV_FILE:-$DEFAULT_ENV_FILE}"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

APP_NAME="SixFingers"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLIST_TEMPLATE="$PACKAGING_DIR/sixfingers-info.plist"
SOURCE_RESOURCES_DIR="$ROOT_DIR/Resources"
DEFAULT_ENTITLEMENTS_PATH="$PACKAGING_DIR/sixfingers-entitlements.plist"
ENTITLEMENTS_PATH="${ENTITLEMENTS_PATH:-$DEFAULT_ENTITLEMENTS_PATH}"
ENABLE_CODESIGN="${ENABLE_CODESIGN:-0}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-}"

if [[ ! -f "$PLIST_TEMPLATE" ]]; then
  echo "Missing Info.plist template: $PLIST_TEMPLATE" >&2
  exit 1
fi

if [[ ! -d "$SOURCE_RESOURCES_DIR" ]]; then
  echo "Missing resources directory: $SOURCE_RESOURCES_DIR" >&2
  exit 1
fi

if [[ "$ENABLE_CODESIGN" == "1" ]]; then
  if [[ -z "$CODESIGN_IDENTITY" ]]; then
    echo "ENABLE_CODESIGN=1 requires CODESIGN_IDENTITY to be set." >&2
    exit 1
  fi
  if [[ ! -f "$ENTITLEMENTS_PATH" ]]; then
    echo "Missing entitlements file: $ENTITLEMENTS_PATH" >&2
    exit 1
  fi
fi

echo "Building release binary..."
swift build -c release --package-path "$ROOT_DIR"

BIN_DIR="$(swift build -c release --package-path "$ROOT_DIR" --show-bin-path)"
BIN_PATH="$BIN_DIR/$APP_NAME"

if [[ ! -x "$BIN_PATH" ]]; then
  echo "Release binary not found at: $BIN_PATH" >&2
  exit 1
fi

echo "Preparing app bundle at $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$BIN_PATH" "$MACOS_DIR/$APP_NAME"
cp "$PLIST_TEMPLATE" "$CONTENTS_DIR/Info.plist"
printf "APPL????" > "$CONTENTS_DIR/PkgInfo"

echo "Copying app resources..."
rsync -a --delete --exclude ".DS_Store" "$SOURCE_RESOURCES_DIR/" "$RESOURCES_DIR/"

if [[ "$ENABLE_CODESIGN" == "1" ]]; then
  echo "Signing app bundle with Hardened Runtime..."
  codesign --force --deep --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS_PATH" \
    --sign "$CODESIGN_IDENTITY" \
    "$APP_DIR"
else
  # Swift ships a linker-signed binary; after we add Contents/Resources, that seal is wrong and
  # Launch Services can refuse to open (e.g. error -600). We resign the finished bundle ad hoc.
  echo "Ad-hoc signing app bundle (Resources + executable)..."
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "Built app bundle:"
echo "  $APP_DIR"

echo "Verifying code signature..."
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
