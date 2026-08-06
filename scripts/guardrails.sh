#!/usr/bin/env bash
# Guardrails hook — runs before every tool use to enforce safety boundaries.
# This script is called by Claude Code's PreToolUse hook.
# Exit 0 = allow, Exit 2 = block with message
set -euo pipefail

TOOL_NAME="${TOOL_NAME:-}"
TOOL_INPUT="${TOOL_INPUT:-}"

# Helper: block with reason
block() {
  echo "GUARDRAIL BLOCKED: $1" >&2
  exit 2
}

# === FILE PROTECTION ===
# Block writes to protected paths
if [[ "$TOOL_NAME" == "Write" || "$TOOL_NAME" == "Edit" ]]; then
  # Block modifications to spec-kit templates (managed by speckit CLI)
  if echo "$TOOL_INPUT" | grep -q '\.specify/templates/'; then
    block "Cannot modify spec-kit templates in .specify/templates/. Use speckit CLI."
  fi

  # Block modifications to spec-kit managed scripts
  if echo "$TOOL_INPUT" | grep -q 'scripts/bash/common\.sh\|scripts/powershell/common\.ps1'; then
    # Allow if on main branch (setup phase)
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
      block "Cannot modify shared scripts on feature branches. Make changes on main."
    fi
  fi

  # Block writing secrets files
  if echo "$TOOL_INPUT" | grep -qi '\.env\|credentials\|secrets\|\.pem\|\.key$\|id_rsa'; then
    block "Cannot write to secrets/credential files."
  fi
fi

# === BASH COMMAND PROTECTION ===
if [[ "$TOOL_NAME" == "Bash" ]]; then
  INPUT_LOWER=$(echo "$TOOL_INPUT" | tr '[:upper:]' '[:lower:]')

  # Block destructive git operations
  if echo "$INPUT_LOWER" | grep -q 'git push --force\|git push -f\b'; then
    block "Force push is not allowed. Use regular push."
  fi

  if echo "$INPUT_LOWER" | grep -q 'git reset --hard'; then
    block "git reset --hard is not allowed. Use git stash or git checkout for specific files."
  fi

  if echo "$INPUT_LOWER" | grep -q 'git clean -f'; then
    block "git clean -f is not allowed. Remove files explicitly."
  fi

  # Block database destruction
  if echo "$INPUT_LOWER" | grep -q 'drop table\|drop database\|truncate table'; then
    block "Destructive database operations are not allowed."
  fi

  # Block system-level destruction
  if echo "$INPUT_LOWER" | grep -q 'rm -rf /\|rm -rf ~\|rm -rf \.\*'; then
    block "Recursive deletion of root, home, or hidden directories is not allowed."
  fi

  # Block CI/CD pipeline modifications
  if echo "$INPUT_LOWER" | grep -q '\.github/workflows\|\.gitlab-ci\|Jenkinsfile\|\.circleci'; then
    BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "main")
    if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
      block "CI/CD pipeline changes must be made on the main branch."
    fi
  fi

  # Block disabling linters/type checkers
  if echo "$INPUT_LOWER" | grep -q -- '--no-verify\b'; then
    block "Skipping git hooks (--no-verify) is not allowed."
  fi
fi

# === AGENT BOUNDARY ENFORCEMENT ===
# Product agents should not write code files
# (This is advisory — enforced primarily through agent instructions)

# All checks passed
exit 0
