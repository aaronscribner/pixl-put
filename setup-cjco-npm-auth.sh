#!/usr/bin/env bash
# One-off helper: prompts for an Azure DevOps PAT and writes the
# base64-encoded auth block for the CJCO npm feed to ~/.npmrc.
#
# Usage:  ./setup-cjco-npm-auth.sh
# The PAT needs at minimum "Packaging (Read)" scope.

set -euo pipefail

FEED='//cerebral-juice-co.pkgs.visualstudio.com/_packaging/cjco/npm/registry/'
NPMRC="${HOME}/.npmrc"

read -rsp "Paste Azure DevOps PAT (input hidden, press Enter when done): " PAT
echo

if [[ -z "${PAT}" ]]; then
  echo "Error: no PAT provided." >&2
  exit 1
fi

# Azure Artifacts expects the PAT base64-encoded in _password.
PAT_B64=$(printf '%s' "${PAT}" | base64 | tr -d '\n')

touch "${NPMRC}"
chmod 600 "${NPMRC}"

# Strip any existing lines referencing this feed so we don't stack duplicates.
TMP=$(mktemp)
trap 'rm -f "${TMP}"' EXIT
awk -v feed="${FEED}" 'index($0, feed) == 0 { print }' "${NPMRC}" > "${TMP}"
mv "${TMP}" "${NPMRC}"
chmod 600 "${NPMRC}"

{
  printf '; begin cjco feed auth (managed by setup-cjco-npm-auth.sh)\n'
  printf '%s:username=cerebral-juice-co\n' "${FEED}"
  printf '%s:_password=%s\n' "${FEED}" "${PAT_B64}"
  printf '%s:email=npm-requires-but-ignores@example.com\n' "${FEED}"
  printf '%s:always-auth=true\n' "${FEED}"
  printf '; end cjco feed auth\n'
} >> "${NPMRC}"

unset PAT PAT_B64

echo "Wrote CJCO feed auth block to ${NPMRC} (mode 600)."
echo "Verify with:  npm install --save-dev @cerebral-juice-co/claude-agents@^4.1"
