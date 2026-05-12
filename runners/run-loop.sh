#!/usr/bin/env bash
# Top-level driver that runs all the headless agents continuously, each in its
# own tmux pane.
#
# Layout:
#   ┌─────────────────────┬─────────────────────┬──────────────────────┐
#   │ dispatch:review     │ dispatch:followup   │ dispatch:conflicts   │
#   ├─────────────────────┼──────────┬──────────┴──────────────────────┤
#   │ dev-1               │ dev-2    │ dev-3 (number = --dev-instances)│
#   └─────────────────────┴──────────┴─────────────────────────────────┘
#
# Issue-author is NOT in the loop — it's interactive. Run it manually in a
# separate terminal: st issue
#
# Lock topology — see runners/lib/lock-topology.md for the per-mode map of
# every mkdir-style lock the fleet uses (Mode 1 wrapper-acquired,
# Mode 2/3 dispatcher-acquired, reviewer single-pane), the lock dirs
# ($LOCK_DIR vs $DISPATCH_LOCK_DIR), and the GC story (trap, PID-liveness,
# stale-lock cleanup). Update that doc in lockstep when adding a new
# dispatcher or lock-name format.
#
# Usage:
#   st loop                              # equivalent to 'start' with defaults
#   st loop start                        # create the tmux session and attach
#   st loop start --detach               # create but don't attach
#   st loop start --dev-instances=2      # 2 dev workers instead of 3
#   st loop start --poll-interval=120    # slower polling
#   st loop start --max-runtime=900      # auto-stop after 15 min
#   st loop stop                         # kill the tmux session
#   st loop attach                       # re-attach to running session
#   st loop status                       # is it running?
#
# Press Ctrl+B D inside tmux to detach (loops keep running).
# Use 'stop' from any terminal to terminate cleanly.

set -u
\unalias -a 2>/dev/null || true

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.loop/loop.config"
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/dispatcher.sh"
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/jitter.sh"
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/eligibility.sh"
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/repo_id.sh"
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/event_log.sh"

# Default for older loop.config files predating GH#74. Sanitize via the
# same helper as the SESSION derivation so the prefix stays filesystem-safe
# even if the user's repo name carries a `.`.
: "${LOCK_NAME_PREFIX:=$(loop_sanitize_id "${REPO_NAME:-}")-}"

# Per-repo tmux session — two `st loop start` fleets in different repos
# can coexist (GH#74). Old hardcoded `agent-loop` collided on the second
# `tmux new-session` and refused to start.
# Exported so child wrappers (run-developer.sh, run-reviewer.sh) write to
# the same /tmp/loop-events-${SESSION}.jsonl file (GH#92).
SESSION="$(loop_session_name)"
export SESSION

DEV_INSTANCES="$DEV_INSTANCES_DEFAULT"
POLL_INTERVAL="$POLL_INTERVAL_DEFAULT"
MAX_RUNTIME=0
DETACH=0
ENABLE_MERGER=0

# ---- helpers ------------------------------------------------------------

ts() { date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"; }

cleanup_stale_dispatch_locks() {
  # Heal a missing parent dir before doing anything else (GH#86). The
  # session-teardown rmdir at line ~621 can race with a panes-still-alive
  # state, leaving the parent gone while a dispatcher pane keeps cycling;
  # without this, every subsequent `mkdir "$lock"` in the dispatcher loops
  # silently fails (parent doesn't exist) and no per-PR follow-up is ever
  # dispatched. The early-return below stays as a fallback in case the
  # mkdir itself fails (e.g. permissions).
  mkdir -p "$DISPATCH_LOCK_DIR" 2>/dev/null
  [ -d "$DISPATCH_LOCK_DIR" ] || return 0
  # Glob only own-prefix locks (GH#74). When DISPATCH_LOCK_DIR is shared
  # across misconfigured repos, the previous `*.lock` glob would gc
  # another repo's live locks if their PID happened to be dead on this
  # machine.
  for lock in "$DISPATCH_LOCK_DIR"/"${LOCK_NAME_PREFIX}"*.lock; do
    [ -d "$lock" ] || continue
    local pid
    pid=$(cat "$lock/pid" 2>/dev/null || echo "")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock"
    fi
  done
}

cleanup_stale_dev_locks() {
  # Symmetric counterpart to cleanup_stale_dispatch_locks for $LOCK_DIR
  # (GH#139). The wrapper's EXIT/INT/TERM trap (run-developer.sh:198-210)
  # is the primary release path on healthy exits, but a SIGKILL — or any
  # crash that bypasses the trap — leaks a ${LOCK_NAME_PREFIX}gh-N.lock
  # indefinitely. eligibility_dev_count and eligibility_dev_candidates
  # (eligibility.sh:148,256) treat the leaked lock as a live claim, so
  # without this GC the issue is permanently unclaimable until a human
  # rm -rf's it manually.
  #
  # Heal a missing parent first, mirroring the dispatcher GC's GH#86 logic:
  # if WORKTREE_BASE was wiped between cycles, every later wrapper mkdir
  # would fail silently otherwise.
  mkdir -p "$LOCK_DIR" 2>/dev/null
  [ -d "$LOCK_DIR" ] || return 0
  # Glob only own-prefix gh-* locks. Stays scoped to OUR repo when LOCK_DIR
  # is shared with another repo via misconfiguration (GH#74), and avoids
  # touching any non-issue lock dirs a future caller might add under
  # LOCK_DIR.
  for lock in "$LOCK_DIR"/"${LOCK_NAME_PREFIX}"gh-*.lock; do
    [ -d "$lock" ] || continue
    local pid
    pid=$(cat "$lock/pid" 2>/dev/null || echo "")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock"
    fi
  done
}

# Count surviving (live-PID) dispatch locks for THIS repo only. Callers
# must invoke cleanup_stale_dispatch_locks first so dead PIDs don't
# inflate the count. Independent budget from DEV_INSTANCES (which
# governs foreground tmux-pane workers); this caps background dispatches.
# The LOCK_NAME_PREFIX glob (GH#74) keeps the count repo-local even when
# DISPATCH_LOCK_DIR is shared with another repo by misconfiguration.
#
# Counts follow-up + conflicts locks; review locks (suffix `-review.lock`,
# GH#117) are tracked separately by count_active_review_dispatch_locks so
# the two caps stay independent — neither workload can starve the other.
count_active_dispatch_locks() {
  [ -d "$DISPATCH_LOCK_DIR" ] || {
    echo 0
    return 0
  }
  local count=0 lock
  for lock in "$DISPATCH_LOCK_DIR"/"${LOCK_NAME_PREFIX}"*.lock; do
    [ -d "$lock" ] || continue
    case "$lock" in *-review.lock) continue ;; esac
    count=$((count + 1))
  done
  echo "$count"
}

