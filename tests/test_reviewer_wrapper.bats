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
  "pr review"|"pr comment")
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
