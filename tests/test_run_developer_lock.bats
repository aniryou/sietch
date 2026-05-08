#!/usr/bin/env bats
# run-developer.sh — wrapper-side lock acquisition (GH#31).
#
# The wrapper used to count eligible issues and immediately spawn the LLM,
# leaving lock acquisition to the LLM's first few tool calls. With N parallel
# wrappers and one candidate, all N spawned `claude` and N-1 lost the lock
# race after burning ~$0.20-$0.50 each (TOCTOU between count and mkdir).
#
# The fix moves `mkdir "$LOCK_DIR/${LOCK_NAME_PREFIX}gh-N.lock"` into the
# wrapper itself, before `claude` is invoked. These tests exercise the
# wrapper end-to-end via PATH-mocked `gh` and `claude` to confirm exactly
# one wrapper spawns the LLM under contention, and that the wrapper pre-
# fills `DEV_AGENT_TARGET_ISSUE` so the LLM skips the rediscovery flow.
# (LOCK_NAME_PREFIX added in GH#74 — defaults to "${REPO_NAME}-".)

load 'helpers'

# Build a self-contained test environment under $BATS_TEST_TMPDIR:
#   <tmpdir>/repo/.loop/loop.config   — consumer config with WORKTREE_BASE
#                                        and LOCK_DIR pointing at the tmpdir
#                                        (so we don't collide with /tmp/dev-agent)
#   <tmpdir>/bin/gh                   — gh stub returning fixture issues
#   <tmpdir>/bin/claude               — claude stub recording invocations
#   <tmpdir>/work/                    — wrapper's WORKTREE_BASE / LOCK_DIR root
#   <tmpdir>/state/claude-calls       — appended to once per claude invocation
#
# Echoes the tmpdir on stdout so each test can build paths off it.
_setup_env() {
  local high="${1:-$LOOP_ROOT/tests/fixtures/gh/issues-high.json}"
  local med="${2:-$LOOP_ROOT/tests/fixtures/gh/issues-medium.json}"
  local root="$BATS_TEST_TMPDIR"
  local repo="$root/repo"
  local bin="$root/bin"
  local work="$root/work"
  local state="$root/state"
  mkdir -p "$repo/.loop" "$bin" "$work" "$state"

  # Copy the example config and override:
  #   - REPO_OWNER/REPO_NAME so REPO_SLUG is well-formed
  #   - WORKTREE_BASE/LOCK_DIR so our locks live in the test tmpdir
  awk -v wb="$work" '
    /^REPO_OWNER=/   { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/    { print "REPO_NAME=\"test-repo\""; next }
    /^WORKTREE_BASE=/ { print "WORKTREE_BASE=\"" wb "\""; next }
    /^LOCK_DIR=/     { print "LOCK_DIR=\"" wb "/locks\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"

  # Make REPO_ROOT a real git repo so `git -C "$REPO" worktree list` works
  # even if cleanup paths run.
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init

  # gh stub: respond to `issue list --label LABEL` with the right fixture.
  cat > "$bin/gh" <<STUB
#!/usr/bin/env bash
# Minimal gh stub for run-developer.sh preflight.
label=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--label" ]; then label="\$2"; shift 2
  else shift
  fi
done
case "\$label" in
  severity:high)   cat '$high' ;;
  severity:medium) cat '$med' ;;
  *) echo '[]' ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"

  # claude stub: append a line to state/claude-calls capturing the env the
  # wrapper passes through, AND snapshot the lock-dir run_id while the lock
  # is still held — the wrapper's EXIT trap releases the lock, so a post-
  # mortem inspection of LOCK_DIR can't see it after the wrapper exits.
  cat > "$bin/claude" <<STUB
#!/usr/bin/env bash
echo "called pid=\$\$ target=\${DEV_AGENT_TARGET_ISSUE:-<unset>} run=\${DEV_AGENT_RUN_ID:-<unset>} worktree=\${WORKTREE:-<unset>}" \\
  >> '$state/claude-calls'
LOCK_FILE='$work/locks/test-repo-gh-'"\${DEV_AGENT_TARGET_ISSUE:-?}"'.lock/run_id'
if [ -f "\$LOCK_FILE" ]; then
  cp "\$LOCK_FILE" '$state/lock-run-id'
fi
exit 0
STUB
  chmod +x "$bin/claude"

  echo "$root"
}

# Run runners/run-developer.sh in the test environment. Echoes the wrapper's
# exit code (so the caller can assert on it without `run`'s pseudo-globals).
_run_wrapper() {
  local root="$1"
  shift
  REPO_ROOT="$root/repo" LOOP_HOME="$LOOP_ROOT" \
    PATH="$root/bin:$PATH" \
    KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-developer.sh" "$@" \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err"
}

@test "wrapper: zero candidates → does not invoke claude, exits 2 (no-work)" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local root
  root=$(_setup_env "$empty" "$empty")

  local rc=0
  _run_wrapper "$root" || rc=$?

  [ "$rc" -eq 2 ]
  [ ! -e "$root/state/claude-calls" ]
}

@test "wrapper: single candidate → acquires lock + invokes claude with DEV_AGENT_TARGET_ISSUE set" {
  # High fixture has 101, 102 unassigned. With no concurrent runner and an
  # empty lock dir, the wrapper should pick the first (101), mkdir its lock,
  # export DEV_AGENT_TARGET_ISSUE=101, and invoke claude exactly once.
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty")

  local rc=0
  _run_wrapper "$root" || rc=$?

  [ "$rc" -eq 0 ]
  [ -f "$root/state/claude-calls" ]
  # Exactly one invocation.
  [ "$(wc -l < "$root/state/claude-calls" | tr -d ' ')" -eq 1 ]
  # The env var the wrapper must export, captured by the claude stub.
  grep -qF 'target=101' "$root/state/claude-calls"
}

