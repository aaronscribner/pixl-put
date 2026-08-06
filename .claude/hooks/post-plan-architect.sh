#!/bin/bash
#
# Claude Code Hook: post-plan-architect (PostToolUse on Write|Edit)
#
# After plan.md is written, instruct Claude to re-invoke the architect to
# validate plan ↔ roadmap and append a verdict block. Design §7.3.

set -e
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then exit 0; fi
case "$FILE_PATH" in
  */roadmap/product/*/plan.md) ;;
  *) exit 0 ;;
esac

if grep -q "^## Architect Review — plan phase" "$FILE_PATH" 2>/dev/null; then
  exit 0
fi

cat >&2 << EOM
[hook: post-plan-architect]
You just wrote $FILE_PATH. Per design §7.3:

1. Re-invoke the architect agent.
2. Validate plan.md against the roadmap's NEXT state (not just current).
3. List Required C4 updates the plan implies.
4. Append the Architect Review verdict block scoped to plan phase.
EOM
exit 2
