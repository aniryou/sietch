#!/usr/bin/env bats
# GH#55 — reviewer wrapper posts a stub [reviewer-agent: blocked] review when
# the orchestrator emits `result=sub-agent-failed` and exits 0.
#
# Background: when the orchestrator's sub-agent crashes / hits max-turns /
# forgets the verdict marker, the orchestrator emits
#   `[reviewer-orchestrator] result=sub-agent-failed pr=#N reason=...`
# and exits 0. No `[reviewer-agent: <verdict>]` review is posted on the PR, so
# eligibility_review_pending continues to count the PR as pending review and
# every poll re-spawns the orchestrator + sub-agent — both crash the same way,
# burning ~$0.50–$2.50/cycle. Same architectural shape as #48/#49.
#
# Fix: in run-reviewer.sh, after `wait "$PIPELINE_PID"` and only when the
# pipeline exited 0, parse the log for `result=sub-agent-failed pr=#N` and
# post a stub review whose body matches REVIEWER_AGENT_VERDICT_REGEX. The
# predicate's "review covers head" half then fires next cycle and skips the
# PR until a new commit lands.
#
# The orchestrator template's hard rule "Never call gh pr review" forces this
# fix to live in the wrapper rather than the orchestrator itself.

load 'helpers'

# Build a tmp PATH dir with:
#   - `gh` shim that:
#       (a) serves the eligibility preflight: `pr list` returns one PR with
#           empty reviews + a COMPLETED+SUCCESS check (so predicate exits 0
#           and the wrapper proceeds to claude); `api graphql` returns a date.
#       (b) captures any `pr review` / `pr comment` argv to a sentinel file
#           so the test can assert exactly which calls fired.
#   - `claude` shim whose stdout is the stream-json payload for the test —
#     usually one assistant-text event embedding the orchestrator's marker
#     line. Exit code is the test parameter.
_make_path_stubs() {
  local claude_exit="$1"
  local claude_stdout="$2"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"

  # gh stub. Single-quoted heredoc body where possible; we interpolate the
  # state path by concatenation so the body itself doesn't need bash escapes.
  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
ARGS=("\$@")
SUB1="\${ARGS[0]:-}"
SUB2="\${ARGS[1]:-}"

# Honor --jq the way real gh does (post-filter via jq).
JQ_EXPR=""
for ((i=0; i<\${#ARGS[@]}; i++)); do
  if [ "\${ARGS[i]}" = "--jq" ]; then JQ_EXPR="\${ARGS[i+1]:-}"; fi
done
emit() {
  if [ -n "\$JQ_EXPR" ]; then printf '%s\n' "\$1" | jq -r "\$JQ_EXPR"
  else printf '%s\n' "\$1"; fi
}

case "\$SUB1 \$SUB2" in
  "pr list")
    # One eligible PR: empty reviews + completed CI → predicate sees "pending
    # review", exits 0, wrapper invokes claude.
    emit '[{"number":99,"headRefOid":"abc123","reviews":[],"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}]'
    exit 0
    ;;
  "api graphql")
    emit '{"data":{"repository":{"object":{"committedDate":"2026-05-07T10:00:00Z"}}}}'
    exit 0
    ;;
  "pr view")
    # GH#94 cap path: wrapper queries existing reviews + labels before posting
    # the stub. Drive the test scenario via state files:
    #   \$state/stub-review-count   — N existing stub-blocked reviews on the PR
    #   \$state/has-escalation-label — "1" if escalation label already present
    # Defaults (file missing) are 0 / 0 — matching the original GH#55 path.
    STUB_COUNT=0
    if [ -f '$state/stub-review-count' ]; then
      STUB_COUNT=\$(cat '$state/stub-review-count')
    fi
    HAS_LABEL=0
    if [ -f '$state/has-escalation-label' ]; then
      HAS_LABEL=\$(cat '$state/has-escalation-label')
    fi
    REVIEWS=\$(jq -n --argjson n "\$STUB_COUNT" '
      [range(\$n) | {
        body: "🤖 [reviewer-agent: blocked] Sub-agent run failed before posting a review (likely context exhaustion or API failure).",
        submittedAt: "2026-05-07T10:00:00Z"
      }]')
    LABELS=\$(jq -n --argjson has "\$HAS_LABEL" '
      if \$has == 1 then [{name: "reviewer:needs-human"}] else [] end')
    emit "\$(jq -n --argjson reviews "\$REVIEWS" --argjson labels "\$LABELS" \
      '{reviews: \$reviews, labels: \$labels}')"
    exit 0
    ;;
  "pr review"|"pr comment"|"pr edit"|"label create")
    {
      printf 'CALL: '
      printf '%s ' "\$@"
      printf '\n'
    } >>'$state/gh-args'
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$tmpbin/gh"

  # claude stub. Writes the supplied stream-json payload to stdout, then exits.
  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
touch '$state/claude-was-called'
cat <<'JSON'
${claude_stdout}
JSON
exit ${claude_exit}
STUB
  chmod +x "$tmpbin/claude"
}

# ---------------------------------------------------------------------------
# Behavioral: orchestrator reports sub-agent-failed → wrapper posts stub.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: orchestrator emits result=sub-agent-failed → wrapper posts stub [reviewer-agent: blocked] review on the PR" {
  local repo
  repo=$(make_repo)
  # Stream-json: one assistant-text event whose .text contains the orchestrator's
  # final summary line. The wrapper greps the rendered LOG (or the RAW jsonl)
  # for the marker substring, so any path that leaves the marker on disk works.
  _make_path_stubs 0 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-orchestrator] result=sub-agent-failed pr=#99 reason=context-exhausted"}]}}'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  # Exactly one stub review was posted on PR #99.
  grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--comment' "$BATS_TEST_TMPDIR/state/gh-args"
  # Body must match REVIEWER_AGENT_VERDICT_REGEX so the predicate's
  # "review covers head" gate fires next cycle.
  grep -qF '[reviewer-agent: blocked]' "$BATS_TEST_TMPDIR/state/gh-args"
  # Exactly one pr-review call (not a duplicate per pipeline buffer).
  [ "$(grep -c 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Regression guard: orchestrator success path must NOT trigger stub review.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: orchestrator emits result=dispatched (success) → no stub review posted" {
  local repo
  repo=$(make_repo)
  # The orchestrator's normal success summary line uses 'dispatched', NOT
  # 'sub-agent-failed'. Wrapper must not match this and must not post a stub.
  _make_path_stubs 0 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-orchestrator] dispatched pr=#99 sub-agent-result=commented"}]}}'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF '[reviewer-agent: blocked]' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

# ---------------------------------------------------------------------------
# Defensive: orchestrator emits no marker line at all (LLM crashed before
# any text output) → wrapper logs and does nothing. The cycle still wastes
# the LLM cost but the wrapper must not invent a PR# to post against.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: claude emits no orchestrator marker → no stub review posted (defensive)" {
  local repo
  repo=$(make_repo)
  # Empty stdout — pipeline produces an empty LOG/RAW.
  _make_path_stubs 0 ''

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 0 ]
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

