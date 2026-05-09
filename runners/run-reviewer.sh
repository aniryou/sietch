#!/usr/bin/env bash
# Wrapper for the headless reviewer agent.
# Streams readable output to a log while keeping raw stream-json for debugging.
#
# Usage:
#   st review
#
# Exit code is the agent's exit code.

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.loop/loop.config"
# Structured event log (GH#92) — best-effort NDJSON emission alongside the
# existing human-readable echoes.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/event_log.sh"
# Shared idempotent-escalate helper (GH#108). Sourced ahead of any wrapper
# code that could hard-fail; the existing inline escalation block at
# run-reviewer.sh:198-220 is left in place for now (sub-issue 3 swaps it
# for a one-line call).
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/hard_failure.sh"

# Preflight: skip the LLM if no dev-agent PR needs review at its current
# headRefOid. Exit code 2 lets run-loop.sh distinguish "skipped, no work"
# from "ran successfully" so it can apply exponential backoff.
EL_COUNT=$("$LOOP_HOME/runners/lib/eligibility.sh" review)
EL_RC=$?
case "$EL_RC" in
  0)
    echo "[wrapper] eligibility: $EL_COUNT PR(s) pending review; proceeding"
    event_emit reviewer eligibility result=proceeding count="$EL_COUNT"
    ;;
  1)
    echo "[wrapper] eligibility: no PRs need review; skipping LLM invocation"
    echo "[wrapper] result=no-work"
    event_emit reviewer eligibility result=no-work
    exit 2
    ;;
  *)
    # GH#27: any non-{0,1} rc means the predicate itself failed (gh outage,
    # jq error, GraphQL node-limit, ...). The previous "proceed to be safe"
    # policy turned every persistent failure into a per-cycle token leak —
    # the LLM was spawned each poll while doing nothing useful. Skip + exit 2
    # so run-loop.sh applies the same exponential backoff it uses for rc=1.
    # Operators see the failure on stderr and can intervene.
    echo "[wrapper] eligibility: predicate failed (rc=$EL_RC); skipping LLM invocation and backing off" >&2
    echo "[wrapper] result=no-work reason=predicate-failed"
    event_emit reviewer eligibility result=predicate-failed rc="$EL_RC"
    exit 2
    ;;
