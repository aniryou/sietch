#!/usr/bin/env bash
# Wrapper for the headless developer agent.
# Guarantees worktree cleanup on success, and (optionally) on any exit when KEEP_ON_FAIL=0.
#
# Usage:
#   st dev                       # Mode 1: scan issues, claim one, code+PR+CI
#   st dev follow-up <PR#>       # Mode 2: address reviewer feedback on a specific PR
#   st dev resolve <PR#>         # Mode 3: resolve merge conflicts (triage-gated)
#   KEEP_ON_FAIL=0 st dev ...    # cleanup on every exit, even failures
#
# Exit code is the agent's exit code.

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

usage() {
  cat >&2 <<'EOF'
Usage:
  st dev                                # Mode 1: scan issues, claim one (headless)
  st dev --interactive <issue#>         # Mode 1: human-driven on a specific issue
  st dev follow-up <PR#>                # Mode 2: address review on a PR (headless)
  st dev follow-up <PR#> --interactive  # Mode 2: human-driven
  st dev resolve <PR#>                  # Mode 3: resolve merge conflicts (headless, triage-gated)
  st dev resolve <PR#> --interactive    # Mode 3: human-driven (skips triage)
EOF
}

# GH#147 — strip `--interactive` from anywhere in the argv before mode
# parsing. Operators may write the flag before the PR# (`st dev follow-up
# --interactive 31`) or after (`st dev follow-up 31 --interactive`); both
# parse the same way.
INTERACTIVE=0
_args=()
for _a in "$@"; do
  case "$_a" in
    --interactive) INTERACTIVE=1 ;;
    *) _args+=("$_a") ;;
  esac
done
if [ "${#_args[@]}" -gt 0 ]; then
  set -- "${_args[@]}"
else
  set --
fi
unset _args _a

# Parse args — pick the mode and the kickoff prompt.
MODE="default"
TARGET_PR=""
INTERACTIVE_ISSUE=""
case "${1:-}" in
  "")
    : # Mode 1, no args
    ;;
  follow-up)
    MODE="follow-up"
    TARGET_PR="${2:-}"
    if ! [[ "$TARGET_PR" =~ ^[0-9]+$ ]]; then
      echo "[wrapper] follow-up requires a numeric <PR#>; got: '${TARGET_PR}'" >&2
      usage
      exit 2
    fi
    ;;
  resolve | resolve-conflicts)
    MODE="resolve-conflicts"
    TARGET_PR="${2:-}"
    if ! [[ "$TARGET_PR" =~ ^[0-9]+$ ]]; then
      echo "[wrapper] resolve-conflicts requires a numeric <PR#>; got: '${TARGET_PR}'" >&2
      usage
      exit 2
    fi
    ;;
  *)
    # Under --interactive, a bare numeric first arg is shorthand for Mode 1
    # on a specific issue. Without --interactive, an unknown keyword stays
    # an error (preserves the existing "unknown mode" contract for Modes
    # 2/3 typos).
    if [ "$INTERACTIVE" -eq 1 ] && [[ "$1" =~ ^[0-9]+$ ]]; then
      MODE="default"
      INTERACTIVE_ISSUE="$1"
    else
      echo "[wrapper] unknown mode: $1" >&2
      usage
      exit 2
    fi
    ;;
esac

# Mode 1 + --interactive requires an explicit issue#. The wrapper does
# not scan eligibility under --interactive, so there's nothing to fall
# back on if the operator forgot to specify one.
if [ "$INTERACTIVE" -eq 1 ] && [ "$MODE" = "default" ] && [ -z "$INTERACTIVE_ISSUE" ]; then
  echo "[wrapper] --interactive (Mode 1) requires a numeric <issue#>" >&2
  usage
  exit 2
fi
export INTERACTIVE

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.loop/loop.config"
# Structured event log (GH#92) — best-effort NDJSON emission alongside the
# existing human-readable echoes. Sourced before any boundary that might
# emit so a sourcing failure surfaces here, not mid-run.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/event_log.sh"
# Canonical loop_sanitize_id helper — single source of truth for the
# LOCK_NAME_PREFIX defaulting below (GH#98).
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/repo_id.sh"
# gh_best_effort (GH#99) — log-on-failure wrapper for best-effort `gh` calls
# (triage-untractable draft, Mode 3 hard-fail draft + comment, Mode 2
# follow-up hard-fail comment). Sourced alongside event_log.sh so the helper
# is available in every code path below.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/gh_helpers.sh"
# Shared idempotent-escalate helper (GH#108). Used by the Mode 1 escalation
# path below (GH#109) to apply blocked:human + post the operator comment
# idempotently — re-applying the label is a no-op but the helper also skips
# the comment when the label is already present, avoiding per-cycle noise.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/hard_failure.sh"
# Append-only log marker helpers (GH#100). Used by the Mode-3 triage parse
# below to read the LATEST `reason=...` token from triage output.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/log_helpers.sh"

# Default for older loop.config files predating GH#74. Sanitize via the
# canonical helper so REPO_NAMEs containing `.` produce a clean prefix
# even if the user hasn't re-rendered loop.config.example.
: "${LOCK_NAME_PREFIX:=$(loop_sanitize_id "${REPO_NAME:-}")-}"

# GH#129: the Mode 1 preflight used to call eligibility.sh twice per cycle
# (`dev` for the fast skip, `dev-candidates` for the lock loop), each issuing
# the same 3 `gh issue list` + 1 `gh pr list` queries. The lock-acquisition
# block below is now the single preflight; its rc=1/rc=2 paths produce the
# same `result=no-work` / event-log shape the deleted block did, and its rc=0
# path emits `eligibility result=proceeding` before the mkdir loop so the
# event-order contract (eligibility before lock_acquired) is preserved.

