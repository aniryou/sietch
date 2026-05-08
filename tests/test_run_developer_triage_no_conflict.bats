#!/usr/bin/env bats
# GH#75 — Mode 3 wrapper must short-circuit on triage's "no-conflict" success.
#
# `runners/run-conflict-triage.sh` emits exit 0 for two distinct tractable
# outcomes:
#   reason=no-conflict                 → rebase succeeded, nothing to resolve
#   reason=mechanical-conflict-N-lines → ≤10 mechanical lines, safe for Mode 3
#
# Pre-fix: the wrapper's rc=0 case-arm logged "triage tractable — invoking
# dev-agent Mode 3" unconditionally, so a healthy non-conflicting PR still
# burned a Mode 3 LLM run (~$0.50–$2.00) every dispatcher cycle until
# merged or drafted. Sister bug to GH#27 / GH#48 / GH#56 / GH#58 in shape:
# a tractable outcome that should be a no-op was being treated as work.
#
# Fix: between `echo "$TRIAGE_OUTPUT"` and the existing "tractable —
# invoking dev-agent Mode 3" log, add a `reason=no-conflict` guard that
# logs `result=triage-no-conflict` and exits 0 (successful no-op, parallel
# to the eligibility `result=no-work` cases). The PR is healthy and must
# NOT be drafted.

load 'helpers'

# Build a fake LOOP_HOME with a stubbed run-conflict-triage.sh that exits with
# the requested rc and prints the requested body. Mirrors the helper in
# tests/test_triage_rc.bats — kept here rather than factored out because the
# existing pattern across triage-rc / wrapper-rc duplicates it deliberately,
# so each file is independently revertible.
_make_loop_home_with_triage() {
  local triage_rc="$1" triage_body="$2"
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
  rm -f "$fake/runners/run-conflict-triage.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "echo $(printf %q "$triage_body")"
    echo "exit $triage_rc"
  } >"$fake/runners/run-conflict-triage.sh"
  chmod +x "$fake/runners/run-conflict-triage.sh"
  echo "$fake"
}

# PATH-mock `claude` (records sentinel + exits 0) and `gh` (records argv to a
# file, exits 0 always). Sentinel-presence proves whether the LLM was reached;
# gh-args grepping proves whether any PR-state mutations fired.
_make_path_stubs() {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"
  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
touch '$state/claude-was-called'
exit 0
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

# ---------------------------------------------------------------------------
# Behavioral: rc=0 splits into two sub-paths based on `reason=`.
# ---------------------------------------------------------------------------

@test "Mode 3: triage rc=0 reason=no-conflict → wrapper exits 0, no LLM, no draft, no comment" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_triage 0 \
    '[triage] result=tractable reason=no-conflict issue=#7 conflict_files= conflict_lines=0')
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 7

  [ "$status" -eq 0 ]
  # The whole point: the LLM must NOT run on a healthy PR.
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  # The PR is healthy — no draft, no decline-comment, no auto-resolution comment.
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr ready --undo 7' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'pr comment 7' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'auto-resolution declined' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
  echo "$output" | grep -qF 'result=triage-no-conflict'
  echo "$output" | grep -qF 'pr=#7'
}

@test "Mode 3: triage rc=0 reason=mechanical-conflict → wrapper invokes LLM, no draft (regression guard)" {
  # Pin the other rc=0 sub-path: when there's an actual mechanical conflict the
  # wrapper must still reach the LLM. Without this guard, a future edit could
  # over-broaden the no-conflict short-circuit and silently disable Mode 3.
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_triage 0 \
    '[triage] result=tractable reason=mechanical-conflict-3-lines issue=#7 conflict_files=requirements.txt conflict_lines=3')
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 7

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr ready --undo 7' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'auto-resolution declined' "$BATS_TEST_TMPDIR/state/gh-args"
    # And — crucially — the wrapper did NOT log result=triage-no-conflict here.
    ! grep -qF 'result=triage-no-conflict' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
  ! echo "$output" | grep -qF 'result=triage-no-conflict'
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the new short-circuit so a future refactor can't
# silently drop it and re-introduce the per-cycle Mode 3 token leak.
# ---------------------------------------------------------------------------

@test "run-developer.sh: rc=0 arm contains 'reason=no-conflict' short-circuit" {
  grep -qF 'reason=no-conflict' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: rc=0 arm emits 'result=triage-no-conflict'" {
  grep -qF 'result=triage-no-conflict' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: no-conflict short-circuit precedes the Mode 3 dispatch log" {
  # Order matters: the guard must fire BEFORE "triage tractable — invoking
  # dev-agent Mode 3" runs and BEFORE the `claude` pipeline launches.
  # Compare line numbers to pin the relative ordering.
  local sh="$LOOP_ROOT/runners/run-developer.sh"
  local guard_line dispatch_line
  guard_line=$(grep -nF 'result=triage-no-conflict' "$sh" | head -1 | cut -d: -f1)
  dispatch_line=$(grep -nF 'triage tractable — invoking dev-agent Mode 3' "$sh" | head -1 | cut -d: -f1)
  [ -n "$guard_line" ]
  [ -n "$dispatch_line" ]
  [ "$guard_line" -lt "$dispatch_line" ]
}
