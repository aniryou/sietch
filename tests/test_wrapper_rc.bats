#!/usr/bin/env bats
# GH#27 — wrapper rc=2 policy must skip + back off, not proceed to be safe.
#
# Background: when an eligibility predicate exits with rc=2 (gh/jq invocation
# failed), the wrappers used to fall through and invoke the LLM "to be safe".
# Any persistent predicate failure (e.g. a broken GraphQL query, gh outage)
# therefore became a per-cycle token leak — the LLM was spawned every poll
# while doing nothing useful.
#
# Fix: treat rc=2 the same as rc=1 (no work) at the wrapper level — log the
# failure to stderr and exit 2 so run-loop.sh applies its existing exponential
# backoff. The follow-up dispatcher already does this at run-loop.sh:196-200;
# the wrapper preflight just hadn't been brought into line.
#
# This file pins both wrappers to the new policy at two layers:
#   1. End-to-end behavioral: PATH-mock `gh` to fail, run the wrapper, assert
#      exit 2 AND that the PATH-mocked `claude` was never invoked.
#   2. Source-of-truth grep: the string "proceeding to be safe" must not
#      reappear in either wrapper, and the new "skipping" + exit-2 path must
#      stay wired up.

load 'helpers'

# Build a tmp PATH dir with a `gh` shim that exits according to MODE
# ("fail" → rc=1; "empty" → emits []), and a `claude` shim that records its
# own invocation by touching a sentinel file. The tests later assert presence
# or absence of the sentinel to pin "the LLM was/was not spawned".
_make_stub_path() {
  local mode="$1"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  case "$mode" in
    fail)
      cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
# Simulate a transient gh failure (network, auth, GraphQL node-limit, ...).
exit 1
STUB
      ;;
    empty)
      cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
# Simulate "no candidates" for both `gh issue list` (dev) and `gh pr list`
# (reviewer). Both predicates pipe through `jq -r ...` so a literal `[]` is
# the canonical empty fixture.
case "$1 $2" in
  "issue list"|"pr list") echo '[]'; exit 0 ;;
esac
exit 0
STUB
      ;;
  esac
  chmod +x "$tmpbin/gh"

  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
# Sentinel — if the wrapper ever invokes me, the test fails because the rc=2
# / rc=1 paths must short-circuit before launching the LLM pipeline.
touch "$BATS_TEST_TMPDIR/claude-was-called"
exit 0
STUB
  chmod +x "$tmpbin/claude"
  echo "$tmpbin"
}

# ---------------------------------------------------------------------------
# Behavioral: rc=2 (predicate failure) → wrapper exits 2, no claude.
# ---------------------------------------------------------------------------

@test "run-developer.sh: predicate rc=2 (gh fails) → exit 2, no claude, stderr 'predicate failed'" {
  local repo tmpbin
  repo=$(make_repo)
  tmpbin=$(_make_stub_path fail)

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/claude-was-called" ]
  # stderr-or-stdout, since `run` merges them; both messages should be visible
  # to the operator tailing the tmux pane.
  echo "$output" | grep -qF 'predicate failed'
  echo "$output" | grep -qF 'skipping'
}

@test "run-reviewer.sh: predicate rc=2 (gh fails) → exit 2, no claude, stderr 'predicate failed'" {
  local repo tmpbin
  repo=$(make_repo)
  tmpbin=$(_make_stub_path fail)

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/claude-was-called" ]
  echo "$output" | grep -qF 'predicate failed'
  echo "$output" | grep -qF 'skipping'
}

# ---------------------------------------------------------------------------
# Behavioral regression guard: rc=1 (no work) path must remain "exit 2, no
# claude". The fix could conceivably collapse rc=1 and rc=2 into a single
# arm — these tests pin the existing rc=1 messaging to keep operator logs
# distinguishable between "no work" (expected) and "predicate broken" (alert).
# ---------------------------------------------------------------------------

@test "run-developer.sh: predicate rc=1 (no work) → exit 2, no claude (regression guard)" {
  local repo tmpbin
  repo=$(make_repo)
  tmpbin=$(_make_stub_path empty)

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/claude-was-called" ]
  echo "$output" | grep -qF 'no eligible issues'
}

@test "run-reviewer.sh: predicate rc=1 (no work) → exit 2, no claude (regression guard)" {
  local repo tmpbin
  repo=$(make_repo)
  tmpbin=$(_make_stub_path empty)

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/claude-was-called" ]
  echo "$output" | grep -qF 'no PRs need review'
}

# ---------------------------------------------------------------------------
# Source-of-truth: the leak phrase must be gone, and the new policy must be
# wired up so a future refactor can't silently regress to "proceed to be safe".
# ---------------------------------------------------------------------------

@test "run-developer.sh: 'proceeding to be safe' is gone (GH#27 regression guard)" {
  ! grep -qF 'proceeding to be safe' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh: 'proceeding to be safe' is gone (GH#27 regression guard)" {
  ! grep -qF 'proceeding to be safe' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-developer.sh: rc=2 path emits 'skipping' and exits 2" {
  # Pin the wrapper's own rc=2 case-arm — without these greps, the "leak gone"
  # tests above could pass while the new arm silently fell through to a
  # different code path.
  grep -qE 'predicate failed.*skipping' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh: rc=2 path emits 'skipping' and exits 2" {
  grep -qE 'predicate failed.*skipping' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "eligibility.sh: header contract documents rc=2 as 'skip', not 'assume work'" {
  # The lib header is the contract that wrapper authors read first — it must
  # tell them rc=2 means skip, otherwise the next wrapper to be added will
  # repeat the leak shape.
  ! grep -qF 'fall back to "assume work"' "$LOOP_ROOT/runners/lib/eligibility.sh"
  grep -qE 'rc=2.*skip|skip.*back.?off' "$LOOP_ROOT/runners/lib/eligibility.sh"
}
