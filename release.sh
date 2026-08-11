#!/bin/bash
#
# Builds, signs, notarises and publishes a release.
#
#   CODESIGN_IDENTITY="Developer ID Application: … (TEAMID)" \
#   NOTARY_PROFILE=<profile> \
#   ./release.sh 1.3.0
#
# NOTARY_PROFILE is a keychain profile created once with:
#   xcrun notarytool store-credentials <profile> \
#     --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>
#
# Without NOTARY_PROFILE the zip is signed but not notarised, and users have to
# right-click → Open on first launch.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
if [[ -z "${VERSION}" ]]; then
    echo "usage: ./release.sh <version>   e.g. ./release.sh 1.3.0" >&2
    exit 1
fi

APP="AudioSwitch.app"
ZIP="AudioSwitch.zip"

if [[ "${CODESIGN_IDENTITY:--}" == "-" ]]; then
    echo "!! CODESIGN_IDENTITY is not set — the build would be ad-hoc signed" >&2
    echo "   and rejected by Gatekeeper on other machines." >&2
    exit 1
fi

# Keep the bundle's version in step with the tag.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" packaging/Info.plist
CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" packaging/Info.plist)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" packaging/Info.plist

./build.sh

echo "==> Packaging ${ZIP}"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    echo "==> Notarising (this takes a few minutes)"
    xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait

    # The ticket staples onto the .app, not the zip, so the app has to be
    # re-zipped afterwards for the download to carry it.
    echo "==> Stapling"
    xcrun stapler staple "${APP}"
    xcrun stapler validate "${APP}"
    rm -f "${ZIP}"
    ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"
    echo "==> Notarised and stapled"
else
    echo "!! NOTARY_PROFILE not set — shipping signed but un-notarised." >&2
    echo "   Users will need to right-click → Open on first launch." >&2
fi

echo "==> Verifying what Gatekeeper will see"
spctl --assess --type execute --verbose=2 "${APP}" 2>&1 | sed 's/^/    /' || true

echo
echo "Built ${ZIP}. To publish:"
echo "  git commit -am 'Release ${VERSION}' && git tag v${VERSION} && git push --follow-tags"
echo "  gh release create v${VERSION} ${ZIP} --title 'AudioSwitch ${VERSION}' --notes '…'"
