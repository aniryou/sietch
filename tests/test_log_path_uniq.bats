#!/usr/bin/env bats
# GH#32 — wrapper log paths must be unique per invocation, not just per second.
#
# Bug: `runners/run-developer.sh` and `runners/run-reviewer.sh` both compute
#   TS="$(date +%Y%m%d-%H%M%S)"
# and use ${TS} in every LOG=/RAW= path. Two wrappers started in the same
# second collide on /tmp/{dev-agent,reviewer-agent}-${TS}.{log,jsonl} and
# produce interleaved output that is impossible to attribute back to a single
# wrapper run.
#
# Fix: append $$ (parent PID, unique per process) to TS so co-second wrappers
# get distinct log files.
#
# Two layers:
#   1. Source-of-truth: TS lines in both wrappers carry $$ (or $DEV_AGENT_RUN_ID).
#   2. Behavioral: three parallel bash invocations computing TS the same way the
#      wrapper does produce three distinct LOG paths.

load 'helpers'

# ---------------------------------------------------------------------------
# Layer 1 — source-of-truth
# ---------------------------------------------------------------------------

@test "run-developer.sh: TS includes a per-process suffix (\$\$ or \$DEV_AGENT_RUN_ID)" {
  grep -E '^TS=.*(\$\$|DEV_AGENT_RUN_ID)' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: TS does NOT use bare second-resolution timestamp (GH#32 regression guard)" {
  # The exact stripped form `TS="$(date +%Y%m%d-%H%M%S)"` must not reappear.
  ! grep -E '^TS="\$\(date \+%Y%m%d-%H%M%S\)"$' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh: TS includes a per-process suffix (\$\$ or \$DEV_AGENT_RUN_ID)" {
  grep -E '^TS=.*(\$\$|DEV_AGENT_RUN_ID)' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-reviewer.sh: TS does NOT use bare second-resolution timestamp (GH#32 regression guard)" {
  ! grep -E '^TS="\$\(date \+%Y%m%d-%H%M%S\)"$' "$LOOP_ROOT/runners/run-reviewer.sh"
}

# ---------------------------------------------------------------------------
# Layer 2 — behavioral
# ---------------------------------------------------------------------------

@test "GH#32 behavioral: three same-second bash invocations produce distinct LOG paths" {
  # Each `bash -c` is a fresh process, so $$ inside it is unique per
  # invocation. Even if all three land in the same wall-clock second
  # (the bug condition), the $$ suffix keeps the file paths disjoint.
  local d="$BATS_TEST_TMPDIR/wraprace-$$"
  mkdir -p "$d"

  for _ in 1 2 3; do
    bash -c "
      TS=\"\$(date +%Y%m%d-%H%M%S)-\$\$\"
      touch \"$d/dev-agent-\${TS}.log\"
    " &
  done
  wait

  local count
  count=$(find "$d" -maxdepth 1 -name 'dev-agent-*.log' | wc -l | tr -d ' ')
  [ "$count" -eq 3 ]
}