# Sibling counter for review-only dispatch locks (GH#117). Independent budget
# from count_active_dispatch_locks so a saturated follow-up/conflicts cap
# doesn't block reviews and vice versa.
count_active_review_dispatch_locks() {
  [ -d "$DISPATCH_LOCK_DIR" ] || {
    echo 0
    return 0
  }
  local count=0 lock
  for lock in "$DISPATCH_LOCK_DIR"/"${LOCK_NAME_PREFIX}"*-review.lock; do
    [ -d "$lock" ] && count=$((count + 1))
  done
  echo "$count"
}

# ---- per-role loops -----------------------------------------------------
# These run inside a tmux pane via `--internal-role=<X>`. Their stdout is the
# pane itself — no log redirection, the user sees them live. The wrappers
# they invoke still write their own per-invocation log files.

# Compute the next sleep interval given the consecutive-empty-cycle streak.
# Exponential: POLL_INTERVAL * 2^streak, clamped at EMPTY_CYCLE_BACKOFF_CAP_SECONDS,
# plus up to 25% additive jitter via apply_additive_jitter (lib/jitter.sh).
# Without the jitter, N parallel dev panes converge once they all hit the cap
# and wake in lockstep, wasting N-1× the cost on every synchronized scan
# (GH#29). The jitter is strictly additive — the cap remains a floor.
# Streak 0 → ~POLL_INTERVAL. Caller resets streak to 0 on a non-empty cycle.
empty_cycle_sleep() {
  local streak="$1"
  local cap="${EMPTY_CYCLE_BACKOFF_CAP_SECONDS:-300}"
  local interval=$((POLL_INTERVAL * (1 << streak)))
  [ "$interval" -gt "$cap" ] && interval="$cap"
  apply_additive_jitter "$interval"
}

loop_dev_mode1() {
  local id="$1"
  local empty_streak=0 ec sleep_for jitter
  local cycle_counter=0 cycle_id cycle_start_s cycle_dur
  # De-converge parallel workers that all wake from `tmux send-keys` at the
  # same instant — without this, the first cycle has N-1 wasted scans as
  # everyone races for the same lock. See loop-k8u / GH#9.
  jitter=$(dev_startup_jitter "$POLL_INTERVAL")
  echo "[$(ts)] [dev-${id}] startup jitter: sleeping ${jitter}s before first cycle"
  sleep "$jitter"
  while true; do
    cycle_counter=$((cycle_counter + 1))
    cycle_id="$$-${cycle_counter}"
    cycle_start_s=$(date +%s)
    echo "[$(ts)] [dev-${id}] starting Mode 1 cycle"
    event_emit "dev-${id}" cycle_start cycle_id="$cycle_id"
    # GC any leaked gh-N issue locks before the wrapper's preflight runs
    # (GH#139). The wrapper's trap is the primary release path; this only
    # catches the SIGKILL-leak case where the trap was bypassed and the
    # lock would otherwise block the issue from any future cycle.
    cleanup_stale_dev_locks
    ec=0
    "$LOOP_HOME/runners/run-developer.sh" || ec=$?
    cycle_dur=$(($(date +%s) - cycle_start_s))
    case "$ec" in
      0)
        echo "[$(ts)] [dev-${id}] cycle done (exit 0)"
        event_emit "dev-${id}" cycle_end cycle_id="$cycle_id" exit_code=0 duration_s="$cycle_dur"
        empty_streak=0
        sleep_for="$POLL_INTERVAL"
        ;;
      2)
        empty_streak=$((empty_streak + 1))
        sleep_for=$(empty_cycle_sleep "$empty_streak")
        echo "[$(ts)] [dev-${id}] cycle skipped (no work, streak=${empty_streak}, next sleep=${sleep_for}s)"
        event_emit "dev-${id}" cycle_skip cycle_id="$cycle_id" reason=no-work streak="$empty_streak" sleep_s="$sleep_for"
        ;;
      *)
        echo "[$(ts)] [dev-${id}] cycle done (exit ${ec})"
        event_emit "dev-${id}" cycle_end cycle_id="$cycle_id" exit_code="$ec" duration_s="$cycle_dur"
        # Don't backoff on agent failures — keep base interval so we retry promptly
        empty_streak=0
        sleep_for="$POLL_INTERVAL"
        ;;
    esac
    echo "[$(ts)] [dev-${id}] sleeping ${sleep_for}s..."
    sleep "$sleep_for"
  done
}

