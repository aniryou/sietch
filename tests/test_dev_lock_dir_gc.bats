#!/usr/bin/env bats
# GH#139 — `$LOCK_DIR` (Mode-1 issue locks) had no PID-liveness GC: only the
# EXIT/INT/TERM trap in `runners/run-developer.sh` released claimed locks. A
# `SIGKILL` (or any crash that bypasses the trap) leaks a
# `${LOCK_NAME_PREFIX}gh-N.lock` indefinitely, and `eligibility_dev_count`
# (`runners/lib/eligibility.sh:148,256`) treats the leaked lock as a live
# claim, blocking that issue from any future Mode-1 cycle until a human runs
# `rm -rf` manually.
#
# Fix: add `cleanup_stale_dev_locks` to `runners/run-loop.sh`, mirroring
# `cleanup_stale_dispatch_locks`. Wired into `loop_dev_mode1` at the top of
# every cycle. The wrapper now stamps `$$` into `<lock>/pid` alongside the
# existing `run_id` and `started`, so the GC has a PID to test.
#
# Two layers of coverage, mirroring test_dispatch_lock_dir_heal.bats:
#   1. Behavioural: extract cleanup_stale_dev_locks from run-loop.sh, eval
#      it in the test shell, assert leaked locks with dead PIDs are GC'd.
#   2. Source-of-truth: text-level checks that the helper exists, is wired
#      into loop_dev_mode1, and that run-developer.sh stamps $$ into pid.

load 'helpers'

# Print the body of a top-level shell function from run-loop.sh, naively
# delimited by `^<name>() {` ... matching closing `^}`. Mirrors the helper in
# test_dispatch_lock_dir_heal.bats — every function-defining `}` sits in column 0.
_extract_function_body() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ ("^"name"\\(\\)[[:space:]]*\\{") { in_fn=1; next }
    in_fn && /^\}[[:space:]]*$/ { in_fn=0; exit }
    in_fn { print }
  ' "$LOOP_ROOT/runners/run-loop.sh"
}

# Eval the cleanup_stale_dev_locks function definition into the current
# shell. Returns 0 if the function got defined.
_load_cleanup_function() {
  local body
  body=$(_extract_function_body cleanup_stale_dev_locks)
  [ -n "$body" ] || return 1
  eval "cleanup_stale_dev_locks() { $body }"
}

# ---------------------------------------------------------------------------
# Layer 1 — behavioural: cleanup_stale_dev_locks GC's leaked dead-PID locks
# ---------------------------------------------------------------------------

@test "cleanup_stale_dev_locks: recreates LOCK_DIR when it is missing" {
  _load_cleanup_function
  local missing="$BATS_TEST_TMPDIR/locks-missing-$$"
  rm -rf "$missing"
  [ ! -d "$missing" ]

  LOCK_DIR="$missing" LOCK_NAME_PREFIX="test-" cleanup_stale_dev_locks

  [ -d "$missing" ]
}

@test "cleanup_stale_dev_locks: leaves an existing empty parent untouched" {
  _load_cleanup_function
  local existing="$BATS_TEST_TMPDIR/locks-empty-$$"
  mkdir -p "$existing"

  LOCK_DIR="$existing" LOCK_NAME_PREFIX="test-" cleanup_stale_dev_locks

  [ -d "$existing" ]
  [ -z "$(ls -A "$existing")" ]
}

@test "cleanup_stale_dev_locks: GCs stale own-prefix gh-N locks with dead PIDs (the GH#139 SIGKILL-leak path)" {
  _load_cleanup_function
  local parent="$BATS_TEST_TMPDIR/locks-stale-$$"
  mkdir -p "$parent"

  # Stale lock: own prefix, pid is a transient subshell that has already
  # exited. `( true ) & echo $! ; wait` gives us a definitely-dead PID
  # without racing. Avoid PID 0 (kill -0 0 signals the caller's pgid, which
  # is alive) and avoid hard-coded "definitely dead" values that could
  # collide with a real process on a long-uptime machine.
  local stale="$parent/test-gh-9999.lock"
  mkdir "$stale"
  ( true ) & local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  ! kill -0 "$dead_pid" 2>/dev/null  # sanity: pid is gone
  echo "$dead_pid" >"$stale/pid"
  echo "deadbeef" >"$stale/run_id"
  date -Iseconds >"$stale/started"

  # Live lock: own prefix, pid is the bats subshell ($$), which is alive.
  local live="$parent/test-gh-1234.lock"
  mkdir "$live"
  echo "$$" >"$live/pid"
  echo "alive" >"$live/run_id"
  date -Iseconds >"$live/started"

  LOCK_DIR="$parent" LOCK_NAME_PREFIX="test-" cleanup_stale_dev_locks

  [ ! -d "$stale" ]   # GC'd
  [ -d "$live" ]      # preserved
}

