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

# Keep the bundle's version in step with the tag. Idempotent: re-running for a
# version that is already set does not keep inflating the build number, which
# matters in CI where the version comes from the tag rather than from here.
CURRENT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" packaging/Info.plist)
if [[ "${CURRENT_VERSION}" != "${VERSION}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" packaging/Info.plist
    CURRENT_BUILD=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" packaging/Info.plist)
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $((CURRENT_BUILD + 1))" packaging/Info.plist
    echo "==> Version set to ${VERSION} (build $((CURRENT_BUILD + 1)))"
fi

./build.sh

echo "==> Packaging ${ZIP}"
rm -f "${ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"

if [[ -n "${NOTARY_PROFILE:-}" || -n "${APPLE_ID:-}" ]]; then
    echo "==> Notarising (this takes a few minutes)"
    if [[ -n "${NOTARY_PROFILE:-}" ]]; then
        xcrun notarytool submit "${ZIP}" --keychain-profile "${NOTARY_PROFILE}" --wait
    else
        # CI path: credentials arrive as environment variables instead of a
        # keychain profile.
        xcrun notarytool submit "${ZIP}" \
            --apple-id "${APPLE_ID}" \
            --team-id "${APPLE_TEAM_ID}" \
            --password "${APPLE_ID_PASSWORD}" --wait
    fi

    # The ticket staples onto the .app, not the zip, so the app has to be
    # re-zipped afterwards for the download to carry it.
    echo "==> Stapling"
    xcrun stapler staple "${APP}"
    xcrun stapler validate "${APP}"
    rm -f "${ZIP}"
    ditto -c -k --sequesterRsrc --keepParent "${APP}" "${ZIP}"
    echo "==> Notarised and stapled"
else
    echo "!! No notary credentials — shipping signed but un-notarised." >&2
    echo "   Users will need to right-click → Open on first launch." >&2
fi

echo "==> Verifying what Gatekeeper will see"
spctl --assess --type execute --verbose=2 "${APP}" 2>&1 | sed 's/^/    /' || true

# Sparkle appcast. The app polls this file for updates and verifies the download
# against the EdDSA signature written here, so it has to be regenerated from the
# exact archive that gets uploaded.
SIGN_UPDATE=$(find .build -name "sign_update" -type f 2>/dev/null | head -1)
if [[ -z "${SIGN_UPDATE}" ]]; then
    echo "!! sign_update not found under .build — run 'swift build' first" >&2
    exit 1
fi

BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" packaging/Info.plist)
DOWNLOAD_URL="https://github.com/iamzifei/audioswitch/releases/download/v${VERSION}/AudioSwitch.zip"

echo "==> Updating appcast.xml"
# sign_update reads the EdDSA private key from the login keychain. The first
# time a given binary does that, macOS puts up an authorisation dialog and the
# command blocks until it is answered — choose "Always Allow" so later releases
# run unattended. If this step appears to hang, that dialog is what it is
# waiting on.
# Signs with the EdDSA private key held in the login keychain; --key-file is
# only needed in CI, where the key arrives as a secret instead.
if [[ -n "${SPARKLE_KEY_FILE:-}" ]]; then
    python3 scripts/update_appcast.py \
        --appcast appcast.xml --archive "${ZIP}" \
        --version "${VERSION}" --build "${BUILD_NUMBER}" \
        --url "${DOWNLOAD_URL}" \
        --sign-tool "${SIGN_UPDATE}" --key-file "${SPARKLE_KEY_FILE}" \
        --min-system 14.0
else
    SIGNATURE=$("${SIGN_UPDATE}" "${ZIP}" -p)
    LENGTH=$(stat -f%z "${ZIP}")
    python3 - "${VERSION}" "${BUILD_NUMBER}" "${DOWNLOAD_URL}" "${SIGNATURE}" "${LENGTH}" <<'PYTHON'
import sys, os
sys.path.insert(0, "scripts")
from update_appcast import APPCAST_TEMPLATE, build_item
from types import SimpleNamespace

version, build, url, signature, length = sys.argv[1:6]
args = SimpleNamespace(version=version, build=build, url=url, min_system="14.0")

path = "appcast.xml"
if not os.path.exists(path):
    open(path, "w").write(APPCAST_TEMPLATE)
xml = open(path).read()

marker = f"<title>{version}</title>"
if marker in xml:
    start = xml.rfind("    <item>", 0, xml.index(marker))
    end = xml.index("</item>", xml.index(marker)) + len("</item>\n")
    xml = xml[:start] + xml[end:]

insert_at = xml.index("</language>") + len("</language>\n")
xml = xml[:insert_at] + build_item(args, signature, int(length)) + xml[insert_at:]
open(path, "w").write(xml)
print(f"appcast updated: {version} (build {build}, {length} bytes)")
PYTHON
fi

echo
echo "Built ${ZIP} and updated appcast.xml. To publish:"
echo "  git commit -am 'Release ${VERSION}' && git tag v${VERSION} && git push --follow-tags"
echo "  gh release create v${VERSION} ${ZIP} --title 'AudioSwitch ${VERSION}' --notes '…'"
echo
echo "The appcast must be on main before the app will see the update."
