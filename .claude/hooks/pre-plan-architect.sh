#!/bin/bash
#
# Claude Code Hook: pre-plan-architect (PreToolUse on Write)
#
# Block writing plan.md unless the corresponding spec.md contains an
# Architect Review verdict. Enforces design §7.3 gate.

set -e
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then exit 0; fi
case "$FILE_PATH" in
  */roadmap/product/*/plan.md) ;;
  *) exit 0 ;;
esac

SPEC_PATH="${FILE_PATH%/plan.md}/spec.md"
if [ ! -f "$SPEC_PATH" ]; then
  echo "[hook: pre-plan-architect] BLOCKED — spec.md missing at $SPEC_PATH. Run spec phase first." >&2
  exit 2
fi
if ! grep -q "^## Architect Review" "$SPEC_PATH" 2>/dev/null; then
  echo "[hook: pre-plan-architect] BLOCKED — $SPEC_PATH has no Architect Review verdict block. Invoke the architect agent before planning." >&2
  exit 2
fi
if grep -E "^\*\*Verdict\*\*:.*BLOCKING" "$SPEC_PATH" >/dev/null 2>&1; then
  echo "[hook: pre-plan-architect] BLOCKED — Architect verdict on $SPEC_PATH is BLOCKING. Resolve via clarify phase before plan phase." >&2
  exit 2
fi
exit 0