loop_dispatcher_review() {
  # GH#117: replaces the single-pane `loop_reviewer` with a dispatcher pattern
  # mirroring loop_dispatcher_followup. Scans eligible PRs via
  # eligibility_review_pending_list and fans out one background
  # `run-reviewer.sh <PR>` per slot up to REVIEWER_DISPATCH_MAX_CONCURRENT
  # so several PR reviews can run in parallel — under the previous design,
  # each review serialized on the lone reviewer pane.
  : "${REVIEWER_DISPATCH_MAX_CONCURRENT:=3}"
  local cycle_counter=0 cycle_id cycle_start_s cycle_dur dispatched empty_streak=0 sleep_for
  while true; do
    cycle_counter=$((cycle_counter + 1))
    cycle_id="$$-${cycle_counter}"
    cycle_start_s=$(date +%s)
    dispatched=0
    event_emit "dispatch:review" cycle_start cycle_id="$cycle_id"
    # Re-source lib/eligibility.sh each cycle so on-disk fixes apply without
    # restarting the long-running tmux pane (matches the followup/conflicts
    # dispatchers). Failure logs a WARN and keeps cached helpers.
    # shellcheck disable=SC1091
    . "$LOOP_HOME/runners/lib/eligibility.sh" || echo "[$(ts)] [dispatch:review] WARN: failed to re-source lib/eligibility.sh; using cached predicates"
    cleanup_stale_dispatch_locks
    echo "[$(ts)] [dispatch:review] scanning open dev-agent PRs..."

    while IFS= read -r pr; do
      [ -z "$pr" ] && continue
      local lock="${DISPATCH_LOCK_DIR}/${LOCK_NAME_PREFIX}pr-${pr}-review.lock"
      [ -d "$lock" ] && continue

      local active
      active=$(count_active_review_dispatch_locks)
      if [ "$active" -ge "$REVIEWER_DISPATCH_MAX_CONCURRENT" ]; then
        echo "[$(ts)] [dispatch:review] at cap (${active}/${REVIEWER_DISPATCH_MAX_CONCURRENT}); skipping remaining eligible PRs this cycle"
        event_emit "dispatch:review" dispatch_at_cap kind=review active="$active" cap="$REVIEWER_DISPATCH_MAX_CONCURRENT"
        break
      fi

      # GH#172: one dispatch_id per PR-attempt — exported into the wrapper
      # below and stamped on both the fire and skip emits so consumers can
      # trace `dispatch_fired → llm_started → llm_exited` end-to-end.
      local dispatch_id="$$-$(date +%s%N 2>/dev/null || date +%s)"
      if mkdir "$lock" 2>/dev/null; then
        echo "$$" >"$lock/pid"
        echo "[$(ts)] [dispatch:review] dispatching review for PR #${pr}"
        event_emit "dispatch:review" dispatch_fired kind=review pr="$pr" dispatch_id="$dispatch_id"
        (LOOP_DISPATCH_ID="$dispatch_id" "$LOOP_HOME/runners/run-reviewer.sh" "$pr" >/dev/null 2>&1) &
        local child=$!
        echo "$child" >"$lock/pid"
        dispatched=$((dispatched + 1))
      elif [ ! -d "$lock" ]; then
        # mkdir failed AND the lock dir doesn't exist — i.e. NOT the
        # legitimate EEXIST skip (parent missing, permissions, etc.). Make
        # it loud so a future failure mode isn't another silent fall-through
        # (mirrors the followup/conflicts dispatchers post-GH#86).
        echo "[$(ts)] [dispatch:review] WARN: mkdir failed for PR #${pr} lock at ${lock} (parent dir or permissions?)"
        event_emit "dispatch:review" dispatch_skip kind=review pr="$pr" reason=mkdir-failed dispatch_id="$dispatch_id"
      fi
    done < <(
      bash "$LOOP_HOME/runners/lib/eligibility.sh" review-list 2>/dev/null
    )

    cycle_dur=$(($(date +%s) - cycle_start_s))
    if [ "$dispatched" -eq 0 ]; then
      empty_streak=$((empty_streak + 1))
      sleep_for=$(empty_cycle_sleep "$empty_streak")
      echo "[$(ts)] [dispatch:review] no new dispatches (streak=${empty_streak}, next sleep=${sleep_for}s)"
      event_emit "dispatch:review" cycle_skip cycle_id="$cycle_id" reason=no-work streak="$empty_streak" sleep_s="$sleep_for"
    else
      empty_streak=0
      sleep_for="$POLL_INTERVAL"
      echo "[$(ts)] [dispatch:review] dispatched ${dispatched} PR(s); sleeping ${sleep_for}s..."
      event_emit "dispatch:review" cycle_end cycle_id="$cycle_id" exit_code=0 duration_s="$cycle_dur" dispatched="$dispatched"
    fi
    sleep "$sleep_for"
  done
}