KEEP_ON_FAIL="${KEEP_ON_FAIL:-1}"
# Caller-overridable root for wrapper LOG/RAW paths (GH#126). Production
# default `/tmp` keeps existing log-mining tooling and operator muscle memory
# unchanged; bats sets LOOP_LOG_DIR to a per-test path via tests/helpers.bash
# so fixture-driven runs don't accumulate beside production logs.
: "${LOOP_LOG_DIR:=/tmp}"
# $$ suffix keeps log paths unique when two wrappers start in the same second.
TS="$(date +%Y%m%d-%H%M%S)-$$"

# Unique ID per wrapper invocation so the trap can release exactly the locks
# this run owns when multiple wrappers are running in parallel. Computed
# BEFORE lock acquisition because the lock-write below stamps it into the
# acquired lock dir's run_id file.
_run_ts=$(date +%s%N 2>/dev/null || date +%s)
export DEV_AGENT_RUN_ID="$$-$_run_ts"
unset _run_ts

# LOG / RAW / KICKOFF must be set before `cleanup` is registered — the trap
# references $LOG / $RAW under `set -u`, so an INT/TERM arriving before the
# preflight finished would otherwise hit an unbound-variable error in cleanup.
if [ "$MODE" = "follow-up" ]; then
  LOG="${LOOP_LOG_DIR}/dev-agent-followup-pr${TARGET_PR}-${TS}.log"
  RAW="${LOOP_LOG_DIR}/dev-agent-followup-pr${TARGET_PR}-${TS}.jsonl"
  KICKOFF="Run the developer agent in FOLLOW-UP MODE on PR #${TARGET_PR}. Skip the issue scan. Begin the follow-up workflow defined in Mode 2 of your system prompt now."
elif [ "$MODE" = "resolve-conflicts" ]; then
  LOG="${LOOP_LOG_DIR}/dev-agent-conflicts-pr${TARGET_PR}-${TS}.log"
  RAW="${LOOP_LOG_DIR}/dev-agent-conflicts-pr${TARGET_PR}-${TS}.jsonl"
  KICKOFF="Run the developer agent in MODE 3 (resolve merge conflicts) on PR #${TARGET_PR}. Triage already validated this conflict as tractable — proceed directly to the Mode 3 workflow defined in your system prompt now."
else
  LOG="${LOOP_LOG_DIR}/dev-agent-${TS}.log"   # human-readable live log (this is what you tail)
  RAW="${LOOP_LOG_DIR}/dev-agent-${TS}.jsonl" # raw stream-json (full fidelity, for debugging)
  KICKOFF="Run the developer agent workflow defined in your system prompt. Begin the single-pass scan now."
fi

# Snapshot worktrees BEFORE the run so we can detect what the agent created.
# shellcheck disable=SC2034 # reserved for diff-against-post snapshot in cleanup; not yet wired
PRE_WORKTREES=$(git -C "$REPO" worktree list --porcelain | awk '/^worktree/ {print $2}' | grep "^${WORKTREE_BASE}/" || true)

# Pipeline state — the cleanup trap forwards SIGTERM/SIGINT to PIPELINE_PGID
# so an external `kill <wrapper-pid>` actually tears down claude/tee/jq.
# Without forwarding, those children survive and re-parent to PID 1.
PIPELINE_PID=""
PIPELINE_PGID=""

