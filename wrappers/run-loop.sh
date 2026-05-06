#!/usr/bin/env bash
# Top-level driver that runs all the headless agents continuously, each in its
# own tmux pane.
#
# Layout:
#   ┌────────────┬─────────────────────┬──────────────────────┐
#   │ reviewer   │ dispatch:followup   │ dispatch:conflicts   │
#   ├────────────┼──────────┬──────────┴──────────────────────┤
#   │ dev-1      │ dev-2    │ dev-3 (number = --dev-instances)│
#   └────────────┴──────────┴─────────────────────────────────┘
#
# Issue-author is NOT in the loop — it's interactive. Run it manually in a
# separate terminal: sietch issue
#
# Usage:
#   sietch loop                              # equivalent to 'start' with defaults
#   sietch loop start                        # create the tmux session and attach
#   sietch loop start --detach               # create but don't attach
#   sietch loop start --dev-instances=2      # 2 dev workers instead of 3
#   sietch loop start --poll-interval=120    # slower polling
#   sietch loop start --max-runtime=900      # auto-stop after 15 min
#   sietch loop stop                         # kill the tmux session
#   sietch loop attach                       # re-attach to running session
#   sietch loop status                       # is it running?
#
# Press Ctrl+B D inside tmux to detach (loops keep running).
# Use 'stop' from any terminal to terminate cleanly.

set -u

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the sietch CLI}"
: "${SIETCH_HOME:?SIETCH_HOME must be set; invoke via the sietch CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.sietch/rig.config"

SESSION=agent-loop

DEV_INSTANCES="$DEV_INSTANCES_DEFAULT"
POLL_INTERVAL="$POLL_INTERVAL_DEFAULT"
MAX_RUNTIME=0
DETACH=0

# ---- helpers ------------------------------------------------------------