esac
unset EL_COUNT EL_RC

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
event_emit reviewer llm_started mode=default
_llm_start_s=$(date +%s)
set -m
(
  PAGER=cat GIT_PAGER=cat \
    claude -p "Run the reviewer orchestrator workflow defined in your system prompt. Begin the scan, then dispatch a sub-agent for the chosen PR via the Agent tool. Single-pass — exit after one dispatch." \
    --append-system-prompt "$("$LOOP_HOME/runners/lib/render-prompt.sh" "$LOOP_HOME/templates/reviewer-orchestrator.md")" \
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
event_emit reviewer llm_exited mode=default exit_code="$LLM_EXIT" duration_s="$(($(date +%s) - _llm_start_s))"

# GH#55: when the orchestrator emits `result=sub-agent-failed pr=#N` and the
# pipeline still exits 0 (the orchestrator's failure path is structured exit 0
# — it ran to completion, the sub-agent didn't), no [reviewer-agent: ...]
# review was posted on the PR. eligibility_review_pending would then re-fire
# the orchestrator + sub-agent every cycle, both crash the same way, repeat.
# Post a stub [reviewer-agent: blocked] review here so the predicate's
# "review covers head" half fires next cycle and skips the PR until a new
# commit lands.
#
# GH#94: GH#55's stub closes the per-SHA loop but not the per-PR loop. On a
# deterministically-failing PR (oversized diff, malformed PR), every new push
# yields a fresh head SHA, the orchestrator dispatches again, the sub-agent
# fails the same way, and the wrapper posts another stub. After
# REVIEWER_SUB_AGENT_FAILURE_CAP consecutive stubs (default 3) escalate to a
# human via REVIEWER_ESCALATION_LABEL + one explanation comment instead of
# yet another stub. eligibility_review_pending then drops the PR from
# dispatch until a human removes the label.
#
# The orchestrator template's hard rule "Never call gh pr review" forces this
# fix to live in the wrapper rather than the orchestrator itself; see
# templates/reviewer-orchestrator.md (search for GH#55).
#
# Exit-0-scoped on purpose: a non-zero LLM exit (claude crash, max-turns, OOM,
# API outage) is a wrapper-level failure that run-loop.sh already backs off
# on. Inventing a verdict in that case would mask hard failures.
if [ "$LLM_EXIT" -eq 0 ]; then
  FAILED_PR=""
  for src in "$LOG" "$RAW"; do
    [ -f "$src" ] || continue
    FAILED_PR=$(grep -oE '\[reviewer-orchestrator\] result=sub-agent-failed pr=#[0-9]+' "$src" 2>/dev/null \
      | grep -oE '[0-9]+' \
      | head -1)
    [ -n "$FAILED_PR" ] && break
  done
  if [ -n "${FAILED_PR:-}" ]; then
    # GH#92 observability: emit hard_failure once per orchestrator-reported
    # sub-agent failure, regardless of whether the wrapper goes on to post a
    # stub (below cap), escalate to a human (cap hit), or idempotent-skip
    # (label already present). All three paths represent the same underlying
    # event from a control-tower perspective.
    event_emit reviewer hard_failure mode=default pr="$FAILED_PR" reason=sub-agent-failed

    # Defaults for older loop.config files predating GH#94. Set unconditionally
    # (default-if-unset) so consumer repos don't have to re-run `st init`.
    : "${REVIEWER_SUB_AGENT_FAILURE_CAP:=3}"
    : "${REVIEWER_ESCALATION_LABEL:=reviewer:needs-human}"

    # The substring is the unambiguous marker for "wrapper-posted stub" vs
    # "sub-agent-authored real [reviewer-agent: blocked] verdict" — the
    # sub-agent's review body never contains this phrase.
    STUB_MARKER='Sub-agent run failed before posting a review'

    PR_DATA=$(
      PAGER=cat GIT_PAGER=cat gh pr view "$FAILED_PR" \
        --repo "$REPO_SLUG" \
        --json reviews,labels 2>/dev/null
    ) || PR_DATA=""

    STUB_COUNT=0
    HAS_LABEL=0
    if [ -n "$PR_DATA" ]; then
      STUB_COUNT=$(
        printf '%s' "$PR_DATA" \
          | jq --arg marker "$STUB_MARKER" \
            '[.reviews // [] | .[] | select((.body // "") | contains($marker))] | length' \
            2>/dev/null
      ) || STUB_COUNT=0
      HAS_LABEL=$(
        printf '%s' "$PR_DATA" \
          | jq --arg label "$REVIEWER_ESCALATION_LABEL" \
            'if ((.labels // []) | map(.name) | index($label)) != null then 1 else 0 end' \
            2>/dev/null
      ) || HAS_LABEL=0
    fi
    STUB_COUNT="${STUB_COUNT:-0}"
    HAS_LABEL="${HAS_LABEL:-0}"

    if [ "$STUB_COUNT" -ge "$REVIEWER_SUB_AGENT_FAILURE_CAP" ]; then
      if [ "$HAS_LABEL" -eq 1 ]; then
        # Idempotent: label already applied, human already pinged. Re-applying
        # the label would be a no-op (gh dedupes), but re-posting the comment
        # would pile up noise on every subsequent failed cycle.
        echo "[wrapper] PR #$FAILED_PR already carries $REVIEWER_ESCALATION_LABEL ($STUB_COUNT stub failures); skipping escalation (idempotent)" >&2
      else
        echo "[wrapper] PR #$FAILED_PR has $STUB_COUNT stub-blocked reviews (cap=$REVIEWER_SUB_AGENT_FAILURE_CAP); escalating to human via $REVIEWER_ESCALATION_LABEL" >&2
        # Idempotent label create — --force makes "already exists" a no-op.
        PAGER=cat GIT_PAGER=cat gh label create "$REVIEWER_ESCALATION_LABEL" \
          --repo "$REPO_SLUG" \
          --color d73a4a \
          --description "Reviewer sub-agent failed repeatedly; reviewer will not re-dispatch until removed" \
          --force >/dev/null 2>&1 || true
        PAGER=cat GIT_PAGER=cat gh pr edit "$FAILED_PR" \
          --repo "$REPO_SLUG" \
          --add-label "$REVIEWER_ESCALATION_LABEL" \
          >/dev/null 2>&1 || true
        PAGER=cat GIT_PAGER=cat gh pr comment "$FAILED_PR" \
          --repo "$REPO_SLUG" \
          --body "🤖 Reviewer agent has failed $STUB_COUNT consecutive times on this PR. This is likely a deterministic failure (oversized diff, malformed PR, or similar). Human attention required; the reviewer will not re-dispatch on this PR until the \`$REVIEWER_ESCALATION_LABEL\` label is removed." \
          >/dev/null 2>&1 || true
      fi
    else
      echo "[wrapper] orchestrator reported sub-agent failure on PR #$FAILED_PR ($((STUB_COUNT + 1))/$REVIEWER_SUB_AGENT_FAILURE_CAP); posting stub [reviewer-agent: blocked] review" >&2
      PAGER=cat GIT_PAGER=cat gh pr review "$FAILED_PR" \
        --repo "$REPO_SLUG" \
        --comment \
        --body "🤖 [reviewer-agent: blocked] Sub-agent run failed before posting a review (likely context exhaustion or API failure). The reviewer dispatcher will not re-fire on this head SHA. Please push a new commit or request a fresh review." \
        >/dev/null 2>&1 || true
    fi
  fi
fi

exit "$LLM_EXIT"
