#!/usr/bin/env bash
# Wrapper for the headless reviewer agent.
# Streams readable output to a log while keeping raw stream-json for debugging.
#
# Usage:
#   st review <PR>
#
# GH#117: takes a mandatory PR number. The previous orchestrator-based
# scan-and-dispatch flow has been replaced by a shell-level dispatcher
# (run-loop.sh: loop_dispatcher_review) that picks the PR and passes it in.
# Without an argument, the wrapper exits 2 with a usage line — no LLM is
# spawned. This lets dispatcher backoff treat "no work" as rc=2 (matches
# the run-developer.sh contract).
#
# Exit code is the agent's exit code.

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

usage() {
  cat >&2 <<'EOF'
Usage: st review <PR>

Reviews a single GitHub PR by number. The PR must be open, non-draft, have
finished CI, not already carry a [reviewer-agent: ...] review at its current
head, and not carry the REVIEWER_ESCALATION_LABEL.
EOF
}

TARGET_PR="${1:-}"
if ! [[ "$TARGET_PR" =~ ^[0-9]+$ ]]; then
  echo "[wrapper] review requires a numeric <PR>; got: '${TARGET_PR}'" >&2
  usage
  exit 2
fi

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.loop/loop.config"
# Structured event log (GH#92) — best-effort NDJSON emission alongside the
# existing human-readable echoes.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/event_log.sh"
# Shared idempotent-escalate helper (GH#108 / GH#110) — used by the per-PR
# cap escalation below. Sourced ahead of any wrapper code that could
# hard-fail.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/hard_failure.sh"

# Defaults for older loop.config files predating the relevant GH issues. Each
# `:` default-if-unset matches the pattern run-developer.sh uses so consumer
# repos don't have to re-run `st init` to pick up new knobs.
# GH#94 — sub-agent-failure cap and escalation label (now flattened-LLM
# failure cap).
: "${REVIEWER_SUB_AGENT_FAILURE_CAP:=3}"
: "${REVIEWER_ESCALATION_LABEL:=reviewer:needs-human}"
# GH#117 — dispatcher-side concurrency cap default; consumed by run-loop.sh's
# loop_dispatcher_review. Mirrored here so direct `st review <PR>` invocations
# don't error on `set -u` if a stale loop.config lacks the key. The wrapper
# itself doesn't gate on this knob (one wrapper handles one PR), but sourcing
# the config file with the key absent is fine.

# Defense-in-depth single-PR check (GH#117): the dispatcher already filtered
# this PR via eligibility_review_pending_list, but the time between scan and
# wrapper start is non-zero. A fresh review may have landed, the PR may have
# been drafted, or CI may have restarted — re-check before spawning the LLM.
# On miss, exit 2 so dispatcher backoff treats it as "no work" rather than
# failure (mirrors the run-developer.sh contract).
PR_DATA=$(
  PAGER=cat GIT_PAGER=cat gh pr view "$TARGET_PR" \
    --repo "$REPO_SLUG" \
    --json number,state,isDraft,headRefOid,reviews,labels,statusCheckRollup 2>/dev/null
) || PR_DATA=""
if [ -z "$PR_DATA" ]; then
  # GH#27 contract: predicate failures (gh outage, jq error, GraphQL drift)
  # are skip+backoff, not "proceed to be safe". The wording mirrors
  # run-developer.sh's rc=2 path so operators tailing the tmux pane see the
  # same shape across wrappers.
  echo "[wrapper] eligibility: predicate failed (gh-pr-view rc=non-zero or empty); skipping LLM invocation and backing off" >&2
  echo "[wrapper] result=no-work reason=predicate-failed"
  event_emit reviewer eligibility result=predicate-failed pr="$TARGET_PR"
  exit 2
fi

ELIG_DECISION=$(
  printf '%s' "$PR_DATA" | jq -r \
    --arg re "$REVIEWER_AGENT_VERDICT_REGEX" \
    --arg label "$REVIEWER_ESCALATION_LABEL" '
    if .state != "OPEN" then "skip:not-open"
    elif .isDraft == true then "skip:draft"
    elif (.labels // [] | map(.name) | index($label)) != null then "skip:escalated"
    elif (.statusCheckRollup // [] | map(.status // .state)
          | any(. == "IN_PROGRESS" or . == "PENDING" or . == "QUEUED"))
      then "skip:ci-running"
    elif (.reviews // [] | any((.body // "") | test($re))) then "skip:reviewed"
    else "proceed"
    end
  ' 2>/dev/null
) || ELIG_DECISION=""
case "$ELIG_DECISION" in
  proceed)
    echo "[wrapper] eligibility: PR #${TARGET_PR} ready for review; proceeding"
    event_emit reviewer eligibility result=proceeding pr="$TARGET_PR"
    ;;
  skip:*)
    REASON="${ELIG_DECISION#skip:}"
    echo "[wrapper] eligibility: PR #${TARGET_PR} not eligible (${REASON}); no PRs need review here, skipping LLM invocation"
    echo "[wrapper] result=no-work reason=${REASON}"
    event_emit reviewer eligibility result=no-work pr="$TARGET_PR" reason="$REASON"
    exit 2
    ;;
  *)
    # jq itself failed (malformed JSON, jq missing) — treat as predicate failed.
    echo "[wrapper] eligibility: predicate failed (jq classification error); skipping LLM invocation and backing off" >&2
    echo "[wrapper] result=no-work reason=predicate-failed"
    event_emit reviewer eligibility result=predicate-failed pr="$TARGET_PR"
    exit 2
    ;;
