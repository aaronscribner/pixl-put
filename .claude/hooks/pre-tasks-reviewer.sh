#!/bin/bash
#
# Claude Code Hook: pre-tasks-reviewer (PreToolUse on Write)
#
# Block writing tasks.md unless plan.md has an Architect Review verdict.
# Design §7.5 gate.

set -e
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then exit 0; fi
case "$FILE_PATH" in
  */roadmap/product/*/tasks.md) ;;
  *) exit 0 ;;
esac

PLAN_PATH="${FILE_PATH%/tasks.md}/plan.md"
if [ ! -f "$PLAN_PATH" ]; then
  echo "[hook: pre-tasks-reviewer] BLOCKED — plan.md missing at $PLAN_PATH. Run plan phase first." >&2
  exit 2
fi
if ! grep -q "^## Architect Review — plan phase" "$PLAN_PATH" 2>/dev/null; then
  echo "[hook: pre-tasks-reviewer] BLOCKED — $PLAN_PATH has no Architect Review verdict for plan phase. Re-invoke architect first." >&2
  exit 2
fi
exit 0
