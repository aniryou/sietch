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

# -- apply_additive_jitter / empty_cycle_sleep (GH#29) ---------------------
#
# Backoff jitter de-converges parallel dev panes once they all hit the
# EMPTY_CYCLE_BACKOFF_CAP_SECONDS cap. Without it, N panes wake in lockstep
# every cycle, race for the same lock, and burn N-1× the cost.
#
# Contract (additive — never below base):
#   apply_additive_jitter <interval>  -> [interval, interval + interval/4]
# At interval ≤ 3 the formula degenerates to [interval, interval] (no jitter)
# because POLL_INTERVAL has a hard min of 10 in run-loop.sh, this never
# bites at runtime — but the helper is well-defined for those inputs too.

@test "apply_additive_jitter: 50 samples with interval=60 stay in [60, 75]" {
  local out v
  out=$(bash "$JITTER" additive 60 50)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 50 ]
  while IFS= read -r v; do
    [ "$v" -ge 60 ]
    [ "$v" -le 75 ]
  done <<<"$out"
}

@test "apply_additive_jitter: 50 samples with interval=300 stay in [300, 375]" {
  # Cap behavior — at the exponential-backoff ceiling, jitter must add
  # *up to* 25%, never subtract. A value below 300 means we slept less than
  # the configured cap, which violates the backoff contract.
  local out v
  out=$(bash "$JITTER" additive 300 50)
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 50 ]
  while IFS= read -r v; do
    [ "$v" -ge 300 ]
    [ "$v" -le 375 ]
  done <<<"$out"
}

@test "apply_additive_jitter: 50 samples cover at least 30% of the jitter range" {
  # n=50 samples over 16 buckets [60..75] — expected coverage ~13.5.
  # Set the bound at 5 distinct (≥ 30% of 16) to keep the test stable;
  # if jitter is missing, distinct=1 and the test fails loudly.
  local out distinct
  out=$(bash "$JITTER" additive 60 50)
  distinct=$(printf '%s\n' "$out" | sort -u | wc -l | tr -d ' ')
  [ "$distinct" -ge 5 ]
}

@test "apply_additive_jitter: never returns below the base interval (additive guard)" {
  # Regression guard for the bidirectional-jitter mistake. Backoff exists to
  # keep the loop quiet — jitter that subtracts seconds defeats the cap and
  # re-introduces thunder at the lower edge of the window.
  local out v
  out=$(bash "$JITTER" additive 60 100)
  while IFS= read -r v; do
    [ "$v" -ge 60 ]
  done <<<"$out"
}

@test "apply_additive_jitter: interval=4 yields [4, 5]" {
  # Smallest interval where the formula produces a non-trivial range
  # (4/4 = 1, RANDOM % 2 ∈ {0,1}). Guards the divide-by-zero edge.
  local out v
  out=$(bash "$JITTER" additive 4 30)
  while IFS= read -r v; do
    [ "$v" -ge 4 ]
    [ "$v" -le 5 ]
  done <<<"$out"
}

@test "apply_additive_jitter: interval=1 always yields 1 (no divide-by-zero)" {
  local out v
  out=$(bash "$JITTER" additive 1 20)
  while IFS= read -r v; do
    [ "$v" -eq 1 ]
  done <<<"$out"
}

@test "apply_additive_jitter: missing interval exits non-zero" {
  run bash "$JITTER" additive
  [ "$status" -ne 0 ]
}

@test "apply_additive_jitter: non-numeric interval exits non-zero" {
  run bash "$JITTER" additive abc
  [ "$status" -ne 0 ]
}

@test "empty_cycle_sleep references RANDOM (jitter applied at backoff time)" {
  # Source-of-truth: the empty_cycle_sleep function in run-loop.sh must
  # invoke jitter — either directly via `RANDOM` or by calling the helper.
  # Anchored to the function body so a stray `RANDOM` elsewhere doesn't
  # mask removal of the jitter logic.
  local fn_block
  fn_block=$(awk '/^empty_cycle_sleep\(\)/,/^\}$/' "$LOOP_ROOT/runners/run-loop.sh")
  [ -n "$fn_block" ]
  printf '%s\n' "$fn_block" | grep -E 'apply_additive_jitter|RANDOM'
}

@test "empty_cycle_sleep returns jittered value (end-to-end through run-loop.sh)" {
  # Extract the function body from run-loop.sh and exercise it in a clean
  # bash subshell. This is the closest we can get to testing the actual
  # call site without spinning up the full loop wrapper.
  local fn_block out v
  fn_block=$(awk '/^empty_cycle_sleep\(\)/,/^\}$/' "$LOOP_ROOT/runners/run-loop.sh")
  [ -n "$fn_block" ]
  # Source jitter.sh first so apply_additive_jitter is in scope, then
  # define empty_cycle_sleep and call it 30 times at streak 5 (clamped
  # to cap=300 → jittered range [300, 375]).
  out=$(bash -c "
    source '$LOOP_ROOT/runners/lib/jitter.sh'
    POLL_INTERVAL=60
    EMPTY_CYCLE_BACKOFF_CAP_SECONDS=300
    $fn_block
    for _ in \$(seq 1 30); do empty_cycle_sleep 5; done
  ")
  [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" -eq 30 ]
  # All in [300, 375] (cap + 25%).
  while IFS= read -r v; do
    [ "$v" -ge 300 ]
    [ "$v" -le 375 ]
  done <<<"$out"
  # Distinct count must be > 1 — proves jitter is actually applied, not
  # accidentally hard-coded to 0.
  local distinct
  distinct=$(printf '%s\n' "$out" | sort -u | wc -l | tr -d ' ')
  [ "$distinct" -gt 1 ]
}