loop_dispatcher_followup() {
  local cycle_counter=0 cycle_id cycle_start_s cycle_dur dispatched
  while true; do
    cycle_counter=$((cycle_counter + 1))
    cycle_id="$$-${cycle_counter}"
    cycle_start_s=$(date +%s)
    dispatched=0
    event_emit "dispatch:followup" cycle_start cycle_id="$cycle_id"
    # Re-read lib/dispatcher.sh and lib/eligibility.sh each cycle so on-disk
    # fixes apply without restarting the long-running tmux pane. Failure
    # (mid-edit, syntax error) logs a WARN and continues with the previously
    # cached helpers.
    # shellcheck disable=SC1091
    . "$LOOP_HOME/runners/lib/dispatcher.sh" || echo "[$(ts)] [dispatch:followup] WARN: failed to re-source lib/dispatcher.sh; using cached helpers"
    # shellcheck disable=SC1091
    . "$LOOP_HOME/runners/lib/eligibility.sh" || echo "[$(ts)] [dispatch:followup] WARN: failed to re-source lib/eligibility.sh; using cached predicates"
    cleanup_stale_dispatch_locks
    echo "[$(ts)] [dispatch:followup] scanning open dev-agent PRs..."

    while IFS= read -r pr; do
      [ -z "$pr" ] && continue
      local lock="${DISPATCH_LOCK_DIR}/${LOCK_NAME_PREFIX}pr-${pr}-followup.lock"
      [ -d "$lock" ] && continue

      # Concurrency gate — don't fan out beyond the shared cap.
      local active
      active=$(count_active_dispatch_locks)
      if [ "$active" -ge "$DISPATCH_MAX_CONCURRENT" ]; then
        echo "[$(ts)] [dispatch:followup] at cap (${active}/${DISPATCH_MAX_CONCURRENT}); skipping remaining eligible PRs this cycle"
        event_emit "dispatch:followup" dispatch_at_cap kind=followup active="$active" cap="$DISPATCH_MAX_CONCURRENT"
        break
      fi

      # GH#172: one dispatch_id per PR-attempt — stamped on every skip /
      # fire emit for this PR and exported into the wrapper so consumers
      # can join the dispatcher decision to the wrapper's event chain.
      local dispatch_id="$$-$(date +%s%N 2>/dev/null || date +%s)"

      # Verdict-aware gate (GH#24): skip clean/nits unconditionally, and
      # changes/comment/blocked once the dev-agent has already responded.
      # The predicate prints the verdict (or "none" / "?") to stdout for
      # log visibility; exit 0 means dispatch, 1 means skip, 2 means gh/jq
      # failure (treat as skip — next cycle re-checks).
      local verdict ec=0
      verdict=$(eligibility_followup_pr "$pr") || ec=$?
      if [ "$ec" -ne 0 ]; then
        echo "[$(ts)] [dispatch:followup] skip PR #${pr} (verdict=${verdict})"
        event_emit "dispatch:followup" dispatch_skip kind=followup pr="$pr" verdict="$verdict" dispatch_id="$dispatch_id"
        continue
      fi

      if mkdir "$lock" 2>/dev/null; then
        echo "$$" >"$lock/pid"
        echo "[$(ts)] [dispatch:followup] dispatching follow-up for PR #${pr} (verdict=${verdict})"
        event_emit "dispatch:followup" dispatch_fired kind=followup pr="$pr" verdict="$verdict" dispatch_id="$dispatch_id"
        (LOOP_DISPATCH_ID="$dispatch_id" "$LOOP_HOME/runners/run-developer.sh" follow-up "$pr" >/dev/null 2>&1) &
        local child=$!
        echo "$child" >"$lock/pid"
        dispatched=$((dispatched + 1))
      elif [ ! -d "$lock" ]; then
        # mkdir failed AND the lock dir doesn't exist — i.e. the failure
        # was NOT the legitimate EEXIST skip (parent missing, permissions,
        # etc.). Make it loud so the next failure mode after GH#86 is not
        # another silent fall-through.
        echo "[$(ts)] [dispatch:followup] WARN: mkdir failed for PR #${pr} lock at ${lock} (parent dir or permissions?)"
        event_emit "dispatch:followup" dispatch_skip kind=followup pr="$pr" reason=mkdir-failed dispatch_id="$dispatch_id"
      fi
    done < <(
      gh pr list --repo "$REPO_SLUG" --state open \
        --json number,headRefName,isDraft \
        --jq "$(_dispatch_followup_jq "$BRANCH_PREFIX")" \
        2>/dev/null
    )

    cycle_dur=$(($(date +%s) - cycle_start_s))
    if [ "$dispatched" -eq 0 ]; then
      event_emit "dispatch:followup" cycle_skip cycle_id="$cycle_id" reason=no-work streak=0 sleep_s="$POLL_INTERVAL"
    else
      event_emit "dispatch:followup" cycle_end cycle_id="$cycle_id" exit_code=0 duration_s="$cycle_dur" dispatched="$dispatched"
    fi
    echo "[$(ts)] [dispatch:followup] sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
  done
}

