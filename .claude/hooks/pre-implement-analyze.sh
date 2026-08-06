#!/bin/bash
#
# Claude Code Hook: pre-implement-analyze (PreToolUse on Write|Edit)
#
# Block any implementation file write unless analyze phase has produced
# both architect (ALIGNED) and code-reviewer (OK) verdicts on the current
# feature. Design §7.6 gate.

set -e
INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

[ -z "$FILE_PATH" ] && exit 0

# Skip non-implementation paths: docs/, .claude/, roadmap/, tests, node_modules
case "$FILE_PATH" in
  */docs/*) exit 0 ;;
  */.claude/*) exit 0 ;;
  */roadmap/*) exit 0 ;;
  */Tests/*) exit 0 ;;
  */node_modules/*) exit 0 ;;
  *.md) exit 0 ;;
esac

# Only enforce for Swift source files (this is a Swift project; other extensions left for portability)
case "$FILE_PATH" in
  *.swift|*.cs|*.ts|*.tsx|*.js|*.mjs|*.jsx|*.kt|*.kts|*.py|*.go|*.rs|*.java) ;;
  *) exit 0 ;;
esac

# Find the current feature dir from the branch name or working dir
BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$BRANCH" in
  feature/*|story/*) ;;
  *) exit 0 ;;  # No active feature; allow.
esac

# Locate the spec dir (best-effort: most recently modified roadmap/product/<NNN-or-S-X.Y.Z>/)
SPEC_DIR=$(ls -td roadmap/product/*/ 2>/dev/null | grep -v '/draft-' | head -1)
[ -z "$SPEC_DIR" ] && exit 0

ANALYSIS="${SPEC_DIR}analysis.md"
[ ! -f "$ANALYSIS" ] && {
  echo "[hook: pre-implement-analyze] BLOCKED — $ANALYSIS missing. Run analyze phase before implementing." >&2
  exit 2
}

if ! grep -q "^## Architect Review — analyze phase" "$ANALYSIS"; then
  echo "[hook: pre-implement-analyze] BLOCKED — $ANALYSIS lacks architect verdict. Run analyze phase." >&2
  exit 2
fi
if ! grep -q "^## Code Reviewer Verdict — analyze phase" "$ANALYSIS"; then
  echo "[hook: pre-implement-analyze] BLOCKED — $ANALYSIS lacks code-reviewer verdict. Run analyze phase." >&2
  exit 2
fi
if grep -E "^\*\*Verdict\*\*:.*(BLOCKING|IDIOM-GAP|CONSTITUTION-GAP)" "$ANALYSIS" >/dev/null; then
  echo "[hook: pre-implement-analyze] BLOCKED — analysis has unresolved BLOCKING, IDIOM-GAP, or CONSTITUTION-GAP verdict. Resolve before implementing." >&2
  exit 2
fi
exit 0
