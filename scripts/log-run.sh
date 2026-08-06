#!/usr/bin/env bash
# log-run.sh — append a structured JSONL telemetry line for a factory event.
#
# Usage:
#   scripts/log-run.sh <feature-dir> <agent> <phase> <verdict> [--rubric '<json>'] [--extra '<json>']
#
# Examples:
#   scripts/log-run.sh specs/042-add-user-export architect spec OK
#   scripts/log-run.sh specs/042-add-user-export qa green APPROVED --extra '{"tests":127,"pass":127}'
#   scripts/log-run.sh specs/042-add-user-export architect spec OK \
#     --rubric '{"precepts-loaded":true,"c4-cited":true,"verdict-block-emitted":true,"no-source-edits":true}'
#
# Output: appends one JSON object per line to <feature-dir>/run.jsonl.
# Schema:
#   {
#     "ts": "<ISO 8601>",
#     "agent": "<agent name>",
#     "phase": "<spec|plan|tasks|red|green|refactor|analyze|pr|...>",
#     "verdict": "<OK|BLOCKING|...>",
#     "git_sha": "<short HEAD>",
#     "branch": "<current branch>",
#     "rubric": { ... },     # only present if --rubric supplied — agent self-report scores
#     "extra": { ... }       # only present if --extra supplied — any other structured payload
#   }
#
# Backward compatibility: a positional 5th argument (no flag) is treated as
# --extra for callers still using the v4.1.0 layer-1 signature.
#
# Soft fail: if <feature-dir> doesn't exist, prints a warning and exits 0
# so telemetry never blocks real work.

set -euo pipefail

if [ "$#" -lt 4 ]; then
  echo "usage: log-run.sh <feature-dir> <agent> <phase> <verdict> [--rubric '<json>'] [--extra '<json>']" >&2
  exit 2
fi

FEATURE_DIR="$1"; shift
AGENT="$1"; shift
PHASE="$1"; shift
VERDICT="$1"; shift

RUBRIC=""
EXTRA=""

# Parse remaining args. Accept --rubric/--extra flags OR a single bare
# positional argument (treated as --extra for layer-1 backwards-compat).
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rubric)
      RUBRIC="${2:-}"
      shift 2
      ;;
    --extra)
      EXTRA="${2:-}"
      shift 2
      ;;
    --*)
      echo "log-run: unknown flag '$1'" >&2
      exit 2
      ;;
    *)
      # Bare positional argument — layer-1 compat mode for extra-json.
      if [ -z "$EXTRA" ]; then
        EXTRA="$1"
      else
        echo "log-run: unexpected extra positional arg '$1'" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ ! -d "$FEATURE_DIR" ]; then
  echo "log-run: feature dir '$FEATURE_DIR' does not exist; skipping log" >&2
  exit 0
fi

TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || echo 'no-git')"
BRANCH="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'no-git')"

LOG_FILE="$FEATURE_DIR/run.jsonl"

if command -v jq >/dev/null 2>&1; then
  # Build incrementally so we can omit empty fields cleanly.
  JQ_BASE='{ts:$ts, agent:$agent, phase:$phase, verdict:$verdict, git_sha:$sha, branch:$branch}'
  JQ_ARGS=(
    --arg ts "$TS"
    --arg agent "$AGENT"
    --arg phase "$PHASE"
    --arg verdict "$VERDICT"
    --arg sha "$GIT_SHA"
    --arg branch "$BRANCH"
  )
  JQ_EXPR="$JQ_BASE"
  if [ -n "$RUBRIC" ]; then
    JQ_ARGS+=(--argjson rubric "$RUBRIC")
    JQ_EXPR="$JQ_EXPR + {rubric:\$rubric}"
  fi
  if [ -n "$EXTRA" ]; then
    JQ_ARGS+=(--argjson extra "$EXTRA")
    JQ_EXPR="$JQ_EXPR + {extra:\$extra}"
  fi
  jq -nc "${JQ_ARGS[@]}" "$JQ_EXPR" >> "$LOG_FILE"
else
  # Best-effort fallback: assume agent/phase/verdict contain no quotes
  # or backslashes (they shouldn't — they're enum-like values).
  RUBRIC_FIELD=""
  EXTRA_FIELD=""
  if [ -n "$RUBRIC" ]; then
    RUBRIC_FIELD=",\"rubric\":$RUBRIC"
  fi
  if [ -n "$EXTRA" ]; then
    EXTRA_FIELD=",\"extra\":$EXTRA"
  fi
  printf '{"ts":"%s","agent":"%s","phase":"%s","verdict":"%s","git_sha":"%s","branch":"%s"%s%s}\n' \
    "$TS" "$AGENT" "$PHASE" "$VERDICT" "$GIT_SHA" "$BRANCH" "$RUBRIC_FIELD" "$EXTRA_FIELD" \
    >> "$LOG_FILE"
fi
