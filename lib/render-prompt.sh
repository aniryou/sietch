#!/usr/bin/env bash
# Render a loop prompt template by substituting ${VARS} from the consumer
# repo's .loop/loop.config.
#
# Usage:
#   render-prompt.sh <template-path>
#
# Required env (set by the loop CLI):
#   REPO_ROOT     consumer repo (contains .loop/loop.config)
#   LOOP_HOME   ~/code/loop (or wherever this framework is installed)
#
# Outputs the rendered prompt on stdout. Wrappers pipe this into
# `claude --append-system-prompt "$(...)"`.

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI}"

CONFIG="$REPO_ROOT/.loop/loop.config"
[ -f "$CONFIG" ] || { echo "[render-prompt] missing config: $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

TEMPLATE="${1:-}"
[ -n "$TEMPLATE" ] && [ -f "$TEMPLATE" ] || {
  echo "[render-prompt] template not found: ${TEMPLATE:-<missing>}" >&2
  exit 2
}

command -v envsubst >/dev/null 2>&1 || {
  echo "[render-prompt] envsubst (gettext) is required but not on PATH." >&2
  echo "  macOS:  brew install gettext && brew link --force gettext" >&2
  echo "  Debian: sudo apt-get install -y gettext-base" >&2
  exit 1
}

# Single source of truth for keys substituted into prompt templates.
# Add new loop.config keys that templates may reference here.
# Anything outside this list passes through literally — essential for
# $REPO_ROOT, which the agent expands via bash at runtime, not here.
RIG_KEYS=(
  REPO_OWNER REPO_NAME REPO_SLUG DEFAULT_BRANCH
  BRANCH_PREFIX WORKTREE_BASE LOCK_DIR DISPATCH_LOCK_DIR
  SEVERITY_LABEL_HIGH SEVERITY_LABEL_MEDIUM SEVERITY_LABEL_LOW TYPE_LABELS
  TRIAGE_CORE_FILES_REGEX TRIAGE_TESTS_REGEX TRIAGE_CI_SECRETS_REGEX TRIAGE_LINE_LIMIT
  DEV_INSTANCES_DEFAULT POLL_INTERVAL_DEFAULT EMPTY_CYCLE_BACKOFF_CAP_SECONDS
  DEV_MAX_TURNS REVIEWER_MAX_TURNS
  DEV_CI_RETRY_ATTEMPTS DEV_FOLLOWUP_CYCLE_LIMIT REVIEWER_BASH_CALL_BUDGET
  STALE_LOCK_HOURS TEST_CMD
  DEV_AGENT_COMMENT_PREFIX DEV_AGENT_PR_BODY_TAG
  REVIEWER_AGENT_COMMENT_PREFIX REVIEWER_AGENT_VERDICT_REGEX
)

export "${RIG_KEYS[@]}"
printf -v ALLOWLIST ' ${%s}' "${RIG_KEYS[@]}"
envsubst "$ALLOWLIST" < "$TEMPLATE"
