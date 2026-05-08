#!/usr/bin/env bats
# GH#57 — Mode 3 wrapper must branch on triage's three-way exit code:
#   rc=0 (tractable)    → invoke LLM
#   rc=1 (untractable)  → draft PR + post auto-resolution-declined comment + exit 1
#   rc=2 (setup error)  → exit 2 only; NO draft, NO comment, NO LLM
#
# Pre-fix: `runners/run-developer.sh` used `if TRIAGE_OUTPUT=$(... triage ...);`
# which only sees zero/nonzero. rc=1 and rc=2 both fell into the `else` branch,
# so a transient `gh pr view` / `git fetch origin` failure during the ~5s triage
# window permanently drafted the PR with a misleading "auto-resolution declined"
# comment that required human un-draft. Same architectural shape as the rc=2
# leak GH#27 fixed for eligibility predicates.

load 'helpers'

# Build a fake LOOP_HOME with a stubbed run-conflict-triage.sh that exits with
# the requested rc and prints the requested body. Everything else (libs,
# templates, other runners) is symlinked from $LOOP_ROOT so the wrapper still
# resolves render-prompt.sh / pipeline_signal.sh / jq_filter.sh / developer.md.
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
# file, exits 0 always). The gh stub captures EVERY call so a single grep on
# the recorded log proves whether `pr ready --undo` and `pr comment` fired.
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
# Behavioral: the three triage exit codes must take three distinct paths.
# ---------------------------------------------------------------------------

@test "Mode 3: triage rc=2 (transient setup error) → wrapper exits 2, no draft, no comment, no LLM" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_triage 2 '[triage] error: cannot read PR #99')
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 99

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  # No PR-state-mutating gh calls: the transient-failure path must not draft
  # or comment, since dispatch:conflicts will re-test next cycle once the
  # transient gh/git outage clears.
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr ready --undo' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'auto-resolution declined' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
  echo "$output" | grep -qF 'triage failed (rc=2)'
  echo "$output" | grep -qF 'result=triage-failed'
  echo "$output" | grep -qF 'pr=#99'
}

@test "Mode 3: triage rc=1 (untractable) → wrapper drafts PR + posts comment + exits 1, no LLM (regression guard)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_triage 1 \
    '[triage] result=untractable reason=test-file-conflict:tests/foo.py issue=#42 conflict_files=tests/foo.py conflict_lines=3')
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 42

  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  grep -qF 'pr ready --undo 42' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr comment 42' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'auto-resolution declined' "$BATS_TEST_TMPDIR/state/gh-args"
  echo "$output" | grep -qF 'result=triage-untractable'
  echo "$output" | grep -qF 'reason=test-file-conflict:tests/foo.py'
}

@test "Mode 3: triage rc=0 (tractable) → wrapper invokes LLM, no draft, no decline-comment (regression guard)" {
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
  fi
}

# ---------------------------------------------------------------------------
# Source-of-truth grepping: pin the new wiring so a future refactor cannot
# silently regress to bash `if`-zero/nonzero (which conflates rc=1 and rc=2).
# ---------------------------------------------------------------------------

@test "run-developer.sh: triage branching uses 'case \$TRIAGE_RC' not 'if TRIAGE_OUTPUT=\$(...)'" {
  grep -qE 'case[[:space:]]+"\$TRIAGE_RC"' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: triage rc=2 arm emits 'transient setup error' and 'result=triage-failed'" {
  grep -qF 'transient setup error' "$LOOP_ROOT/runners/run-developer.sh"
  grep -qF 'result=triage-failed' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-conflict-triage.sh: header documents wrapper's three-way branching contract" {
  # Future maintainers changing the triage exit-code contract need to know the
  # wrapper depends on a three-way (0/1/2) split — not just zero/nonzero.
  grep -qE 'wrapper.*case|three-way|trichotomous' "$LOOP_ROOT/runners/run-conflict-triage.sh"
}
