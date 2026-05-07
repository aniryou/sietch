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

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the sietch CLI}"
: "${SIETCH_HOME:?SIETCH_HOME must be set; invoke via the sietch CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.sietch/rig.config"

# Mode 1 only — preflight: skip the LLM if there are no eligible issues.
# Modes 2/3 already arrive with a specific PR number and don't scan.
# Exit code 2 distinguishes "skipped, no work" from "ran successfully" (0)
# so run-loop.sh can apply exponential backoff to consecutive empty cycles.
if [ "$MODE" = "default" ]; then
  EL_COUNT=$("$SIETCH_HOME/lib/eligibility.sh" dev)
  EL_RC=$?
  case "$EL_RC" in
    0) echo "[wrapper] eligibility: $EL_COUNT candidate issue(s); proceeding" ;;
    1) echo "[wrapper] eligibility: no eligible issues; skipping LLM invocation"
       echo "[wrapper] result=no-work mode=$MODE"
       exit 2 ;;
    *) echo "[wrapper] eligibility: predicate failed (rc=$EL_RC); proceeding to be safe" >&2 ;;
  esac
  unset EL_COUNT EL_RC
fi

KEEP_ON_FAIL="${KEEP_ON_FAIL:-1}"
TS="$(date +%Y%m%d-%H%M%S)"

# Unique ID per wrapper invocation so the trap can release exactly the locks
# this run owns when multiple wrappers are running in parallel.
export DEV_AGENT_RUN_ID="$$-$(date +%s%N 2>/dev/null || date +%s)"
if [ "$MODE" = "follow-up" ]; then
  LOG="/tmp/dev-agent-followup-pr${TARGET_PR}-${TS}.log"
  RAW="/tmp/dev-agent-followup-pr${TARGET_PR}-${TS}.jsonl"
  KICKOFF="Run the developer agent in FOLLOW-UP MODE on PR #${TARGET_PR}. Skip the issue scan. Begin the follow-up workflow defined in Mode 2 of your system prompt now."
elif [ "$MODE" = "resolve-conflicts" ]; then
  LOG="/tmp/dev-agent-conflicts-pr${TARGET_PR}-${TS}.log"
  RAW="/tmp/dev-agent-conflicts-pr${TARGET_PR}-${TS}.jsonl"
  KICKOFF="Run the developer agent in MODE 3 (resolve merge conflicts) on PR #${TARGET_PR}. Triage already validated this conflict as tractable — proceed directly to the Mode 3 workflow defined in your system prompt now."
else
  LOG="/tmp/dev-agent-${TS}.log"          # human-readable live log (this is what you tail)
  RAW="/tmp/dev-agent-${TS}.jsonl"        # raw stream-json (full fidelity, for debugging)
  KICKOFF="Run the developer agent workflow defined in your system prompt. Begin the single-pass scan now."
fi

# Mode 3 only: run the triage gate BEFORE invoking the LLM. If triage says
# untractable, the wrapper itself escalates via gh and exits — no LLM call.
if [ "$MODE" = "resolve-conflicts" ]; then
  echo "[wrapper] running triage for PR #$TARGET_PR..."
  if TRIAGE_OUTPUT=$("$SIETCH_HOME/wrappers/triage-conflict.sh" "$TARGET_PR" 2>&1); then
    echo "$TRIAGE_OUTPUT"
    echo "[wrapper] triage tractable — invoking dev-agent Mode 3."
  else
    echo "$TRIAGE_OUTPUT" >&2
    REASON=$(echo "$TRIAGE_OUTPUT" | grep -oE 'reason=[^ ]+' | head -1 | cut -d= -f2-)
    echo "[wrapper] triage says untractable (reason=${REASON}); escalating without invoking LLM." >&2
    PAGER=cat GIT_PAGER=cat gh pr comment "$TARGET_PR" --repo "$REPO_SLUG" --body "$(cat <<EOF
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

# Snapshot worktrees BEFORE the run so we can detect what the agent created.
PRE_WORKTREES=$(git -C "$REPO" worktree list --porcelain | awk '/^worktree/ {print $2}' | grep "^${WORKTREE_BASE}/" || true)

cleanup() {
  local exit_code=$?
  echo "[wrapper] agent exited with code $exit_code; cleaning up..." >&2

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
  echo "[wrapper] raw json: $RAW"  >&2
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# jq filter: turn each stream-json event into one human-readable line.
# Covers: assistant text, tool_use (with arg snippet), tool_result (truncated),
# system init, and the final result event with cost/duration.
JQ_FILTER='
  if .type == "system" and .subtype == "init" then
    "[init] model=\(.model) tools=\(.tools | length) cwd=\(.cwd)"
  elif .type == "assistant" then
    (.message.content // [])[] | (
      if .type == "text" then
        "[text] " + ((.text // "") | gsub("\n"; " ⏎ ") | .[0:400])
      elif .type == "tool_use" then
        "[tool] " + .name + " " + ((.input // {}) | tostring | .[0:300])
      else empty end
    )
  elif .type == "user" then
    (.message.content // [])[] | (
      if .type == "tool_result" then
        "[result] " + (
          if (.content | type) == "array" then
            (.content[0].text // "" | gsub("\n"; " ⏎ ") | .[0:400])
          else (.content // "" | tostring | .[0:400]) end
        )
      else empty end
    )
  elif .type == "result" then
    "[done] " + .subtype + " duration=\(.duration_ms)ms turns=\(.num_turns) cost=$\(.total_cost_usd // 0)"
  else empty end
'

cd "$REPO"

echo "[wrapper] mode: $MODE${TARGET_PR:+ (PR #$TARGET_PR)} run_id=$DEV_AGENT_RUN_ID"
echo "[wrapper] live log: $LOG"
echo "[wrapper] raw json: $RAW"
echo "[wrapper] tail with: tail -f $LOG"
echo

PAGER=cat GIT_PAGER=cat \
claude -p "$KICKOFF" \
  --append-system-prompt "$("$SIETCH_HOME/lib/render-prompt.sh" "$SIETCH_HOME/templates/developer.md")" \
  --permission-mode bypassPermissions \
  --max-turns "$DEV_MAX_TURNS" \
  --verbose \
  --output-format stream-json \
  2> >(tee "$RAW.stderr" >&2) \
  | tee "$RAW" \
  | jq -r --unbuffered "$JQ_FILTER" 2>/dev/null \
  | tee "$LOG"
