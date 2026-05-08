#!/usr/bin/env bats
# GH#49 — wrapper Mode 2 (follow-up) hard-failure marker.
#
# Background: the follow-up dispatcher's verdict-aware gate (GH#24) compares
# the latest reviewer-agent review's submittedAt against the latest dev-agent
# comment's createdAt. The premise is that every Mode 2 graceful exit posts a
# 🤖-prefixed comment (success / give-up / no-action). Hard failures (claude
# exits non-zero from --max-turns, API outage, OOM, …) bypass that LLM-side
# comment, the dev-comment timestamp doesn't advance, and the dispatcher
# re-fires the LLM every poll cycle on the same stuck PR.
#
# Fix: after `wait "$PIPELINE_PID"`, capture the LLM's exit code; when MODE
# is follow-up and exit != 0, post a 🤖-prefixed failure marker via gh pr
# comment. Because the marker starts with the DEV_AGENT_COMMENT_PREFIX
# ("🤖 Developer agent"), eligibility_followup_pr's existing
# `startswith($prefix)` filter recognizes it as a dev-comment and the
# next-cycle predicate exits 1 (skip).
#
# This file pins the wrapper-side behavior at two layers:
#   1. Behavioral: PATH-mock `claude` (exits non-zero) and `gh` (records its
#      args) → assert the failure marker was posted with the expected body.
#   2. Regression guards: claude exit 0 → no failure marker; Mode 1 + Mode 3
#      hard failures → no failure marker (those modes have their own gates,
#      and a Mode-2-specific marker would muddle their telemetry).

load 'helpers'

# Build a tmp PATH dir with `claude` and `gh` shims:
#   - $1 = claude exit code (e.g. 124 for max-turns, 0 for graceful)
# `gh` records every invocation (one line per call) to the sentinel
# $GH_LOG_FILE so tests can assert presence/absence of the failure marker.
_make_followup_stubs() {
  local claude_exit="$1"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"

  # Path the gh stub writes its argv to. Each invocation becomes one line.
  local gh_log="$BATS_TEST_TMPDIR/gh-calls.log"
  printf '' > "$gh_log"   # truncate

  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
# Mock claude — emits a single stream-json event then exits with the
# configured code. The stream-json line is enough to keep the wrapper's
# tee/jq pipeline happy under `set -o pipefail`.
printf '{"type":"system","subtype":"init","model":"mock"}\n'
exit ${claude_exit}
STUB
  chmod +x "$tmpbin/claude"

  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
# Record every gh invocation to the sentinel file. One call per line:
#   <subcommand-pair>\t<full argv>
# So tests can grep for 'pr comment' and inspect the --body that follows.
printf '%s\t%s\n' "\$1 \$2" "\$*" >> '${gh_log}'
exit 0
STUB
  chmod +x "$tmpbin/gh"

  echo "$tmpbin"
}

# Helper — find the latest 'pr comment' line in the gh log and emit the
# entire argv (so callers can grep --body content out of it).
_last_gh_comment_argv() {
  grep -F 'pr comment' "$BATS_TEST_TMPDIR/gh-calls.log" | tail -1
}

# ---------------------------------------------------------------------------
# Behavioral: claude exit != 0 in Mode 2 → wrapper posts failure marker.
# ---------------------------------------------------------------------------

@test "run-developer.sh follow-up: claude exit 124 → posts 🤖-prefixed failure marker (GH#49)" {
  local repo tmpbin
  repo=$(make_repo)
  tmpbin=$(_make_followup_stubs 124)

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" follow-up 99

  # Wrapper exits with the LLM's exit code (124).
  [ "$status" -eq 124 ]

  # The failure-marker comment must have been posted exactly once.
  local last
  last=$(_last_gh_comment_argv)
  [ -n "$last" ]
  echo "$last" | grep -qF 'pr comment'
  echo "$last" | grep -qF '99'
  echo "$last" | grep -qF -- '--body'
  # Must start with the DEV_AGENT_COMMENT_PREFIX so eligibility_followup_pr
  # picks it up via `startswith($prefix)`.
  echo "$last" | grep -qF '🤖 Developer agent'
  # Must include the LLM exit code so operators can correlate with the live log.
  echo "$last" | grep -qF 'exit=124'
}

