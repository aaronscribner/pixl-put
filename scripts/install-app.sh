#!/usr/bin/env bash
# Install PixlPut.app into /Applications and open it at every login.
#
# Restore after a restart only works if PixlPut is already running while
# macOS relaunches everyone else's apps, so the login item is part of the
# install, not a preference.
#
# The login item has to point at a path that outlives rebuilds: build-app.sh
# deletes and reassembles build/PixlPut.app on every run. Installed at a
# stable path, like yabai, the Developer ID signature keeps the Accessibility
# grant valid across reinstalls.
#
# Opening at login is a per-user launch agent rather than SMAppService or a
# System Events login item: a script can install it without the app running
# and without Automation consent. It shows in System Settings → General →
# Login Items & Extensions under "Allow in the Background", where it can be
# switched off.
#
# Usage:
#   scripts/install-app.sh                                 # install build/PixlPut.app, register, launch
#   PIXLPUT_INSTALL_APP=/some/where/PixlPut.app scripts/install-app.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_APP="${PIXLPUT_SOURCE_APP:-${ROOT}/build/PixlPut.app}"
INSTALL_APP="${PIXLPUT_INSTALL_APP:-/Applications/PixlPut.app}"
LABEL="co.cerebraljuice.pixlput.login"
AGENT_PLIST="${HOME}/Library/LaunchAgents/${LABEL}.plist"
DOMAIN="gui/$(id -u)"

if [[ ! -d "${SOURCE_APP}" ]]; then
    echo "ERROR: ${SOURCE_APP} not found; run scripts/build-app.sh first" >&2
    exit 1
fi
INSTALL_DIR="$(dirname "${INSTALL_APP}")"
if [[ ! -d "${INSTALL_DIR}" ]]; then
    echo "ERROR: ${INSTALL_DIR} does not exist; set PIXLPUT_INSTALL_APP" >&2
    exit 1
fi

echo "==> quitting running PixlPut"
# Every copy, installed or in build/: a second instance means two menu bar
# icons and two restore passes racing. SIGTERM rather than an Apple Event,
# because `quit app` from a script needs Automation consent; Info.plist
# declares sudden-termination support.
if pkill -x PixlPut; then
    for _ in $(seq 1 50); do
        pgrep -x PixlPut >/dev/null || break
        sleep 0.1
    done
    if pgrep -x PixlPut >/dev/null; then
        echo "ERROR: PixlPut did not quit within 5 seconds" >&2
        exit 1
    fi
fi

echo "==> installing to ${INSTALL_APP}"
# Same escalation rule as build-yabai.sh: sudo only when the directory is
# actually read-only. A function rather than an array: bash 3.2 treats an
# empty array as unbound under `set -u`.
if [[ -w "${INSTALL_DIR}" ]]; then
    as_installer() { "$@"; }
else
    echo "    ${INSTALL_DIR} is not writable by $(whoami); using sudo (the prompt is sudo's)"
    as_installer() { sudo "$@"; }
fi
# Replace wholesale: ditto merges, and a half-updated bundle fails signature
# validation.
as_installer rm -rf "${INSTALL_APP}"
as_installer ditto "${SOURCE_APP}" "${INSTALL_APP}"
if codesign --verify --strict "${INSTALL_APP}" >/dev/null 2>&1; then
    echo "    signature valid"
else
    echo "    WARNING: signature invalid or missing; the Accessibility grant will not carry over"
fi

echo "==> login item ${LABEL}"
mkdir -p "$(dirname "${AGENT_PLIST}")"
launchctl bootout "${DOMAIN}/${LABEL}" 2>/dev/null || true
# `open` rather than the executable: LaunchServices keeps a single instance
# if PixlPut is somehow already running, and the job exits once the app is
# up, so there is nothing for launchd to restart when the user quits it.
cat > "${AGENT_PLIST}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>${LABEL}</string>
	<key>ProgramArguments</key>
	<array>
		<string>/usr/bin/open</string>
		<string>${INSTALL_APP}</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>LimitLoadToSessionType</key>
	<string>Aqua</string>
</dict>
</plist>
PLIST
plutil -lint "${AGENT_PLIST}" >/dev/null
# Loading runs the job, which launches the freshly installed copy now.
launchctl bootstrap "${DOMAIN}" "${AGENT_PLIST}"
echo "    ${AGENT_PLIST}"

for _ in $(seq 1 100); do
    pgrep -x PixlPut >/dev/null && break
    sleep 0.1
done
RUNNING="$(pgrep -x PixlPut | head -1 || true)"
if [[ -n "${RUNNING}" ]]; then
    echo
    echo "PixlPut is running (pid ${RUNNING}) from ${INSTALL_APP} and opens at every login."
else
    echo "WARNING: PixlPut did not start; try: open ${INSTALL_APP}" >&2
    exit 2
fi
