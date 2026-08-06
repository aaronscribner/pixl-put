#!/bin/bash
#
# Claude Code Hook: post-tasks-reviewer (PostToolUse on Write|Edit)
#
# After tasks.md is written, instruct Claude to invoke code-reviewer for
# pattern-gap and platform-code checks. Design §7.5.

set -e
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')

if [ -z "$FILE_PATH" ]; then exit 0; fi
case "$FILE_PATH" in
  */roadmap/product/*/tasks.md) ;;
  *) exit 0 ;;
esac

if grep -q "^## Code Reviewer Verdict — tasks phase" "$FILE_PATH" 2>/dev/null; then
  exit 0
fi

cat >&2 << EOM
[hook: post-tasks-reviewer]
You just wrote $FILE_PATH. Per design §7.5:

1. Invoke the code-reviewer agent.
2. For every task: resolve a Swift idiom / Apple framework / project extension point
   (via agents/stacks/swift.md and the C4 components under roadmap/arch/c4/).
3. Flag IDIOM-GAP and CONSTITUTION-GAP tasks; for true project-precept gaps, write
   precept-gap prompts to roadmap/product/precept-gaps/<feature-slug>-<gap-name>.md.
4. Append the Code Reviewer Verdict block scoped to tasks phase.
5. Also invoke architect (advisory) to confirm the gap prompts are C4-consistent.
EOM
exit 2
