#!/bin/bash
# Builds, signs (Developer ID + hardened runtime), notarizes and staples
# Chatwerk, producing a distributable dist/Chatwerk.dmg.
#
# Requirements:
#   - a "Developer ID Application" certificate in the login keychain
#   - an App Store Connect API key with the Developer role or higher
#
# Configuration via environment (or an untracked .notarize.env in the repo root):
#   ASC_KEY_PATH   path to the AuthKey_XXXXXXXX.p8 file
#   ASC_KEY_ID     the key id (XXXXXXXX)
#   ASC_ISSUER_ID  the issuer id (UUID)
#   IDENTITY       optional signing identity override (auto-detected otherwise)
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .notarize.env ] && source .notarize.env
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH to your App Store Connect API key (.p8) — see script header}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID}"

IDENTITY="${IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"
if [ -z "$IDENTITY" ]; then
    echo "error: no 'Developer ID Application' certificate in the keychain." >&2
    echo "Create one in Xcode → Settings → Accounts → Manage Certificates… → + → Developer ID Application." >&2
    exit 1
fi
echo "→ signing as: $IDENTITY"

make app

echo "→ codesign (hardened runtime)"
codesign --force --options runtime --timestamp \
    --entitlements Chatwerk/Chatwerk.entitlements \
    --sign "$IDENTITY" dist/Chatwerk.app
codesign --verify --strict --verbose=2 dist/Chatwerk.app

echo "→ notarize app"
ditto -c -k --keepParent dist/Chatwerk.app dist/Chatwerk.zip
xcrun notarytool submit dist/Chatwerk.zip \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait
xcrun stapler staple dist/Chatwerk.app
rm -f dist/Chatwerk.zip

echo "→ build + sign + notarize dmg"
rm -f dist/Chatwerk.dmg
hdiutil create -volname Chatwerk -srcfolder dist/Chatwerk.app -ov -format UDZO dist/Chatwerk.dmg
codesign --force --sign "$IDENTITY" dist/Chatwerk.dmg
xcrun notarytool submit dist/Chatwerk.dmg \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait
xcrun stapler staple dist/Chatwerk.dmg

echo "→ gatekeeper check"
spctl --assess --type execute --verbose dist/Chatwerk.app

echo "→ done"
shasum -a 256 dist/Chatwerk.dmg
