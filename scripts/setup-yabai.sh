#!/usr/bin/env bash
# Privileged setup of yabai as PixPut's per-window Space actuator (ADR-0002).
# Run once after scripts/build-yabai.sh, and again whenever that rebuild
# changes the binary (the sudoers rule pins its hash).
#
# PixPut moves windows between Spaces through yabai because the in-process
# CGS call is per-app: every window of an app moves together. yabai runs the
# window-scoped call from inside Dock.app, which owns the windows, so it can
# move one window at a time. That needs:
#
#   1. A sudoers rule so `yabai --load-sa` runs without a password. The
#      scripting addition must be re-injected into Dock.app after every
#      reboot, and the launch agent has no terminal to type a password into.
#   2. ~/.yabairc that loads the scripting addition and keeps every window
#      floating (yabai's default bsp layout would re-tile your desktop).
#   3. The yabai launch agent pointing at OUR binary, so the service comes
#      back after a reboot.
#
# Accessibility permission for yabai cannot be scripted. Add the binary
# under System Settings → Privacy & Security → Accessibility once; because
# build-yabai.sh signs it with a Developer ID, the grant survives rebuilds.
#
# Requires: SIP disabled (csrutil status), scripts/build-yabai.sh already run.

set -euo pipefail

YABAI="${YABAI_INSTALL_PATH:-/Applications/Utilities/yabai.app/Contents/MacOS/yabai}"
if [[ ! -x "${YABAI}" ]]; then
    echo "${YABAI} is missing. Run scripts/build-yabai.sh first." >&2
    exit 1
fi
if csrutil status 2>/dev/null | grep -q "enabled"; then
    echo "System Integrity Protection is enabled; yabai's scripting addition needs it disabled." >&2
    exit 1
fi

echo "==> sudoers rule for --load-sa (the password prompt is sudo's)"
HASH="$(shasum -a 256 "${YABAI}" | cut -d ' ' -f 1)"
RULE="$(whoami) ALL=(root) NOPASSWD: sha256:${HASH} ${YABAI} --load-sa"
echo "${RULE}" | sudo tee /private/etc/sudoers.d/yabai >/dev/null
sudo chmod 0440 /private/etc/sudoers.d/yabai
echo "    written; pinned to this binary's hash, so re-run after a rebuild that changes it"

echo "==> ~/.yabairc"
RC="${HOME}/.yabairc"
if [[ ! -f "${RC}" ]]; then
    printf '#!/usr/bin/env sh\n' > "${RC}"
fi
# Absolute paths: the launch agent's PATH may still find a Homebrew yabai.
if grep -q -- "--load-sa" "${RC}"; then
    sed -i '' "s|^sudo .*yabai --load-sa.*|sudo ${YABAI} --load-sa|" "${RC}"
else
    printf 'sudo %s --load-sa\n' "${YABAI}" >> "${RC}"
fi
if grep -q "config layout" "${RC}"; then
    sed -i '' "s|^.*yabai -m config layout .*|${YABAI} -m config layout float|" "${RC}"
else
    printf '%s -m config layout float\n' "${YABAI}" >> "${RC}"
fi
chmod +x "${RC}"
echo "    loads the scripting addition from ${YABAI}; layout float"

echo "==> load the scripting addition now"
sudo -n "${YABAI}" --load-sa

echo "==> launch agent -> ${YABAI}"
# --start-service refuses to overwrite an existing plist, and the existing
# one may point at a Homebrew binary. Remove by label, then install ours.
"${YABAI}" --stop-service 2>/dev/null || true
"${YABAI}" --uninstall-service 2>/dev/null || true
# Earlier builds registered under other labels; a leftover agent would race
# ours for the socket at login.
for OLD_LABEL in com.asmvik.yabai com.koekeishiya.yabai; do
    OLD_PLIST="${HOME}/Library/LaunchAgents/${OLD_LABEL}.plist"
    if [[ -f "${OLD_PLIST}" ]]; then
        launchctl bootout "gui/$(id -u)/${OLD_LABEL}" 2>/dev/null || true
        rm -f "${OLD_PLIST}"
        echo "    removed stale launch agent ${OLD_LABEL}"
    fi
done
"${YABAI}" --start-service
sleep 2
if "${YABAI}" -m query --spaces >/dev/null 2>&1; then
    echo "    yabai is answering"
else
    echo "    yabai is not answering yet."
    echo "    Grant it Accessibility: System Settings → Privacy & Security → Accessibility → '+',"
    echo "    press Cmd+Shift+G, enter ${YABAI}, then run: ${YABAI} --restart-service"
    tail -3 "/tmp/yabai_$(whoami).err.log" 2>/dev/null || true
    exit 2
fi
echo "Done. Restore windows to their Spaces now uses per-window moves."
