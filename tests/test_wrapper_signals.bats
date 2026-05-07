#!/usr/bin/env bats
# Wrapper signal handling — verify run-developer.sh and run-reviewer.sh exit
# promptly on external SIGTERM/SIGINT and don't leave orphaned children.
#
# The wrappers run `claude | tee | jq | tee` as a foreground pipeline, which
# (per bash docs) defers any trap until the pipeline drains. An external
# `kill <wrapper-pid>` therefore hangs the wrapper indefinitely. The fix
# backgrounds the pipeline in a subshell with `set -m` (own pgroup) and
# uses `wait` (signal-interruptible) so the trap fires immediately and
# can forward TERM/KILL to the whole pipeline group.
#
# Tests use a minimal stand-in wrapper that exercises the exact pattern
# (sourcing runners/lib/pipeline_signal.sh) — we can't run the real
# wrappers in CI because they invoke `claude`. Source-of-truth grep tests
# at the bottom enforce that the production wrappers stay on the pattern.

load 'helpers'

# Build a minimal wrapper that mirrors run-developer.sh's signal pattern but
# uses `sleep 30` in place of the claude pipeline so we can deterministically
# signal it mid-run.
_make_test_wrapper() {
  local script="$BATS_TEST_TMPDIR/fake-wrapper.sh"
  cat >"$script" <<EOSH
#!/usr/bin/env bash
set -u
set -o pipefail

# shellcheck source=/dev/null
. "$LOOP_ROOT/runners/lib/pipeline_signal.sh"

PIPELINE_PID=""
PIPELINE_PGID=""

cleanup() {
  local exit_code=\$?
  pipeline_kill_pgroup_if_alive "\${PIPELINE_PGID:-}"
  exit "\$exit_code"
}
trap cleanup EXIT INT TERM

set -m
(
  # Two-stage pipeline mimics claude | tee | jq | tee in shape: a long
  # producer feeding two consumers via tee. SIGTERM to the wrapper alone
  # would not propagate to these without our pgroup-kill logic.
  sleep 30 | tee /dev/null | tee /dev/null
) &
PIPELINE_PID=\$!
PIPELINE_PGID=\$(pipeline_capture_pgid "\$PIPELINE_PID")
set +m

# Mark ready so the test knows the pipeline is up.
echo "READY pgid=\$PIPELINE_PGID" > "$BATS_TEST_TMPDIR/ready"

wait "\$PIPELINE_PID"
EOSH
  chmod +x "$script"
  echo "$script"
}

# Wait until the wrapper has launched the pipeline and printed the READY line.
_wait_ready() {
  local i=0
  while [ "$i" -lt 50 ] && [ ! -s "$BATS_TEST_TMPDIR/ready" ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -s "$BATS_TEST_TMPDIR/ready" ]
}

