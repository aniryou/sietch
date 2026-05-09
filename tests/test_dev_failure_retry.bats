#!/usr/bin/env bats
# GH#56 — Mode 1 wrapper retry counter via dev-failed:N labels.
#
# Background: when an issue body, fixture, or scope reproducibly crashes the
# LLM (max-turns hit before reaching the in-prompt safety-net check, bash
# error in a tool call, missing test dep that crashes pytest reproducibly),
# the wrapper used to keep re-spawning a fresh LLM every cycle on the same
# issue (~$1-3 per Mode 1 run). The blocked:human label that GH#28 added
# only fires from inside the LLM (safety-net path) — hard failures that
# crash before that check leave the issue unlabeled, unassigned, and
# re-eligible until a human notices.
#
# Fix: track consecutive hard failures via dev-failed:N labels on the GH
# issue. After DEV_HARD_FAILURE_RETRY_LIMIT (default 3) escalate by adding
# blocked:human + posting a comment naming the wrapper log path. A
# successful Mode 1 cycle clears any dev-failed:N labels.

load 'helpers'

# Build a fake LOOP_HOME mirroring the real one (same shape as the Mode 3
# fixture in test_wrapper_rc.bats). The triage gate is stubbed to always
# return tractable so Mode 3 tests reach the LLM pipeline; Mode 1 runs
# don't invoke triage so the stub is harmless there.
_make_mode1_loop_home() {
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
  cat >"$fake/runners/run-conflict-triage.sh" <<'STUB'
#!/usr/bin/env bash
echo "[triage-stub] tractable"
exit 0
STUB
  chmod +x "$fake/runners/run-conflict-triage.sh"
  echo "$fake"
}

# PATH-mock claude (parameterized exit code) and gh.
#
# Args:
#   $1 = claude exit code
#   $2 = JSON array of existing labels for issue 42, e.g. '[]'
#                                                  or '[{"name":"dev-failed:1"}]'
#
# The gh stub:
#   - records every invocation's argv to $state/gh-args (one CALL: line each),
#   - returns issue 42 for `gh issue list --label severity:high`,
#   - returns [] for `gh issue list --label severity:medium` (so the wrapper
#     only sees one candidate and pre-locks it),
#   - returns the labels JSON for `gh issue view 42 --json labels` (no --jq;
#     the wrapper applies jq locally to keep the stub simple and portable),
#   - is a no-op for `gh issue edit` and `gh issue comment` (argv captured).
_make_mode1_path_stubs() {
  local claude_exit="$1"
  local existing_labels_json="$2"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"
  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
touch '$state/claude-was-called'
exit $claude_exit
STUB
  chmod +x "$tmpbin/claude"

  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
{
  printf 'CALL: '
  printf '%s ' "\$@"
  printf '\n'
} >>'$state/gh-args'
case "\$1 \$2" in
  "issue list")
    label=""
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--label" ]; then
        label="\$2"
        shift 2
      else
        shift
      fi
    done
    case "\$label" in
      severity:high)   echo '[{"number":42,"assignees":[],"labels":[]}]' ;;
      severity:medium) echo '[]' ;;
      *)               echo '[]' ;;
    esac
    ;;
  "issue view")
    # Wrapper queries: gh issue view N --repo X --json labels
    # (no --jq; jq is applied locally in the wrapper). Return the labels
    # object using the test-provided existing-labels array.
    echo '{"labels": $existing_labels_json}'
    ;;
esac
exit 0
STUB
  chmod +x "$tmpbin/gh"
}

# Common harness: produce a make_repo'd consumer dir.
_setup_consumer_repo() {
  local repo
  repo=$(make_repo)
  echo "$repo"
}

# ---------------------------------------------------------------------------
# Failure path — increment the per-issue counter by one each cycle.
# ---------------------------------------------------------------------------

@test "Mode 1 hard-failure: claude exit=1, no prior dev-failed label → adds dev-failed:1, no escalation" {
  local repo fake
  repo=$(_setup_consumer_repo)
  fake=$(_make_mode1_loop_home)
  _make_mode1_path_stubs 1 '[]'

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 1 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  grep -qF 'issue edit 42' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--add-label dev-failed:1' "$BATS_TEST_TMPDIR/state/gh-args"
  # Below the limit (default 3) → no escalation comment, no blocked:human.
  ! grep -qF -- '--add-label blocked:human' "$BATS_TEST_TMPDIR/state/gh-args"
  ! grep -qF 'issue comment 42' "$BATS_TEST_TMPDIR/state/gh-args"
}