# shellcheck disable=SC2329 # invoked via `trap cleanup EXIT INT TERM` below
cleanup() {
  local exit_code=$?
  # GH#147: under --interactive, leave worktrees, locks, and branches
  # untouched — the operator likely wants to inspect or retry. `exec`
  # below replaces the wrapper process so this trap rarely fires under
  # --interactive in practice; this guard is belt-and-suspenders for the
  # case where exec itself fails (claude binary not found, etc).
  if [ "${INTERACTIVE:-0}" = 1 ]; then
    exit "$exit_code"
  fi
  echo "[wrapper] agent exited with code $exit_code; cleaning up..." >&2

  # If the pipeline is still running (we got here via SIGTERM/SIGINT, not
  # natural completion of `wait`), forward the signal to its process group.
  pipeline_kill_pgroup_if_alive "${PIPELINE_PGID:-}"

  # Always cd out of any worktree before removing it.
  cd "$REPO" || cd /

  # Find worktrees the agent created (under ${WORKTREE_BASE}/) that didn't exist before.
  local POST_WORKTREES
  POST_WORKTREES=$(git -C "$REPO" worktree list --porcelain | awk '/^worktree/ {print $2}' | grep "^${WORKTREE_BASE}/" || true)

  for wt in $POST_WORKTREES; do
    # If wrapper was started with KEEP_ON_FAIL=1 (default) AND the agent failed (non-zero exit),
    # leave the worktree alone so you can debug.
    if [ "$exit_code" -ne 0 ] && [ "$KEEP_ON_FAIL" = "1" ]; then
      echo "[wrapper] keeping $wt (agent failed, KEEP_ON_FAIL=1)" >&2
      continue
    fi
    echo "[wrapper] removing $wt" >&2
    git -C "$REPO" worktree remove --force "$wt" 2>/dev/null || true
    rm -rf "$wt" 2>/dev/null || true
  done

  git -C "$REPO" worktree prune 2>/dev/null || true

  # Release any per-issue locks owned by THIS wrapper run (DEV_AGENT_RUN_ID match).
  # Locks are filesystem dirs at $LOCK_DIR/${LOCK_NAME_PREFIX}gh-<num>.lock;
  # the wrapper writes this run's id into <lock>/run_id when it acquires
  # the lock. Glob is repo-prefixed (GH#74) so a shared LOCK_DIR doesn't
  # cause us to accidentally inspect another repo's lock dirs.
  if [ -d "$LOCK_DIR" ]; then
    for lock in "$LOCK_DIR"/"${LOCK_NAME_PREFIX}"gh-*.lock; do
      [ -d "$lock" ] || continue
      if [ "$(cat "$lock/run_id" 2>/dev/null)" = "$DEV_AGENT_RUN_ID" ]; then
        echo "[wrapper] releasing lock $lock" >&2
        rm -rf "$lock"
      fi
    done
  fi

  # Delete local dev-agent/* branches that no longer have a worktree AND have a remote ref
  # (so the PR is preserved on origin). Branches without a remote ref are kept — they
  # represent uncommitted/unpushed work the agent didn't finish.
  for br in $(git -C "$REPO" branch --list "${BRANCH_PREFIX}/*" --format '%(refname:short)'); do
    # Skip branches that still have a worktree
    if git -C "$REPO" worktree list --porcelain | grep -q "branch refs/heads/${br}$"; then continue; fi
    # Only delete if there's a remote ref (PR exists on origin)
    if git -C "$REPO" rev-parse --verify "origin/$br" >/dev/null 2>&1; then
      echo "[wrapper] deleting local branch $br (remote ref preserved)" >&2
      git -C "$REPO" branch -D "$br" 2>/dev/null || true
    fi
  done

  echo "[wrapper] live log: $LOG" >&2
  echo "[wrapper] raw json: $RAW" >&2
  exit "$exit_code"
}
# Install the trap BEFORE the lock-acquisition mkdir below, so a SIGINT/SIGTERM
# arriving in the gap between mkdir and the (former) trap-registration line
# still releases our lock. Pre-fix the gap was ~135 lines of wrapper setup
# (config sourcing, Mode-3 triage, jq_filter source, cd) during which any
# signal leaked the lock until STALE_LOCK_HOURS — see GH#36 review P1.
trap cleanup EXIT INT TERM

# Mode 1 only — preflight: list eligible candidates, mkdir-acquire one's lock
# BEFORE spawning the LLM. This closes the TOCTOU window (GH#31) where the
# wrapper saw "1 candidate" and spawned claude, but a sibling wrapper claimed
# the same candidate ~2-5s later in its own LLM startup → losers burned
# ~$0.20-$0.50 per race. Now the lock is the wrapper's first side effect; the
# LLM only runs when we've already won the claim.
#
# Modes 2/3 already arrive with a specific PR number and don't scan.
# Exit code 2 distinguishes "skipped, no work" from "ran successfully" (0)
# so run-loop.sh can apply exponential backoff to consecutive empty cycles.
# Skipped under --interactive (GH#147): no lock acquired; the operator's
# explicit issue# becomes DEV_AGENT_TARGET_ISSUE directly.
if [ "$MODE" = "default" ] && [ "$INTERACTIVE" = 1 ]; then
  export DEV_AGENT_TARGET_ISSUE="$INTERACTIVE_ISSUE"
  export WORKTREE="${WORKTREE_BASE}/gh-${DEV_AGENT_TARGET_ISSUE}"
  echo "[wrapper] interactive: Mode 1 on issue #${DEV_AGENT_TARGET_ISSUE} (lock skipped)"
