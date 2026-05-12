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

# GH#172: per-invocation dispatch correlation field. The dispatcher
# (run-loop.sh: loop_dispatcher_review) generates a dispatch_id at each fire
# site and exports LOOP_DISPATCH_ID into the wrapper's env so structured-event
# consumers can join `dispatch_fired` to this wrapper's `llm_started` /
# `llm_exited` / `hard_failure` chain. Stored as a single string and
# expanded UNQUOTED at each call site — bash 3.2 (macOS default) errors
# on `"${empty_array[@]}"` under `set -u`. dispatch_id values are
# `${PID}-<ns_timestamp>` and never contain spaces.
_dispatch_kv=""
[ -n "${LOOP_DISPATCH_ID:-}" ] && _dispatch_kv="dispatch_id=${LOOP_DISPATCH_ID}"

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
  event_emit reviewer eligibility result=predicate-failed pr="$TARGET_PR" $_dispatch_kv
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
    elif (
      (.headRefOid // "") as $head
      | .reviews // []
      | any(((.body // "") | test($re)) and ((.commit.oid // "") == $head))
    ) then "skip:reviewed"
    else "proceed"
    end
  ' 2>/dev/null
) || ELIG_DECISION=""
case "$ELIG_DECISION" in
  proceed)
    echo "[wrapper] eligibility: PR #${TARGET_PR} ready for review; proceeding"
    event_emit reviewer eligibility result=proceeding pr="$TARGET_PR" $_dispatch_kv
    ;;
  skip:*)
    REASON="${ELIG_DECISION#skip:}"
    echo "[wrapper] eligibility: PR #${TARGET_PR} not eligible (${REASON}); no PRs need review here, skipping LLM invocation"
    echo "[wrapper] result=no-work reason=${REASON}"
    event_emit reviewer eligibility result=no-work pr="$TARGET_PR" reason="$REASON" $_dispatch_kv
    exit 2
    ;;
  *)
    # jq itself failed (malformed JSON, jq missing) — treat as predicate failed.
    echo "[wrapper] eligibility: predicate failed (jq classification error); skipping LLM invocation and backing off" >&2
    echo "[wrapper] result=no-work reason=predicate-failed"
    event_emit reviewer eligibility result=predicate-failed pr="$TARGET_PR" $_dispatch_kv
    exit 2
    ;;
esac

# Caller-overridable root for wrapper LOG/RAW paths (GH#126). Production
# default `/tmp` keeps existing log-mining tooling and operator muscle memory
# unchanged; bats sets LOOP_LOG_DIR to a per-test path via tests/helpers.bash
# so fixture-driven runs don't accumulate beside production logs.
: "${LOOP_LOG_DIR:=/tmp}"
# $$ suffix keeps log paths unique when two wrappers start in the same second.
TS="$(date +%Y%m%d-%H%M%S)-$$"
LOG="${LOOP_LOG_DIR}/reviewer-agent-${TS}.log"
RAW="${LOOP_LOG_DIR}/reviewer-agent-${TS}.jsonl"

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
# Signal-forwarding helpers (pipeline_capture_pgid, pipeline_kill_pgroup_if_alive).
# MUST be sourced BEFORE `trap cleanup EXIT INT TERM` below (GH#160). The
# reviewer wrapper has no explicit early exits between the trap and the
# (former) source line, but a SIGINT/SIGTERM arriving in the ~10-line gap
# (jq_filter source, source itself) would fire the cleanup trap and call
# pipeline_kill_pgroup_if_alive — undefined yet — printing
# `command not found` to stderr. The helper has no side effects (only
# function definitions plus the canonical preamble already enabled above),
# so the early source is safe. See the lib file for why foreground
# pipelines hang on `kill <pid>`.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/pipeline_signal.sh"
trap cleanup EXIT INT TERM

# jq filter: same stream-json → human-readable filter as run-developer.sh,
# sourced from the shared lib so both panes emit identical event tags and
# ANSI colors. Honors NO_COLOR.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/jq_filter.sh"

cd "$REPO" || exit 1

echo "[wrapper] live log: $LOG"
echo "[wrapper] raw json: $RAW"
echo "[wrapper] tail with: tail -f $LOG"
echo

# Background the pipeline in a subshell with `set -m` so `wait` (below) is
# signal-interruptible and the pipeline lives in its own process group. See
# runners/lib/pipeline_signal.sh for the rationale.
event_emit reviewer llm_started mode=default pr="$TARGET_PR" $_dispatch_kv
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
# GH#170: extract total_cost_usd / input_tokens / output_tokens / num_turns
# from the final `type:"result"` line in $RAW so the llm_exited event carries
# per-run cost. Each field defaults to 0 when the result frame is missing
# (e.g. claude crash before completion); see event_cost_fields_from_raw.
_llm_cost_kv=()
while IFS= read -r _kv; do
  [ -n "$_kv" ] && _llm_cost_kv+=("$_kv")
