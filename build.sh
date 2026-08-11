#!/bin/bash
#
# Builds AudioSwitch.app — a release, Apple-Silicon-native menu bar app bundle.
#
# Usage:
#   ./build.sh            build ./AudioSwitch.app
#   ./build.sh --install  build, then copy into /Applications and relaunch it
#
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="AudioSwitch"
APP_BUNDLE="${PROJECT_DIR}/${APP_NAME}.app"
INSTALL_DIR="/Applications"

cd "${PROJECT_DIR}"

echo "==> Running tests"
swift test

echo "==> Building release binary (arm64)"
swift build -c release --arch arm64

echo "==> Rendering app icon"
# The icon is drawn from code (packaging/make_icon.swift) so it always matches
# Apple's current geometry; regenerate it on every build rather than checking a
# stale binary into the tree.
swift packaging/make_icon.swift packaging/AppIcon.icns > /dev/null

echo "==> Assembling ${APP_NAME}.app"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp ".build/arm64-apple-macosx/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "packaging/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "packaging/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

# SwiftPM emits localizations into its own resource bundle. Bundle.module looks
# for it inside Contents/Resources, so it has to be copied in — without this the
# app silently falls back to the base language.
RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/AudioSwitch_AudioSwitch.bundle"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/Resources/"
else
    echo "!! resource bundle missing at ${RESOURCE_BUNDLE} — localizations will not load" >&2
    exit 1
fi

# Ad-hoc signature. Enough for local use; replace "-" with a Developer ID
# identity if the app is ever distributed to other machines.
echo "==> Signing (ad-hoc)"
codesign --force --sign - --timestamp=none "${APP_BUNDLE}"
codesign --verify --verbose "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'

echo "==> Built ${APP_BUNDLE}"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to ${INSTALL_DIR}"
    # Quit any running copy first so the bundle can be replaced cleanly.
    pkill -x "${APP_NAME}" 2>/dev/null || true
    sleep 1
    rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
    cp -R "${APP_BUNDLE}" "${INSTALL_DIR}/"
    open "${INSTALL_DIR}/${APP_NAME}.app"
    echo "==> Installed and launched: ${INSTALL_DIR}/${APP_NAME}.app"
fi