esac

# $$ suffix keeps log paths unique when two wrappers start in the same second.
TS="$(date +%Y%m%d-%H%M%S)-$$"
LOG="/tmp/reviewer-agent-${TS}.log"
RAW="/tmp/reviewer-agent-${TS}.jsonl"

# Pipeline state — the cleanup trap forwards SIGTERM/SIGINT to PIPELINE_PGID
# so an external `kill <wrapper-pid>` actually tears down claude/tee/jq.
PIPELINE_PID=""
PIPELINE_PGID=""

# shellcheck disable=SC2329 # invoked via `trap cleanup EXIT INT TERM` below
cleanup() {
  local exit_code=$?
  echo "[wrapper] reviewer exited with code $exit_code; cleaning up..." >&2
  pipeline_kill_pgroup_if_alive "${PIPELINE_PGID:-}"
  echo "[wrapper] live log: $LOG" >&2
  echo "[wrapper] raw json: $RAW" >&2
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# jq filter: same stream-json → human-readable filter as run-developer.sh,
# sourced from the shared lib so both panes emit identical event tags and
# ANSI colors. Honors NO_COLOR.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/jq_filter.sh"

# Signal-forwarding helpers — see runners/lib/pipeline_signal.sh for the
# full explanation of why foreground pipelines hang on `kill <pid>`.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/pipeline_signal.sh"

cd "$REPO" || exit 1

echo "[wrapper] live log: $LOG"
echo "[wrapper] raw json: $RAW"
echo "[wrapper] tail with: tail -f $LOG"
echo

# Background the pipeline in a subshell with `set -m` so `wait` (below) is
# signal-interruptible and the pipeline lives in its own process group. See
# runners/lib/pipeline_signal.sh for the rationale.
event_emit reviewer llm_started mode=default pr="$TARGET_PR"
_llm_start_s=$(date +%s)
set -m
(
  PAGER=cat GIT_PAGER=cat \
    claude -p "You are running headless as a reviewer agent. Never wait for human input. Decide and act.

ASSIGNMENT: Review GitHub PR #${TARGET_PR} in the ${REPO_SLUG} repo.

The dispatcher already filtered this PR for eligibility (open, non-draft, CI finished, not already reviewed at current head, no escalation label). Skip the orchestrator-style scan steps in your instructions — your PR is already assigned. Follow the per-PR workflow in your system prompt.

When you finish, print exactly one final summary line in this format and exit:
[reviewer-agent] result=<commented|requested-changes|skipped|blocked> pr=#${TARGET_PR} sha=<head_sha> findings=<P0:X P1:Y P2:Z> beads=<PARENT>" \
    --append-system-prompt "$("$LOOP_HOME/runners/lib/render-prompt.sh" "$LOOP_HOME/templates/reviewer.md")" \
    --permission-mode bypassPermissions \
    --max-turns "$REVIEWER_MAX_TURNS" \
    --verbose \
    --output-format stream-json \
    2> >(tee "$RAW.stderr" >&2) \
    | tee "$RAW" \
    | jq -r --unbuffered "$JQ_FILTER" 2>/dev/null \
    | tee "$LOG"
) &
PIPELINE_PID=$!
PIPELINE_PGID=$(pipeline_capture_pgid "$PIPELINE_PID")
set +m

wait "$PIPELINE_PID"
LLM_EXIT=$?
event_emit reviewer llm_exited mode=default pr="$TARGET_PR" exit_code="$LLM_EXIT" duration_s="$(($(date +%s) - _llm_start_s))"

# GH#55 + GH#94 (re-applied to the flattened invocation, GH#117): when the
# LLM exits 0 but never reaches its final `[reviewer-agent] result=...` line
# (typical failure modes: claude max-turns mid-review, context exhaustion,
# the LLM forgetting the marker contract), no [reviewer-agent: ...] review
# was posted on the PR. eligibility_review_pending_list would then re-fire
# the wrapper every cycle on the same PR, the LLM crashes the same way,
# repeat — leaking ~$0.50–$2.50/cycle per such PR.
#
# Fix mirrors the original GH#55 path: post a stub `[reviewer-agent: blocked]`
# review here so the predicate's "review covers head" half fires next cycle
# and skips the PR until a new commit lands. Exit-0-scoped on purpose: a
# non-zero LLM exit (claude crash, max-turns at the protocol layer, OOM,
# API outage) is a wrapper-level failure that run-loop.sh already backs off
# on. Inventing a verdict in that case would mask hard failures.
#
# GH#94 cap: after $REVIEWER_SUB_AGENT_FAILURE_CAP consecutive stub-blocked
# reviews on this PR, escalate via $REVIEWER_ESCALATION_LABEL + a one-time
# explanation comment instead of yet another stub. The wrapper greps for
# the same marker substring (`Sub-agent run failed before posting a review`)
# the stub body carries, so the cap-counter stays in sync with the stub
# format. Idempotent: re-running on a PR that already carries the label is
# a no-op.
#
# Pre-GH#117 the failure-detection grep matched
# `[reviewer-orchestrator] result=sub-agent-failed pr=#N` (the orchestrator
# emitted that line when its dispatched sub-agent crashed). The flattened
# invocation has no orchestrator layer — instead, a successfully-completed
# review prints `[reviewer-agent] result=...` per templates/reviewer.md, so
# the absence of that marker after exit 0 is the equivalent failure signal.
if [ "$LLM_EXIT" -eq 0 ]; then
  HAS_RESULT_LINE=0
  for src in "$LOG" "$RAW"; do
    [ -f "$src" ] || continue
    if grep -qE '\[reviewer-agent\] result=(commented|requested-changes|skipped|blocked)' "$src" 2>/dev/null; then
      HAS_RESULT_LINE=1
      break
    fi
  done
  if [ "$HAS_RESULT_LINE" -eq 0 ]; then
    FAILED_PR="$TARGET_PR"
    # GH#92 observability: emit hard_failure once per LLM-side failure to
    # complete a review, regardless of whether the wrapper goes on to post a
    # stub (below cap), escalate to a human (cap hit), or idempotent-skip
    # (label already present). All three paths represent the same underlying
    # event from a control-tower perspective.
    event_emit reviewer hard_failure mode=default pr="$FAILED_PR" reason=no-result-line

    # The substring is the unambiguous marker for "wrapper-posted stub" vs
    # "LLM-authored real [reviewer-agent: blocked] verdict" — the LLM's
    # review body never contains this phrase.
    STUB_MARKER='Sub-agent run failed before posting a review'

    PR_REVIEW_DATA=$(
      PAGER=cat GIT_PAGER=cat gh pr view "$FAILED_PR" \
        --repo "$REPO_SLUG" \
        --json reviews 2>/dev/null
    ) || PR_REVIEW_DATA=""

    STUB_COUNT=0
    if [ -n "$PR_REVIEW_DATA" ]; then
      STUB_COUNT=$(
        printf '%s' "$PR_REVIEW_DATA" \
          | jq --arg marker "$STUB_MARKER" \
            '[.reviews // [] | .[] | select((.body // "") | contains($marker))] | length' \
            2>/dev/null
      ) || STUB_COUNT=0
    fi
    STUB_COUNT="${STUB_COUNT:-0}"

    if [ "$STUB_COUNT" -ge "$REVIEWER_SUB_AGENT_FAILURE_CAP" ]; then
      echo "[wrapper] PR #$FAILED_PR has $STUB_COUNT stub-blocked reviews (cap=$REVIEWER_SUB_AGENT_FAILURE_CAP); escalating to human via $REVIEWER_ESCALATION_LABEL" >&2
      _escalation_body="🤖 Reviewer agent has failed $STUB_COUNT consecutive times on this PR. This is likely a deterministic failure (oversized diff, malformed PR, or similar). Human attention required; the reviewer will not re-dispatch on this PR until the \`$REVIEWER_ESCALATION_LABEL\` label is removed."
      hard_failure_idempotent_escalate pr "$FAILED_PR" \
        "$REVIEWER_ESCALATION_LABEL" "$_escalation_body" \
        d73a4a "Reviewer LLM failed repeatedly; reviewer will not re-dispatch until removed"
      unset _escalation_body
    else
      echo "[wrapper] LLM produced no [reviewer-agent] result line on PR #$FAILED_PR ($((STUB_COUNT + 1))/$REVIEWER_SUB_AGENT_FAILURE_CAP); posting stub [reviewer-agent: blocked] review" >&2
      PAGER=cat GIT_PAGER=cat gh pr review "$FAILED_PR" \
        --repo "$REPO_SLUG" \
        --comment \
        --body "🤖 [reviewer-agent: blocked] Sub-agent run failed before posting a review (likely context exhaustion or API failure). The reviewer dispatcher will not re-fire on this head SHA. Please push a new commit or request a fresh review." \
        >/dev/null 2>&1 || true
    fi
  fi
fi

unset PR_DATA ELIG_DECISION

exit "$LLM_EXIT"
