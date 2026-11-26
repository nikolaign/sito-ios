#!/bin/bash
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="$REPO_DIR/build"
DERIVED_DATA="$BUILD_DIR/DerivedData"
APP_PATH="$DERIVED_DATA/Build/Products/Release-iphoneos/Sito.app"
APP_VERSION="0.9.5"
IPA_PATH="$BUILD_DIR/SITO-${APP_VERSION}-unsigned.ipa"

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Xcode is required. Run this script on a Mac with Xcode installed." >&2
    exit 1
fi

mkdir -p "$BUILD_DIR"

xcodebuild \
    -project "$REPO_DIR/Sito.xcodeproj" \
    -scheme Sito \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    build

if [[ ! -d "$APP_PATH" ]]; then
    echo "Build completed, but Sito.app was not found at $APP_PATH" >&2
    exit 1
fi

STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sito-ipa.XXXXXX")"
trap 'rm -rf -- "$STAGING_DIR"' EXIT
mkdir -p "$STAGING_DIR/Payload"
ditto "$APP_PATH" "$STAGING_DIR/Payload/Sito.app"

# An IPA is a ZIP archive with the app inside a top-level Payload directory.
(cd "$STAGING_DIR" && /usr/bin/zip -qry "$IPA_PATH" Payload)

echo
echo "Unsigned IPA ready: $IPA_PATH"
echo "Use this only with a compatible test/sideloading setup such as LiveContainer."
