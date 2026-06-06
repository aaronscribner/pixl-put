#!/usr/bin/env bash
# Sparkle release pipeline: zip + sign the new build, then append a
# new <item> to appcast.xml.
#
# Prerequisites (one-time setup):
#
#   1. Run `sparkle_generate_keys` once on this machine. It stores the
#      EdDSA private key in your login Keychain and prints the public key.
#      → Paste the public key into Resources/Info.plist as `SUPublicEDKey`,
#        replacing `TODO_REPLACE_WITH_REAL_EDDSA_PUBLIC_KEY`.
#
#   2. `scripts/release-app.sh` must have been run successfully (so
#      build/PixlPut.app is signed + notarised + stapled).
#
#   3. Set up updates hosting at the SUFeedURL host (default
#      https://updates.pixput.app/). CF Pages, S3, anywhere serving static
#      files works — the URL in Info.plist must point to a writable bucket.
#
# Usage:
#   VERSION="0.2.0"  ./scripts/sparkle-release.sh
#
# What this does:
#   1. Locate the sparkle_sign_update tool (bundled in Sparkle's
#      SwiftPM artifact bundle at .build/artifacts/.../bin/).
#   2. `ditto -c -k --keepParent build/PixlPut.app build/PixlPut-VERSION.zip`.
#   3. `sparkle_sign_update PixlPut-VERSION.zip` → captures sparkle:edSignature
#      and length (bytes).
#   4. Generate a new <item> XML snippet for appcast.xml.
#   5. Print upload instructions.

set -euo pipefail

VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" build/PixlPut.app/Contents/Info.plist)}"
APP_BUNDLE="build/PixlPut.app"
ZIP="build/PixlPut-${VERSION}.zip"
APPCAST_LOCAL="build/appcast-snippet-${VERSION}.xml"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "❌ $APP_BUNDLE not found. Run scripts/release-app.sh first." >&2
    exit 1
fi

echo "==> Locating sparkle_sign_update..."
SIGN_TOOL=$(find .build/artifacts -type f -name 'sign_update' 2>/dev/null | head -1)
if [[ -z "$SIGN_TOOL" ]]; then
    # SwiftPM hasn't extracted the artifact bundle yet — trigger a build.
    swift build > /dev/null
    SIGN_TOOL=$(find .build/artifacts -type f -name 'sign_update' 2>/dev/null | head -1)
fi
if [[ -z "$SIGN_TOOL" ]]; then
    echo "❌ Couldn't find sparkle sign_update. Did Sparkle SwiftPM resolve?" >&2
    exit 1
fi
echo "    sign_update: $SIGN_TOOL"

echo "==> Zipping $APP_BUNDLE → $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP_BUNDLE" "$ZIP"
SIZE=$(stat -f%z "$ZIP")
echo "    $ZIP ($SIZE bytes)"

echo "==> Signing the zip..."
SIGN_OUT=$("$SIGN_TOOL" "$ZIP")
echo "$SIGN_OUT"
# Capture the sparkle:edSignature value (the tool prints
# sparkle:edSignature="..." length="..." for direct paste into appcast.xml).

PUB_DATE=$(date -R)

cat > "$APPCAST_LOCAL" <<EOF
        <item>
            <title>Version ${VERSION}</title>
            <pubDate>${PUB_DATE}</pubDate>
            <sparkle:version>${VERSION}</sparkle:version>
            <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <description><![CDATA[
                <ul>
                    <li>(release notes here)</li>
                </ul>
            ]]></description>
            <enclosure
                url="https://updates.pixput.app/PixlPut-${VERSION}.zip"
                length="${SIZE}"
                type="application/octet-stream"
                ${SIGN_OUT}
            />
        </item>
EOF

echo "==> Appcast snippet written to $APPCAST_LOCAL"
echo
echo "Next steps:"
echo "  1. Upload  $ZIP  to https://updates.pixput.app/PixlPut-${VERSION}.zip"
echo "  2. Insert the contents of $APPCAST_LOCAL into appcast.xml under <channel>"
echo "  3. Upload the updated appcast.xml to https://updates.pixput.app/appcast.xml"
echo "  4. Bump CFBundleShortVersionString in Resources/Info.plist for next release"
