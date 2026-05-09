#!/usr/bin/env bash
# lib/pipeline_signal.sh — Helpers for forwarding SIGTERM/SIGINT from a
# wrapper bash to a backgrounded pipeline (claude | tee | jq | tee).
#
# Why this exists
# ---------------
# The wrappers run a foreground pipeline. When bash is waiting for a
# foreground command and receives a signal for which a trap is set, the
# trap is deferred until the command completes (per `man bash`):
#
#   "If bash is waiting for a command to complete and receives a signal for
#    which a trap has been set, the trap will not be executed until the
#    command completes."
#
# The signal is delivered to bash itself, not to the pipeline children, so
# `claude`/`tee`/`jq` keep running and the pipe stays open — meaning bash's
# `waitpid` never returns and the trap is permanently queued. External
# `kill <wrapper-pid>` therefore hangs the wrapper indefinitely.
#
# The fix in the wrappers is to background the pipeline in a subshell with
# `set -m` (so the subshell becomes its own process group leader) and use
# the bash `wait` builtin, which IS signal-interruptible:
#
#   "When bash is waiting for an asynchronous command via the wait builtin,
#    the reception of a signal for which a trap has been set will cause the
#    wait builtin to return immediately with an exit status greater than
#    128, immediately after which the trap is executed."
#
# The trap then forwards the signal to the pipeline's process group via the
# helpers below, so claude/tee/jq actually exit. Without that forwarding,
# `wait` would unblock but the children would still be alive and re-parent
# to PID 1 when bash exits.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"

# Capture the process-group ID of a backgrounded pipeline.
#
# Under `set -m` (job control), a backgrounded subshell becomes its own
# pgroup leader: the pgid equals the subshell's PID. We resolve it via
# `ps` to be portable across bash versions where $! semantics differ
# (last command in pipeline vs. subshell), and fall back to the PID
# itself if `ps` fails.
#
# Args:  $1 = PID of the backgrounded subshell (i.e. $!).
# Stdout: numeric pgid (or the input PID as fallback).
pipeline_capture_pgid() {
  local pid=${1:-}
  [ -n "$pid" ] || {
    echo ""
    return
  }
  local pgid
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ')
  echo "${pgid:-$pid}"
}

# Kill an entire process group with TERM, give it up to ~2s to exit, then
# SIGKILL whatever's left. Idempotent and safe to call repeatedly.
#
# Args:  $1 = pgid (numeric). Empty / unset → no-op.
# Side effect: pipeline children (claude, tee, jq, …) die.
pipeline_kill_pgroup_if_alive() {
  local pgid=${1:-}
  [ -n "$pgid" ] || return 0
  # `kill -0 -- -<pgid>` checks whether ANY process in the pgroup is alive.
  kill -0 -- -"$pgid" 2>/dev/null || return 0

  kill -TERM -- -"$pgid" 2>/dev/null || true

  # Up to 2 seconds (20 * 0.1s) for graceful shutdown on TERM.
  local _t=0
  while [ "$_t" -lt 20 ] && kill -0 -- -"$pgid" 2>/dev/null; do
    sleep 0.1
    _t=$((_t + 1))
  done

  if kill -0 -- -"$pgid" 2>/dev/null; then
    kill -KILL -- -"$pgid" 2>/dev/null || true
  fi
}