loop_dispatcher_merge() {
  # Closes the loop end-to-end (GH#37): scan dev-agent PRs that earned a
  # `clean`/`nits` verdict + green CI and squash-merge them. Off by default;
  # activated by `st loop start --enable-merger`. Mirrors the follow-up
  # dispatcher's shape — pure shell, no LLM.
  local empty_streak=0 dispatched sleep_for
  local cycle_counter=0 cycle_id cycle_start_s cycle_dur
  while true; do
    cycle_counter=$((cycle_counter + 1))
    cycle_id="$$-${cycle_counter}"
    cycle_start_s=$(date +%s)
    event_emit merger cycle_start cycle_id="$cycle_id"
    # Re-read lib/dispatcher.sh and lib/eligibility.sh each cycle so on-disk
    # fixes apply without restarting the long-running tmux pane. Failure
    # (mid-edit, syntax error) logs a WARN and continues with the previously
    # cached helpers.
    # shellcheck disable=SC1091
    . "$LOOP_HOME/runners/lib/dispatcher.sh" || echo "[$(ts)] [merger] WARN: failed to re-source lib/dispatcher.sh; using cached helpers"
    # shellcheck disable=SC1091
    . "$LOOP_HOME/runners/lib/eligibility.sh" || echo "[$(ts)] [merger] WARN: failed to re-source lib/eligibility.sh; using cached predicates"
    echo "[$(ts)] [merger] scanning open dev-agent PRs..."
    dispatched=0

    while IFS= read -r pr; do
      [ -z "$pr" ] && continue

      # GH#172: one dispatch_id per PR-attempt, stamped on the verdict-skip /
      # fire / gh-merge-failed paths so consumers can correlate a single
      # merge decision end-to-end. The merger never backgrounds a wrapper
      # (it calls `gh pr merge` directly), so there is no LOOP_DISPATCH_ID
      # to export — the id only lives on this dispatcher's events.
      local dispatch_id="$$-$(date +%s%N 2>/dev/null || date +%s)"

      # Verdict + staleness + human-veto + CI gate. The predicate prints the
      # verdict on stdout for the log line; exit 0 = merge, 1 = skip, 2 =
      # gh/jq failure (treat as skip — next cycle re-checks).
      local verdict ec=0
      verdict=$(eligibility_merge_pr "$pr") || ec=$?
      if [ "$ec" -ne 0 ]; then
        echo "[$(ts)] [merger] skip pr=#${pr} verdict=${verdict}"
        event_emit merger dispatch_skip kind=merge pr="$pr" verdict="$verdict" dispatch_id="$dispatch_id"
        continue
      fi

      # `gh pr merge` is idempotent for already-merged PRs — no lock needed.
      # Use --auto only via the configured method flag; --delete-branch is
      # opt-out via MERGER_DELETE_BRANCH=0 for repos that retain branches.
      local merge_args=("--$MERGER_MERGE_METHOD")
      [ "$MERGER_DELETE_BRANCH" = "1" ] && merge_args+=(--delete-branch)
      if PAGER=cat GIT_PAGER=cat gh pr merge "$pr" --repo "$REPO_SLUG" "${merge_args[@]}" >/dev/null 2>&1; then
        echo "[$(ts)] [merger] merged pr=#${pr} verdict=${verdict}"
        event_emit merger dispatch_fired kind=merge pr="$pr" verdict="$verdict" dispatch_id="$dispatch_id"
        dispatched=$((dispatched + 1))
      else
        # gh failure here is rare (network, permissions, race with a human
        # merging concurrently). Log and move on; the candidate scan will
        # re-test next cycle.
        echo "[$(ts)] [merger] skip pr=#${pr} verdict=${verdict} reason=gh-merge-failed"
        event_emit merger dispatch_skip kind=merge pr="$pr" verdict="$verdict" reason=gh-merge-failed dispatch_id="$dispatch_id"
      fi
    done < <(
      gh pr list --repo "$REPO_SLUG" --state open \
        --json number,headRefName,isDraft \
        --jq "$(_dispatch_merge_jq "$BRANCH_PREFIX")" \
        2>/dev/null
    )

    cycle_dur=$(($(date +%s) - cycle_start_s))
    # Backoff on cycles where nothing was merged. Mirrors the conflict
    # dispatcher's shape — `dispatched` here counts successful merges only.
    if [ "$dispatched" -eq 0 ]; then
      empty_streak=$((empty_streak + 1))
      sleep_for=$(empty_cycle_sleep "$empty_streak")
      echo "[$(ts)] [merger] no merges (streak=${empty_streak}, next sleep=${sleep_for}s)"
      event_emit merger cycle_skip cycle_id="$cycle_id" reason=no-work streak="$empty_streak" sleep_s="$sleep_for"
    else
      empty_streak=0
      sleep_for="$POLL_INTERVAL"
      echo "[$(ts)] [merger] merged ${dispatched} PR(s); sleeping ${sleep_for}s..."
      event_emit merger cycle_end cycle_id="$cycle_id" exit_code=0 duration_s="$cycle_dur" dispatched="$dispatched"
    fi
    sleep "$sleep_for"
  done
}

