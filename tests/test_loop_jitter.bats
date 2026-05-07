#!/usr/bin/env bats
# jitter.sh — startup jitter for parallel dev workers (loop-k8u, GH#9).
#
# Verifies the formula `(RANDOM % POLL_INTERVAL) + 1`:
#   - lands in the inclusive range [1, POLL_INTERVAL]
#   - produces variation across calls (rough uniformity)
#   - degenerates to 1 when POLL_INTERVAL=1
#   - errors when invoked without an argument
#
# The 50 samples in a single bash process come from one RANDOM sequence,
# so they reflect the actual sampling the loop will perform — not 50
# fresh subshells each reseeded from PID+time.

load 'helpers'

JITTER="$LOOP_ROOT/runners/lib/jitter.sh"

@test "jitter: 50 samples with POLL_INTERVAL=60 stay in [1, 60]" {
  local out v
  out=$(bash "$JITTER" 60 50)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 50 ]
  while IFS= read -r v; do
    [ "$v" -ge 1 ]
    [ "$v" -le 60 ]
  done <<< "$out"
}

@test "jitter: 50 samples with POLL_INTERVAL=60 cover at least 30% of [1..60]" {
  # 30% (≥ 18 distinct) is a generous lower bound; n=50 against 60 buckets
  # has expected coverage ~34. Strict 80% (48) would flake regularly.
  local out
  out=$(bash "$JITTER" 60 50)
  local distinct
  distinct=$(printf '%s\n' "$out" | sort -u | wc -l | tr -d ' ')
  [ "$distinct" -ge 18 ]
}

@test "jitter: POLL_INTERVAL=1 always yields 1" {
  local out v
  out=$(bash "$JITTER" 1 20)
  while IFS= read -r v; do
    [ "$v" -eq 1 ]
  done <<< "$out"
}

@test "jitter: missing argument exits non-zero" {
  run bash "$JITTER"
  [ "$status" -ne 0 ]
}

@test "jitter: count defaults to 1 when omitted" {
  local out
  out=$(bash "$JITTER" 60)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 1 ]
}

@test "loop_dev_mode1 logs startup jitter line before first cycle" {
  # Spot-check the integration: when run-loop.sh sources jitter.sh, the
  # `[dev-N] startup jitter: sleeping <S>s before first cycle` log line
  # must appear before the first 'starting Mode 1 cycle' line.
  grep -n 'startup jitter: sleeping' "$LOOP_ROOT/runners/run-loop.sh"
  grep -n 'starting Mode 1 cycle' "$LOOP_ROOT/runners/run-loop.sh"
  # Jitter line lives strictly above the while-true.
  local jitter_line cycle_line
  jitter_line=$(grep -n 'startup jitter: sleeping' "$LOOP_ROOT/runners/run-loop.sh" | head -1 | cut -d: -f1)
  cycle_line=$(grep -n 'starting Mode 1 cycle' "$LOOP_ROOT/runners/run-loop.sh" | head -1 | cut -d: -f1)
  [ -n "$jitter_line" ]
  [ -n "$cycle_line" ]
  [ "$jitter_line" -lt "$cycle_line" ]
}