elif [ "$MODE" = "default" ]; then
  CANDIDATES=$("$LOOP_HOME/runners/lib/eligibility.sh" dev-candidates)
  EL_RC=$?
  case "$EL_RC" in
    0)
      # GH#129: emit the eligibility/proceeding event before the lock loop
      # so structured-event consumers (and the test_event_log_integration
      # contract) keep seeing eligibility before lock_acquired. Pre-GH#129
      # this fired from the now-deleted dev-count preflight block.
      _proceeding_count=$(printf '%s\n' "$CANDIDATES" | grep -c .)
      echo "[wrapper] eligibility: $_proceeding_count candidate issue(s); proceeding"
      event_emit dev eligibility result=proceeding count="$_proceeding_count" mode="$MODE"
      unset _proceeding_count
      # Iterate candidates in id-ascending order (per dev-candidates contract,
      # GH#113). The first mkdir that succeeds is our lock; mkdir is the
      # atomic primitive — exactly one caller wins under contention.
      mkdir -p "$LOCK_DIR"
      DEV_AGENT_TARGET_ISSUE=""
      for _cand in $CANDIDATES; do
        # Lock filename carries LOCK_NAME_PREFIX (GH#74) so two repos
        # pointed at a shared LOCK_DIR don't false-positive on the same
        # issue number. Default behaviour with per-repo WORKTREE_BASE is
        # unchanged (the prefix just adds belt-and-suspenders).
        if mkdir "$LOCK_DIR/${LOCK_NAME_PREFIX}gh-${_cand}.lock" 2>/dev/null; then
          # Stamp $$ for cleanup_stale_dev_locks (GH#139). The symmetric
          # PID-liveness GC in run-loop.sh's loop_dev_mode1 needs this to
          # tell a live wrapper from a SIGKILL-leaked lock; written first
          # so the GC's race window between mkdir and pid-write is the
          # narrowest possible single shell statement.
          echo "$$" >"$LOCK_DIR/${LOCK_NAME_PREFIX}gh-${_cand}.lock/pid"
          echo "$DEV_AGENT_RUN_ID" >"$LOCK_DIR/${LOCK_NAME_PREFIX}gh-${_cand}.lock/run_id"
          date -Iseconds >"$LOCK_DIR/${LOCK_NAME_PREFIX}gh-${_cand}.lock/started"
          DEV_AGENT_TARGET_ISSUE="$_cand"
          break
        fi
      done
      unset _cand
      if [ -z "$DEV_AGENT_TARGET_ISSUE" ]; then
        # The predicate found candidates but every one was claimed between
        # the listing and our mkdir attempts. Skip the LLM — no work left.
        echo "[wrapper] eligibility: every candidate already locked by sibling runs; skipping LLM"
        echo "[wrapper] result=lock-race-loss-pre-LLM mode=$MODE"
        event_emit dev lock_race_lost run_id="$DEV_AGENT_RUN_ID"
        exit 2
      fi
      export DEV_AGENT_TARGET_ISSUE
      # GH#82: export the per-issue worktree path so the developer-agent
      # template can use $WORKTREE/<relpath> everywhere instead of re-typing
      # the literal /tmp/dev-agent/.../gh-N/... 60+ times per Mode 1 cycle.
      # WORKTREE_BASE comes from .loop/loop.config (sourced near line 62).
      # Only Mode 1 sets DEV_AGENT_TARGET_ISSUE; Modes 2/3 derive ISSUE_NUM
      # from the PR body, so they set $WORKTREE themselves in F3/R1.
      export WORKTREE="${WORKTREE_BASE}/gh-${DEV_AGENT_TARGET_ISSUE}"
      echo "[wrapper] eligibility: locked GH#${DEV_AGENT_TARGET_ISSUE} (run=$DEV_AGENT_RUN_ID); proceeding"
      event_emit dev lock_acquired issue="$DEV_AGENT_TARGET_ISSUE" run_id="$DEV_AGENT_RUN_ID"
      ;;
    1)
      echo "[wrapper] eligibility: no eligible issues; skipping LLM invocation"
      echo "[wrapper] result=no-work mode=$MODE"
      event_emit dev eligibility result=no-work mode="$MODE"
      exit 2
      ;;
    *)
      # Transient predicate failure (gh down, jq error). Don't burn a cycle
      # by spawning the LLM — without a pre-locked issue the LLM would
      # rediscover and re-race anyway. Treat as no-work.
      echo "[wrapper] eligibility: predicate failed (rc=$EL_RC); skipping LLM" >&2
      echo "[wrapper] result=predicate-failed mode=$MODE"
      event_emit dev eligibility result=predicate-failed mode="$MODE" rc="$EL_RC"
      exit 2
      ;;
  esac
  unset CANDIDATES EL_RC
fi

# Mode 3 only: run the triage gate BEFORE invoking the LLM. The triage script's
# exit codes are trichotomous (see runners/run-conflict-triage.sh:17):
#   0 = tractable           → invoke LLM
#   1 = untractable          → draft PR + post auto-resolution-declined comment
#   2 = misuse / setup error → exit 2 only; do NOT draft, dispatch:conflicts
#                              will re-test next cycle once the transient
#                              gh/git outage clears.
# Pre-fix (GH#57): bash `if`-zero/nonzero conflated rc=1 and rc=2, so a
# transient `gh pr view` outage permanently drafted the PR with a misleading
# "auto-resolution declined" comment. Same architectural shape as the rc=2
# leak GH#27 fixed for eligibility predicates — transient infra failures must
# not commit to permanent PR-state mutations.
if [ "$MODE" = "resolve-conflicts" ] && [ "$INTERACTIVE" = 1 ]; then
  echo "[wrapper] interactive: Mode 3 on PR #${TARGET_PR} (triage skipped)"
elif [ "$MODE" = "resolve-conflicts" ]; then
  echo "[wrapper] running triage for PR #$TARGET_PR..."
  TRIAGE_OUTPUT=$("$LOOP_HOME/runners/run-conflict-triage.sh" "$TARGET_PR" 2>&1)
  TRIAGE_RC=$?
  case "$TRIAGE_RC" in
    0)
      echo "$TRIAGE_OUTPUT"
      # rc=0 splits into two sub-paths. `tractable no-conflict` (rebase
      # succeeded — nothing to resolve) is a healthy PR; falling through
      # to the Mode 3 LLM here is the GH#75 bug — every cycle the
      # dispatcher hands us a CI-green dev-agent PR awaiting review,
      # we'd burn ~$0.50–$2.00 of LLM tokens for nothing. Short-circuit
      # to a successful no-op (parallel to the eligibility `result=no-work`
      # cases). Do NOT draft the PR — it's healthy.
      if grep -q 'reason=no-conflict' <<<"$TRIAGE_OUTPUT"; then
        echo "[wrapper] triage reports no conflict — skipping LLM (PR already mergeable)."
        echo "[wrapper] result=triage-no-conflict pr=#${TARGET_PR}"
        event_emit dev triage_result pr="$TARGET_PR" result=tractable reason=no-conflict
        exit 0
      fi
      echo "[wrapper] triage tractable — invoking dev-agent Mode 3."
      event_emit dev triage_result pr="$TARGET_PR" result=tractable reason=mechanical-conflict
      ;;
    1)
      echo "$TRIAGE_OUTPUT" >&2
      # GH#100: read the LATEST reason= token. The triage script currently
      # emits one reason= line, but treating its output as append-only keeps
      # this site robust if the script grows progress logs that reuse the
      # same marker shape.
      REASON=$(printf '%s\n' "$TRIAGE_OUTPUT" \
        | grep -oE 'reason=[^ ]+' \
        | loop_marker_last 'reason=[^ ]+' \
        | cut -d= -f2-)
      echo "[wrapper] triage says untractable (reason=${REASON}); escalating without invoking LLM." >&2
      event_emit dev triage_result pr="$TARGET_PR" result=untractable reason="$REASON"
      PAGER=cat GIT_PAGER=cat gh pr comment "$TARGET_PR" --repo "$REPO_SLUG" --body "$(
        cat <<EOF
