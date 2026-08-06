#!/usr/bin/env bash
# Orchestration helper — provides context for the /orchestrate command
# This script detects the current state and determines where to resume
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bash/common.sh"

REPO_ROOT=$(get_repo_root)
BRANCH=$(get_current_branch)

# Determine pipeline state
STATE="fresh"
FEATURE_DIR=""
COMPLETED_PHASES=()

# Check if we're on a feature branch with existing artifacts
if FEATURE_DIR=$(get_current_feature_dir 2>/dev/null); then
  if [[ -f "${FEATURE_DIR}/research.md" ]]; then
    COMPLETED_PHASES+=("research")
  fi
  if [[ -f "${FEATURE_DIR}/spec.md" ]] && [[ -s "${FEATURE_DIR}/spec.md" ]]; then
    COMPLETED_PHASES+=("specify")
  fi
  if [[ -f "${FEATURE_DIR}/plan.md" ]] && [[ -s "${FEATURE_DIR}/plan.md" ]]; then
    COMPLETED_PHASES+=("plan")
  fi
  if [[ -f "${FEATURE_DIR}/tasks.md" ]] && [[ -s "${FEATURE_DIR}/tasks.md" ]]; then
    COMPLETED_PHASES+=("tasks")
  fi

  # Check for TDD commits
  if git log --oneline --format="%s" | grep -q "^test(red):"; then
    COMPLETED_PHASES+=("red")
  fi
  if git log --oneline --format="%s" | grep -q "^feat(green):"; then
    COMPLETED_PHASES+=("green")
  fi
  if git log --oneline --format="%s" | grep -q "^refactor:"; then
    COMPLETED_PHASES+=("refactor")
  fi

  if [[ ${#COMPLETED_PHASES[@]} -gt 0 ]]; then
    STATE="resuming"
  fi
fi

# Detect tech stack
TECH_STACK="unknown"
if [[ -n "$FEATURE_DIR" && -f "${FEATURE_DIR}/plan.md" ]]; then
  if grep -qi "swift\|ios\|macos" "${FEATURE_DIR}/plan.md"; then TECH_STACK="swift"
  elif grep -qi "kotlin\|android\|gradle" "${FEATURE_DIR}/plan.md"; then TECH_STACK="kotlin"
  elif grep -qi "c#\|csharp\|dotnet" "${FEATURE_DIR}/plan.md"; then TECH_STACK="csharp"
  elif grep -qi "angular" "${FEATURE_DIR}/plan.md"; then TECH_STACK="angular"
  elif grep -qi "react\|next\.js" "${FEATURE_DIR}/plan.md"; then TECH_STACK="react"
  elif grep -qi "electron" "${FEATURE_DIR}/plan.md"; then TECH_STACK="electron"
  fi
fi

PHASES_JSON=$(printf '"%s",' "${COMPLETED_PHASES[@]}" 2>/dev/null | sed 's/,$//')

cat <<EOF
{
  "STATE": "${STATE}",
  "BRANCH": "${BRANCH}",
  "FEATURE_DIR": "${FEATURE_DIR}",
  "TECH_STACK": "${TECH_STACK}",
  "COMPLETED_PHASES": [${PHASES_JSON}],
  "REPO_ROOT": "${REPO_ROOT}"
}
EOF
