#!/bin/sh
# Build a release WorkTracker.app from WorkTracker.xcodeproj.
#
#   scripts/build-app.sh [output-folder]          # default: .build/app
#   BUNDLE_ID=com.example.test scripts/build-app.sh /tmp/test   # separate settings domain
#
# Xcode compiles the String Catalogs (UI, Info.plist privacy strings, Siri phrases), the
# Liquid Glass icon (Resources/AppIcon.icon → Assets.car + AppIcon.icns), extracts the
# App Intents metadata Siri and Shortcuts read, and signs the app (ad hoc, hardened
# runtime, microphone entitlement).
set -eu
cd "$(dirname "$0")/.."

OUT="${1:-.build/app}"
BUNDLE_ID="${BUNDLE_ID:-com.worktracker.app}"
VERSION="${VERSION:-1.7}"
BUILD="${BUILD:-11}"
DERIVED=.build/xcode

xcodebuild -project WorkTracker.xcodeproj -scheme WorkTracker -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" -quiet \
    PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    build

APP="$OUT/WorkTracker.app"
mkdir -p "$OUT"
rm -rf "$APP"
ditto "$DERIVED/Build/Products/Release/WorkTracker.app" "$APP"
echo "Built $APP ($BUNDLE_ID $VERSION/$BUILD)"
