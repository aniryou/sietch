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

# Default for older loop.config files predating GH#28. Set unconditionally
# (default-if-unset) so consumer repos don't have to re-run `st init` to pick
# up the new safety-net skip marker.
: "${BLOCKED_HUMAN_LABEL:=blocked:human}"

# ---------------------------------------------------------------------------
# Mode 1 dev-agent: open severity:high|medium issues with no assignee, no
# ${BLOCKED_HUMAN_LABEL} label, AND no live filesystem lock under $LOCK_DIR.
#
# The label filter (GH#28) drops issues the safety-net flow has flagged as
# permanently ineligible until a human acts. Without it, every poll cycle
# rediscovers the same blocked issue, the wrapper spawns a fresh LLM, the
# LLM re-trips the same safety-net rule, and exits — burning tokens until
# the human closes/reassigns the GH issue.
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
        --json number,assignees,labels \
        --limit 50 2>/dev/null \
        | jq -r --arg blocked "$BLOCKED_HUMAN_LABEL" '
            .[]
            | select(.assignees == [])
            | select((.labels // [] | map(.name)) | index($blocked) | not)
            | .number
          ' 2>/dev/null
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
# Reviewer orchestrator: open ${BRANCH_PREFIX}/* PRs whose head commit is not
# yet covered by a [reviewer-agent: ...] review.
#
# A review is considered to "cover" the head when its `submittedAt` is later
# than the head commit's `committedDate`. (We can't use `review.commit_id` —
# `gh pr list --json reviews` populates it as null in current gh versions.)
#
# Mirrors the orchestrator's own filter, so false-positive rate is minimal.
# The orchestrator still re-checks before dispatching its sub-agent.
# ---------------------------------------------------------------------------
eligibility_review_pending() {
  # `gh pr list --json reviews` populates each review's `commit_id` as null,
  # so the previous `index($pr.headRefOid)` lookup never matched and every
  # PR was wrongly counted as needing review. Use review.submittedAt vs the
  # head commit's committedDate — both are non-null in real gh output.
  local data count
  if ! data=$(
    PAGER=cat GIT_PAGER=cat gh pr list \
      --repo "$REPO_SLUG" --state open \
      --search "head:${BRANCH_PREFIX}/ -is:draft" \
      --json number,commits,reviews \
      --limit 100 2>/dev/null
  ); then
    echo "?"
    return 2
  fi
  if ! count=$(
    echo "$data" | jq --arg re "$REVIEWER_AGENT_VERDICT_REGEX" '
      [.[]
       | . as $pr
       | ((($pr.commits // [])[-1] | .committedDate) // null) as $head_date
       | ($pr.reviews // [] | [.[] | select(.body | test($re)) | .submittedAt]) as $review_dates
       | select(
           $head_date == null
           or ($review_dates | map(select(. != null and . > $head_date)) | length == 0)
         )
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
# Mode 2 follow-up dispatcher: should we spin up a dev-agent on PR <N>?
#
# Until GH#24 the dispatcher fired on a pure timestamp comparison — every
# `[reviewer-agent: clean]` review beat the latest dev-comment by definition,
# so the LLM was woken up only to discover there was nothing actionable. Cost
# recurred every poll cycle until the PR merged (severity:medium token leak).
#
# The verdict-aware gate:
#   - {clean, nits}             → skip regardless of timestamp ordering
#                                   (`nits` is explicitly optional in Mode 2;
#                                    `clean` is by definition no-op).
#   - {changes, comment, blocked} → dispatch IFF the review's submittedAt
#                                   is newer than the latest dev-agent
#                                   comment's createdAt (otherwise the dev
#                                   already responded; another dispatch
#                                   would re-do work).
#   - no reviewer-agent review yet → skip (nothing to follow-up on).
#
# Prints the verdict (or "none" / "?") on stdout for log visibility.
# ---------------------------------------------------------------------------
eligibility_followup_pr() {
  local pr="${1:-}"
  if [ -z "$pr" ]; then
    echo "?"
    return 2
  fi

  local data
  if ! data=$(
    PAGER=cat GIT_PAGER=cat gh pr view "$pr" \
      --repo "$REPO_SLUG" \
      --json reviews,comments 2>/dev/null
  ); then
    echo "?"
    return 2
  fi

  # One pass of jq: classify the latest reviewer-agent review and the
  # ordering vs the latest dev-agent comment, emit a TAB-separated
  # "<verdict>\t<dispatch?>" string.
  local result
  if ! result=$(
    echo "$data" | jq -r \
      --arg re "$REVIEWER_AGENT_VERDICT_REGEX" \
      --arg prefix "$DEV_AGENT_COMMENT_PREFIX" '
      (.reviews // []
        | map(select(.body | test($re)))
        | sort_by(.submittedAt)
        | last) as $latest_review
      | (.comments // []
        | map(select(.body | startswith($prefix)))
        | sort_by(.createdAt)
        | last) as $latest_devcomment
      | if $latest_review == null then "none\tno"
        else
          ($latest_review.body | match($re).captures[0].string) as $verdict
          | if ($verdict == "clean" or $verdict == "nits") then "\($verdict)\tno"
            elif ($latest_devcomment == null
                  or $latest_review.submittedAt > $latest_devcomment.createdAt) then
              "\($verdict)\tyes"
            else "\($verdict)\tno"
            end
        end
      ' 2>/dev/null
  ); then
    echo "?"
    return 2
  fi

  local verdict should
  # `result` is "<verdict>\t<dispatch>"; use cut(1) instead of literal-tab
  # parameter expansion so the source is robust to whitespace re-indenting.
  verdict=$(printf '%s\n' "$result" | cut -f1)
  should=$(printf '%s\n' "$result" | cut -f2)
  echo "$verdict"
  if [ "$should" = "yes" ]; then
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# CLI entry point. Lets agents invoke this via:
#   bash $LOOP_HOME/runners/lib/eligibility.sh dev
#   bash $LOOP_HOME/runners/lib/eligibility.sh review
#   bash $LOOP_HOME/runners/lib/eligibility.sh followup <PR#>
# Wrappers source the file and call functions directly.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    dev)
      eligibility_dev_count
      exit $?
      ;;
    review)
      eligibility_review_pending
      exit $?
      ;;
    followup)
      eligibility_followup_pr "${2:-}"
      exit $?
      ;;
    -h | --help | help | "")
      cat <<'EOF'
Usage: eligibility.sh <mode> [args]

Modes:
  dev              Count open severity:high|medium issues with no assignee.
  review           Count open dev-agent PRs not yet reviewed at current head SHA.
  followup <PR#>   Should the follow-up dispatcher dispatch a Mode 2 dev-agent
                   for PR <PR#>? Skips clean/nits verdicts unconditionally;
                   dispatches changes/comment/blocked iff the review is newer
                   than the latest dev-agent comment.

Output: one line — count (dev/review) or verdict (followup), or '?' on failure.
Exit:   0 = work to do, 1 = nothing eligible, 2 = predicate failed.

Required env:
  REPO_ROOT, LOOP_HOME (set automatically when invoked via the loop CLI).
EOF
      exit 0
      ;;
    *)
      echo "[eligibility] unknown mode: $1" >&2
      exit 2
      ;;
  esac
fi