# ---------------------------------------------------------------------------
# Regression guard: claude exits non-zero. The fix must be exit-0-scoped —
# a hard claude failure (max-turns, OOM, API outage) is a wrapper-level
# failure, not an orchestrator's-considered-decision failure. The wrapper
# already propagates that exit code via run-loop.sh's existing backoff.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: claude exits non-zero → no stub review posted (exit code propagates)" {
  local repo
  repo=$(make_repo)
  # Even if the marker is in the stream, a non-zero LLM exit means the
  # orchestrator didn't run to completion — defer to the existing
  # backoff/retry path rather than inventing a verdict.
  _make_path_stubs 124 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-orchestrator] result=sub-agent-failed pr=#99 reason=context-exhausted"}]}}'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 124 ]
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the new fallback wiring so a future refactor can't
# silently drop the gh-pr-review call or reintroduce the leak.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: GH#55 stub-review fallback is wired up after wait" {
  # Wrapper greps the orchestrator's failure marker.
  grep -qF 'result=sub-agent-failed' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Wrapper posts the stub review with the verdict-regex-matching body.
  grep -qF '[reviewer-agent: blocked]' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Wrapper invokes gh pr review (the only way the predicate's "review
  # covers head" half can fire on the next cycle).
  grep -qE 'gh pr review' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "reviewer-orchestrator.md: documents wrapper-side stub-review fallback (GH#55)" {
  # Coupling note: anyone changing the orchestrator's hard-rule against
  # `gh pr review` or the wrapper's failure-marker grep needs to update
  # both sites. This test enforces the doc trail.
  grep -qF 'GH#55' "$LOOP_ROOT/templates/reviewer-orchestrator.md"
}

# ---------------------------------------------------------------------------
# GH#94: per-PR cap on consecutive sub-agent failures. After
# REVIEWER_SUB_AGENT_FAILURE_CAP (default 3) wrapper-stub reviews on the same
# PR, the next failure escalates to a human (label + one comment) instead of
# posting yet another stub. This stops the per-PR loop on deterministically-
# failing PRs (oversized diff, malformed PR) where every new push reproduces
# the same sub-agent failure and accumulates blocked stubs indefinitely.
#
# The cap is observable via `gh pr view --json reviews` filtered on the
# stub-body marker substring "Sub-agent run failed before posting a review"
# (run-reviewer.sh:139). The escalation label defaults to `reviewer:needs-human`
# and is consumed by eligibility_review_pending to drop the PR from review
# dispatch until a human removes the label.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: PR has 2 existing stub reviews → wrapper posts stub #3 (still under default cap of 3) (GH#94)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-orchestrator] result=sub-agent-failed pr=#99 reason=context-exhausted"}]}}'
  echo 2 >"$BATS_TEST_TMPDIR/state/stub-review-count"
  echo 0 >"$BATS_TEST_TMPDIR/state/has-escalation-label"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  # Stub #3 IS posted (count was 2; 2 < cap=3, still under).
  grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF '[reviewer-agent: blocked]' "$BATS_TEST_TMPDIR/state/gh-args"
  # Cap-path side effects must NOT have fired.
  ! grep -qF 'pr edit 99' "$BATS_TEST_TMPDIR/state/gh-args"
  ! grep -qF 'label create' "$BATS_TEST_TMPDIR/state/gh-args"
  ! grep -qF 'pr comment 99' "$BATS_TEST_TMPDIR/state/gh-args"
}

