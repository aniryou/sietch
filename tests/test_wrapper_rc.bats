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

  # GH#117: wrapper now takes a mandatory <PR> arg. The arg-validation rc=2
  # path is exercised in test_reviewer_wrapper.bats; this test still pins
  # GH#27's predicate-failure rc=2 contract (gh outage → skip+backoff, not
  # "proceed to be safe"). The PR arg supplied here is what gets passed to
  # the wrapper's per-PR `gh pr view`; the `fail` stub makes that view
  # exit 1, and the wrapper's empty-PR_DATA branch is what we're pinning.
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

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
  # GH#117: the wrapper now takes a specific <PR> and does its own per-PR
  # eligibility check (drafted / reviewed / escalated / CI-running). The
  # equivalent of "rc=1 no work" is now "this PR is not eligible". Use a
  # gh stub that returns a drafted-PR shape so the wrapper's skip-arm fires.
  local repo tmpbin
  repo=$(make_repo)
  tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
JSON_EXPR=""
for ((i=0; i<${#ARGS[@]}; i++)); do
  if [ "${ARGS[i]}" = "--json" ]; then JSON_EXPR="${ARGS[i+1]:-}"; fi
done
case "${ARGS[0]:-} ${ARGS[1]:-}" in
  "pr view")
    if [[ "$JSON_EXPR" == *statusCheckRollup* ]]; then
      jq -n '{state: "OPEN", isDraft: true, headRefOid: "abc", number: 99,
              reviews: [], labels: [],
              statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}'
      exit 0
    fi
    ;;
esac
exit 0
STUB
  chmod +x "$tmpbin/gh"
  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
touch "$BATS_TEST_TMPDIR/claude-was-called"
exit 0
STUB
  chmod +x "$tmpbin/claude"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

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

# ---------------------------------------------------------------------------
# GH#48 — Mode 3 hard-failure (max-turns / claude crash / OOM / API outage):
# the wrapper must draft the PR + post a fallback abort comment so
# dispatch:conflicts doesn't re-fire the LLM every cycle on the same PR.
#
# The LLM's three Mode 3 graceful-abort blocks (templates/developer.md) all
# call `gh pr ready --undo` themselves. Hard failures bypass those blocks
# entirely (LLM never reaches them). Without a wrapper-side fallback the
# PR stays mergeable=CONFLICTING + isDraft=false, dispatch:conflicts
# re-fires Mode 3 next cycle, same probable failure, repeat —  same
# failure shape PR #45 closed for graceful aborts but left open for
# ungraceful ones.
#
# Precedent: the triage-untractable wrapper-side block at run-developer.sh
# already drafts the PR + posts a comment without spawning the LLM. This
# extends the same shape to the post-LLM hard-failure path.
# ---------------------------------------------------------------------------

# Build a fake LOOP_HOME with a stubbed run-conflict-triage.sh (so the wrapper
# always reaches the LLM pipeline). Everything else is symlinked from the real
# LOOP_ROOT so render-prompt.sh / pipeline_signal.sh / jq_filter.sh / the
# developer.md template all resolve correctly under $LOOP_HOME.
_make_mode3_loop_home() {
  local fake="$BATS_TEST_TMPDIR/loop-home"
  rm -rf "$fake"
  mkdir -p "$fake/runners/lib" "$fake/templates"
  for f in "$LOOP_ROOT"/runners/*.sh; do
    [ -f "$f" ] || continue
    ln -sf "$f" "$fake/runners/$(basename "$f")"
  done
  for f in "$LOOP_ROOT"/runners/lib/*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$fake/runners/lib/$(basename "$f")"
  done
  for f in "$LOOP_ROOT"/templates/*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$fake/templates/$(basename "$f")"
  done
  # Override the triage gate — pretend it's tractable so we always reach
  # the LLM pipeline that the new fallback guards.
  rm -f "$fake/runners/run-conflict-triage.sh"
  cat >"$fake/runners/run-conflict-triage.sh" <<'STUB'
#!/usr/bin/env bash
echo "[triage-stub] tractable"
exit 0
STUB
  chmod +x "$fake/runners/run-conflict-triage.sh"
  echo "$fake"
}

# PATH-mock `claude` (exit code is the test parameter) and `gh` (capture
# argv to a file, exit 0 always). The gh stub records ALL argv across all
# calls so a single grep can prove the fallback fired.
_make_mode3_path_stubs() {
  local exit_code="$1"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"
  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
touch '$state/claude-was-called'
exit $exit_code
STUB
  chmod +x "$tmpbin/claude"
  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
{
  printf 'CALL: '
  printf '%s ' "\$@"
  printf '\n'
} >>'$state/gh-args'
exit 0
STUB
  chmod +x "$tmpbin/gh"
}

@test "Mode 3 hard-failure: claude exit=124 (max-turns) → wrapper drafts PR + posts fallback comment, returns 124" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_mode3_loop_home)
  _make_mode3_path_stubs 124

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 99

  [ "$status" -eq 124 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  # Both fallback gh side-effects fired with the right PR number.
  grep -qF 'pr ready --undo 99' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr comment 99' "$BATS_TEST_TMPDIR/state/gh-args"
  # The comment carries the same '🤖 Mode 3 conflict resolution — aborted'
  # marker prefix used by the prompt's three graceful-abort blocks, so any
  # log-scraping / dashboards keyed on that prefix pick up hard failures
  # too.
  grep -qF 'Mode 3 conflict resolution — aborted' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'agent run failed mid-flow' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'exit=124' "$BATS_TEST_TMPDIR/state/gh-args"
}

@test "Mode 3 hard-failure: claude exit=137 (SIGKILL/OOM) → wrapper drafts PR + posts fallback comment, returns 137" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_mode3_loop_home)
  _make_mode3_path_stubs 137

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 77

  [ "$status" -eq 137 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  grep -qF 'pr ready --undo 77' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr comment 77' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'exit=137' "$BATS_TEST_TMPDIR/state/gh-args"
}

@test "Mode 3 graceful exit (regression guard): claude exit=0 → wrapper does NOT draft, no fallback comment" {
  # When the LLM exits cleanly in Mode 3 the prompt's graceful-abort blocks
  # (or a successful resolution) have already done the right thing. The
  # wrapper must NOT double-draft / double-comment, otherwise we corrupt
  # operator-visible state — the existing "Mode 3 conflict resolution —
  # complete." comment from R9 would be followed by a misleading "aborted"
  # comment.
  local repo fake
  repo=$(make_repo)
  fake=$(_make_mode3_loop_home)
  _make_mode3_path_stubs 0

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 99

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr ready --undo 99' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'agent run failed mid-flow' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

@test "Mode 3 hard-failure (regression guard): default mode (Mode 1) failures do NOT draft anything" {
  # The new fallback must be Mode 3-scoped only. A Mode 1 LLM crash leaves
  # the GH issue assigned but no PR exists yet to draft — calling
  # `gh pr ready --undo` against a non-existent PR would emit a real error
  # and confuse operators. Pre-lock with DEV_AGENT_TARGET_ISSUE so the
  # wrapper skips the eligibility scan and goes straight to spawning
  # claude (which then fails).
  local repo fake
  repo=$(make_repo)
  fake=$(_make_mode3_loop_home)
  _make_mode3_path_stubs 124

  DEV_AGENT_TARGET_ISSUE=42 REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  # Wrapper's Mode 1 path runs the eligibility preflight which under our
  # gh stub returns no issues, so it exits 2 BEFORE invoking claude. That's
  # the right behavior — and crucially gh-args contains no `pr ready` /
  # `pr comment` calls.
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr ready --undo' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'agent run failed mid-flow' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the new fallback wiring so a future refactor can't
# silently drop the gh-comment / gh-pr-ready calls.
# ---------------------------------------------------------------------------

@test "run-developer.sh: Mode 3 hard-failure fallback is wired up after wait" {
  # The body uses the same '🤖 Mode 3 conflict resolution — aborted' marker
  # prefix as the prompt's three graceful aborts.
  grep -qF 'Mode 3 conflict resolution — aborted' "$LOOP_ROOT/runners/run-developer.sh"
  # The fallback is gated on Mode 3 + non-zero LLM exit code.
  grep -qF 'agent run failed mid-flow' "$LOOP_ROOT/runners/run-developer.sh"
  # The fallback issues the same gh side-effects as the graceful aborts.
  grep -cF 'gh pr ready --undo' "$LOOP_ROOT/runners/run-developer.sh" >/tmp/_gh_undo_count
  # Two call sites: one in the triage-untractable block, one in the new
  # post-LLM hard-failure block. Pre-fix only one existed.
  [ "$(cat /tmp/_gh_undo_count)" -ge 2 ]
}