@test "cleanup_stale_dev_locks: foreign-prefix locks are left alone even when stale (multi-repo guard)" {
  # Mirrors GH#74 invariant: when LOCK_DIR is shared across misconfigured
  # repos, the prefix-glob keeps the GC scoped to OUR locks.
  _load_cleanup_function
  local parent="$BATS_TEST_TMPDIR/locks-foreign-$$"
  mkdir -p "$parent"

  local foreign="$parent/other-repo-gh-1234.lock"
  mkdir "$foreign"
  echo "0" >"$foreign/pid"  # dead pid, but foreign prefix → leave alone

  LOCK_DIR="$parent" LOCK_NAME_PREFIX="test-" cleanup_stale_dev_locks

  [ -d "$foreign" ]
}

@test "cleanup_stale_dev_locks: missing pid file is treated as stale (handles pre-fix leaked locks)" {
  # A leaked lock written by a wrapper from BEFORE the GH#139 pid-stamp
  # patch has no `pid` file at all. Treat it the same as a dead-PID lock so
  # an upgrade doesn't leave such locks orphaned forever. The window during
  # which a healthy wrapper exists with mkdir-but-not-yet-pid-write is
  # nanoseconds — a missed cleanup just means the next `loop_dev_mode1`
  # cycle catches it, and the lock auto-clears once the wrapper exits via
  # its trap anyway.
  _load_cleanup_function
  local parent="$BATS_TEST_TMPDIR/locks-no-pid-$$"
  mkdir -p "$parent"

  local stale="$parent/test-gh-42.lock"
  mkdir "$stale"
  echo "old-run-id" >"$stale/run_id"
  date -Iseconds >"$stale/started"
  # No pid file — pre-fix leak shape.

  LOCK_DIR="$parent" LOCK_NAME_PREFIX="test-" cleanup_stale_dev_locks

  [ ! -d "$stale" ]
}

# ---------------------------------------------------------------------------
# Layer 2 — source-of-truth: run-loop.sh / run-developer.sh body contents
# ---------------------------------------------------------------------------

@test "run-loop.sh: cleanup_stale_dev_locks is defined" {
  local body
  body=$(_extract_function_body cleanup_stale_dev_locks)
  [ -n "$body" ]
}

@test "run-loop.sh: cleanup_stale_dev_locks contains a 'mkdir -p \"\$LOCK_DIR\"' heal line" {
  local body
  body=$(_extract_function_body cleanup_stale_dev_locks)
  [ -n "$body" ]
  echo "$body" | grep -qE 'mkdir -p[[:space:]]+"\$LOCK_DIR"'
}

@test "run-loop.sh: cleanup_stale_dev_locks heal line precedes the '[ -d ... ] || return 0' fallback" {
  # The mkdir -p must run BEFORE the early-return guard, otherwise a missing
  # parent on the first cycle still bails out and the heal never fires.
  local body
  body=$(_extract_function_body cleanup_stale_dev_locks)
  [ -n "$body" ]
  local mkdir_lineno return_lineno
  mkdir_lineno=$(echo "$body" | grep -nE 'mkdir -p[[:space:]]+"\$LOCK_DIR"' | head -1 | cut -d: -f1)
  return_lineno=$(echo "$body" | grep -nE '\[ -d[[:space:]]+"\$LOCK_DIR"[[:space:]]+\][[:space:]]+\|\|[[:space:]]+return' | head -1 | cut -d: -f1)
  [ -n "$mkdir_lineno" ]
  [ -n "$return_lineno" ]
  [ "$mkdir_lineno" -lt "$return_lineno" ]
}

@test "run-loop.sh: cleanup_stale_dev_locks globs only own-prefix gh-* locks (multi-repo guard)" {
  local body
  body=$(_extract_function_body cleanup_stale_dev_locks)
  [ -n "$body" ]
  echo "$body" | grep -qE '\$LOCK_DIR.*\$\{?LOCK_NAME_PREFIX\}?.*gh-\*\.lock'
}

@test "run-loop.sh: loop_dev_mode1 calls cleanup_stale_dev_locks each cycle" {
  local body
  body=$(_extract_function_body loop_dev_mode1)
  [ -n "$body" ]
  echo "$body" | grep -qE 'cleanup_stale_dev_locks'
}

@test "run-developer.sh: wrapper stamps \$\$ into <lock>/pid alongside run_id" {
  # The PID-liveness GC requires the wrapper to write its own PID into the
  # lock dir. Without this, every fresh lock looks "stale" (no pid file)
  # and the GC would race the wrapper's own preflight.
  grep -qE 'echo[[:space:]]+"\$\$"[[:space:]]+>.*LOCK_NAME_PREFIX.*gh-.*\.lock/pid' "$LOOP_ROOT/runners/run-developer.sh"
}