done < <(event_cost_fields_from_raw "$RAW")
event_emit reviewer llm_exited mode=default pr="$TARGET_PR" exit_code="$LLM_EXIT" duration_s="$(($(date +%s) - _llm_start_s))" $_dispatch_kv "${_llm_cost_kv[@]}"
unset _llm_cost_kv _kv

# GH#127: count Bash tool_use events from the raw stream-json and emit a
# `bash_overshoot` event when the count exceeds REVIEWER_BASH_CALL_GUIDANCE.
# The guidance is *soft* — the wrapper does not interrupt the run, change
# exit code, or post a stub based on the count. The signal exists so we can
# tune the prompt or threshold over time without breaking flowing reviews.
# Default if the consumer's loop.config predates GH#127 (was *_BUDGET).
: "${REVIEWER_BASH_CALL_GUIDANCE:=25}"
if [ -f "$RAW" ]; then
  BASH_CALL_COUNT=$(
    jq -r 'select(.type=="assistant") | .message.content[]? | select(.type=="tool_use" and .name=="Bash") | .id' \
      "$RAW" 2>/dev/null | wc -l | tr -d ' '
  ) || BASH_CALL_COUNT=0
  BASH_CALL_COUNT="${BASH_CALL_COUNT:-0}"
  if [ "$BASH_CALL_COUNT" -gt "$REVIEWER_BASH_CALL_GUIDANCE" ]; then
    echo "[wrapper] reviewer used $BASH_CALL_COUNT Bash calls (guidance ~$REVIEWER_BASH_CALL_GUIDANCE)" >&2
    event_emit reviewer bash_overshoot count="$BASH_CALL_COUNT" guidance="$REVIEWER_BASH_CALL_GUIDANCE" pr="$TARGET_PR" $_dispatch_kv
  fi
  unset BASH_CALL_COUNT
fi

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
VERDICT_DRIFT_DETECTED=0
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
    event_emit reviewer hard_failure mode=default pr="$FAILED_PR" reason=no-result-line $_dispatch_kv

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
  else
    # GH#128: verdict-drift detection. The LLM emitted a result line (so it
    # thinks it succeeded) and the stub-fallback path didn't fire — but the
    # actual review body posted on the PR may carry an off-spec marker (one
    # observed in the wild: `[reviewer-agent: commented]` instead of the
    # canonical `comment`). Downstream consumers of
    # REVIEWER_AGENT_VERDICT_REGEX (the eligibility predicate's
    # "review covers head" half, dev-agent follow-up mode, future merger
    # scripts) match the regex literally — an off-spec token slips through
    # silently and the dispatcher re-fires forever. Validate the actual
    # review body against the canonical regex and exit non-zero on drift so
    # the orchestrator's existing backoff / GH#94 cap escalation can take
    # over. Out-of-scope per GH#128: forcing a retry from inside the wrapper.
    PR_DRIFT_DATA=$(
      PAGER=cat GIT_PAGER=cat gh pr view "$TARGET_PR" \
        --repo "$REPO_SLUG" \
        --json reviews,headRefOid 2>/dev/null
    ) || PR_DRIFT_DATA=""

    if [ -n "$PR_DRIFT_DATA" ]; then
      # Pick the most recent reviewer-agent review on the CURRENT head SHA
      # only. Scoping to head matches the eligibility predicate's "review
      # covers head" semantic — a stale review on an older SHA is irrelevant
      # and shouldn't drive a drift verdict on this run. Filter on the
      # `🤖 Reviewer agent` body prefix to ignore the wrapper's own
      # `🤖 [reviewer-agent: blocked] Sub-agent run failed...` stub bodies
      # (they intentionally use a different prefix).
      DRIFT_VERDICT=$(
        printf '%s' "$PR_DRIFT_DATA" | jq -r \
          --arg re "$REVIEWER_AGENT_VERDICT_REGEX" \
          --arg prefix "$REVIEWER_AGENT_COMMENT_PREFIX" '
          (.headRefOid // "") as $head
          | (.reviews // []
             | map(select(((.body // "") | startswith($prefix))
                          and ((.commit.oid // "") == $head)))
             | sort_by(.submittedAt) | reverse | .[0]) as $latest
          | if $latest == null then "no-agent-review-at-head"
            elif (($latest.body // "") | test($re)) then "canonical"
            else "drift"
            end
        ' 2>/dev/null
      ) || DRIFT_VERDICT=""

      if [ "$DRIFT_VERDICT" = "drift" ]; then
        echo "[wrapper] verdict-drift detected on PR #${TARGET_PR}: latest reviewer-agent review body does not match REVIEWER_AGENT_VERDICT_REGEX (canonical token set: clean|nits|comment|changes|blocked)" >&2
        event_emit reviewer verdict_drift pr="$TARGET_PR" $_dispatch_kv
        VERDICT_DRIFT_DETECTED=1
      fi
    fi
    unset PR_DRIFT_DATA DRIFT_VERDICT
  fi
fi

unset PR_DATA ELIG_DECISION

if [ "$VERDICT_DRIFT_DETECTED" -eq 1 ]; then
  exit 1
fi

exit "$LLM_EXIT"
