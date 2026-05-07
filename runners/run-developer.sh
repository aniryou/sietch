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
  st dev                            # Mode 1: scan issues, claim one
  st dev follow-up <PR#>            # Mode 2: address review on a PR
  st dev resolve <PR#>              # Mode 3: resolve merge conflicts (triage-gated)
EOF
}

# Parse args — pick the mode and the kickoff prompt.
MODE="default"
TARGET_PR=""
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
  resolve-conflicts)
    MODE="resolve-conflicts"
    TARGET_PR="${2:-}"
    if ! [[ "$TARGET_PR" =~ ^[0-9]+$ ]]; then
      echo "[wrapper] resolve-conflicts requires a numeric <PR#>; got: '${TARGET_PR}'" >&2
      usage
      exit 2
    fi
    ;;
  *)
    echo "[wrapper] unknown mode: $1" >&2
    usage
    exit 2
    ;;
esac

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.loop/loop.config"

# Mode 1 only — preflight: skip the LLM if there are no eligible issues.
# Modes 2/3 already arrive with a specific PR number and don't scan.
# Exit code 2 distinguishes "skipped, no work" from "ran successfully" (0)
# so run-loop.sh can apply exponential backoff to consecutive empty cycles.
if [ "$MODE" = "default" ]; then
  EL_COUNT=$("$LOOP_HOME/runners/lib/eligibility.sh" dev)
  EL_RC=$?
  case "$EL_RC" in
    0) echo "[wrapper] eligibility: $EL_COUNT candidate issue(s); proceeding" ;;
    1)
      echo "[wrapper] eligibility: no eligible issues; skipping LLM invocation"
      echo "[wrapper] result=no-work mode=$MODE"
      exit 2
      ;;
    *)
      # GH#27: any non-{0,1} rc means the predicate itself failed (gh outage,
      # jq error, GraphQL schema drift, ...). The previous "proceed to be safe"
      # policy turned every persistent failure into a per-cycle token leak —
      # the LLM was spawned each poll while doing nothing useful. Skip + exit 2
      # so run-loop.sh applies the same exponential backoff it uses for rc=1.
      # Operators see the failure on stderr and can intervene.
      echo "[wrapper] eligibility: predicate failed (rc=$EL_RC); skipping LLM invocation and backing off" >&2
      echo "[wrapper] result=no-work mode=$MODE reason=predicate-failed"
      exit 2
      ;;
  esac
  unset EL_COUNT EL_RC
fi

KEEP_ON_FAIL="${KEEP_ON_FAIL:-1}"
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
  LOG="/tmp/dev-agent-followup-pr${TARGET_PR}-${TS}.log"
  RAW="/tmp/dev-agent-followup-pr${TARGET_PR}-${TS}.jsonl"
  KICKOFF="Run the developer agent in FOLLOW-UP MODE on PR #${TARGET_PR}. Skip the issue scan. Begin the follow-up workflow defined in Mode 2 of your system prompt now."
elif [ "$MODE" = "resolve-conflicts" ]; then
  LOG="/tmp/dev-agent-conflicts-pr${TARGET_PR}-${TS}.log"
  RAW="/tmp/dev-agent-conflicts-pr${TARGET_PR}-${TS}.jsonl"
  KICKOFF="Run the developer agent in MODE 3 (resolve merge conflicts) on PR #${TARGET_PR}. Triage already validated this conflict as tractable — proceed directly to the Mode 3 workflow defined in your system prompt now."
else
  LOG="/tmp/dev-agent-${TS}.log"   # human-readable live log (this is what you tail)
  RAW="/tmp/dev-agent-${TS}.jsonl" # raw stream-json (full fidelity, for debugging)
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

cleanup() {
  local exit_code=$?
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
  # Locks are filesystem dirs at $LOCK_DIR/gh-<num>.lock; the agent
  # writes our run id into <lock>/run_id when it acquires the lock.
  if [ -d "$LOCK_DIR" ]; then
    for lock in "$LOCK_DIR"/gh-*.lock; do
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
if [ "$MODE" = "default" ]; then
  CANDIDATES=$("$LOOP_HOME/runners/lib/eligibility.sh" dev-candidates)
  EL_RC=$?
  case "$EL_RC" in
    0)
      # Iterate candidates in priority order (high-first per dev-candidates
      # contract). The first mkdir that succeeds is our lock; mkdir is the
      # atomic primitive — exactly one caller wins under contention.
      mkdir -p "$LOCK_DIR"
      DEV_AGENT_TARGET_ISSUE=""
      for _cand in $CANDIDATES; do
        if mkdir "$LOCK_DIR/gh-${_cand}.lock" 2>/dev/null; then
          echo "$DEV_AGENT_RUN_ID" >"$LOCK_DIR/gh-${_cand}.lock/run_id"
          date -Iseconds >"$LOCK_DIR/gh-${_cand}.lock/started"
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
        exit 2
      fi
      export DEV_AGENT_TARGET_ISSUE
      echo "[wrapper] eligibility: locked GH#${DEV_AGENT_TARGET_ISSUE} (run=$DEV_AGENT_RUN_ID); proceeding"
      ;;
    1)
      echo "[wrapper] eligibility: no eligible issues; skipping LLM invocation"
      echo "[wrapper] result=no-work mode=$MODE"
      exit 2
      ;;
    *)
      # Transient predicate failure (gh down, jq error). Don't burn a cycle
      # by spawning the LLM — without a pre-locked issue the LLM would
      # rediscover and re-race anyway. Treat as no-work.
      echo "[wrapper] eligibility: predicate failed (rc=$EL_RC); skipping LLM" >&2
      echo "[wrapper] result=predicate-failed mode=$MODE"
      exit 2
      ;;
  esac
  unset CANDIDATES EL_RC
fi

# Mode 3 only: run the triage gate BEFORE invoking the LLM. If triage says
# untractable, the wrapper itself escalates via gh and exits — no LLM call.
if [ "$MODE" = "resolve-conflicts" ]; then
  echo "[wrapper] running triage for PR #$TARGET_PR..."
  if TRIAGE_OUTPUT=$("$LOOP_HOME/runners/run-conflict-triage.sh" "$TARGET_PR" 2>&1); then
    echo "$TRIAGE_OUTPUT"
    echo "[wrapper] triage tractable — invoking dev-agent Mode 3."
  else
    echo "$TRIAGE_OUTPUT" >&2
    REASON=$(echo "$TRIAGE_OUTPUT" | grep -oE 'reason=[^ ]+' | head -1 | cut -d= -f2-)
    echo "[wrapper] triage says untractable (reason=${REASON}); escalating without invoking LLM." >&2
    PAGER=cat GIT_PAGER=cat gh pr comment "$TARGET_PR" --repo "$REPO_SLUG" --body "$(
      cat <<EOF
🤖 Conflict triage — auto-resolution declined.

**Reason:** \`${REASON}\`

The triage rules deemed these merge conflicts not safe for autonomous resolution. Please resolve manually.

For the rules: \`st triage <PR>\`. Strict-mode policy: test files / CI / secrets / core code files (eval.py, Dockerfile, .pre-commit-config.yaml) never auto-resolve, and total conflict lines must be ≤ 10.
EOF
    )" >/dev/null 2>&1 || true
    PAGER=cat GIT_PAGER=cat gh pr ready --undo "$TARGET_PR" --repo "$REPO_SLUG" >/dev/null 2>&1 || true
    echo "[wrapper] result=triage-untractable pr=#${TARGET_PR} reason=${REASON}"
    exit 1
  fi
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
