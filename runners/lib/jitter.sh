#!/usr/bin/env bash
# lib/jitter.sh — Random startup jitter for parallel dev workers.
#
# Used by `loop_dev_mode1` to de-converge multiple instances that would
# otherwise wake from `tmux send-keys` simultaneously and waste cycles
# racing for the same eligible issues. Each worker gets a unique phase
# offset that persists across cycles, since they all sleep the same fixed
# POLL_INTERVAL afterwards.
#
# Function:
#   dev_startup_jitter <poll_interval>
#     Echo a random integer in [1, poll_interval] (inclusive).
#
# CLI:
#   jitter.sh <poll_interval>           # print one value
#   jitter.sh <poll_interval> <count>   # print COUNT values, one per line
#
# Notes:
#   - With POLL_INTERVAL=1 the value is always 1 (degenerate range).
#   - Sampling happens via bash's `$RANDOM`; the CLI accepts COUNT to make
#     uniformity testable in a single bash process (one RANDOM sequence).

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

dev_startup_jitter() {
  local poll="${1:-}"
  if [ -z "$poll" ] || ! [[ "$poll" =~ ^[0-9]+$ ]] || [ "$poll" -lt 1 ]; then
    echo "[jitter] poll_interval must be a positive integer (got: '${1:-}')" >&2
    return 2
  fi
  echo $(( (RANDOM % poll) + 1 ))
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  poll="${1:-}"
  count="${2:-1}"
  if [ -z "$poll" ]; then
    echo "Usage: jitter.sh <poll_interval> [count]" >&2
    exit 2
  fi
  if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
    echo "[jitter] count must be a positive integer (got: '$count')" >&2
    exit 2
  fi
  for ((__i=0; __i<count; __i++)); do
    dev_startup_jitter "$poll" || exit $?
  done
fi