@test "Mode 1 hard-failure: claude exit=1, prior dev-failed:1 → removes 1, adds 2, no escalation" {
  local repo fake
  repo=$(_setup_consumer_repo)
  fake=$(_make_mode1_loop_home)
  _make_mode1_path_stubs 1 '[{"name":"dev-failed:1"}]'

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 1 ]
  grep -qF -- '--remove-label dev-failed:1' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--add-label dev-failed:2' "$BATS_TEST_TMPDIR/state/gh-args"
  ! grep -qF -- '--add-label blocked:human' "$BATS_TEST_TMPDIR/state/gh-args"
}

@test "Mode 1 hard-failure: claude exit=124 (max-turns), prior dev-failed:2, limit=3 → adds dev-failed:3, blocked:human, escalation comment" {
  local repo fake
  repo=$(_setup_consumer_repo)
  fake=$(_make_mode1_loop_home)
  echo "DEV_HARD_FAILURE_RETRY_LIMIT=3" >>"$repo/.loop/loop.config"
  _make_mode1_path_stubs 124 '[{"name":"dev-failed:2"}]'

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 124 ]
  grep -qF -- '--remove-label dev-failed:2' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--add-label dev-failed:3' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--add-label blocked:human' "$BATS_TEST_TMPDIR/state/gh-args"
  # Escalation comment posted on the GH issue. The body must name the
  # wrapper log path (operator visibility) and include the consecutive
  # failure count + last exit code.
  grep -qF 'issue comment 42' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'Dev-agent hard-failed 3 consecutive times' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'last exit=124' "$BATS_TEST_TMPDIR/state/gh-args"
}

@test "Mode 1 hard-failure: limit=2 → escalates at 2nd consecutive failure" {
  # Operator-tunable threshold. Verify a non-default DEV_HARD_FAILURE_RETRY_LIMIT
  # actually changes the escalation point — without this, a typo in the env
  # var name or a stale default-if-unset would silently keep the limit at 3.
  local repo fake
  repo=$(_setup_consumer_repo)
  fake=$(_make_mode1_loop_home)
  echo "DEV_HARD_FAILURE_RETRY_LIMIT=2" >>"$repo/.loop/loop.config"
  _make_mode1_path_stubs 1 '[{"name":"dev-failed:1"}]'

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 1 ]
  grep -qF -- '--add-label dev-failed:2' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--add-label blocked:human' "$BATS_TEST_TMPDIR/state/gh-args"
}

# ---------------------------------------------------------------------------
# Success path — clears the counter so a transient failure followed by two
# successes doesn't leave the issue with a stale dev-failed:1.
# ---------------------------------------------------------------------------

@test "Mode 1 success: claude exit=0, prior dev-failed:1 → removes the label" {
  local repo fake
  repo=$(_setup_consumer_repo)
  fake=$(_make_mode1_loop_home)
  _make_mode1_path_stubs 0 '[{"name":"severity:high"},{"name":"dev-failed:1"}]'

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 0 ]
  grep -qF -- '--remove-label dev-failed:1' "$BATS_TEST_TMPDIR/state/gh-args"
  # Must NOT add any new dev-failed label.
  ! grep -qF -- '--add-label dev-failed' "$BATS_TEST_TMPDIR/state/gh-args"
}

@test "Mode 1 success: claude exit=0, no prior dev-failed labels → no edit calls (no-op)" {
  # Regression guard: the success path's "clear counter" branch must be a
  # no-op when there's nothing to clear. Otherwise every successful run
  # would log a `--remove-label dev-failed:` call with an empty argument,
  # which gh treats as an error.
  local repo fake
  repo=$(_setup_consumer_repo)
  fake=$(_make_mode1_loop_home)
  _make_mode1_path_stubs 0 '[{"name":"severity:high"}]'

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 0 ]
  ! grep -qF -- '--remove-label dev-failed' "$BATS_TEST_TMPDIR/state/gh-args"
  ! grep -qF -- '--add-label dev-failed' "$BATS_TEST_TMPDIR/state/gh-args"
}

