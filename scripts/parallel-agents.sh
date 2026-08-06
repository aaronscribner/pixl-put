#!/usr/bin/env bash
# Parallel agent execution helper
# Coordinates multiple Claude agent instances working on non-overlapping file scopes
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/bash/common.sh"

REPO_ROOT=$(get_repo_root)

# Parse JSON task file
TASK_FILE="${1:-}"
if [[ -z "$TASK_FILE" || ! -f "$TASK_FILE" ]]; then
  die "Usage: parallel-agents.sh <task-file.json>"
fi

echo "Parallel Agent Orchestrator"
echo "==========================="
echo "Task file: ${TASK_FILE}"
echo "Repo root: ${REPO_ROOT}"
echo ""

# Validate task file has required structure
if ! jq -e '.tasks' "$TASK_FILE" >/dev/null 2>&1; then
  die "Task file must contain a 'tasks' array."
fi

TASK_COUNT=$(jq '.tasks | length' "$TASK_FILE")
echo "Tasks to execute: ${TASK_COUNT}"

# Check for file scope conflicts
echo ""
echo "Checking for file scope conflicts..."
CONFLICTS=$(jq -r '
  [.tasks[].files // []] |
  flatten |
  group_by(.) |
  map(select(length > 1)) |
  flatten |
  unique[]
' "$TASK_FILE" 2>/dev/null || echo "")

if [[ -n "$CONFLICTS" ]]; then
  echo "WARNING: File scope conflicts detected:"
  echo "$CONFLICTS"
  echo ""
  echo "Conflicting tasks will be run sequentially."
fi

echo ""
echo "Task summary:"
jq -r '.tasks[] | "  - [\(.id)] \(.type // "general"): \(.description)"' "$TASK_FILE"
echo ""
echo "Ready for execution. Use the Claude Agent tool to dispatch tasks."
