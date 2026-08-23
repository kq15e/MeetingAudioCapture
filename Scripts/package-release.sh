#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "Usage: Scripts/package-release.sh v<major>.<minor>.<patch>" >&2
    exit 64
fi

RELEASE_TAG="$1"
if [[ ! "$RELEASE_TAG" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    echo "Release tag must use semantic version format: v<major>.<minor>.<patch>" >&2
    exit 64
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/Resources/Info.plist"
RELEASE_VERSION="${RELEASE_TAG#v}"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$INFO_PLIST")"

if [[ "$PLIST_VERSION" != "$RELEASE_VERSION" ]]; then
    echo "Tag version $RELEASE_VERSION does not match Info.plist version $PLIST_VERSION" >&2
    exit 65
fi

"$ROOT_DIR/Scripts/package-app.sh"

APP_PATH="$ROOT_DIR/.build/release/MeetingAudioCapture.app"
ARCHIVE_NAME="MeetingAudioCapture-$RELEASE_TAG-macos-arm64.zip"
ARCHIVE_PATH="$ROOT_DIR/.build/release/$ARCHIVE_NAME"
CHECKSUM_PATH="$ARCHIVE_PATH.sha256"
BINARY_PATH="$APP_PATH/Contents/MacOS/MeetingAudioCapture"

codesign --verify --deep --strict --verbose=2 "$APP_PATH"
plutil -lint "$APP_PATH/Contents/Info.plist"

ARCHITECTURES="$(lipo -archs "$BINARY_PATH")"
if [[ "$ARCHITECTURES" != "arm64" ]]; then
    echo "Release binary must contain only arm64, found: $ARCHITECTURES" >&2
    exit 66
fi

rm -f "$ARCHIVE_PATH" "$CHECKSUM_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ARCHIVE_PATH"

(
    cd "$(dirname "$ARCHIVE_PATH")"
    shasum -a 256 "$ARCHIVE_NAME" > "$(basename "$CHECKSUM_PATH")"
)

echo "$ARCHIVE_PATH"
echo "$CHECKSUM_PATH"
