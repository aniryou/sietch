#!/usr/bin/env bash
# lib/eligibility.sh — Shell-side eligibility predicates for loop agents.
#
# Each function answers "does this agent mode have any work to do?" without
# loading an LLM. Wrappers source this file and short-circuit before invoking
# 'claude' on empty cycles. Agents may also invoke the same predicates (via
# Bash) on entry, so the wrapper preflight and the in-prompt re-check stay
# in sync — they call the same shell function.
#
# Each predicate prints the candidate count to stdout (one line) and exits:
#   0  → there is work; the wrapper should proceed to invoke the agent
#   1  → there is NO work; the wrapper should exit early without invoking
#   2  → gh / jq invocation failed (network, auth); fall back to "assume work"
#         so transient errors don't silently halt the loop
#
# Required env (set by the loop CLI):
#   REPO_ROOT     consumer repo (contains .loop/loop.config)
#   LOOP_HOME   ~/code/loop
#
# loop.config keys consumed:
#   REPO_SLUG, BRANCH_PREFIX, SEVERITY_LABEL_HIGH, SEVERITY_LABEL_MEDIUM,
#   REVIEWER_AGENT_VERDICT_REGEX

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI or wrappers}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI or wrappers}"

# shellcheck disable=SC1091
. "$REPO_ROOT/.loop/loop.config"

# ---------------------------------------------------------------------------
# Mode 1 dev-agent: open severity:high|medium issues with no assignee AND no
# live filesystem lock under $LOCK_DIR.
#
# The lock-dir post-filter is advisory: the agent still does the atomic mkdir
# for the actual claim. Without it, every parallel wrapper sees the same gh
# count, every wrapper invokes the LLM, and N-1 lose the lock race and exit
# after a wasted scan — the dominant cost path under DEV_INSTANCES>1.
#
# Stale-lock cleanup remains the agent's responsibility (STALE_LOCK_HOURS).
# False negatives (gh hit but lock present) still skip real work for one
# cycle, but the next cycle picks them up once the lock is released.
# ---------------------------------------------------------------------------
eligibility_dev_count() {
  # Use the REST list endpoint (--label) instead of --search: the search index
  # silently drops freshly-created issues (minutes of lag) and issues hidden by
  # GitHub's automated content filter (e.g. duplicate titles, code-dense bodies
  # on new repos). REST list reflects current state immediately.
  local label raw nums_all nums n filtered
  nums_all=""
  for label in "$SEVERITY_LABEL_HIGH" "$SEVERITY_LABEL_MEDIUM"; do
    if ! raw=$(
      PAGER=cat GIT_PAGER=cat gh issue list \
        --repo "$REPO_SLUG" --state open \
        --label "$label" \
        --json number,assignees \
        --limit 50 2>/dev/null \
        | jq -r '.[] | select(.assignees == []) | .number' 2>/dev/null
    ); then
      echo "?"
      return 2
    fi
    nums_all+="${raw}"$'\n'
  done
  nums=$(printf '%s' "$nums_all" | sort -u | grep . || true)
  filtered=0
  for n in $nums; do
    [ -d "${LOCK_DIR}/gh-${n}.lock" ] && continue
    filtered=$((filtered + 1))
  done
  echo "$filtered"
  [ "$filtered" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Reviewer orchestrator: open ${BRANCH_PREFIX}/* PRs whose current headRefOid
# does not yet have a [reviewer-agent: ...] review attached.
#
# Mirrors the orchestrator's own filter (no agent review at current head),
# so false-positive rate is minimal. The orchestrator still re-checks before
# dispatching its sub-agent.
# ---------------------------------------------------------------------------
eligibility_review_pending() {
  local data count
  if ! data=$(
    PAGER=cat GIT_PAGER=cat gh pr list \
      --repo "$REPO_SLUG" --state open \
      --search "head:${BRANCH_PREFIX}/ -is:draft" \
      --json number,headRefOid,reviews \
      --limit 100 2>/dev/null
  ); then
    echo "?"
    return 2
  fi
  if ! count=$(
    echo "$data" | jq --arg re "$REVIEWER_AGENT_VERDICT_REGEX" '
      [.[]
       | . as $pr
       | select(($pr.reviews // [])
                | map(select(.body | test($re)) | .commit_id)
                | index($pr.headRefOid) | not)
      ] | length
    ' 2>/dev/null
  ); then
    echo "?"
    return 2
  fi
  count="${count:-0}"
  echo "$count"
  [ "$count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# CLI entry point. Lets agents invoke this via:
#   bash $LOOP_HOME/runners/lib/eligibility.sh dev
#   bash $LOOP_HOME/runners/lib/eligibility.sh review
# Wrappers source the file and call functions directly.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    dev)        eligibility_dev_count; exit $? ;;
    review)     eligibility_review_pending; exit $? ;;
    -h|--help|help|"")
      cat <<'EOF'
Usage: eligibility.sh <mode>

Modes:
  dev     Count open severity:high|medium issues with no assignee.
  review  Count open dev-agent PRs not yet reviewed at current head SHA.

Output: one line with the count (or '?' on gh/jq failure).
Exit:   0 = work to do, 1 = nothing eligible, 2 = predicate failed.

Required env:
  REPO_ROOT, LOOP_HOME (set automatically when invoked via the loop CLI).
EOF
      exit 0 ;;
    *) echo "[eligibility] unknown mode: $1" >&2; exit 2 ;;
  esac
fi