🤖 Conflict triage — auto-resolution declined.

**Reason:** \`${REASON}\`

The triage rules deemed these merge conflicts not safe for autonomous resolution. Please resolve manually.

For the rules: \`st triage <PR>\`. Strict-mode policy: test files / CI / secrets / core code files (eval.py, Dockerfile, .pre-commit-config.yaml) never auto-resolve, and total conflict lines must be ≤ ${TRIAGE_LINE_LIMIT}.
EOF
      )" >/dev/null 2>&1 || true
      gh_best_effort gh pr ready --undo "$TARGET_PR" --repo "$REPO_SLUG"
      echo "[wrapper] result=triage-untractable pr=#${TARGET_PR} reason=${REASON}"
      exit 1
      ;;
    *)
      # rc=2 (or any unexpected non-{0,1}) — transient setup failure: gh outage,
      # git fetch failed, worktree creation failed. Don't draft, don't comment;
      # dispatch:conflicts will re-test next cycle. Mirror the eligibility
      # predicate rc=2 policy from GH#27.
      echo "$TRIAGE_OUTPUT" >&2
      echo "[wrapper] triage failed (rc=$TRIAGE_RC); transient setup error, skipping LLM and not drafting. Will retry next dispatcher cycle." >&2
      echo "[wrapper] result=triage-failed pr=#${TARGET_PR} rc=${TRIAGE_RC}"
      event_emit dev triage_result pr="$TARGET_PR" result=failed rc="$TRIAGE_RC"
      exit 2
      ;;
  esac
fi

# jq filter: turn each stream-json event into one human-readable line.
# Sourced from the shared lib so both run-developer.sh and run-reviewer.sh
# emit identical event tags and ANSI colors. Honors NO_COLOR.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/jq_filter.sh"

# Signal-forwarding helpers (pipeline_capture_pgid, pipeline_kill_pgroup_if_alive).
# See the lib file for the full rationale; in short: the bash `wait` builtin is
# signal-interruptible, but only when the pipeline is asynchronous. Foreground
# pipelines defer the trap. So we background the pipeline below and forward
# signals here.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/pipeline_signal.sh"

cd "$REPO" || exit 1

echo "[wrapper] mode: $MODE${TARGET_PR:+ (PR #$TARGET_PR)} run_id=$DEV_AGENT_RUN_ID"
echo "[wrapper] live log: $LOG"
echo "[wrapper] raw json: $RAW"
echo "[wrapper] tail with: tail -f $LOG"
echo

# Background the pipeline in a subshell with `set -m` so:
#   1. `wait` (used below) is signal-interruptible — bash defers traps for
#      foreground pipelines, but fires them immediately for async ones.
#   2. The subshell becomes its own process-group leader, so the cleanup
#      trap can kill claude+tee+jq with one `kill -- -<pgid>` syscall.
# Without (1), `kill <wrapper-pid>` hangs the wrapper. Without (2), the
# children survive the trap and re-parent to PID 1.
#
# GH#80: export GH_REPO so the agent's `gh` calls don't need `--repo …`.
# Inherited by claude and every Bash subprocess the agent spawns. Cuts
# ~70 chars of pure-boilerplate prefix from every gh tool call.
export GH_REPO="$REPO_SLUG"
# GH#92: emit llm_started and capture wall-clock so the matching llm_exited
# event records duration_s. The `pr`/`issue` field disambiguates which work
# unit the LLM ran on; only one is populated per mode.
_llm_target_kv=()
if [ -n "$TARGET_PR" ]; then
  _llm_target_kv=(pr="$TARGET_PR")
elif [ -n "${DEV_AGENT_TARGET_ISSUE:-}" ]; then
  _llm_target_kv=(issue="$DEV_AGENT_TARGET_ISSUE")
fi

# GH#147: --interactive replaces the headless `claude -p ... | tee | jq |
# tee` pipeline with an `exec claude ...` so the wrapper hands its TTY
# to claude. `exec` naturally bypasses the post-LLM blocks below
# (process replacement) and the cleanup trap (bash skips EXIT trap on
# successful exec). No log/raw JSONL files are written. The operator
# handles failures themselves — none of the wrapper-side dispatcher
# guard rails apply.
if [ "$INTERACTIVE" = 1 ]; then
  echo "[wrapper] interactive: handing off to claude (mode=$MODE${TARGET_PR:+ pr=#$TARGET_PR}${DEV_AGENT_TARGET_ISSUE:+ issue=#$DEV_AGENT_TARGET_ISSUE})"
  exec env PAGER=cat GIT_PAGER=cat \
    claude "$KICKOFF" \
    --append-system-prompt "$("$LOOP_HOME/runners/lib/render-prompt.sh" "$LOOP_HOME/templates/developer.md")" \
    --permission-mode bypassPermissions