loop_dispatcher_conflicts() {
  local empty_streak=0 dispatched sleep_for
  local cycle_counter=0 cycle_id cycle_start_s cycle_dur
  while true; do
    cycle_counter=$((cycle_counter + 1))
    cycle_id="$$-${cycle_counter}"
    cycle_start_s=$(date +%s)
    event_emit "dispatch:conflicts" cycle_start cycle_id="$cycle_id"
    # Re-read lib/dispatcher.sh each cycle so on-disk fixes apply without
    # restarting the long-running tmux pane. Failure (mid-edit, syntax error)
    # logs a WARN and continues with the previously cached helpers.
    # shellcheck disable=SC1091
    . "$LOOP_HOME/runners/lib/dispatcher.sh" || echo "[$(ts)] [dispatch:conflicts] WARN: failed to re-source lib/dispatcher.sh; using cached helpers"
    cleanup_stale_dispatch_locks
    echo "[$(ts)] [dispatch:conflicts] scanning for CONFLICTING dev-agent PRs..."
    dispatched=0

    while IFS= read -r pr; do
      [ -z "$pr" ] && continue
      local lock="${DISPATCH_LOCK_DIR}/${LOCK_NAME_PREFIX}pr-${pr}-conflicts.lock"
      [ -d "$lock" ] && continue

      # Concurrency gate — don't fan out beyond the shared cap.
      local active
      active=$(count_active_dispatch_locks)
      if [ "$active" -ge "$DISPATCH_MAX_CONCURRENT" ]; then
        echo "[$(ts)] [dispatch:conflicts] at cap (${active}/${DISPATCH_MAX_CONCURRENT}); skipping remaining eligible PRs this cycle"
        event_emit "dispatch:conflicts" dispatch_at_cap kind=conflicts active="$active" cap="$DISPATCH_MAX_CONCURRENT"
        break
      fi

      # GH#172: one dispatch_id per PR-attempt, stamped on the fire / skip
      # emits and exported into the wrapper subshell so the Mode 3 chain
      # (eligibility, triage_result, llm_started, llm_exited, hard_failure)
      # joins to the dispatcher decision that spawned it.
      local dispatch_id="$$-$(date +%s%N 2>/dev/null || date +%s)"
      if mkdir "$lock" 2>/dev/null; then
        echo "$$" >"$lock/pid"
        echo "[$(ts)] [dispatch:conflicts] dispatching resolve-conflicts for PR #${pr}"
        event_emit "dispatch:conflicts" dispatch_fired kind=conflicts pr="$pr" dispatch_id="$dispatch_id"
        (LOOP_DISPATCH_ID="$dispatch_id" "$LOOP_HOME/runners/run-developer.sh" resolve-conflicts "$pr" >/dev/null 2>&1) &
        local child=$!
        echo "$child" >"$lock/pid"
        dispatched=$((dispatched + 1))
      elif [ ! -d "$lock" ]; then
        # mkdir failed AND the lock dir doesn't exist — i.e. the failure
        # was NOT the legitimate EEXIST skip (parent missing, permissions,
        # etc.). Make it loud so the next failure mode after GH#86 is not
        # another silent fall-through.
        echo "[$(ts)] [dispatch:conflicts] WARN: mkdir failed for PR #${pr} lock at ${lock} (parent dir or permissions?)"
        event_emit "dispatch:conflicts" dispatch_skip kind=conflicts pr="$pr" reason=mkdir-failed dispatch_id="$dispatch_id"
      fi
    done < <(
      # GH#111: `labels` is added to the field set so the conflicts predicate
      # can drop PRs carrying ${BLOCKED_HUMAN_LABEL} after the Mode 3 wrapper
      # escalates DEV_CONFLICTS_FAILURE_RETRY_LIMIT consecutive hard-failures.
      # Single extra field on the existing call — no extra round-trip.
      gh pr list --repo "$REPO_SLUG" --state open \
        --json number,headRefName,mergeable,isDraft,labels \
        --jq "$(_dispatch_conflicts_jq "$BRANCH_PREFIX" "${BLOCKED_HUMAN_LABEL:-blocked:human}")" \
        2>/dev/null
    )

    cycle_dur=$(($(date +%s) - cycle_start_s))
    # Backoff on cycles where nothing new was dispatched. "Nothing new" means
    # zero NEW lock acquisitions — already-locked PRs from prior cycles don't
    # count as work this cycle. Resets to base on the first non-empty cycle.
    if [ "$dispatched" -eq 0 ]; then
      empty_streak=$((empty_streak + 1))
      sleep_for=$(empty_cycle_sleep "$empty_streak")
      echo "[$(ts)] [dispatch:conflicts] no new dispatches (streak=${empty_streak}, next sleep=${sleep_for}s)"
      event_emit "dispatch:conflicts" cycle_skip cycle_id="$cycle_id" reason=no-work streak="$empty_streak" sleep_s="$sleep_for"
    else
      empty_streak=0
      sleep_for="$POLL_INTERVAL"
      echo "[$(ts)] [dispatch:conflicts] dispatched ${dispatched} PR(s); sleeping ${sleep_for}s..."
      event_emit "dispatch:conflicts" cycle_end cycle_id="$cycle_id" exit_code=0 duration_s="$cycle_dur" dispatched="$dispatched"
    fi
    sleep "$sleep_for"
  done
}

# ---- internal dispatch (used by tmux panes) -----------------------------

if [[ "${1:-}" == --internal-role=* ]]; then
  ROLE="${1#*=}"
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --poll-interval=*) POLL_INTERVAL="${1#*=}" ;;
    esac
    shift
  done
  cd "$REPO" || exit 1
  case "$ROLE" in
    dev-[1-9]) loop_dev_mode1 "${ROLE#dev-}" ;;
    dispatch-review) loop_dispatcher_review ;;
    dispatch-followup) loop_dispatcher_followup ;;
    dispatch-conflicts) loop_dispatcher_conflicts ;;
    dispatch-merge) loop_dispatcher_merge ;;
    *)
      echo "Unknown internal role: $ROLE" >&2
      exit 2
      ;;
  esac
  exit
fi

# ---- normal command handling --------------------------------------------