@test "Mode 1 success: clears multiple stale dev-failed:N labels in one call" {
  # Defensive: if a prior run partially failed (e.g. add-label succeeded but
  # remove-label didn't), the issue could end up with two dev-failed labels.
  # The success-path clear must remove all of them so the next failure
  # starts cleanly from dev-failed:1.
  local repo fake
  repo=$(_setup_consumer_repo)
  fake=$(_make_mode1_loop_home)
  _make_mode1_path_stubs 0 '[{"name":"dev-failed:1"},{"name":"dev-failed:2"}]'

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 0 ]
  # Both labels removed (single comma-separated --remove-label call is fine).
  grep -qF 'dev-failed:1' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'dev-failed:2' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--remove-label' "$BATS_TEST_TMPDIR/state/gh-args"
}

# ---------------------------------------------------------------------------
# Mode-scoping — the new logic must only fire in Mode 1 (default). Modes 2/3
# already have their own hard-failure handling (PR-scoped, GH#48/#49). This
# is issue-scoped and would be confused with the PR fallbacks if it leaked.
# ---------------------------------------------------------------------------

@test "Mode 3 hard-failure (regression guard): no dev-failed label is touched" {
  # Re-run the existing Mode 3 hard-failure shape and assert no `dev-failed:`
  # label argv shows up. Without this guard a future refactor could move the
  # retry counter into a shared post-wait block that fires in every mode.
  local repo fake
  repo=$(_setup_consumer_repo)
  fake=$(_make_mode1_loop_home)
  _make_mode1_path_stubs 124 '[{"name":"dev-failed:1"}]'

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 99

  [ "$status" -eq 124 ]
  ! grep -qF 'dev-failed:' "$BATS_TEST_TMPDIR/state/gh-args"
}

# ---------------------------------------------------------------------------
# Eligibility predicate compatibility (regression guard for GH#56).
# Issues carrying dev-failed:N labels alone (no blocked:human) must still
# count as eligible — otherwise a single transient failure would
# permanently remove the issue from the queue without a human action.
# Issues carrying blocked:human (with or without dev-failed:N) must still
# be excluded — that's the existing GH#28 contract.
# ---------------------------------------------------------------------------

@test "eligibility_dev_count: dev-failed:N alone (no blocked:human) → still counts the issue" {
  local repo
  repo=$(make_repo)
  local tmpbin="$BATS_TEST_TMPDIR/bin-eligibility"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    # Issue 777 has dev-failed:1 but NOT blocked:human → still eligible.
    echo '[{"number":777,"assignees":[],"labels":[{"name":"severity:high"},{"name":"dev-failed:1"}]}]'
    exit 0
    ;;
  "pr list")
    # GH#65: predicate now also queries open PRs to skip already-claimed issues.
    echo '[]'
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev
  [ "$status" -eq 0 ]
  # Same fixture returned for both severity queries → sort -u dedupes to 1.
  [ "$output" = "1" ]
}

@test "eligibility_dev_count: dev-failed:N + blocked:human → excludes the issue" {
  local repo
  repo=$(make_repo)
  local tmpbin="$BATS_TEST_TMPDIR/bin-eligibility-blocked"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    echo '[{"number":888,"assignees":[],"labels":[{"name":"dev-failed:3"},{"name":"blocked:human"}]}]'
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Source-of-truth: the wrapper must reference dev-failed: prefix and the
# DEV_HARD_FAILURE_RETRY_LIMIT config var. The config var must be declared
# in loop.config.example with a default. labels.json must declare the three
# canonical dev-failed:N labels so `st init` provisions them.
# ---------------------------------------------------------------------------

@test "run-developer.sh: retry counter consults dev-failed: prefix and DEV_HARD_FAILURE_RETRY_LIMIT" {
  grep -qF 'dev-failed:' "$LOOP_ROOT/runners/run-developer.sh"
  grep -qF 'DEV_HARD_FAILURE_RETRY_LIMIT' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "loop.config.example: declares DEV_HARD_FAILURE_RETRY_LIMIT with a numeric default" {
  grep -qE '^DEV_HARD_FAILURE_RETRY_LIMIT=[0-9]+' "$LOOP_ROOT/templates/loop.config.example"
}

@test "labels.json: declares dev-failed:1, dev-failed:2, dev-failed:3" {
  jq -e '[.[].name] | contains(["dev-failed:1","dev-failed:2","dev-failed:3"])' \
    "$LOOP_ROOT/templates/labels.json" >/dev/null
}
