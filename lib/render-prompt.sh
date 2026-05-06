#!/usr/bin/env bash
# Render a sietch prompt template by substituting ${VARS} from the consumer
# repo's .sietch/rig.config.
#
# Usage:
#   render-prompt.sh <template-path>
#
# Required env (set by the sietch CLI):
#   REPO_ROOT     consumer repo (contains .sietch/rig.config)
#   SIETCH_HOME   ~/code/sietch (or wherever this framework is installed)
#
# Outputs the rendered prompt on stdout. Wrappers pipe this into
# `claude --append-system-prompt "$(...)"`.

set -u
set -o pipefail

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the sietch CLI}"
: "${SIETCH_HOME:?SIETCH_HOME must be set; invoke via the sietch CLI}"

CONFIG="$REPO_ROOT/.sietch/rig.config"
[ -f "$CONFIG" ] || { echo "[render-prompt] missing config: $CONFIG" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONFIG"

TEMPLATE="${1:-}"
[ -n "$TEMPLATE" ] && [ -f "$TEMPLATE" ] || {
  echo "[render-prompt] template not found: ${TEMPLATE:-<missing>}" >&2
  exit 2
}

# Export every rig.config variable that templates may reference. Anything
# outside this list passes through literally, which is essential for
# $REPO_ROOT — the agent expands it via bash at runtime, not at render time.
export REPO_OWNER REPO_NAME REPO_SLUG DEFAULT_BRANCH \
       BRANCH_PREFIX WORKTREE_BASE LOCK_DIR \
       SEVERITY_LABEL_HIGH SEVERITY_LABEL_MEDIUM SEVERITY_LABEL_LOW TYPE_LABELS \
       TRIAGE_CORE_FILES_REGEX TRIAGE_LINE_LIMIT \
       DEV_CI_RETRY_ATTEMPTS DEV_FOLLOWUP_CYCLE_LIMIT REVIEWER_BASH_CALL_BUDGET \
       STALE_LOCK_HOURS TEST_CMD \
       DEV_AGENT_COMMENT_PREFIX DEV_AGENT_PR_BODY_TAG REVIEWER_AGENT_COMMENT_PREFIX

ALLOWLIST='${REPO_OWNER} ${REPO_NAME} ${REPO_SLUG} ${DEFAULT_BRANCH} \
${BRANCH_PREFIX} ${WORKTREE_BASE} ${LOCK_DIR} \
${SEVERITY_LABEL_HIGH} ${SEVERITY_LABEL_MEDIUM} ${SEVERITY_LABEL_LOW} ${TYPE_LABELS} \
${TRIAGE_CORE_FILES_REGEX} ${TRIAGE_LINE_LIMIT} \
${DEV_CI_RETRY_ATTEMPTS} ${DEV_FOLLOWUP_CYCLE_LIMIT} ${REVIEWER_BASH_CALL_BUDGET} \
${STALE_LOCK_HOURS} ${TEST_CMD} \
${DEV_AGENT_COMMENT_PREFIX} ${DEV_AGENT_PR_BODY_TAG} ${REVIEWER_AGENT_COMMENT_PREFIX}'

if command -v envsubst >/dev/null 2>&1; then
  envsubst "$ALLOWLIST" < "$TEMPLATE"
else
  # Sed fallback for systems without gettext. Keep in sync with rig.config keys.
  sed \
    -e "s|\${REPO_OWNER}|${REPO_OWNER}|g" \
    -e "s|\${REPO_NAME}|${REPO_NAME}|g" \
    -e "s|\${REPO_SLUG}|${REPO_SLUG}|g" \
    -e "s|\${DEFAULT_BRANCH}|${DEFAULT_BRANCH}|g" \
    -e "s|\${BRANCH_PREFIX}|${BRANCH_PREFIX}|g" \
    -e "s|\${WORKTREE_BASE}|${WORKTREE_BASE}|g" \
    -e "s|\${LOCK_DIR}|${LOCK_DIR}|g" \
    -e "s|\${SEVERITY_LABEL_HIGH}|${SEVERITY_LABEL_HIGH}|g" \
    -e "s|\${SEVERITY_LABEL_MEDIUM}|${SEVERITY_LABEL_MEDIUM}|g" \
    -e "s|\${SEVERITY_LABEL_LOW}|${SEVERITY_LABEL_LOW}|g" \
    -e "s|\${TYPE_LABELS}|${TYPE_LABELS}|g" \
    -e "s|\${TRIAGE_CORE_FILES_REGEX}|${TRIAGE_CORE_FILES_REGEX}|g" \
    -e "s|\${TRIAGE_LINE_LIMIT}|${TRIAGE_LINE_LIMIT}|g" \
    -e "s|\${DEV_CI_RETRY_ATTEMPTS}|${DEV_CI_RETRY_ATTEMPTS}|g" \
    -e "s|\${DEV_FOLLOWUP_CYCLE_LIMIT}|${DEV_FOLLOWUP_CYCLE_LIMIT}|g" \
    -e "s|\${REVIEWER_BASH_CALL_BUDGET}|${REVIEWER_BASH_CALL_BUDGET}|g" \
    -e "s|\${STALE_LOCK_HOURS}|${STALE_LOCK_HOURS}|g" \
    -e "s|\${TEST_CMD}|${TEST_CMD}|g" \
    -e "s|\${DEV_AGENT_COMMENT_PREFIX}|${DEV_AGENT_COMMENT_PREFIX}|g" \
    -e "s|\${DEV_AGENT_PR_BODY_TAG}|${DEV_AGENT_PR_BODY_TAG}|g" \
    -e "s|\${REVIEWER_AGENT_COMMENT_PREFIX}|${REVIEWER_AGENT_COMMENT_PREFIX}|g" \
    "$TEMPLATE"
fi