usage() {
  cat <<EOF
Usage: $0 <command> [options]

Commands:
  start    Create the tmux session and run all loops in panes (default if no command given).
  stop     Kill the tmux session and clean up dispatch locks.
  attach   Attach to the running session.
  status   Show whether the session is running, and list panes.

Options (for 'start'):
  --dev-instances=N      Number of parallel Mode 1 dev-agents (default: 3, range 1-9).
  --poll-interval=SECS   Seconds between polling cycles (default: 60, min 10).
  --max-runtime=SECS     Auto-stop after this many seconds (default: 0 = unlimited).
  --enable-merger        Add a 4th top-row pane that auto-merges dev-agent PRs
                         with a clean/nits reviewer-agent verdict + green CI.
                         Off by default; squash-merges via gh, deletes branch
                         (configurable via MERGER_* keys in loop.config).
  --detach               Don't attach to the session after creating it.
  --help, -h             Show this help.

Layout:
  Top row:    dispatch:review | dispatch:followup | dispatch:conflicts [| merger]
  Bottom row: dev-1, dev-2, ..., dev-<N>

Inside tmux:
  Ctrl+B D       detach (loops keep running)
  Ctrl+B arrow   navigate panes
  Ctrl+B z       toggle full-screen for current pane

Issue-author is interactive — run st issue in a separate terminal.
EOF
}

ACTION=start
if [ $# -gt 0 ]; then
  case "$1" in
    start | stop | attach | status)
      ACTION=$1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    --*) ;; # flag without subcommand — default ACTION=start
    *)
      echo "Unknown command: $1" >&2
      usage
      exit 2
      ;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --dev-instances=*)
      DEV_INSTANCES="${1#*=}"
      shift
      ;;
    --poll-interval=*)
      POLL_INTERVAL="${1#*=}"
      shift
      ;;
    --max-runtime=*)
      MAX_RUNTIME="${1#*=}"
      shift
      ;;
    --detach)
      DETACH=1
      shift
      ;;
    --enable-merger)
      ENABLE_MERGER=1
      shift
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      exit 2
      ;;
  esac
done

