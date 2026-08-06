#!/bin/bash
#
# Claude Code Hook: post-spec-architect (PostToolUse on Write|Edit)
#
# After SpecKit writes a feature spec.md, instruct Claude to consult the
# architect agent and append the Architect Review verdict block.
#
# Part of: spec phase → architect consultation (design §7.1)

set -e

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

# Only fire on roadmap/product/*/spec.md writes.
if [ -z "$FILE_PATH" ]; then exit 0; fi
case "$FILE_PATH" in
  */roadmap/product/*/spec.md) ;;
  *) exit 0 ;;
esac

# Skip if architect verdict already present (idempotent).
if grep -q "^## Architect Review" "$FILE_PATH" 2>/dev/null; then
  exit 0
fi

cat <<EOF >&2
[hook: post-spec-architect]
You just wrote $FILE_PATH. Per the agent-design contract for spec phase
(\`agents/engineering/architect.md\`):

1. Invoke the architect agent.
2. Resolve agents.architecture.source from the constitution (directory or mcp).
3. Validate the spec against current C4 + roadmap.
4. Append the Architect Review verdict block to $FILE_PATH.

If the verdict is BLOCKING, surface its questions for clarify phase before
proceeding to plan phase.
EOF

exit 2
