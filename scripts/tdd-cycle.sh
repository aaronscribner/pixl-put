#!/usr/bin/env bash
# TDD cycle helper — provides context for the /tdd-cycle command
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bash/common.sh"

REPO_ROOT=$(get_repo_root)
FEATURE_DIR=$(get_current_feature_dir) || die "No feature directory found. Run /specify first."
BRANCH=$(get_current_branch)

# Check prerequisites
[[ -f "${FEATURE_DIR}/tasks.md" ]] || die "tasks.md not found. Run /tasks first."
[[ -f "${FEATURE_DIR}/spec.md" ]] || die "spec.md not found. Run /specify first."
[[ -f "${FEATURE_DIR}/plan.md" ]] || die "plan.md not found. Run /plan first."

# Determine TDD state from git history
TDD_STATE="not-started"
RED_COUNT=$(git log --oneline --format="%s" | grep -c "^test(red):" || echo "0")
GREEN_COUNT=$(git log --oneline --format="%s" | grep -c "^feat(green):" || echo "0")
REFACTOR_COUNT=$(git log --oneline --format="%s" | grep -c "^refactor:" || echo "0")

if [[ "$REFACTOR_COUNT" -gt 0 ]]; then
  TDD_STATE="refactor-in-progress"
elif [[ "$GREEN_COUNT" -gt 0 ]]; then
  TDD_STATE="green-in-progress"
elif [[ "$RED_COUNT" -gt 0 ]]; then
  TDD_STATE="red-in-progress"
fi

AVAILABLE_DOCS=$(list_available_docs "$FEATURE_DIR")

cat <<EOF
{
  "FEATURE_DIR": "${FEATURE_DIR}",
  "BRANCH": "${BRANCH}",
  "TDD_STATE": "${TDD_STATE}",
  "RED_COUNT": ${RED_COUNT},
  "GREEN_COUNT": ${GREEN_COUNT},
  "REFACTOR_COUNT": ${REFACTOR_COUNT},
  "AVAILABLE_DOCS": "${AVAILABLE_DOCS}",
  "REPO_ROOT": "${REPO_ROOT}"
}
EOF
