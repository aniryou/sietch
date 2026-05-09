#!/usr/bin/env bash
# lib/jitter.sh — Random jitter helpers for parallel dev workers.
#
# Used by `loop_dev_mode1` and `empty_cycle_sleep` in run-loop.sh to
# de-converge N parallel instances that would otherwise wake in lockstep
# and waste cycles racing for the same eligible issues / locks.
#
# Functions:
#   dev_startup_jitter <poll_interval>
#     Random integer in [1, poll_interval]. Used once per dev pane at
#     startup to phase-shift workers that all wake from `tmux send-keys`
#     in the same instant.
#
#   apply_additive_jitter <interval>
#     Returns interval + RANDOM%(interval/4 + 1) — i.e. the input plus up
#     to 25% additive jitter. Strictly ≥ interval (never subtracts), so
#     callers using this on a backoff-cap value still respect the cap as
#     a floor. At interval ≤ 3 the formula degenerates to the input
#     unchanged (no jitter).
#
# CLI:
#   jitter.sh <poll_interval>                       # one startup value
#   jitter.sh <poll_interval> <count>               # COUNT startup values
#   jitter.sh additive <interval>                   # one jittered value
#   jitter.sh additive <interval> <count>           # COUNT jittered values
#
# Notes:
#   - Sampling happens via bash's `$RANDOM`; the CLI accepts COUNT to make
#     uniformity testable in a single bash process (one RANDOM sequence).

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"

dev_startup_jitter() {
  local poll="${1:-}"
  if [ -z "$poll" ] || ! [[ "$poll" =~ ^[0-9]+$ ]] || [ "$poll" -lt 1 ]; then
    echo "[jitter] poll_interval must be a positive integer (got: '${1:-}')" >&2
    return 2
  fi
  echo $(((RANDOM % poll) + 1))
}

apply_additive_jitter() {
  local interval="${1:-}"
  if [ -z "$interval" ] || ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ]; then
    echo "[jitter] interval must be a positive integer (got: '${1:-}')" >&2
    return 2
  fi
  # interval/4 is integer-truncated, so for interval ∈ {1,2,3} the modulus
  # is 1 and the jitter is always 0 — degenerate but safe.
  local span=$((interval / 4 + 1))
  echo $((interval + (RANDOM % span)))
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = "additive" ]; then
    shift
    interval="${1:-}"
    count="${2:-1}"
    if [ -z "$interval" ]; then
      echo "Usage: jitter.sh additive <interval> [count]" >&2
      exit 2
    fi
    if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
      echo "[jitter] count must be a positive integer (got: '$count')" >&2
      exit 2
    fi
    for ((__i = 0; __i < count; __i++)); do
      apply_additive_jitter "$interval" || exit $?
    done
    exit 0
  fi

  poll="${1:-}"
  count="${2:-1}"
  if [ -z "$poll" ]; then
    echo "Usage: jitter.sh <poll_interval> [count]" >&2
    echo "       jitter.sh additive <interval> [count]" >&2
    exit 2
  fi
  if ! [[ "$count" =~ ^[1-9][0-9]*$ ]]; then
    echo "[jitter] count must be a positive integer (got: '$count')" >&2
    exit 2
  fi
  for ((__i = 0; __i < count; __i++)); do
    dev_startup_jitter "$poll" || exit $?
  done
fi
