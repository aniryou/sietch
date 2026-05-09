#!/usr/bin/env bats
# GH#55 + GH#94 + GH#117 — reviewer wrapper exercises the flattened single-PR
# invocation, the missing-marker stub-review fallback, and the per-PR cap that
# escalates to a human after $REVIEWER_SUB_AGENT_FAILURE_CAP consecutive
# failures.
#
# Background:
# - GH#117 collapsed the previous orchestrator → sub-agent dispatch into a
#   single `claude -p` invocation rendered with `templates/reviewer.md` as the
#   system prompt and `ASSIGNMENT: Review GitHub PR #<N>` in the user prompt.
#   The wrapper now takes a mandatory `<PR>` positional arg; it does its own
#   defense-in-depth eligibility check against that single PR before spawning
#   the LLM.
# - GH#55: when the LLM exits 0 but never reaches its final
#   `[reviewer-agent] result=...` line (typical: max-turns mid-review,
#   context exhaustion), no review is posted on the PR. The dispatcher would
#   then re-fire the wrapper every cycle on the same PR, the LLM crashes the
#   same way, repeat — leaking ~$0.50–$2.50/cycle per such PR. The wrapper
#   posts a stub `[reviewer-agent: blocked]` review whose body matches
#   REVIEWER_AGENT_VERDICT_REGEX so the predicate's "review covers head" half
#   fires next cycle and skips the PR until a new commit lands.
# - GH#94: caps consecutive stubs on the same PR at
#   $REVIEWER_SUB_AGENT_FAILURE_CAP — beyond that, escalate to a human via
#   $REVIEWER_ESCALATION_LABEL + a one-time explanation comment.

load 'helpers'