ts() { date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"; }

cleanup_stale_dispatch_locks() {
  [ -d "$DISPATCH_LOCK_DIR" ] || return 0
  for lock in "$DISPATCH_LOCK_DIR"/*.lock; do
    [ -d "$lock" ] || continue
    local pid
    pid=$(cat "$lock/pid" 2>/dev/null || echo "")
    if [ -z "$pid" ] || ! kill -0 "$pid" 2>/dev/null; then
      rm -rf "$lock"
    fi
  done
}

# ---- per-role loops -----------------------------------------------------
# These run inside a tmux pane via `--internal-role=<X>`. Their stdout is the
# pane itself — no log redirection, the user sees them live. The wrappers
# they invoke still write their own per-invocation log files.

loop_dev_mode1() {
  local id="$1"
  while true; do
    echo "[$(ts)] [dev-${id}] starting Mode 1 cycle"
    if "$SIETCH_HOME/wrappers/run-developer.sh"; then
      echo "[$(ts)] [dev-${id}] cycle done (exit 0)"
    else
      echo "[$(ts)] [dev-${id}] cycle done (exit $?)"
    fi
    echo "[$(ts)] [dev-${id}] sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
  done
}

loop_reviewer() {
  while true; do
    echo "[$(ts)] [reviewer] starting orchestrator cycle"
    if "$SIETCH_HOME/wrappers/run-reviewer.sh"; then
      echo "[$(ts)] [reviewer] cycle done (exit 0)"
    else
      echo "[$(ts)] [reviewer] cycle done (exit $?)"
    fi
    echo "[$(ts)] [reviewer] sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
  done
}

loop_dispatcher_followup() {
  while true; do
    cleanup_stale_dispatch_locks
    echo "[$(ts)] [dispatch:followup] scanning open dev-agent PRs..."

    while IFS= read -r pr; do
      [ -z "$pr" ] && continue
      local lock="${DISPATCH_LOCK_DIR}/pr-${pr}-followup.lock"
      [ -d "$lock" ] && continue

      local data latest_review latest_devcomment
      data=$(gh pr view "$pr" --repo "$REPO_SLUG" --json reviews,comments 2>/dev/null) || continue

      latest_review=$(echo "$data" | jq -r --arg re "$REVIEWER_AGENT_VERDICT_REGEX" '
        .reviews
        | map(select(.body | test($re)))
        | sort_by(.submittedAt)
        | last | .submittedAt // "none"
      ')
      [ "$latest_review" = "none" ] && continue

      latest_devcomment=$(echo "$data" | jq -r --arg prefix "$DEV_AGENT_COMMENT_PREFIX" '
        .comments
        | map(select(.body | startswith($prefix)))
        | sort_by(.createdAt)
        | last | .createdAt // "none"
      ')

      if [ "$latest_devcomment" = "none" ] || [[ "$latest_review" > "$latest_devcomment" ]]; then
        if mkdir "$lock" 2>/dev/null; then
          echo "$$" > "$lock/pid"
          echo "[$(ts)] [dispatch:followup] dispatching follow-up for PR #${pr} (review=${latest_review} dev=${latest_devcomment})"
          ( "$SIETCH_HOME/wrappers/run-developer.sh" follow-up "$pr" > /dev/null 2>&1 ) &
          local child=$!
          echo "$child" > "$lock/pid"
        fi
      fi
    done < <(
      gh pr list --repo "$REPO_SLUG" --state open \
        --json number,headRefName,isDraft \
        --jq --arg prefix "${BRANCH_PREFIX}/" \
            '.[] | select(.headRefName | startswith($prefix)) | select(.isDraft == false) | .number' \
        2>/dev/null
    )

    echo "[$(ts)] [dispatch:followup] sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
  done
}

loop_dispatcher_conflicts() {
  while true; do
    cleanup_stale_dispatch_locks
    echo "[$(ts)] [dispatch:conflicts] scanning for CONFLICTING dev-agent PRs..."

    while IFS= read -r pr; do
      [ -z "$pr" ] && continue
      local lock="${DISPATCH_LOCK_DIR}/pr-${pr}-conflicts.lock"
      [ -d "$lock" ] && continue

      if mkdir "$lock" 2>/dev/null; then
        echo "$$" > "$lock/pid"
        echo "[$(ts)] [dispatch:conflicts] dispatching resolve-conflicts for PR #${pr}"
        ( "$SIETCH_HOME/wrappers/run-developer.sh" resolve-conflicts "$pr" > /dev/null 2>&1 ) &
        local child=$!
        echo "$child" > "$lock/pid"
      fi
    done < <(
      gh pr list --repo "$REPO_SLUG" --state open \
        --json number,headRefName,mergeable,isDraft \
        --jq --arg prefix "${BRANCH_PREFIX}/" \
            '.[]
              | select(.headRefName | startswith($prefix))
              | select(.mergeable == "CONFLICTING")
              | select(.isDraft == false)
              | .number' \
        2>/dev/null
    )

    echo "[$(ts)] [dispatch:conflicts] sleeping ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
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
  cd "$REPO"
  case "$ROLE" in
    dev-[1-9])           loop_dev_mode1 "${ROLE#dev-}" ;;
    reviewer)            loop_reviewer ;;
    dispatch-followup)   loop_dispatcher_followup ;;
    dispatch-conflicts)  loop_dispatcher_conflicts ;;
    *) echo "Unknown internal role: $ROLE" >&2; exit 2 ;;
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
  --detach               Don't attach to the session after creating it.
  --help, -h             Show this help.

Layout:
  Top row:    reviewer | dispatch:followup | dispatch:conflicts
  Bottom row: dev-1, dev-2, ..., dev-<N>

Inside tmux:
  Ctrl+B D       detach (loops keep running)
  Ctrl+B arrow   navigate panes
  Ctrl+B z       toggle full-screen for current pane

Issue-author is interactive — run sietch issue in a separate terminal.
EOF
}

ACTION=start
if [ $# -gt 0 ]; then
  case "$1" in
    start|stop|attach|status) ACTION=$1; shift ;;
    --help|-h) usage; exit 0 ;;
    --*) ;;  # flag without subcommand — default ACTION=start
    *) echo "Unknown command: $1" >&2; usage; exit 2 ;;
  esac
fi

while [ $# -gt 0 ]; do
  case "$1" in
    --dev-instances=*) DEV_INSTANCES="${1#*=}"; shift ;;
    --poll-interval=*) POLL_INTERVAL="${1#*=}"; shift ;;
    --max-runtime=*)   MAX_RUNTIME="${1#*=}"; shift ;;
    --detach)          DETACH=1; shift ;;
    --help|-h)         usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ "$DEV_INSTANCES" =~ ^[1-9]$ ]] || { echo "--dev-instances must be 1-9" >&2; exit 2; }
[[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || { echo "--poll-interval must be numeric" >&2; exit 2; }
[ "$POLL_INTERVAL" -ge 10 ] || { echo "--poll-interval must be >= 10 (gh rate limits)" >&2; exit 2; }
[[ "$MAX_RUNTIME" =~ ^[0-9]+$ ]] || { echo "--max-runtime must be numeric" >&2; exit 2; }

SCRIPT="$SIETCH_HOME/wrappers/run-loop.sh"

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

  cd "$REPO"
  mkdir -p "$DISPATCH_LOCK_DIR"

  COMMON_ARGS="--poll-interval=$POLL_INTERVAL"

  # Create session, detached.
  tmux new-session -d -s "$SESSION" -n agents
  tmux set-option -t "$SESSION" history-limit 50000
  tmux set-option -t "$SESSION" pane-border-status top
  tmux set-option -t "$SESSION" pane-border-format ' #{pane_title} '

  # Pane 0 (initial pane) becomes top-left = reviewer.
  TOP1=$(tmux list-panes -t "$SESSION:agents" -F '#{pane_id}' | head -1)

  # Split horizontally to create the bottom row at 50% height.
  BOT1=$(tmux split-window -P -F '#{pane_id}' -t "$TOP1" -v -p 50)

  # Split top into 3 cols: reviewer | dispatch:followup | dispatch:conflicts.
  # Percentages 67 then 50 produce roughly 33/33/33.
  TOP2=$(tmux split-window -P -F '#{pane_id}' -t "$TOP1" -h -p 67)
  TOP3=$(tmux split-window -P -F '#{pane_id}' -t "$TOP2" -h -p 50)

  # Split bottom into DEV_INSTANCES even cols using the formula
  # split_pct[i] = 100 * (N - i + 1) / (N - i + 2)  for i in 2..N.
  DEV_PANES=("$BOT1")
  prev="$BOT1"
  for ((i=2; i<=DEV_INSTANCES; i++)); do
    pct=$((100 * (DEV_INSTANCES - i + 1) / (DEV_INSTANCES - i + 2)))
    new=$(tmux split-window -P -F '#{pane_id}' -t "$prev" -h -p "$pct")
    DEV_PANES+=("$new")
    prev="$new"
  done

  # Title each pane (for the tmux pane border).
  tmux select-pane -t "$TOP1" -T "reviewer"
  tmux select-pane -t "$TOP2" -T "dispatch:followup"
  tmux select-pane -t "$TOP3" -T "dispatch:conflicts"
  for ((i=1; i<=DEV_INSTANCES; i++)); do
    tmux select-pane -t "${DEV_PANES[$((i-1))]}" -T "dev-$i"
  done

  # Send the loop command to each pane. Don't `exec` — keeps the shell
  # alive after the loop dies (e.g., from Ctrl+C), so the user sees output.
  tmux send-keys -t "$TOP1" "cd '$REPO' && '$SCRIPT' --internal-role=reviewer $COMMON_ARGS" Enter
  tmux send-keys -t "$TOP2" "cd '$REPO' && '$SCRIPT' --internal-role=dispatch-followup $COMMON_ARGS" Enter
  tmux send-keys -t "$TOP3" "cd '$REPO' && '$SCRIPT' --internal-role=dispatch-conflicts $COMMON_ARGS" Enter
  for ((i=1; i<=DEV_INSTANCES; i++)); do
    tmux send-keys -t "${DEV_PANES[$((i-1))]}" "cd '$REPO' && '$SCRIPT' --internal-role=dev-$i $COMMON_ARGS" Enter
  done

  # Focus the first dev pane (most likely place for action).
  tmux select-pane -t "${DEV_PANES[0]}"

  # Schedule auto-stop if requested. Detached so it survives even if the
  # user never attaches or detaches early.
  if [ "$MAX_RUNTIME" -gt 0 ]; then
    nohup bash -c "sleep $MAX_RUNTIME && '$SCRIPT' stop" > /dev/null 2>&1 < /dev/null &
    disown 2>/dev/null || true
  fi

  echo "Session '$SESSION' started with $DEV_INSTANCES dev-agent worker(s)."
  echo "  Attach: $0 attach    (or just $0)"
  echo "  Stop:   $0 stop"
  if [ "$MAX_RUNTIME" -gt 0 ]; then
    echo "  Auto-stop scheduled in: ${MAX_RUNTIME}s"
  fi
  echo "  File a new issue:  sietch issue   (separate terminal — interactive)"

  if [ "$DETACH" -eq 0 ]; then
    echo "  Attaching now (Ctrl+B D to detach, Ctrl+B z to zoom a pane)..."
    sleep 1   # let panes settle and start their loops
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
  rm -rf "$DISPATCH_LOCK_DIR" 2>/dev/null
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
  start)  start_session ;;
  stop)   stop_session ;;
  attach) attach_session ;;
  status) show_status ;;
esac
