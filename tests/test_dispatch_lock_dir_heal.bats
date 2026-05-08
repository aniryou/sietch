#!/usr/bin/env bats
# GH#86 — When DISPATCH_LOCK_DIR (the parent of all per-PR dispatch locks) is
# missing for any reason — manual cleanup, fresh tmpfs, the session-teardown
# `rmdir` followed by a panes-still-alive state — every subsequent
# `mkdir "$lock"` in the dispatcher loops silently fails and no PR follow-up
# is ever dispatched. The fix:
#   1. cleanup_stale_dispatch_locks() recreates DISPATCH_LOCK_DIR on every
#      cycle (it is invoked at the top of both dispatcher loops).
#   2. The per-PR `mkdir "$lock"` in loop_dispatcher_followup and
#      loop_dispatcher_conflicts has an `elif [ ! -d "$lock" ]` branch that
#      logs WARN — distinguishing a genuine mkdir failure from a legitimate
#      EEXIST skip.
#
# Two layers of coverage, mirroring test_dispatcher_resource.bats:
#   1. Behavioural: extract cleanup_stale_dispatch_locks from run-loop.sh,
#      eval it in the test shell, assert DISPATCH_LOCK_DIR is recreated when
#      missing.
#   2. Source-of-truth: text-level check that the heal line and the WARN-on-
#      non-EEXIST-mkdir-failure branch are present in run-loop.sh.

load 'helpers'

# Print the body of a top-level shell function from run-loop.sh, naively
# delimited by `^<name>() {` ... matching closing `^}`. Mirrors the helper in
# test_dispatcher_resource.bats — every function-defining `}` sits in column 0.
_extract_function_body() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ ("^"name"\\(\\)[[:space:]]*\\{") { in_fn=1; next }
    in_fn && /^\}[[:space:]]*$/ { in_fn=0; exit }
    in_fn { print }
  ' "$LOOP_ROOT/runners/run-loop.sh"
}

# Eval the cleanup_stale_dispatch_locks function definition into the current
# shell. Returns 0 if the function got defined.
_load_cleanup_function() {
  local body
  body=$(_extract_function_body cleanup_stale_dispatch_locks)
  [ -n "$body" ] || return 1
  eval "cleanup_stale_dispatch_locks() { $body }"
}

# ---------------------------------------------------------------------------
# Layer 1 — behavioural: cleanup_stale_dispatch_locks heals a missing parent
# ---------------------------------------------------------------------------

@test "cleanup_stale_dispatch_locks: recreates DISPATCH_LOCK_DIR when it is missing" {
  _load_cleanup_function
  local missing="$BATS_TEST_TMPDIR/dispatched-missing-$$"
  rm -rf "$missing"
  [ ! -d "$missing" ]

  DISPATCH_LOCK_DIR="$missing" LOCK_NAME_PREFIX="test-" cleanup_stale_dispatch_locks

  [ -d "$missing" ]
}

@test "cleanup_stale_dispatch_locks: leaves an existing empty parent untouched" {
  _load_cleanup_function
  local existing="$BATS_TEST_TMPDIR/dispatched-empty-$$"
  mkdir -p "$existing"

  DISPATCH_LOCK_DIR="$existing" LOCK_NAME_PREFIX="test-" cleanup_stale_dispatch_locks

  [ -d "$existing" ]
  # Still empty — function should not have created any spurious files.
  [ -z "$(ls -A "$existing")" ]
}

@test "cleanup_stale_dispatch_locks: still GCs stale own-prefix locks with dead PIDs (no regression)" {
  _load_cleanup_function
  local parent="$BATS_TEST_TMPDIR/dispatched-stale-$$"
  mkdir -p "$parent"

  # Stale lock: own prefix, pid is a transient subshell that has already
  # exited by the time we read it. `( true ) & echo $! ; wait` gives us a
  # definitely-dead PID without racing. We avoid PID 0 (kill -0 0 signals
  # the caller's pgid, which is alive) and avoid hard-coded "definitely
  # dead" values that could collide with a real process on a long-uptime
  # machine.
  local stale="$parent/test-pr-9999-followup.lock"
  mkdir "$stale"
  ( true ) & local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  # Sanity: the PID is gone.
  ! kill -0 "$dead_pid" 2>/dev/null
  echo "$dead_pid" > "$stale/pid"

  # Live lock: own prefix, pid is the bats subshell ($$), which is alive.
  local live="$parent/test-pr-1234-followup.lock"
  mkdir "$live"
  echo "$$" > "$live/pid"

  DISPATCH_LOCK_DIR="$parent" LOCK_NAME_PREFIX="test-" cleanup_stale_dispatch_locks

  # Stale removed; live preserved.
  [ ! -d "$stale" ]
  [ -d "$live" ]
}

