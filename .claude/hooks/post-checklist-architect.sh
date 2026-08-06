#!/bin/bash
#
# Claude Code Hook: post-checklist-architect (PostToolUse on Write|Edit)
#
# After SpecKit writes a requirements checklist, instruct Claude to invoke
# the architect agent to append an Architecture section.
#
# Part of: requirements checklist → architect appends arch section
# (design §7.4 — keeps a single checklist file; no SpecKit core change)

set -e

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then exit 0; fi
case "$FILE_PATH" in
  */roadmap/product/*/checklists/requirements.md) ;;
  *) exit 0 ;;
esac

# Skip if architecture section already present.
if grep -qiE "^## Architecture( |$)" "$FILE_PATH" 2>/dev/null; then
  exit 0
fi

cat <<EOF >&2
[hook: post-checklist-architect]
You just wrote a requirements checklist at $FILE_PATH. Per design §7.4:

1. Invoke the architect agent.
2. For each affected container, component, ADR, and cross-context interaction
   identified from C4 (resolved via agents.architecture.source), append a
   checklist item to a new "## Architecture" section in $FILE_PATH.
3. Each item must be specific enough to be ticked off during implementation.

Do NOT create a separate architecture checklist file; append to this one.
EOF

exit 2