# Wait up to N tenths-of-a-second for $1 (a PID) to no longer be alive.
_wait_dead() {
  local pid=$1 ticks=$2 i=0
  while [ "$i" -lt "$ticks" ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    i=$((i + 1))
  done
  ! kill -0 "$pid" 2>/dev/null
}

# After the wrapper exits, confirm none of the pipeline children survived as
# orphans re-parented to PID 1.
_no_pgroup_orphans() {
  local pgid=$1
  ! pgrep -g "$pgid" >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# Functional tests — the pattern actually interrupts on signals.
# ---------------------------------------------------------------------------

@test "wrapper signals: SIGTERM tears down pipeline within 5s, no orphans" {
  local wrapper pgid
  wrapper=$(_make_test_wrapper)
  "$wrapper" </dev/null >/dev/null 2>&1 &
  local wpid=$!

  _wait_ready
  pgid=$(awk '{print $2}' "$BATS_TEST_TMPDIR/ready" | sed 's/pgid=//')
  [ -n "$pgid" ]

  kill -TERM "$wpid"

  _wait_dead "$wpid" 50  # 5 seconds
  _no_pgroup_orphans "$pgid"
}

# Note on SIGINT: per `man bash`, "When job control is not in effect,
# asynchronous commands ignore SIGINT and SIGQUIT", and "Signals ignored upon
# entry to the shell cannot be trapped or reset." Bats spawns tests in a non-
# interactive bash without job control, so any wrapper we launch with `&`
# starts with SIGINT set to SIG_IGN and `trap '...' INT` becomes a no-op for
# THAT process — and the SAME constraint holds in production whenever the
# wrapper is launched as a backgrounded subshell from a non-interactive
# parent (e.g. `run-loop.sh`'s dispatcher: `( run-developer.sh ... ) &`). In
# those scripted contexts `kill -INT <wrapper-pid>` is silently ignored. The
# wrapper's `trap cleanup INT` IS effective when the parent has job control
# on (interactive tmux pane, `bash -i`, login shell) — Ctrl+C in a tmux
# pane signals the whole pgroup and works end-to-end. SIGTERM is portable
# across all launch contexts; see templates/developer.md "Supported kill
# mechanisms" for the full breakdown. We verify SIGINT trap-registration
# via the source-of-truth grep tests below and rely on the SIGTERM
# functional test above to prove the wait/pgroup-kill mechanism — both
# signals share the same code path once delivered.

@test "wrapper signals: natural exit (no signal) still works — pipeline ends, wrapper exits 0-or-pipeline-rc" {
  # Replace the long sleep with a fast-exit producer so the pipeline ends on
  # its own. The wrapper should exit normally without the trap killing
  # anything (kill_pgroup_if_alive is a no-op when pgroup is already dead).
  local script="$BATS_TEST_TMPDIR/fake-wrapper-fast.sh"
  cat >"$script" <<EOSH
#!/usr/bin/env bash
set -u
set -o pipefail
. "$LOOP_ROOT/runners/lib/pipeline_signal.sh"
PIPELINE_PID=""
PIPELINE_PGID=""
cleanup() {
  local rc=\$?
  pipeline_kill_pgroup_if_alive "\${PIPELINE_PGID:-}"
  exit "\$rc"
}
trap cleanup EXIT INT TERM
set -m
( echo hello | tee /dev/null | tee /dev/null ) &
PIPELINE_PID=\$!
PIPELINE_PGID=\$(pipeline_capture_pgid "\$PIPELINE_PID")
set +m
wait "\$PIPELINE_PID"
EOSH
  chmod +x "$script"

  run "$script"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Lib unit tests — pipeline_signal.sh helpers behave correctly in isolation.
# ---------------------------------------------------------------------------

@test "pipeline_capture_pgid: returns a numeric pgid for a running PID" {
  # shellcheck source=/dev/null
  . "$LOOP_ROOT/runners/lib/pipeline_signal.sh"
  sleep 5 &
  local pid=$!
  local pgid
  pgid=$(pipeline_capture_pgid "$pid")
  [[ "$pgid" =~ ^[0-9]+$ ]]
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

@test "pipeline_capture_pgid: falls back to PID when ps fails" {
  # shellcheck source=/dev/null
  . "$LOOP_ROOT/runners/lib/pipeline_signal.sh"
  # PID 999999 almost certainly doesn't exist; ps returns nothing → fallback.
  local pgid
  pgid=$(pipeline_capture_pgid "999999")
  [ "$pgid" = "999999" ]
}

@test "pipeline_kill_pgroup_if_alive: empty pgid is a no-op (no error)" {
  # shellcheck source=/dev/null
  . "$LOOP_ROOT/runners/lib/pipeline_signal.sh"
  pipeline_kill_pgroup_if_alive ""
  pipeline_kill_pgroup_if_alive
}

@test "pipeline_kill_pgroup_if_alive: dead pgid is a no-op (no error)" {
  # shellcheck source=/dev/null
  . "$LOOP_ROOT/runners/lib/pipeline_signal.sh"
  pipeline_kill_pgroup_if_alive "999999"
}

# ---------------------------------------------------------------------------
# Source-of-truth checks — production wrappers must use the new pattern.
# Without these, a future refactor could silently revert to the broken
# foreground-pipeline shape and CI would still pass the functional tests.
# ---------------------------------------------------------------------------

@test "run-developer.sh: sources pipeline_signal.sh" {
  grep -qF 'pipeline_signal.sh' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: backgrounds the claude pipeline (uses set -m + wait)" {
  grep -qF 'set -m' "$LOOP_ROOT/runners/run-developer.sh"
  grep -qE 'wait[[:space:]]+"\$PIPELINE_PID"' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: trap forwards signal to pipeline pgroup" {
  grep -qF 'pipeline_kill_pgroup_if_alive' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: trap registers EXIT, INT, and TERM" {
  # The trap MUST include INT so SIGINT (Ctrl+C, kill -INT) fires the cleanup
  # in production. Bats can't deliver SIGINT to its async child to verify
  # functionally — see the comment above the natural-exit test.
  grep -qE '^trap cleanup EXIT INT TERM' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh: sources pipeline_signal.sh" {
  grep -qF 'pipeline_signal.sh' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-reviewer.sh: backgrounds the claude pipeline (uses set -m + wait)" {
  grep -qF 'set -m' "$LOOP_ROOT/runners/run-reviewer.sh"
  grep -qE 'wait[[:space:]]+"\$PIPELINE_PID"' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-reviewer.sh: trap forwards signal to pipeline pgroup" {
  grep -qF 'pipeline_kill_pgroup_if_alive' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-reviewer.sh: trap registers EXIT, INT, and TERM" {
  grep -qE '^trap cleanup EXIT INT TERM' "$LOOP_ROOT/runners/run-reviewer.sh"
}