[[ "$DEV_INSTANCES" =~ ^[1-9]$ ]] || {
  echo "--dev-instances must be 1-9" >&2
  exit 2
}
[[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || {
  echo "--poll-interval must be numeric" >&2
  exit 2
}
[ "$POLL_INTERVAL" -ge 10 ] || {
  echo "--poll-interval must be >= 10 (gh rate limits)" >&2
  exit 2
}
[[ "$MAX_RUNTIME" =~ ^[0-9]+$ ]] || {
  echo "--max-runtime must be numeric" >&2
  exit 2
}

SCRIPT="$LOOP_HOME/runners/run-loop.sh"

require_tmux() {
  command -v tmux >/dev/null || {
    echo "tmux is required. Install it first (macOS: brew install tmux)." >&2
    exit 1
  }
}

start_session() {
  require_tmux

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Session '$SESSION' is already running." >&2
    echo "  Use '$0 attach' to view, or '$0 stop' first to restart." >&2
    exit 1
  fi

  cd "$REPO" || exit 1
  mkdir -p "$DISPATCH_LOCK_DIR"

  COMMON_ARGS="--poll-interval=$POLL_INTERVAL"

  # Create session, detached.
  tmux new-session -d -s "$SESSION" -n agents
  tmux set-option -t "$SESSION" history-limit 50000
  tmux set-option -t "$SESSION" pane-border-status top
  tmux set-option -t "$SESSION" pane-border-format ' #{pane_title} '

  # Pane 0 (initial pane) becomes top-left = dispatch:review.
  TOP1=$(tmux list-panes -t "$SESSION:agents" -F '#{pane_id}' | head -1)

  # Split horizontally to create the bottom row at 50% height.
  BOT1=$(tmux split-window -P -F '#{pane_id}' -t "$TOP1" -v -p 50)

  # Split top into 3 cols (dispatch:review | dispatch:followup | dispatch:conflicts),
  # or 4 cols when --enable-merger adds the merger pane on the right.
  # Even-split percentages: for N panes, split[i] = 100*(N-i)/(N-i+1).
  if [ "$ENABLE_MERGER" -eq 1 ]; then
    # 4 panes → splits at 75, 67, 50 produce ~25/25/25/25.
    TOP2=$(tmux split-window -P -F '#{pane_id}' -t "$TOP1" -h -p 75)
    TOP3=$(tmux split-window -P -F '#{pane_id}' -t "$TOP2" -h -p 67)
    TOP4=$(tmux split-window -P -F '#{pane_id}' -t "$TOP3" -h -p 50)
  else
    # 3 panes → splits at 67, 50 produce ~33/33/33.
    TOP2=$(tmux split-window -P -F '#{pane_id}' -t "$TOP1" -h -p 67)
    TOP3=$(tmux split-window -P -F '#{pane_id}' -t "$TOP2" -h -p 50)
  fi

  # Split bottom into DEV_INSTANCES even cols using the formula
  # split_pct[i] = 100 * (N - i + 1) / (N - i + 2)  for i in 2..N.
  DEV_PANES=("$BOT1")
  prev="$BOT1"
  for ((i = 2; i <= DEV_INSTANCES; i++)); do
    pct=$((100 * (DEV_INSTANCES - i + 1) / (DEV_INSTANCES - i + 2)))
    new=$(tmux split-window -P -F '#{pane_id}' -t "$prev" -h -p "$pct")
    DEV_PANES+=("$new")
    prev="$new"
  done

  # Title each pane (for the tmux pane border).
  tmux select-pane -t "$TOP1" -T "dispatch:review"
  tmux select-pane -t "$TOP2" -T "dispatch:followup"
  tmux select-pane -t "$TOP3" -T "dispatch:conflicts"
  if [ "$ENABLE_MERGER" -eq 1 ]; then
    tmux select-pane -t "$TOP4" -T "merger"
  fi
  for ((i = 1; i <= DEV_INSTANCES; i++)); do
    tmux select-pane -t "${DEV_PANES[$((i - 1))]}" -T "dev-$i"
  done

  # Send the loop command to each pane. Don't `exec` — keeps the shell
  # alive after the loop dies (e.g., from Ctrl+C), so the user sees output.
  #
  # Each payload re-exports REPO_ROOT and LOOP_HOME (GH#162). Panes spawned
  # inside `tmux new-session` inherit env from the existing tmux server,
  # NOT from this run-loop.sh process. Without an explicit export the
  # per-pane run-loop.sh re-exec sees whatever the server was started
  # with — silently targeting the wrong repo when a fleet is started from
  # a different repo than the one that first launched the tmux server.
  ENV_EXPORT="export REPO_ROOT='$REPO' LOOP_HOME='$LOOP_HOME'"
  tmux send-keys -t "$TOP1" "cd '$REPO' && $ENV_EXPORT && '$SCRIPT' --internal-role=dispatch-review $COMMON_ARGS" Enter
  tmux send-keys -t "$TOP2" "cd '$REPO' && $ENV_EXPORT && '$SCRIPT' --internal-role=dispatch-followup $COMMON_ARGS" Enter
  tmux send-keys -t "$TOP3" "cd '$REPO' && $ENV_EXPORT && '$SCRIPT' --internal-role=dispatch-conflicts $COMMON_ARGS" Enter
  if [ "$ENABLE_MERGER" -eq 1 ]; then
    tmux send-keys -t "$TOP4" "cd '$REPO' && $ENV_EXPORT && '$SCRIPT' --internal-role=dispatch-merge $COMMON_ARGS" Enter
  fi
  for ((i = 1; i <= DEV_INSTANCES; i++)); do
    tmux send-keys -t "${DEV_PANES[$((i - 1))]}" "cd '$REPO' && $ENV_EXPORT && '$SCRIPT' --internal-role=dev-$i $COMMON_ARGS" Enter
  done

  # Focus the first dev pane (most likely place for action).
  tmux select-pane -t "${DEV_PANES[0]}"

  # Schedule auto-stop if requested. Detached so it survives even if the
  # user never attaches or detaches early.
  if [ "$MAX_RUNTIME" -gt 0 ]; then
    nohup bash -c "sleep $MAX_RUNTIME && '$SCRIPT' stop" >/dev/null 2>&1 </dev/null &
    disown 2>/dev/null || true
  fi

  echo "Session '$SESSION' started with $DEV_INSTANCES dev-agent worker(s)."
  echo "  Attach: $0 attach    (or just $0)"
  echo "  Stop:   $0 stop"
  if [ "$MAX_RUNTIME" -gt 0 ]; then
    echo "  Auto-stop scheduled in: ${MAX_RUNTIME}s"
  fi
  echo "  File a new issue:  st issue   (separate terminal — interactive)"

  if [ "$DETACH" -eq 0 ]; then
    echo "  Attaching now (Ctrl+B D to detach, Ctrl+B z to zoom a pane)..."
    sleep 1 # let panes settle and start their loops
    tmux attach -t "$SESSION"
  fi
}

stop_session() {
  require_tmux
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux kill-session -t "$SESSION"
    echo "Session '$SESSION' stopped."
  else
    echo "Session '$SESSION' is not running."
  fi
  # Only remove THIS repo's dispatch locks (GH#74). When DISPATCH_LOCK_DIR
  # is per-repo (the post-#74 default) the prefix glob still matches every
  # lock in there; when it's misconfigured to a shared base, we leave the
  # other repo's live locks alone.
  if [ -d "$DISPATCH_LOCK_DIR" ]; then
    for lock in "$DISPATCH_LOCK_DIR"/"${LOCK_NAME_PREFIX}"*.lock; do
      [ -d "$lock" ] && rm -rf "$lock"
    done
    # If the dir is now empty, prune it to avoid stale-empty-dir clutter.
    rmdir "$DISPATCH_LOCK_DIR" 2>/dev/null || true
  fi
}

attach_session() {
  require_tmux
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux attach -t "$SESSION"
  else
    echo "Session '$SESSION' is not running. Use '$0 start' first." >&2
    exit 1
  fi
}

show_status() {
  require_tmux
  # Always print the repo identity alongside the session — with multi-repo
  # fleets (GH#74) the same machine can host several `agent-loop-*`
  # sessions, and `st loop status` should make it obvious which repo's
  # fleet is being inspected.
  echo "Repo: $REPO_SLUG  (worktree base: $WORKTREE_BASE)"
  if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Session '$SESSION': RUNNING"
    echo
    echo "Panes:"
    tmux list-panes -t "$SESSION:agents" -F '  #{pane_id}  #{pane_title}'
  else
    echo "Session '$SESSION': not running"
  fi
}

case "$ACTION" in
  start) start_session ;;
  stop) stop_session ;;
  attach) attach_session ;;
  status) show_status ;;
esac