@test "run-reviewer.sh: PR has 3 existing stub reviews → wrapper escalates (label + one comment, no stub) (GH#94)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-orchestrator] result=sub-agent-failed pr=#99 reason=context-exhausted"}]}}'
  echo 3 >"$BATS_TEST_TMPDIR/state/stub-review-count"
  echo 0 >"$BATS_TEST_TMPDIR/state/has-escalation-label"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  # Escalation: label create (idempotent --force) + label add to PR + ONE
  # escalation comment. NO stub review.
  grep -qF 'label create' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'reviewer:needs-human' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr edit 99' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr comment 99' "$BATS_TEST_TMPDIR/state/gh-args"
  # Critical: no stub review posted at the cap.
  ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  # Comment was posted exactly once (no pile-up).
  [ "$(grep -c 'pr comment 99' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
}

@test "run-reviewer.sh: PR already has escalation label → wrapper is fully idempotent (no label, no comment, no stub) (GH#94)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-orchestrator] result=sub-agent-failed pr=#99 reason=context-exhausted"}]}}'
  echo 5 >"$BATS_TEST_TMPDIR/state/stub-review-count"
  echo 1 >"$BATS_TEST_TMPDIR/state/has-escalation-label"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh"

  [ "$status" -eq 0 ]
  # No mutating side effects at all — full idempotency. The label is already
  # present, the human has been notified, and re-posting either the label
  # or the comment would just pile up noise. gh-args either doesn't exist
  # (no captured call fired) or is empty.
  [ ! -f "$BATS_TEST_TMPDIR/state/gh-args" ] || [ ! -s "$BATS_TEST_TMPDIR/state/gh-args" ]
}

@test "run-reviewer.sh: GH#94 cap + escalation wiring is present (source-of-truth)" {
  # Wrapper grep counts existing stubs by the marker substring.
  grep -qF 'Sub-agent run failed before posting a review' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Cap config knob.
  grep -qF 'REVIEWER_SUB_AGENT_FAILURE_CAP' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Escalation label config knob.
  grep -qF 'REVIEWER_ESCALATION_LABEL' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Wrapper applies the label via gh pr edit (the GH CLI label-add idiom).
  grep -qE 'gh pr edit' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "loop.config.example: documents REVIEWER_SUB_AGENT_FAILURE_CAP + REVIEWER_ESCALATION_LABEL (GH#94)" {
  grep -qF 'REVIEWER_SUB_AGENT_FAILURE_CAP' "$LOOP_ROOT/templates/loop.config.example"
  grep -qF 'REVIEWER_ESCALATION_LABEL' "$LOOP_ROOT/templates/loop.config.example"
}

@test "reviewer-orchestrator.md: GH#55 note references the GH#94 cap (coupling)" {
  # Anyone changing the failure-marker format must update both the per-SHA
  # stub grep AND the per-PR cap grep — they're the same marker.
  grep -qF 'GH#94' "$LOOP_ROOT/templates/reviewer-orchestrator.md"
}
