#!/usr/bin/env bats
# GH#111 — Mode 3 (resolve-conflicts) per-PR cap on consecutive hard-failures.
#
# Background: GH#48 added a wrapper-side fallback that posts a `🤖 Mode 3
# conflict resolution — aborted` comment + drafts the PR when claude exits
# non-zero before reaching one of the prompt's three graceful abort blocks
# (ambiguous-intent / post-resolution test failure / post-force-push CI
# failure). Each new push to a CONFLICTING PR un-drafts it, the conflicts
# dispatcher re-fires Mode 3, and on a deterministically-failing PR every
# cycle accumulates another `🤖 Mode 3 conflict resolution — aborted` comment
# (~$0.50–$2.00 per LLM run).
#
# Fix (mirrors GH#94 reviewer pattern + GH#56 dev Mode 1 pattern): after
# DEV_CONFLICTS_FAILURE_RETRY_LIMIT (default 3) consecutive abort markers on
# the same PR, the wrapper escalates via BLOCKED_HUMAN_LABEL + one comment
# instead of posting yet another fallback stub. Drafting (`gh pr ready --undo`)
# still happens — it's a per-trigger circuit breaker, not a per-PR cap, and
# is what _dispatch_conflicts_jq's `isDraft == false` filter consumes to
# stop re-firing the LLM in the next cycle.
#
# The cap is observable via `gh pr view --json comments` filtered on the
# marker substring `🤖 Mode 3 conflict resolution — aborted` (which both
# the LLM's graceful abort blocks and the wrapper's hard-fail stub use).

load 'helpers'

# Build a fake LOOP_HOME with a stubbed run-conflict-triage.sh that always
# reports rc=0 reason=mechanical-conflict, so the wrapper falls through to the
# claude pipeline — that's the path Mode 3 hard-failure handling lives on.
# Mirrors test_run_developer_triage_no_conflict.bats's helper but with a
# fixed rc=0/tractable body.
_make_loop_home_with_tractable_triage() {
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
  cat >"$fake/runners/run-conflict-triage.sh" <<'TRI'
#!/usr/bin/env bash
echo '[triage] result=tractable reason=mechanical-conflict-3-lines issue=#7 conflict_files=requirements.txt conflict_lines=3'
exit 0
TRI
  chmod +x "$fake/runners/run-conflict-triage.sh"
  echo "$fake"
}

