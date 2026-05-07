#!/usr/bin/env bats
# render-prompt.sh — substitution and error-path coverage.

load 'helpers'

setup() {
  REPO=$(make_repo)
  export REPO_ROOT="$REPO"
  export LOOP_HOME="$LOOP_ROOT"
  TEMPLATE="$LOOP_ROOT/tests/fixtures/template-all-keys.md"
}

@test "every REPO_KEYS variable substitutes (no literal \${KEY} left for any repo key)" {
  run bash "$LOOP_ROOT/runners/lib/render-prompt.sh" "$TEMPLATE"
  [ "$status" -eq 0 ]
  # No literal \${KEY} remaining for any of the known repo keys.
  for key in REPO_OWNER REPO_NAME REPO_SLUG BRANCH_PREFIX LOCK_DIR \
             DISPATCH_LOCK_DIR TRIAGE_CORE_FILES_REGEX TRIAGE_TESTS_REGEX \
             TRIAGE_CI_SECRETS_REGEX TRIAGE_LINE_LIMIT \
             DISPATCH_MAX_CONCURRENT \
             REVIEWER_AGENT_VERDICT_REGEX \
             DEV_AGENT_COMMENT_PREFIX REVIEWER_AGENT_COMMENT_PREFIX; do
    if echo "$output" | grep -qF "\${$key}"; then
      echo "key not substituted: $key" >&2
      return 1
    fi
  done
}

@test "concrete repo values appear in output" {
  run bash "$LOOP_ROOT/runners/lib/render-prompt.sh" "$TEMPLATE"
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF 'REPO_OWNER=test-owner'
  echo "$output" | grep -qF 'REPO_SLUG=test-owner/test-repo'
  echo "$output" | grep -qF 'BRANCH_PREFIX=dev-agent'
  # The fix to loop-2lp ensures REVIEWER_AGENT_VERDICT_REGEX renders. Note
  # the loop.config value contains literal backslashes (\[ and \]) so the
  # rendered output contains them verbatim.
  echo "$output" | grep -qF 'REVIEWER_AGENT_VERDICT_REGEX=\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
}

@test "non-REPO_KEYS variables pass through literally" {
  run bash "$LOOP_ROOT/runners/lib/render-prompt.sh" "$TEMPLATE"
  [ "$status" -eq 0 ]
  # \${REPO_ROOT} and \${HOLDER} are NOT in REPO_KEYS — must remain literal so
  # the agent (or its bash subshell) can expand them at runtime.
  echo "$output" | grep -qF 'PASSTHROUGH_REPO_ROOT=${REPO_ROOT}'
  echo "$output" | grep -qF 'PASSTHROUGH_HOLDER=${HOLDER}'
}

@test "missing template path exits 2" {
  run bash "$LOOP_ROOT/runners/lib/render-prompt.sh" "$BATS_TEST_TMPDIR/does-not-exist.md"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF '[render-prompt] template not found'
}

@test "missing loop.config exits 1" {
  REPO_ROOT="$BATS_TEST_TMPDIR/empty-repo" \
    run bash "$LOOP_ROOT/runners/lib/render-prompt.sh" "$TEMPLATE"
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF '[render-prompt] missing config'
}

@test "missing REPO_ROOT exits non-zero" {
  unset REPO_ROOT
  run bash "$LOOP_ROOT/runners/lib/render-prompt.sh" "$TEMPLATE"
  [ "$status" -ne 0 ]
}

@test "envsubst not on PATH exits 1 with helpful message" {
  # Strip envsubst from PATH. /usr/bin and /bin do not contain envsubst on
  # macOS or Debian (gettext lives in /usr/local/bin or /opt/homebrew/bin).
  PATH=/usr/bin:/bin run bash "$LOOP_ROOT/runners/lib/render-prompt.sh" "$TEMPLATE"
  if command -v envsubst >/dev/null 2>&1 && \
     [ "$(PATH=/usr/bin:/bin command -v envsubst 2>/dev/null)" != "" ]; then
    skip "envsubst is on /usr/bin or /bin in this environment; cannot exercise the missing-envsubst path"
  fi
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF 'envsubst (gettext) is required'
}
