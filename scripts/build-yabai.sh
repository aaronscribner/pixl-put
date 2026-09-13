#!/usr/bin/env bash
# Build yabai from the vendored fork, sign it with the same Developer ID
# PixPut uses, and install it at a stable path in /Applications.
#
# Why build it ourselves instead of using Homebrew's binary: macOS ties the
# Accessibility grant to the binary's code-signing identity. Homebrew's yabai
# is ad-hoc signed, so its identity is the hash of the bytes, and every
# upgrade is a new program that has to be re-approved by hand. Signed with
# our Developer ID, the identity is "yabai signed by us", which survives
# rebuilds — the same reason build-app.sh signs PixPut.
#
# Sudo is used only to write into the install directory when it is root-owned,
# as /Applications/Utilities is. The rest of the privileged setup (sudoers rule
# for --load-sa, scripting addition, launch agent) is scripts/setup-yabai.sh,
# run once and after any yabai rebuild that changes the binary.
#
# Usage:
#   scripts/build-yabai.sh                 # build, sign, install to /Applications/Utilities/yabai
#   SIGN_IDENTITY="" scripts/build-yabai.sh   # build unsigned (dev machines without the cert)
#   YABAI_INSTALL_PATH=/some/where scripts/build-yabai.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/vendor/yabai"
# yabai ships as an .app bundle, not a bare executable. TCC refuses to create
# an Accessibility record for a bare Mach-O: tccd logs "resolves to attributed
# bundle: (null)" and then "DB Action: None", so no row is written and the
# binary can never appear in System Settings — neither the permission prompt
# nor the "+" button can add it. Inside a bundle it has an identity TCC can
# record. yabai itself does not care; it finds its own path at runtime.
INSTALL_APP="${YABAI_INSTALL_APP:-/Applications/Utilities/yabai.app}"
INSTALL_PATH="${INSTALL_APP}/Contents/MacOS/yabai"
DEFAULT_IDENTITY="Developer ID Application: Aaron Scribner (8P9LPVFM5R)"
SIGN_IDENTITY="${SIGN_IDENTITY-${DEFAULT_IDENTITY}}"

if [[ ! -f "${SRC}/makefile" ]]; then
    echo "==> fetching vendor/yabai submodule"
    git -C "${ROOT}" submodule update --init --recursive vendor/yabai
fi

echo "==> building yabai ($(git -C "${SRC}" describe --tags --always))"
# `install` is the fork's release-flags target; it builds bin/yabai and
# installs nothing. It embeds the scripting-addition payload and loader
# (xxd into C arrays), so xxd and the Xcode command line tools are required.
( cd "${SRC}" && make install >/dev/null )
BUILT="${SRC}/bin/yabai"
[[ -x "${BUILT}" ]] || { echo "ERROR: build produced no binary at ${BUILT}" >&2; exit 1; }

echo "==> assembling $(basename "${INSTALL_APP}")"
# Staged next to the binary, then copied into place as a whole.
STAGE="${SRC}/bin/$(basename "${INSTALL_APP}")"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/Contents/MacOS"
cp "${BUILT}" "${STAGE}/Contents/MacOS/yabai"
chmod 755 "${STAGE}/Contents/MacOS/yabai"
YABAI_VERSION="$( "${BUILT}" --version 2>/dev/null | sed 's/^yabai-v//' )"
# LSUIElement keeps it out of the Dock and the app switcher; it is a daemon
# that merely needs a bundle so TCC will record an Accessibility decision.
cat > "${STAGE}/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>yabai</string>
	<key>CFBundleIdentifier</key>
	<string>co.cerebraljuice.yabai</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>yabai</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${YABAI_VERSION:-0}</string>
	<key>CFBundleVersion</key>
	<string>${YABAI_VERSION:-0}</string>
	<key>LSMinimumSystemVersion</key>
	<string>11.0</string>
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
PLIST

if [[ -n "${SIGN_IDENTITY}" ]] && security find-identity -p codesigning -v 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
    echo "==> codesign --sign '${SIGN_IDENTITY}'"
    # No hardened runtime: yabai injects its scripting addition into Dock and
    # loads private frameworks; the hardened runtime would only get in the way
    # and gains nothing for a local, unsandboxed tool.
    codesign --force --sign "${SIGN_IDENTITY}" --identifier "co.cerebraljuice.yabai" "${STAGE}"
    codesign --verify --deep --verbose=2 "${STAGE}" >/dev/null
    echo "    signature valid; Accessibility grant will survive rebuilds"
else
    echo "==> codesign SKIPPED (identity '${SIGN_IDENTITY}' not in keychain, or SIGN_IDENTITY='')"
    echo "    the Accessibility grant will have to be re-added after every rebuild"
fi

echo "==> installing to ${INSTALL_APP}"
INSTALL_DIR="$(dirname "${INSTALL_APP}")"
if [[ ! -d "${INSTALL_DIR}" ]]; then
    echo "ERROR: ${INSTALL_DIR} does not exist; set YABAI_INSTALL_APP" >&2
    exit 1
fi
# /Applications/Utilities is root-owned, so installing there needs sudo even
# for an admin user. Escalate only when the directory is actually read-only.
# A function rather than an array: bash 3.2, which is what macOS ships,
# treats an empty array as unbound under `set -u`.
if [[ -w "${INSTALL_DIR}" ]]; then
    as_installer() { "$@"; }
else
    echo "    ${INSTALL_DIR} is not writable by $(whoami); using sudo (the prompt is sudo's)"
    as_installer() { sudo "$@"; }
fi
# Replace wholesale: ditto merges rather than removing files the new bundle
# no longer has, and a half-updated bundle fails signature validation.
as_installer rm -rf "${INSTALL_APP}"
as_installer ditto "${STAGE}" "${INSTALL_APP}"

echo
echo "Installed $( "${INSTALL_PATH}" --version ) at ${INSTALL_APP}."
echo "If the binary changed, run scripts/setup-yabai.sh to refresh the sudoers hash and restart the service."
