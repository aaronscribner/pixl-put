#!/usr/bin/env bash
# Build the `.app` bundle.
#
# Wraps the SwiftPM-produced executable into a macOS .app structure and
# signs it with Developer ID Application (if a matching identity is in the
# keychain) so the Designated Requirement stays stable across rebuilds —
# TCC grants for Accessibility and Automation persist. Falls back to
# unsigned for machines without a signing identity.
#
# For notarisation + stapling (required for distribution / Gatekeeper),
# use scripts/release-app.sh.
#
# Usage:
#   ./scripts/build-app.sh                # debug build, auto-sign if identity present
#   ./scripts/build-app.sh release        # release-config build
#   SIGN_IDENTITY="" ./scripts/build-app.sh   # force unsigned

set -euo pipefail

CONFIG="${1:-debug}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${ROOT}/build"
APP_BUNDLE="${BUILD_DIR}/PixlPut.app"
CONTENTS="${APP_BUNDLE}/Contents"
MACOS_DIR="${CONTENTS}/MacOS"
RES_DIR="${CONTENTS}/Resources"

# yabai is PixPut's per-window Space actuator (ADR-0002). It is built from
# the vendored fork, signed with the same Developer ID as the app, and
# installed at a stable path, so its Accessibility grant survives rebuilds.
# SKIP_YABAI=1 skips it (CI, machines that only need the app).
if [[ "${SKIP_YABAI:-0}" != "1" ]]; then
    "${ROOT}/scripts/build-yabai.sh"
fi

echo "==> swift build (${CONFIG})"
( cd "${ROOT}" && swift build -c "${CONFIG}" )

BIN_PATH="$( cd "${ROOT}" && swift build -c "${CONFIG}" --show-bin-path )"
EXE="${BIN_PATH}/PixlPut"

if [[ ! -x "${EXE}" ]]; then
    echo "ERROR: built executable not found at ${EXE}" >&2
    exit 1
fi

echo "==> assembling ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
FRAMEWORKS_DIR="${CONTENTS}/Frameworks"
mkdir -p "${MACOS_DIR}" "${RES_DIR}" "${FRAMEWORKS_DIR}"

cp "${EXE}" "${MACOS_DIR}/PixlPut"
cp "${ROOT}/Resources/Info.plist" "${CONTENTS}/Info.plist"

# Minimal PkgInfo so Finder recognises the bundle.
printf "APPL????" > "${CONTENTS}/PkgInfo"

# Sparkle.framework — bundle the framework SwiftPM resolved into
# Contents/Frameworks/. Without this, launch crashes with "Sparkle not
# found". Sparkle has nested XPC services and an Updater.app inside that
# all need to be signed independently — see the codesign section below.
SPARKLE_SRC="${BIN_PATH}/Sparkle.framework"
if [[ -d "${SPARKLE_SRC}" ]]; then
    echo "==> copying Sparkle.framework"
    rsync -a "${SPARKLE_SRC}/" "${FRAMEWORKS_DIR}/Sparkle.framework/"
else
    echo "    WARNING: Sparkle.framework not found at ${SPARKLE_SRC} — updater will crash at launch"
fi

echo "==> bundle ready: ${APP_BUNDLE}"

# Auto-sign with Developer ID Application if a matching identity is present.
# Keeps the binary's Designated Requirement stable across rebuilds so TCC
# (Accessibility, Automation) grants persist — no toggle-off-then-on dance.
# Falls back gracefully when no identity is configured, so the script
# remains portable to machines without signing credentials.
DEFAULT_IDENTITY="Developer ID Application: Aaron Scribner (8P9LPVFM5R)"
SIGN_IDENTITY="${SIGN_IDENTITY-${DEFAULT_IDENTITY}}"
ENTITLEMENTS="${ROOT}/Resources/Entitlements.plist"

if [[ -n "${SIGN_IDENTITY}" ]] && security find-identity -p codesigning -v 2>/dev/null | grep -q "${SIGN_IDENTITY}"; then
    # Sign INSIDE-OUT: nested code first (XPC services, Autoupdate, Updater.app,
    # the Sparkle framework binary), then the outer .app. `--deep` is deprecated
    # by Apple — explicit nested signing is the supported path.
    if [[ -d "${FRAMEWORKS_DIR}/Sparkle.framework" ]]; then
        SP_VERSION_DIR="${FRAMEWORKS_DIR}/Sparkle.framework/Versions/B"
        echo "==> codesign Sparkle nested artifacts"
        # XPC services
        for xpc in "${SP_VERSION_DIR}/XPCServices/"*.xpc; do
            [[ -d "$xpc" ]] || continue
            codesign --force --options runtime --sign "${SIGN_IDENTITY}" "$xpc"
        done
        # Autoupdate helper executable
        if [[ -e "${SP_VERSION_DIR}/Autoupdate" ]]; then
            codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${SP_VERSION_DIR}/Autoupdate"
        fi
        # Updater.app
        if [[ -d "${SP_VERSION_DIR}/Updater.app" ]]; then
            codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${SP_VERSION_DIR}/Updater.app"
        fi
        # Framework itself (signs the dylib + bundle metadata)
        codesign --force --options runtime --sign "${SIGN_IDENTITY}" "${FRAMEWORKS_DIR}/Sparkle.framework"
    fi

    echo "==> codesign --options runtime --sign '${SIGN_IDENTITY}'"
    codesign --force --options runtime \
        --entitlements "${ENTITLEMENTS}" \
        --sign "${SIGN_IDENTITY}" \
        "${APP_BUNDLE}"
    if codesign --verify --strict --verbose=2 "${APP_BUNDLE}" >/dev/null 2>&1; then
        echo "    signature valid; Designated Requirement stable across rebuilds."
    else
        echo "    WARNING: codesign verify failed — check signature manually."
    fi
else
    echo "==> codesign SKIPPED (identity '${SIGN_IDENTITY}' not in keychain, or SIGN_IDENTITY='')"
    echo "    Set SIGN_IDENTITY env var or run unsigned for local dev."
fi

echo
echo "Next steps:"
echo "  - Launch:        open ${APP_BUNDLE}"
echo "  - Run directly:  ${MACOS_DIR}/PixlPut"
echo
echo "Full release (signed + notarised + stapled): scripts/release-app.sh"