fi

event_emit dev llm_started mode="$MODE" run_id="$DEV_AGENT_RUN_ID" "${_llm_target_kv[@]}"
_llm_start_s=$(date +%s)
set -m
(
  PAGER=cat GIT_PAGER=cat \
    claude -p "$KICKOFF" \
    --append-system-prompt "$("$LOOP_HOME/runners/lib/render-prompt.sh" "$LOOP_HOME/templates/developer.md")" \
    --permission-mode bypassPermissions \
    --max-turns "$DEV_MAX_TURNS" \
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
event_emit dev llm_exited mode="$MODE" exit_code="$LLM_EXIT" duration_s="$(($(date +%s) - _llm_start_s))" "${_llm_target_kv[@]}"

# GH#56 — Mode 1 hard-failure retry counter (wrapper-side).
#
# A deterministic-fail issue (max-turns reproducibly hit before reaching the
# in-prompt safety-net check, bash error inside a tool call, missing test
# dep that crashes pytest reproducibly) used to get re-claimed every poll
# cycle and burn ~$1-3 per spawn until a human intervened. The blocked:human
# label GH#28 added only fires from inside the LLM — failures that crash
# before the safety-net check leave the issue unlabeled and re-eligible.
#
# Mirror the Mode 2/Mode 3 wrapper-side fallback shape: track consecutive
# hard failures via dev-failed:N labels on the GH issue, and after
# DEV_HARD_FAILURE_RETRY_LIMIT (default 3) escalate by adding blocked:human
# + posting a comment naming the wrapper log path. A successful Mode 1
# cycle clears any dev-failed:N labels so a transient failure followed by
# two successes doesn't leave a stale counter.
#
# Mode-scoped to "default" (Mode 1): Modes 2/3 already have their own
# PR-scoped hard-failure handling (GH#48/#49); this is issue-scoped and
# would be confused with the PR fallbacks if it leaked. Gated on
# DEV_AGENT_TARGET_ISSUE because the eligibility short-circuit paths exit
# before this block — we only get here when the wrapper actually owns an
# issue lock and spawned the LLM.
if [ "$MODE" = "default" ] && [ -n "${DEV_AGENT_TARGET_ISSUE:-}" ]; then
  _retry_blocked_label="${BLOCKED_HUMAN_LABEL:-blocked:human}"
  _retry_limit="${DEV_HARD_FAILURE_RETRY_LIMIT:-3}"
  if [ "$LLM_EXIT" -ne 0 ]; then
    # Read existing labels and find the highest dev-failed:N (0 if none).
    # The default-on-failure (echo 0 / [] fallback) keeps a flaky gh from
    # blocking the wrapper exit — worst case we miss a counter increment
    # this cycle and the label converges next cycle.
    _retry_labels_json=$(
      PAGER=cat GIT_PAGER=cat gh issue view "$DEV_AGENT_TARGET_ISSUE" \
        --repo "$REPO_SLUG" --json labels 2>/dev/null \
        || echo '{"labels":[]}'
    )
    _retry_current=$(
      echo "$_retry_labels_json" \
        | jq -r '[.labels[].name | select(startswith("dev-failed:")) | sub("dev-failed:";"") | tonumber] | max // 0' \
          2>/dev/null \
        || echo 0
    )
    _retry_next=$((_retry_current + 1))
    if [ "$_retry_current" -gt 0 ]; then
      PAGER=cat GIT_PAGER=cat gh issue edit "$DEV_AGENT_TARGET_ISSUE" \
        --repo "$REPO_SLUG" --remove-label "dev-failed:${_retry_current}" \
        >/dev/null 2>&1 || true
    fi
    PAGER=cat GIT_PAGER=cat gh issue edit "$DEV_AGENT_TARGET_ISSUE" \
      --repo "$REPO_SLUG" --add-label "dev-failed:${_retry_next}" \
      >/dev/null 2>&1 || true
    if [ "$_retry_next" -ge "$_retry_limit" ]; then
      _retry_body="🤖 Dev-agent hard-failed ${_retry_next} consecutive times (last exit=${LLM_EXIT}). Labeling \`${_retry_blocked_label}\` so the eligibility predicate skips this issue. Investigate the wrapper logs at \`${LOG}\`."
      hard_failure_idempotent_escalate issue "$DEV_AGENT_TARGET_ISSUE" \
        "$_retry_blocked_label" "$_retry_body"
      unset _retry_body
    fi
    event_emit dev hard_failure mode="$MODE" issue="$DEV_AGENT_TARGET_ISSUE" exit_code="$LLM_EXIT" retry_count="$_retry_next"
    unset _retry_labels_json _retry_current _retry_next
  else
    # Success path — clear any dev-failed:N labels so a transient failure
    # followed by two successes doesn't leave the issue with a stale
    # dev-failed:1. Single comma-joined --remove-label call covers any
    # number of stale labels in one gh roundtrip.
    _retry_labels_json=$(
      PAGER=cat GIT_PAGER=cat gh issue view "$DEV_AGENT_TARGET_ISSUE" \
        --repo "$REPO_SLUG" --json labels 2>/dev/null \
        || echo '{"labels":[]}'
    )
    _retry_existing=$(
      echo "$_retry_labels_json" \
        | jq -r '[.labels[].name | select(startswith("dev-failed:"))] | join(",")' \
          2>/dev/null \
        || echo ""
    )
    if [ -n "$_retry_existing" ]; then
      PAGER=cat GIT_PAGER=cat gh issue edit "$DEV_AGENT_TARGET_ISSUE" \
        --repo "$REPO_SLUG" --remove-label "$_retry_existing" \
        >/dev/null 2>&1 || true
    fi
    unset _retry_labels_json _retry_existing
  fi
  unset _retry_blocked_label _retry_limit
fi

# GH#111 — per-PR cap wrapper for Mode 2 / Mode 3 hard-failures.
#
# Counts existing PR comments matching $marker_substring; under cap posts the
# stub body via gh_best_effort, at-cap delegates the apply (label create +
# add-label + comment) and the has-label idempotency short-circuit to
# hard_failure_idempotent_escalate (GH#108 / PR #119). Mirrors the GH#94
# reviewer pattern. The count-and-decide stays local to this wrapper —
# Mode 1 (issue-scoped) keeps its own dev-failed:N escalation path because
# it has no PR target to count comments against.
#
# Args:
#   $1 = PR number
#   $2 = marker substring to count (e.g. '🤖 Mode 3 conflict resolution — aborted')
#   $3 = retry cap (e.g. $DEV_FOLLOWUP_FAILURE_RETRY_LIMIT)
#   $4 = stub body (posted when count < cap)
#   $5 = escalation body (posted at-cap, alongside the label)
_dev_hardfail_post() {
  local pr="$1" marker="$2" cap="$3" stub_body="$4" escalation_body="$5"
  local pr_data count
  pr_data=$(
    PAGER=cat GIT_PAGER=cat gh pr view "$pr" \
      --repo "$REPO_SLUG" --json comments 2>/dev/null
  ) || pr_data=""
  count=0
  if [ -n "$pr_data" ]; then
    count=$(
      printf '%s' "$pr_data" \
        | jq --arg m "$marker" \
          '[.comments // [] | .[] | select((.body // "") | contains($m))] | length' \
          2>/dev/null
    ) || count=0
  fi
  count="${count:-0}"
  if [ "$count" -ge "$cap" ]; then
    echo "[wrapper] PR #$pr has $count hard-failure markers (cap=$cap); escalating to human via $BLOCKED_HUMAN_LABEL" >&2
    # Delegate the apply-side (label create + add-label + comment) and the
    # has-label idempotency short-circuit to the shared helper from
    # GH#108 / PR #119. Keeps the count-and-decide logic local while
    # reusing the escalation primitive — same migration shape as PR #125
    # (Mode 1) and PR #130 (reviewer wrapper).
    hard_failure_idempotent_escalate pr "$pr" \
      "$BLOCKED_HUMAN_LABEL" "$escalation_body"
  else
    gh_best_effort gh pr comment "$pr" \
      --repo "$REPO_SLUG" \
      --body "$stub_body"
  fi
}

# GH#48 — Mode 3 hard-failure fallback. The prompt's three graceful Mode 3
# abort blocks (templates/developer.md: ambiguous-intent, post-resolution
# test failure, post-force-push CI failure) each draft the PR themselves so
# _dispatch_conflicts_jq's `isDraft == false` filter excludes it next cycle
# (GH#44, fixed in PR #45). Hard failures — `--max-turns DEV_MAX_TURNS`
# exceeded mid-resolution, claude API outage, OOM during pytest, bash crash
# inside a tool call — never reach those abort blocks; the LLM exits
# non-zero with the PR still mergeable=CONFLICTING + isDraft=false. Without
# this fallback, dispatch:conflicts re-fires Mode 3 every cycle on the same
# stuck PR (~$0.50-$2.00 per run), and the empty-cycle backoff in
# run-loop.sh stays disarmed because each dispatch counts as `dispatched=1`
# even when the LLM crashed. Mirror the abort-block fix at the wrapper
# level so ungraceful aborts also draft. Precedent: the triage-untractable
# wrapper-side draft above.
#
# GH#111 — wraps the comment in a per-PR cap. After
# DEV_CONFLICTS_FAILURE_RETRY_LIMIT consecutive abort markers (matched by
# substring against both the LLM's graceful-abort comments and this wrapper-
# side stub), escalate to a human via BLOCKED_HUMAN_LABEL + one explanation
# comment instead of yet another stub. The drafting (`gh pr ready --undo`)
# still fires unconditionally — it's a per-trigger circuit breaker so the
# next cycle's `isDraft == false` filter excludes the PR; the cap closes
# the per-PR loop on top of that.
if [ "$MODE" = "resolve-conflicts" ] && [ "$LLM_EXIT" -ne 0 ]; then
  : "${DEV_CONFLICTS_FAILURE_RETRY_LIMIT:=3}"
  : "${BLOCKED_HUMAN_LABEL:=blocked:human}"
  # Pre-build the comment body in a variable rather than `--body "$(cat <<EOF...)"`
  # because bash's $(...) parser tokenizes the heredoc body up-front and trips
  # on unbalanced apostrophes ("won't"). Using a plain heredoc-into-var is the
  # well-known workaround. The stub body MUST start with the same '🤖 Mode 3
  # conflict resolution — aborted' marker prefix the prompt's graceful aborts
  # use, so log-scrapers / dashboards keyed on that prefix pick this up too —
  # AND the per-PR cap counter (_dev_hardfail_post above) uses that same
  # substring as its count-marker.
  HARD_FAIL_BODY=$(
    cat <<EOF
🤖 Mode 3 conflict resolution — aborted (agent run failed mid-flow, exit=${LLM_EXIT}).

The dev-agent did not reach a graceful abort block (likely max-turns exceeded, claude API failure, or OOM kill). Drafting this PR so the conflicts dispatcher will not re-fire the LLM on the next cycle. Please resolve manually or re-attempt after investigation.
EOF
  )
  # Escalation body deliberately AVOIDS the count-marker substring "🤖 Mode 3
  # conflict resolution — aborted" so subsequent cycles don't count it as
  # another abort and re-trigger the at-cap branch. The has-label idempotency
  # guard makes that safe even if the substring did appear, but belt-and-
  # suspenders.
  ESCALATION_BODY="🤖 Mode 3 conflict resolution has hard-failed ${DEV_CONFLICTS_FAILURE_RETRY_LIMIT} or more consecutive times on this PR. Likely a deterministic failure (intractable conflicts, racing pushes, post-resolution test/CI breakage). Human attention required; the conflicts dispatcher will not re-fire on this PR until the \`${BLOCKED_HUMAN_LABEL}\` label is removed."
  _dev_hardfail_post "$TARGET_PR" \
    '🤖 Mode 3 conflict resolution — aborted' \
    "$DEV_CONFLICTS_FAILURE_RETRY_LIMIT" \
    "$HARD_FAIL_BODY" \
    "$ESCALATION_BODY"
  # Drafting still fires unconditionally — per-trigger circuit breaker for
  # the next cycle's `isDraft == false` filter. Routed through gh_best_effort
  # (GH#99) so a transient gh failure leaves a stderr breadcrumb.
  gh_best_effort gh pr ready --undo "$TARGET_PR" --repo "$REPO_SLUG"
  event_emit dev hard_failure mode="$MODE" pr="$TARGET_PR" exit_code="$LLM_EXIT"
  unset HARD_FAIL_BODY ESCALATION_BODY
fi

# GH#49: hard-failure marker for Mode 2 (follow-up). When `claude` exits
# non-zero (--max-turns hit, API outage, OOM, …) the LLM never reaches its
# graceful exit comment ("🤖 Developer agent — follow-up complete|gave-up|
# no-action"), so eligibility_followup_pr's verdict-aware gate sees the
# review as still newer than the latest dev-comment and re-fires the LLM
# every poll cycle on the same stuck PR (~$12-60/hr).
#
# Fix: post a stub failure marker from the wrapper. The body MUST start with
# the DEV_AGENT_COMMENT_PREFIX ("🤖 Developer agent") so the predicate's
# existing `startswith($prefix)` filter recognizes it as a dev-comment and
# advances $latest_devcomment.createdAt past the review's submittedAt.
#
# Mode-1 hard failures don't need this — there's no PR yet, so there's
# nothing for the dispatcher to re-fire on. Mode 3 hard failures are
# already handled by the resolve-conflicts block above (GH#48) plus the
# LLM's `gh pr ready --undo` paths (GH#44), which the conflicts dispatcher's
# `isDraft == false` filter then excludes.
#
# GH#111 — wraps the stub in a per-PR cap. After
# DEV_FOLLOWUP_FAILURE_RETRY_LIMIT consecutive failure-marker stubs (matched
# by 'follow-up failed mid-flow' substring — mode-specific so it doesn't
# conflate with Mode 3's '🤖 Mode 3 conflict resolution — aborted (agent run
# failed mid-flow, …)' wrapper marker), escalate to a human via
# BLOCKED_HUMAN_LABEL + one explanation comment instead of yet another stub.
# eligibility_followup_pr drops PRs carrying that label so the loop stops.
if [ "$MODE" = "follow-up" ] && [ "$LLM_EXIT" -ne 0 ]; then
  : "${DEV_FOLLOWUP_FAILURE_RETRY_LIMIT:=3}"
  : "${BLOCKED_HUMAN_LABEL:=blocked:human}"
  STUB_BODY="🤖 Developer agent — follow-up failed mid-flow (exit=${LLM_EXIT}). The dev-agent did not reach a graceful exit (likely max-turns exceeded, claude API failure, or OOM). The follow-up dispatcher will not re-fire on the current reviewer-agent review (this comment supersedes its timestamp). Please re-trigger by adding a fresh reviewer-agent review or requesting a new review cycle."
  # Escalation body deliberately AVOIDS the count-marker substring 'follow-up
  # failed mid-flow' so subsequent cycles don't count it as another stub.
  # (Per the has-label idempotency guard inside hard_failure_idempotent_escalate
  # the PR is dropped from dispatch anyway, but belt-and-suspenders.) Also
  # retains the DEV_AGENT_COMMENT_PREFIX so eligibility_followup_pr's
  # existing prefix filter still picks it up before the new label-exclusion
  # kicks in.
  ESCALATION_BODY="🤖 Developer agent — follow-up has hard-failed ${DEV_FOLLOWUP_FAILURE_RETRY_LIMIT} or more consecutive times on this PR. Likely a deterministic failure (oversized diff, broken test environment, cyclic reviewer feedback). Human attention required; the follow-up dispatcher will not re-fire on this PR until the \`${BLOCKED_HUMAN_LABEL}\` label is removed."
  _dev_hardfail_post "$TARGET_PR" \
    'follow-up failed mid-flow' \
    "$DEV_FOLLOWUP_FAILURE_RETRY_LIMIT" \
    "$STUB_BODY" \
    "$ESCALATION_BODY"
  event_emit dev hard_failure mode="$MODE" pr="$TARGET_PR" exit_code="$LLM_EXIT"
  unset STUB_BODY ESCALATION_BODY
fi

exit "$LLM_EXIT"