# Build a tmp PATH dir with:
#   - `gh` shim that:
#       (a) serves the wrapper preflight: `pr view` returns the eligibility
#           shape (state, isDraft, headRefOid, reviews, labels,
#           statusCheckRollup) — the configured fixture below covers a clean
#           "ready for review" PR. The same shim later answers the GH#94
#           cap-counter `pr view` (reviews + labels) — the test seeds
#           $state/stub-review-count and $state/has-escalation-label to drive
#           the cap path.
#       (b) captures any `pr review` / `pr comment` / `pr edit` /
#           `label create` argv to a sentinel file so the test can assert
#           exactly which calls fired.
#   - `claude` shim whose stdout is the stream-json payload for the test —
#     usually one assistant-text event embedding the LLM's final summary
#     line (or empty for the no-marker crash case). Exit code is the test
#     parameter.
_make_path_stubs() {
  local claude_exit="$1"
  local claude_stdout="$2"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"

  # Defaults (the GH#55 happy path): no existing stubs, no escalation label.
  # Tests that need the cap path overwrite these files.
  [ -f "$state/stub-review-count" ] || echo 0 >"$state/stub-review-count"
  [ -f "$state/has-escalation-label" ] || echo 0 >"$state/has-escalation-label"
  # Eligibility-stub state: empty reviews, no escalation label, completed CI,
  # state=OPEN, isDraft=false. Tests can override by writing $state/elig-*.
  [ -f "$state/elig-state" ] || echo OPEN >"$state/elig-state"
  [ -f "$state/elig-isDraft" ] || echo false >"$state/elig-isDraft"

  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
ARGS=("\$@")
SUB1="\${ARGS[0]:-}"
SUB2="\${ARGS[1]:-}"
SUB3="\${ARGS[2]:-}"

# Honor --jq the way real gh does (post-filter via jq).
JQ_EXPR=""
for ((i=0; i<\${#ARGS[@]}; i++)); do
  if [ "\${ARGS[i]}" = "--jq" ]; then JQ_EXPR="\${ARGS[i+1]:-}"; fi
done
emit() {
  if [ -n "\$JQ_EXPR" ]; then printf '%s\n' "\$1" | jq -r "\$JQ_EXPR"
  else printf '%s\n' "\$1"; fi
}

# Detect which JSON field set was requested so we can serve either the
# eligibility shape OR the GH#94 cap-counter shape from the same `pr view`
# verb.
JSON_EXPR=""
for ((i=0; i<\${#ARGS[@]}; i++)); do
  if [ "\${ARGS[i]}" = "--json" ]; then JSON_EXPR="\${ARGS[i+1]:-}"; fi
done

case "\$SUB1 \$SUB2" in
  "pr view")
    if [[ "\$JSON_EXPR" == *statusCheckRollup* ]]; then
      # Wrapper preflight (run-reviewer.sh:eligibility check).
      ELIG_STATE=\$(cat '$state/elig-state')
      ELIG_DRAFT=\$(cat '$state/elig-isDraft')
      emit "\$(jq -n --arg s "\$ELIG_STATE" --arg d "\$ELIG_DRAFT" '
        {state: \$s, isDraft: (\$d == "true"), headRefOid: "abc123",
         number: 99, reviews: [], labels: [],
         statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}')"
      exit 0
    fi
    # GH#94 cap-counter shape: reviews + labels only.
    STUB_COUNT=\$(cat '$state/stub-review-count')
    HAS_LABEL=\$(cat '$state/has-escalation-label')
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
# Argument validation: the wrapper must require a numeric <PR> arg (GH#117).
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: no arg → exit 2 with usage on stderr (GH#117)" {
  local repo
  repo=$(make_repo)
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run bash "$LOOP_ROOT/runners/run-reviewer.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qiF 'usage'
}

@test "run-reviewer.sh: non-numeric arg → exit 2 with usage on stderr (GH#117)" {
  local repo
  repo=$(make_repo)
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run bash "$LOOP_ROOT/runners/run-reviewer.sh" not-a-number
  [ "$status" -eq 2 ]
  echo "$output" | grep -qiF 'usage'
}

# ---------------------------------------------------------------------------
# Defense-in-depth eligibility (GH#117): the dispatcher already filtered, but
# the time between scan and wrapper start is non-zero. PR became draft, CI
# restarted, escalation label was applied — wrapper must short-circuit on rc=2
# without spawning the LLM.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: PR became draft after dispatch → exit 2, no LLM (GH#117)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 ''
  echo true >"$BATS_TEST_TMPDIR/state/elig-isDraft"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
}

@test "run-reviewer.sh: PR closed after dispatch → exit 2, no LLM (GH#117)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 ''
  echo CLOSED >"$BATS_TEST_TMPDIR/state/elig-state"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
}

# ---------------------------------------------------------------------------
# Behavioral: LLM exits 0 with no [reviewer-agent] result line → wrapper
# posts stub. This is the GH#55 path under the GH#117 detection model.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: LLM produces no result line on exit 0 → wrapper posts stub (GH#55+GH#117)" {
  local repo
  repo=$(make_repo)
  # Empty stdout — the LLM crashed before reaching its final summary line.
  _make_path_stubs 0 ''

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--comment' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF '[reviewer-agent: blocked]' "$BATS_TEST_TMPDIR/state/gh-args"
  [ "$(grep -c 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Regression guard: a successful review (LLM emits its result line) must NOT
# trigger the stub fallback.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: LLM emits [reviewer-agent] result=commented → no stub posted (GH#117)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-agent] result=commented pr=#99 sha=abc findings=P0:0 P1:1 P2:0 beads=loop-xyz"}]}}'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

@test "run-reviewer.sh: LLM emits result=skipped → no stub posted (sanity-check abort path)" {
  # The sub-agent's own sanity check fired (e.g., PR became draft mid-flight).
  # Result line IS present → wrapper trusts the LLM and does not invent a
  # blocked verdict.
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-agent] result=skipped pr=#99 sha=n/a findings=P0:0 P1:0 P2:0 beads=loop-xyz"}]}}'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

# ---------------------------------------------------------------------------
# Regression guard: a hard claude failure (non-zero exit) must NOT trigger
# the stub fallback. Exit-code propagates so run-loop.sh's existing backoff
# applies.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: claude exits non-zero → no stub posted, exit code propagates" {
  local repo
  repo=$(make_repo)
  # Even with no marker, a non-zero LLM exit is a wrapper-level failure.
  _make_path_stubs 124 ''

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 124 ]
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the new fallback wiring so a future refactor can't
# silently drop the gh-pr-review call or reintroduce the leak.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: stub-review fallback is wired up after wait (GH#55)" {
  # Wrapper greps for the absence of the LLM's success-marker line.
  grep -qF '[reviewer-agent] result=' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Wrapper posts the stub review with the verdict-regex-matching body.
  grep -qF '[reviewer-agent: blocked]' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Wrapper invokes gh pr review (the only way the predicate's "review
  # covers head" half can fire on the next cycle).
  grep -qE 'gh pr review' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-reviewer.sh: takes a mandatory PR positional argument (GH#117)" {
  # Source-of-truth pin: future refactors cannot silently drop the arg
  # validation that turns the wrapper into a per-PR runner.
  grep -qF 'TARGET_PR="${1:-}"' "$LOOP_ROOT/runners/run-reviewer.sh"
  grep -qE 'TARGET_PR.*=~ \^\[0-9\]\+' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-reviewer.sh: invokes templates/reviewer.md (no orchestrator template, GH#117)" {
  # The flattened invocation renders templates/reviewer.md as system prompt.
  grep -qF 'templates/reviewer.md' "$LOOP_ROOT/runners/run-reviewer.sh"
  # The orchestrator template is no longer rendered. (Comments may still
  # reference the prior shape for the change-history paper trail; the pin
  # below targets the actual render call.)
  ! grep -qE 'render-prompt[^"]*templates/reviewer-orchestrator' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "templates/reviewer-orchestrator.md is removed (GH#117)" {
  [ ! -f "$LOOP_ROOT/templates/reviewer-orchestrator.md" ]
}

# ---------------------------------------------------------------------------
# GH#94: per-PR cap on consecutive failures. After
# REVIEWER_SUB_AGENT_FAILURE_CAP (default 3) wrapper-stub reviews on the same
# PR, the next failure escalates to a human (label + one comment) instead of
# posting yet another stub. This stops the per-PR loop on deterministically-
# failing PRs (oversized diff, malformed PR) where every new push reproduces
# the same LLM failure and accumulates blocked stubs indefinitely.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: PR has 2 existing stub reviews → wrapper posts stub #3 (still under cap=3) (GH#94)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 ''
  echo 2 >"$BATS_TEST_TMPDIR/state/stub-review-count"
  echo 0 >"$BATS_TEST_TMPDIR/state/has-escalation-label"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

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
  _make_path_stubs 0 ''
  echo 3 >"$BATS_TEST_TMPDIR/state/stub-review-count"
  echo 0 >"$BATS_TEST_TMPDIR/state/has-escalation-label"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  grep -qF 'label create' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'reviewer:needs-human' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr edit 99' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr comment 99' "$BATS_TEST_TMPDIR/state/gh-args"
  ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
  [ "$(grep -c 'pr comment 99' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
}

@test "run-reviewer.sh: PR already has escalation label → wrapper is fully idempotent (GH#94)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 ''
  echo 5 >"$BATS_TEST_TMPDIR/state/stub-review-count"
  echo 1 >"$BATS_TEST_TMPDIR/state/has-escalation-label"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  # Eligibility predicate excludes PRs carrying the escalation label, so
  # the wrapper short-circuits on rc=2 before reaching the LLM. But a buggy
  # config or label removal between scan and start could land us here — the
  # wrapper must remain idempotent if it ever gets here.
  # Either: the wrapper short-circuited (escalation_label preflight),
  # or: it ran the LLM and the cap path saw HAS_LABEL=1 → no mutating call.
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr review 99' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'pr comment 99' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'label create' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

@test "run-reviewer.sh: GH#94 cap + escalation wiring is present (source-of-truth)" {
  grep -qF 'Sub-agent run failed before posting a review' "$LOOP_ROOT/runners/run-reviewer.sh"
  grep -qF 'REVIEWER_SUB_AGENT_FAILURE_CAP' "$LOOP_ROOT/runners/run-reviewer.sh"
  grep -qF 'REVIEWER_ESCALATION_LABEL' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Wrapper delegates the label-add + comment to the shared helper from
  # runners/lib/hard_failure.sh (GH#108). The helper internally fires
  # `gh pr edit --add-label` + `gh pr comment`; the wrapper no longer
  # contains those calls inline.
  grep -qF 'hard_failure_idempotent_escalate pr' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "loop.config.example: documents REVIEWER_SUB_AGENT_FAILURE_CAP + REVIEWER_ESCALATION_LABEL (GH#94)" {
  grep -qF 'REVIEWER_SUB_AGENT_FAILURE_CAP' "$LOOP_ROOT/templates/loop.config.example"
  grep -qF 'REVIEWER_ESCALATION_LABEL' "$LOOP_ROOT/templates/loop.config.example"
}

@test "templates/reviewer.md: documents wrapper-side stub-review fallback + GH#94 cap (GH#55+GH#94 coupling)" {
  # Anyone changing the failure-marker format must update both the per-SHA
  # stub grep AND the per-PR cap grep — they're the same marker.
  grep -qF 'GH#94' "$LOOP_ROOT/templates/reviewer.md"
  grep -qF 'Sub-agent run failed before posting a review' "$LOOP_ROOT/templates/reviewer.md"
}

# ---------------------------------------------------------------------------
# GH#117 escalation-label preflight: a PR that already carries the escalation
# label must short-circuit before the LLM. Mirrors eligibility_review_pending's
# label gate so a wrapper invoked directly (bypassing the predicate) doesn't
# blow tokens on a PR the reviewer has already given up on.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: PR carries escalation label → preflight skip, no LLM (GH#117)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 ''
  # Override the elig-stub so `pr view --json ...labels` returns the label.
  # The eligibility branch in the gh shim merges this in via has-escalation-label.
  echo 1 >"$BATS_TEST_TMPDIR/state/has-escalation-label"
  # The eligibility-shape stub also needs to advertise the label. We do that
  # by replacing the stub for `pr view --json *statusCheckRollup*` to inject
  # `labels: [{name: ...}]`. Easiest: a separate, more targeted gh stub.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
JSON_EXPR=""
for ((i=0; i<${#ARGS[@]}; i++)); do
  if [ "${ARGS[i]}" = "--json" ]; then JSON_EXPR="${ARGS[i+1]:-}"; fi
done
case "${ARGS[0]:-} ${ARGS[1]:-}" in
  "pr view")
    if [[ "$JSON_EXPR" == *statusCheckRollup* ]]; then
      jq -n '{state: "OPEN", isDraft: false, headRefOid: "abc123", number: 99,
              reviews: [],
              labels: [{name: "reviewer:needs-human"}],
              statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}'
      exit 0
    fi
    jq -n '{reviews: [], labels: [{name: "reviewer:needs-human"}]}'
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
}

# ---------------------------------------------------------------------------
# GH#117 follow-up: skip:reviewed must scope the marker check to the current
# head SHA, mirroring the dispatcher's _REVIEW_ELIGIBLE_JQ "review covers head"
# semantic. Without the scoping, a marker review on a STALE head SHA would make
# the wrapper drop every "second-pass" review on a dev-agent PR after a
# follow-up commit.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: marker review on stale head SHA → wrapper proceeds (GH#117 fixup)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 '{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-agent] result=commented pr=#99 sha=newhead findings=P0:0 P1:0 P2:0 beads=loop-xyz"}]}}'

  # Custom gh shim that returns one marker review whose .commit.oid is OLD,
  # while the PR's current headRefOid is NEW.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
JSON_EXPR=""
for ((i=0; i<${#ARGS[@]}; i++)); do
  if [ "${ARGS[i]}" = "--json" ]; then JSON_EXPR="${ARGS[i+1]:-}"; fi
done
case "${ARGS[0]:-} ${ARGS[1]:-}" in
  "pr view")
    if [[ "$JSON_EXPR" == *statusCheckRollup* ]]; then
      jq -n '{state: "OPEN", isDraft: false, headRefOid: "newhead", number: 99,
              reviews: [{body: "🤖 Reviewer agent — automated review\n\n[reviewer-agent: clean]\n",
                         commit: {oid: "oldhead"},
                         submittedAt: "2026-05-01T00:00:00Z"}],
              labels: [],
              statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}'
      exit 0
    fi
    jq -n '{reviews: [], labels: []}'
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  # Wrapper must NOT short-circuit on `skip:reviewed` — the marker review is
  # on a stale SHA and the dispatcher's predicate already determined this PR
  # needs a re-review at the new head.
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
}

@test "run-reviewer.sh: marker review on current head SHA → wrapper skips (GH#117 fixup)" {
  local repo
  repo=$(make_repo)
  _make_path_stubs 0 ''

  # Custom gh shim: one marker review whose .commit.oid MATCHES the current
  # headRefOid. This is the "already reviewed at this head" case the wrapper
  # is supposed to short-circuit on.
  cat >"$BATS_TEST_TMPDIR/bin/gh" <<'STUB'
#!/usr/bin/env bash
ARGS=("$@")
JSON_EXPR=""
for ((i=0; i<${#ARGS[@]}; i++)); do
  if [ "${ARGS[i]}" = "--json" ]; then JSON_EXPR="${ARGS[i+1]:-}"; fi
done
case "${ARGS[0]:-} ${ARGS[1]:-}" in
  "pr view")
    if [[ "$JSON_EXPR" == *statusCheckRollup* ]]; then
      jq -n '{state: "OPEN", isDraft: false, headRefOid: "samehead", number: 99,
              reviews: [{body: "🤖 Reviewer agent — automated review\n\n[reviewer-agent: clean]\n",
                         commit: {oid: "samehead"},
                         submittedAt: "2026-05-01T00:00:00Z"}],
              labels: [],
              statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}'
      exit 0
    fi
    jq -n '{reviews: [], labels: []}'
    exit 0
    ;;
esac
exit 0
STUB
  chmod +x "$BATS_TEST_TMPDIR/bin/gh"

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
}
