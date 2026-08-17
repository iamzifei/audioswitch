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
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources" \
         "${APP_BUNDLE}/Contents/Frameworks"

cp ".build/arm64-apple-macosx/release/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "packaging/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
cp "packaging/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

# SwiftPM emits localizations into its own resource bundle, which has to be
# copied into Contents/Resources — the standard place for it inside an .app, and
# where Localization.resourceBundle looks first. (Not where SwiftPM's own
# `Bundle.module` accessor looks, which is why the app resolves it by hand; see
# the comment on Localization.resourceBundle.)
RESOURCE_BUNDLE=".build/arm64-apple-macosx/release/AudioSwitch_AudioSwitch.bundle"
if [[ -d "${RESOURCE_BUNDLE}" ]]; then
    cp -R "${RESOURCE_BUNDLE}" "${APP_BUNDLE}/Contents/Resources/"
else
    echo "!! resource bundle missing at ${RESOURCE_BUNDLE} — localizations will not load" >&2
    exit 1
fi

# Bundle Sparkle.framework. SwiftPM fetches it as a binary XCFramework, so the
# macOS slice has to be copied into the app for the runtime to resolve it
# against the @executable_path/../Frameworks rpath set in Package.swift.
SPARKLE_FRAMEWORK=$(find .build -type d -name "Sparkle.framework" -path "*macos*" 2>/dev/null | head -1)
if [[ -z "${SPARKLE_FRAMEWORK}" ]]; then
    echo "!! Sparkle.framework not found under .build — run 'swift build' first" >&2
    exit 1
fi
cp -R "${SPARKLE_FRAMEWORK}" "${APP_BUNDLE}/Contents/Frameworks/"
FRAMEWORK="${APP_BUNDLE}/Contents/Frameworks/Sparkle.framework"

# Signing.
#
# Set CODESIGN_IDENTITY to a "Developer ID Application: …" identity to produce a
# distributable build: that adds the hardened runtime and a secure timestamp,
# both of which the notary service requires. Without it the build is ad-hoc
# signed, which is fine for running locally but not for handing to anyone else.
#
# The entitlements file matters under the hardened runtime: microphone access is
# denied without com.apple.security.device.audio-input, so the input level meter
# would silently receive nothing.
IDENTITY="${CODESIGN_IDENTITY:--}"

sign() {
    if [[ "${IDENTITY}" == "-" ]]; then
        codesign --force --sign - --timestamp=none "$1"
    else
        codesign --force \
            --options runtime \
            --timestamp \
            --entitlements "packaging/AudioSwitch.entitlements" \
            --sign "${IDENTITY}" \
            "$1"
    fi
}

echo "==> Signing ($([[ "${IDENTITY}" == "-" ]] && echo ad-hoc || echo "${IDENTITY}"))"

# Sparkle's nested code has to be signed inside-out — XPC services, then the
# updater helpers, then the framework, then the app. The notary service rejects
# a bundle where any nested Mach-O is unsigned or signed after its container.
for xpc in "${FRAMEWORK}"/Versions/B/XPCServices/*.xpc; do
    [[ -e "${xpc}" ]] && sign "${xpc}"
done
[[ -e "${FRAMEWORK}/Versions/B/Updater.app" ]] && sign "${FRAMEWORK}/Versions/B/Updater.app"
[[ -e "${FRAMEWORK}/Versions/B/Autoupdate" ]] && sign "${FRAMEWORK}/Versions/B/Autoupdate"
sign "${FRAMEWORK}"
sign "${APP_BUNDLE}"

codesign --verify --strict --deep --verbose "${APP_BUNDLE}" 2>&1 | sed 's/^/    /'

# Smoke test: does the assembled bundle stand on its own?
#
# This is the check that was missing when v1.2.0 and v1.3.0 shipped. SwiftPM's
# generated `Bundle.module` falls back to the absolute path of the build
# directory, so a build with misplaced resources runs perfectly on the machine
# that produced it and crashes on launch everywhere else. Asserting that the
# resources resolve to a path *inside* the .app is what catches that here rather
# than in someone's Downloads folder.
echo "==> Smoke-testing the assembled app"
SMOKE_OUTPUT=$(AUDIOSWITCH_SMOKE_TEST=1 "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}" 2>&1) || {
    echo "${SMOKE_OUTPUT}" | sed 's/^/    /'
    echo "!! The app cannot load its localizations — do not ship this build." >&2
    exit 1
}
echo "${SMOKE_OUTPUT}" | sed 's/^/    /'

RESOLVED_RESOURCES=$(echo "${SMOKE_OUTPUT}" | sed -n 's/^resources: //p')
if [[ "${RESOLVED_RESOURCES}" != "$(cd "${APP_BUNDLE}" && pwd)"/* ]]; then
    echo "!! Resources resolved to ${RESOLVED_RESOURCES}, which is outside the app." >&2
    echo "   The build would only work on this machine." >&2
    exit 1
fi

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