@test "wrapper: writes run_id into the acquired lock dir before invoking claude" {
  # The lock contract: while claude is running,
  # $LOCK_DIR/${LOCK_NAME_PREFIX}gh-N.lock/run_id contains the wrapper's
  # DEV_AGENT_RUN_ID. The trap releases the lock on exit, so this test
  # relies on the claude stub snapshotting the file mid-run. Without this
  # evidence, the wrapper could "claim" issues without actually marking
  # ownership and lock-release on exit would be unable to tell whose lock
  # to release.
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty")

  local rc=0
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 0 ]

  # The claude stub copies /work/locks/test-repo-gh-101.lock/run_id (per
  # GH#74 LOCK_NAME_PREFIX, default "${REPO_NAME}-") to state/lock-run-id
  # BEFORE the wrapper's trap fires.
  [ -f "$root/state/lock-run-id" ]
  local stamped run_id_in_call
  stamped=$(cat "$root/state/lock-run-id")
  # The same DEV_AGENT_RUN_ID must appear both in the lock file AND in the
  # env-var line the wrapper exported to the LLM (run=$DEV_AGENT_RUN_ID),
  # otherwise the trap can't match-and-release on exit.
  run_id_in_call=$(grep -oE 'run=[^ ]+' "$root/state/claude-calls" | head -1 | cut -d= -f2)
  [ -n "$stamped" ]
  [ "$stamped" = "$run_id_in_call" ]
}

@test "wrapper: candidate already locked by another run → exits without spawning claude" {
  # Pre-populate the lock dir as if another wrapper instance already claimed
  # the only candidate. The eligibility predicate filters it out, so the
  # wrapper sees zero candidates → exit 2, no claude call.
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty")

  # GH#74: lock filename carries LOCK_NAME_PREFIX (default "${REPO_NAME}-").
  mkdir -p "$root/work/locks/test-repo-gh-101.lock"
  echo "other-run" > "$root/work/locks/test-repo-gh-101.lock/run_id"

  local rc=0
  _run_wrapper "$root" || rc=$?

  [ "$rc" -eq 2 ]
  [ ! -e "$root/state/claude-calls" ]
  # The other run's lock untouched — the wrapper must not release a lock it
  # didn't acquire.
  [ -d "$root/work/locks/test-repo-gh-101.lock" ]
  [ "$(cat "$root/work/locks/test-repo-gh-101.lock/run_id")" = "other-run" ]
}

@test "wrapper: two parallel invocations on a single candidate → claude called exactly once" {
  # The TOCTOU regression test: with a single eligible issue and two parallel
  # wrappers, only one should spawn `claude`. Pre-#31 behavior: both spawn,
  # wasting tokens. Post-fix: the loser exits 2 without invoking claude.
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty")

  # Run two wrappers concurrently. We can't use `_run_wrapper` here because we
  # need them backgrounded; inline the env block.
  REPO_ROOT="$root/repo" LOOP_HOME="$LOOP_ROOT" \
    PATH="$root/bin:$PATH" KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-developer.sh" \
    >"$root/state/w1.out" 2>"$root/state/w1.err" &
  local pid1=$!
  REPO_ROOT="$root/repo" LOOP_HOME="$LOOP_ROOT" \
    PATH="$root/bin:$PATH" KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-developer.sh" \
    >"$root/state/w2.out" 2>"$root/state/w2.err" &
  local pid2=$!

  local rc1=0 rc2=0
  wait "$pid1" || rc1=$?
  wait "$pid2" || rc2=$?

  # Exactly one claude invocation across both wrappers — that's the contract.
  [ -f "$root/state/claude-calls" ]
  [ "$(wc -l < "$root/state/claude-calls" | tr -d ' ')" -eq 1 ]
  # One winner (rc=0), one loser (rc=2 = no-work / lock-race-loss-pre-LLM).
  # We don't care which is which, just that the (0,2) pair shows up.
  case "$rc1:$rc2" in
    0:2|2:0) : ;;
    *) printf 'unexpected (rc1, rc2) = (%s, %s)\n' "$rc1" "$rc2" >&2; return 1 ;;
  esac
}

@test "wrapper: exports WORKTREE=\${WORKTREE_BASE}/gh-\${DEV_AGENT_TARGET_ISSUE} for claude (GH#82)" {
  # GH#82: the wrapper now precomputes the per-issue worktree path and
  # exports it so the developer-agent template can use $WORKTREE everywhere
  # instead of re-typing the literal /tmp/dev-agent/.../gh-N/... path 60+
  # times per run. Saves ~680 chars per Mode 1 cycle.
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty")

  local rc=0
  _run_wrapper "$root" || rc=$?

  [ "$rc" -eq 0 ]
  [ -f "$root/state/claude-calls" ]
  # _setup_env sets WORKTREE_BASE to "$root/work" via the awk override of
  # loop.config. With the wrapper picking issue 101, the exported value
  # must be exactly "$root/work/gh-101".
  grep -qF "worktree=$root/work/gh-101" "$root/state/claude-calls" \
    || { echo "WORKTREE not exported: $(cat "$root/state/claude-calls")" >&2; false; }
}