# PATH-mock claude (exits non-zero to trigger Mode 3 hard-failure block) and
# gh (records argv + serves pr view --json comments,labels from state files).
# State file conventions match the GH#94 reviewer-wrapper test pattern:
#   $state/marker-count        — N existing abort-marker comments on the PR
#   $state/has-blocked-label   — "1" if BLOCKED_HUMAN_LABEL already present
_make_path_stubs() {
  local claude_exit="$1"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"

  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
# Emit one stream-json event so the wrapper's tee/jq pipeline doesn't choke.
printf '{"type":"system","subtype":"init","model":"mock"}\n'
exit ${claude_exit}
STUB
  chmod +x "$tmpbin/claude"

  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
{
  printf 'CALL: '
  printf '%s ' "\$@"
  printf '\n'
} >>'$state/gh-args'

if [ "\$1 \$2" = "pr view" ]; then
  STUB_COUNT=0
  if [ -f '$state/marker-count' ]; then STUB_COUNT=\$(cat '$state/marker-count'); fi
  HAS_LABEL=0
  if [ -f '$state/has-blocked-label' ]; then HAS_LABEL=\$(cat '$state/has-blocked-label'); fi
  COMMENTS=\$(jq -n --argjson n "\$STUB_COUNT" '
    [range(\$n) | {
      body: "🤖 Mode 3 conflict resolution — aborted (agent run failed mid-flow, exit=124).",
      createdAt: "2026-05-07T10:00:00Z"
    }]')
  LABELS=\$(jq -n --argjson has "\$HAS_LABEL" '
    if \$has == 1 then [{name: "blocked:human"}] else [] end')
  jq -n --argjson comments "\$COMMENTS" --argjson labels "\$LABELS" \
    '{comments: \$comments, labels: \$labels}'
  exit 0
fi
exit 0
STUB
  chmod +x "$tmpbin/gh"
}

_set_pr_state() {
  local count="${1:-0}" has_label="${2:-0}"
  echo "$count" > "$BATS_TEST_TMPDIR/state/marker-count"
  echo "$has_label" > "$BATS_TEST_TMPDIR/state/has-blocked-label"
}

# ---------------------------------------------------------------------------
# Behavioral: under cap → wrapper posts hard-fail stub + drafts.
# ---------------------------------------------------------------------------

@test "Mode 3: 0 abort markers → wrapper posts hard-fail stub + drafts the PR (GH#111 under-cap regression guard)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_tractable_triage)
  _make_path_stubs 124
  _set_pr_state 0 0

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 7

  [ "$status" -eq 124 ]
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  # Stub comment + draft both fired.
  grep -qF 'pr comment 7' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF '🤖 Mode 3 conflict resolution — aborted' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr ready --undo 7' "$BATS_TEST_TMPDIR/state/gh-args"
  # Cap-path side effects must NOT have fired. Use `grep -c == 0` — bats
  # doesn't enforce `!`-prefixed assertions when later commands succeed.
  [ -z "$(grep -F 'label create' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
  [ -z "$(grep -F 'pr edit 7' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
}

@test "Mode 3: 2 abort markers → wrapper posts stub #3 + drafts (still under cap=3) (GH#111)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_tractable_triage)
  _make_path_stubs 124
  _set_pr_state 2 0

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 7

  [ "$status" -eq 124 ]
  grep -qF 'pr comment 7' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF '🤖 Mode 3 conflict resolution — aborted' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr ready --undo 7' "$BATS_TEST_TMPDIR/state/gh-args"
  # Cap-path side effects must NOT have fired (count 2 < cap 3).
  [ -z "$(grep -F 'label create' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
  [ -z "$(grep -F 'pr edit 7' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
  # Exactly one pr-comment call (no double-post).
  [ "$(grep -c 'pr comment 7' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Behavioral: at cap → wrapper escalates (label + one comment) instead of stub,
# AND still drafts (per-trigger circuit breaker).
# ---------------------------------------------------------------------------

@test "Mode 3: 3 abort markers → wrapper escalates (label + one comment, no stub) and still drafts (GH#111)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_tractable_triage)
  _make_path_stubs 124
  _set_pr_state 3 0

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 7

  [ "$status" -eq 124 ]
  # Escalation: label create (idempotent --force) + label add to PR + ONE
  # escalation comment.
  grep -qF 'label create' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'blocked:human' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr edit 7' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr comment 7' "$BATS_TEST_TMPDIR/state/gh-args"
  # Critical: the escalation comment must NOT contain the count-marker
  # substring "🤖 Mode 3 conflict resolution — aborted" — otherwise the
  # next cycle would count it as another abort and re-trigger escalation.
  [ -z "$(grep -F 'pr comment 7' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null \
          | grep -F '🤖 Mode 3 conflict resolution — aborted')" ]
  # Drafting still fires — per-trigger circuit breaker (not a per-PR cap).
  grep -qF 'pr ready --undo 7' "$BATS_TEST_TMPDIR/state/gh-args"
  # Comment was posted exactly once (no pile-up).
  [ "$(grep -c 'pr comment 7' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
}

@test "Mode 3: PR already has BLOCKED_HUMAN_LABEL → fully idempotent (no label, no comment, no stub) but still drafts (GH#111)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_tractable_triage)
  _make_path_stubs 124
  _set_pr_state 5 1

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 7

  [ "$status" -eq 124 ]
  # No mutating side effects from the cap path — full idempotency.
  [ -z "$(grep -F 'label create' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
  [ -z "$(grep -F 'pr edit 7' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
  [ -z "$(grep -F 'pr comment 7' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
  # Drafting STILL fires — per-trigger, not per-PR.
  grep -qF 'pr ready --undo 7' "$BATS_TEST_TMPDIR/state/gh-args"
}

# ---------------------------------------------------------------------------
# Regression guards: success path + non-resolve-conflicts modes must NOT
# trigger the Mode 3 cap path.
# ---------------------------------------------------------------------------

@test "Mode 3: claude exits 0 → no hard-fail block fires (regression guard)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_tractable_triage)
  _make_path_stubs 0
  _set_pr_state 5 0   # plenty of pre-existing markers; should be irrelevant

  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 7

  [ "$status" -eq 0 ]
  # On success, the LLM is responsible for any PR comments and the wrapper
  # must NOT post a hard-fail stub or draft the PR.
  [ -z "$(grep -F '🤖 Mode 3 conflict resolution — aborted' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
  [ -z "$(grep -F 'pr ready --undo 7' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
  [ -z "$(grep -F 'label create' "$BATS_TEST_TMPDIR/state/gh-args" 2>/dev/null)" ]
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the new wiring so a future refactor can't silently
# drop the per-PR cap and reopen the per-PR token leak.
# ---------------------------------------------------------------------------

@test "run-developer.sh: GH#111 Mode 3 cap+escalation wiring is present" {
  # Cap config knob.
  grep -qF 'DEV_CONFLICTS_FAILURE_RETRY_LIMIT' "$LOOP_ROOT/runners/run-developer.sh"
  # Wrapper queries pr view for comments to count markers (the has-label
  # idempotency short-circuit lives in hard_failure_idempotent_escalate,
  # which does its own --json labels fetch).
  grep -qF 'gh pr view' "$LOOP_ROOT/runners/run-developer.sh"
  grep -qF -- '--json comments' "$LOOP_ROOT/runners/run-developer.sh"
  # The Mode 3 marker substring is preserved (graceful aborts in the prompt
  # use it too, so log-scrapers / dashboards rely on it).
  grep -qF '🤖 Mode 3 conflict resolution — aborted' "$LOOP_ROOT/runners/run-developer.sh"
  # At-cap branch delegates to the shared escalation helper (GH#108 / PR #119).
  grep -qF 'hard_failure_idempotent_escalate pr' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "loop.config.example: documents DEV_CONFLICTS_FAILURE_RETRY_LIMIT (GH#111)" {
  grep -qF 'DEV_CONFLICTS_FAILURE_RETRY_LIMIT' "$LOOP_ROOT/templates/loop.config.example"
}

@test "run-developer.sh: Mode 3 hard-fail block draft (gh pr ready --undo) fires regardless of cap (per-trigger circuit breaker)" {
  # Source-of-truth: the `gh pr ready --undo` call must remain in the resolve-
  # conflicts hard-failure block AFTER the cap-vs-stub decision, so it fires
  # whether we posted a stub OR escalated. This is the per-trigger circuit
  # breaker that _dispatch_conflicts_jq's `isDraft == false` filter consumes
  # to stop re-firing the LLM next cycle (GH#44 / GH#48).
  local block draft_seen
  block=$(awk '/MODE" = "resolve-conflicts" \] && \[ "\$LLM_EXIT" -ne 0/,/^fi$/' \
    "$LOOP_ROOT/runners/run-developer.sh")
  draft_seen=$(echo "$block" | grep -c 'gh pr ready --undo' || true)
  [ "$draft_seen" -ge 1 ]
}