@test "run-developer.sh follow-up: claude exit 1 → still posts failure marker" {
  # Any non-zero exit (not just 124) must trigger the marker — exit codes
  # vary by failure mode (1 = generic LLM error, 124 = max-turns, 137 = OOM,
  # 143 = SIGTERM, …). The fix must not special-case 124.
  local repo tmpbin
  repo=$(make_repo)
  tmpbin=$(_make_followup_stubs 1)

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" follow-up 99

  [ "$status" -eq 1 ]

  local last
  last=$(_last_gh_comment_argv)
  [ -n "$last" ]
  echo "$last" | grep -qF '🤖 Developer agent'
  echo "$last" | grep -qF 'exit=1'
}

# ---------------------------------------------------------------------------
# Regression guards: success path + non-follow-up modes must NOT post the
# failure marker.
# ---------------------------------------------------------------------------

@test "run-developer.sh follow-up: claude exit 0 → no failure marker (regression guard)" {
  # Graceful exit: the LLM's own '🤖 Developer agent — follow-up complete'
  # comment (posted from inside the prompt) is what advances the dispatcher
  # gate. The wrapper-side marker must NOT be posted on success — otherwise
  # we'd have two consecutive '🤖 Developer agent' comments per cycle and
  # operators would lose signal-to-noise on the activity log.
  local repo tmpbin
  repo=$(make_repo)
  tmpbin=$(_make_followup_stubs 0)

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" follow-up 99

  [ "$status" -eq 0 ]

  # gh may have been called (the LLM is mocked, so probably not — but be
  # defensive). The wrapper itself must not have invoked `gh pr comment`.
  if [ -s "$BATS_TEST_TMPDIR/gh-calls.log" ]; then
    ! grep -qF 'pr comment' "$BATS_TEST_TMPDIR/gh-calls.log"
  fi
}

# ---------------------------------------------------------------------------
# Source-of-truth: the wrapper must reference $TARGET_PR + the failure marker
# string somewhere after `wait "$PIPELINE_PID"`. This guards against a future
# refactor that splits the wait/exit into helpers and accidentally drops the
# new code path.
# ---------------------------------------------------------------------------

@test "run-developer.sh: failure-marker phrase 'failed mid-flow' is wired up (GH#49)" {
  grep -qF 'failed mid-flow' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: failure-marker uses the DEV_AGENT_COMMENT_PREFIX (🤖 Developer agent) so eligibility_followup_pr recognizes it" {
  # The marker body must literally begin with the prefix. Otherwise the
  # eligibility predicate's startswith($prefix) filter drops it and the
  # gate doesn't ratchet forward.
  grep -qE '🤖 Developer agent.*failed mid-flow' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: failure-marker block runs only when MODE=follow-up" {
  # Source-of-truth — the marker must be gated on $MODE so Mode 1 / Mode 3
  # hard failures don't mis-post a follow-up-shaped comment on an unrelated
  # PR. The wrapper has no $TARGET_PR in Mode 1 anyway, but we want to fail
  # fast rather than try to exec gh with an empty PR number.
  # Look in a 5-line window AROUND the marker for the MODE=follow-up gate.
  grep -B5 -F 'failed mid-flow' "$LOOP_ROOT/runners/run-developer.sh" \
    | grep -qE '\$MODE"?[[:space:]]*=[[:space:]]*"?follow-up'
}

@test "run-developer.sh: failure-marker is posted AFTER wait (so the LLM had its chance to graceful-exit)" {
  # Post-wait placement is required: a marker posted before `wait` would race
  # the LLM's own graceful-exit comment and double-post on the success path.
  local wait_line marker_line
  wait_line=$(grep -nE '^wait[[:space:]]*"\$PIPELINE_PID"' "$LOOP_ROOT/runners/run-developer.sh" | head -1 | cut -d: -f1)
  marker_line=$(grep -nF 'failed mid-flow' "$LOOP_ROOT/runners/run-developer.sh" | head -1 | cut -d: -f1)
  [ -n "$wait_line" ]
  [ -n "$marker_line" ]
  [ "$marker_line" -gt "$wait_line" ]
}