@test "cleanup_stale_dispatch_locks: foreign-prefix locks are left alone even when stale (multi-repo guard)" {
  # Mirrors GH#74 invariant: when DISPATCH_LOCK_DIR is shared across
  # misconfigured repos, the prefix-glob keeps the GC scoped to OUR locks.
  _load_cleanup_function
  local parent="$BATS_TEST_TMPDIR/dispatched-foreign-$$"
  mkdir -p "$parent"

  local foreign="$parent/other-repo-pr-1234-followup.lock"
  mkdir "$foreign"
  echo "0" > "$foreign/pid"  # dead pid, but foreign prefix → leave alone

  DISPATCH_LOCK_DIR="$parent" LOCK_NAME_PREFIX="test-" cleanup_stale_dispatch_locks

  [ -d "$foreign" ]
}

# ---------------------------------------------------------------------------
# Layer 2 — source-of-truth: run-loop.sh body contents
# ---------------------------------------------------------------------------

@test "run-loop.sh: cleanup_stale_dispatch_locks contains a 'mkdir -p \"\$DISPATCH_LOCK_DIR\"' heal line" {
  local body
  body=$(_extract_function_body cleanup_stale_dispatch_locks)
  [ -n "$body" ]
  echo "$body" | grep -qE 'mkdir -p[[:space:]]+"\$DISPATCH_LOCK_DIR"'
}

@test "run-loop.sh: cleanup_stale_dispatch_locks heal line precedes the '[ -d ... ] || return 0' fallback" {
  # The mkdir -p must run BEFORE the early-return guard, otherwise a missing
  # parent on the first cycle still bails out and the heal never fires.
  local body
  body=$(_extract_function_body cleanup_stale_dispatch_locks)
  [ -n "$body" ]
  local mkdir_lineno return_lineno
  mkdir_lineno=$(echo "$body" | grep -nE 'mkdir -p[[:space:]]+"\$DISPATCH_LOCK_DIR"' | head -1 | cut -d: -f1)
  return_lineno=$(echo "$body" | grep -nE '\[ -d[[:space:]]+"\$DISPATCH_LOCK_DIR"[[:space:]]+\][[:space:]]+\|\|[[:space:]]+return' | head -1 | cut -d: -f1)
  [ -n "$mkdir_lineno" ]
  [ -n "$return_lineno" ]
  [ "$mkdir_lineno" -lt "$return_lineno" ]
}

@test "run-loop.sh: loop_dispatcher_followup distinguishes EEXIST skip from genuine mkdir failure" {
  # The fix adds an `elif [ ! -d "$lock" ]` branch so a non-EEXIST mkdir
  # failure (parent missing, permissions, etc.) emits a WARN line. EEXIST
  # is still the silent legitimate-skip path.
  local body
  body=$(_extract_function_body loop_dispatcher_followup)
  [ -n "$body" ]
  # The WARN literal — keep it grep-stable so a future copy-paste survives.
  echo "$body" | grep -qE 'WARN: mkdir failed for PR'
  echo "$body" | grep -qE 'elif[[:space:]]+\[[[:space:]]+!.*-d[[:space:]]+"\$lock"'
}

@test "run-loop.sh: loop_dispatcher_conflicts distinguishes EEXIST skip from genuine mkdir failure" {
  local body
  body=$(_extract_function_body loop_dispatcher_conflicts)
  [ -n "$body" ]
  echo "$body" | grep -qE 'WARN: mkdir failed for PR'
  echo "$body" | grep -qE 'elif[[:space:]]+\[[[:space:]]+!.*-d[[:space:]]+"\$lock"'
}

# ---------------------------------------------------------------------------
# Layer 3 — pattern-in-isolation: mirrors the dispatcher's lock-acquire shape
# and verifies that the new error-discrimination pattern emits a WARN line on
# a real (non-EEXIST) mkdir failure, while staying silent on EEXIST.
# ---------------------------------------------------------------------------

@test "lock-acquire pattern: silent on EEXIST (legitimate skip)" {
  local parent="$BATS_TEST_TMPDIR/dispatched-eexist-$$"
  mkdir -p "$parent"
  local lock="$parent/loop-pr-7-followup.lock"
  mkdir "$lock"  # pre-create — simulates a prior cycle still holding the lock

  local out
  out=$(
    set -u
    if mkdir "$lock" 2>/dev/null; then
      echo "DISPATCHED"
    elif [ ! -d "$lock" ]; then
      echo "WARN: mkdir failed for PR #7"
    fi
  )

  # Neither dispatched nor warned — the silent EEXIST path.
  [ -z "$out" ]
}

@test "lock-acquire pattern: WARN on non-EEXIST mkdir failure (parent missing)" {
  local missing_parent="$BATS_TEST_TMPDIR/dispatched-missing-parent-$$"
  rm -rf "$missing_parent"
  [ ! -d "$missing_parent" ]
  local lock="$missing_parent/loop-pr-7-followup.lock"

  local out
  out=$(
    set -u
    if mkdir "$lock" 2>/dev/null; then
      echo "DISPATCHED"
    elif [ ! -d "$lock" ]; then
      echo "WARN: mkdir failed for PR #7"
    fi
  )

  [ "$out" = "WARN: mkdir failed for PR #7" ]
}
