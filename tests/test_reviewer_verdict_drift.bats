#!/usr/bin/env bats
# GH#128 — reviewer wrapper rejects review bodies whose verdict marker drifts
# off-spec.
#
# Background:
# `.loop/loop.config:REVIEWER_AGENT_VERDICT_REGEX` pins the canonical token
# set: `\[reviewer-agent: (clean|nits|comment|changes|blocked)\]`. Downstream
# consumers (eligibility predicate, dev-agent follow-up mode, future merger
# scripts) match against this regex literally. If the LLM ever posts an
# off-spec marker (observed once: `[reviewer-agent: commented]` on PR #66),
# the predicate's "review covers head" half misses it and the dispatcher
# silently re-fires forever.
#
# Defense: after the LLM exits 0 with a result line, the wrapper fetches the
# most recent reviewer-agent review on the current head SHA and re-validates
# its body against `$REVIEWER_AGENT_VERDICT_REGEX`. On miss, log
# `[wrapper] verdict-drift detected` and exit non-zero so the orchestrator's
# existing backoff / GH#94 cap escalation can take over.

load 'helpers'

# Build a tmp PATH dir with custom gh + claude shims for verdict-drift tests.
# The shim served the wrapper preflight (eligibility shape) AND the post-LLM
# drift check (`pr view --json reviews,headRefOid`). The drift body is
# parameterized so each test can drive a different verdict token.
#
# $1 — verdict body to embed in the latest reviewer-agent review (e.g.
#      `[reviewer-agent: comment]` or `[reviewer-agent: commented]`)
_make_drift_stubs() {
  local verdict_body="$1"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"
  printf '%s' "$verdict_body" >"$state/verdict-body"

  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
ARGS=("\$@")
JSON_EXPR=""
for ((i=0; i<\${#ARGS[@]}; i++)); do
  if [ "\${ARGS[i]}" = "--json" ]; then JSON_EXPR="\${ARGS[i+1]:-}"; fi
done
case "\${ARGS[0]:-} \${ARGS[1]:-}" in
  "pr view")
    if [[ "\$JSON_EXPR" == *statusCheckRollup* ]]; then
      # Wrapper preflight (eligibility): no agent-review at head yet.
      jq -n '{state: "OPEN", isDraft: false, headRefOid: "headsha", number: 99,
              reviews: [], labels: [],
              statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}'
      exit 0
    fi
    if [[ "\$JSON_EXPR" == *headRefOid* ]]; then
      # GH#128 drift check (post-LLM). Serve a single reviewer-agent review
      # on the current head, body driven by the test parameter.
      VERDICT=\$(cat '$state/verdict-body')
      jq -n --arg v "\$VERDICT" \
        '{headRefOid: "headsha",
          reviews: [{body: ("🤖 Reviewer agent — automated review\n\n" + \$v + "\n"),
                     commit: {oid: "headsha"},
                     submittedAt: "2026-05-10T00:00:00Z"}]}'
      exit 0
    fi
    # Default cap-counter shape (reviews + labels) — unused here.
    jq -n '{reviews: [], labels: []}'
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

  # claude shim emits the LLM's success-line on stdout (HAS_RESULT_LINE=1).
  # The actual review body served by gh is the drift-check input.
  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
touch '$state/claude-was-called'
cat <<'JSON'
{"type":"assistant","message":{"content":[{"type":"text","text":"[reviewer-agent] result=commented pr=#99 sha=headsha findings=P0:0 P1:1 P2:0 beads=loop-xyz"}]}}
JSON
exit 0
STUB
  chmod +x "$tmpbin/claude"
}

# ---------------------------------------------------------------------------
# Behavioral: off-spec marker → drift, exit non-zero
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: review body has [reviewer-agent: commented] (off-spec) → drift, exit non-zero (GH#128)" {
  local repo
  repo=$(make_repo)
  _make_drift_stubs '[reviewer-agent: commented]'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -ne 0 ]
  # Must NOT collide with the eligibility-skip code (rc=2) — drift is a
  # wrapper-level failure, not "no work".
  [ "$status" -ne 2 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  echo "$output" | grep -qF 'verdict-drift detected'
}

@test "run-reviewer.sh: review body has [reviewer-agent: approved] (off-spec) → drift, exit non-zero (GH#128)" {
  # Cover a second off-spec token to pin the rule (not just the one
  # observed-in-the-wild typo).
  local repo
  repo=$(make_repo)
  _make_drift_stubs '[reviewer-agent: approved]'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -ne 0 ]
  [ "$status" -ne 2 ]
  echo "$output" | grep -qF 'verdict-drift detected'
}

# ---------------------------------------------------------------------------
# Behavioral: every canonical verdict passes the drift check
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: review body has [reviewer-agent: comment] → exit 0 (GH#128)" {
  local repo
  repo=$(make_repo)
  _make_drift_stubs '[reviewer-agent: comment]'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'verdict-drift detected'
}

@test "run-reviewer.sh: review body has [reviewer-agent: nits] → exit 0 (GH#128)" {
  local repo
  repo=$(make_repo)
  _make_drift_stubs '[reviewer-agent: nits]'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'verdict-drift detected'
}

@test "run-reviewer.sh: review body has [reviewer-agent: clean] → exit 0 (GH#128)" {
  local repo
  repo=$(make_repo)
  _make_drift_stubs '[reviewer-agent: clean]'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'verdict-drift detected'
}

@test "run-reviewer.sh: review body has [reviewer-agent: changes] → exit 0 (GH#128)" {
  local repo
  repo=$(make_repo)
  _make_drift_stubs '[reviewer-agent: changes]'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'verdict-drift detected'
}

@test "run-reviewer.sh: review body has [reviewer-agent: blocked] → exit 0 (GH#128)" {
  local repo
  repo=$(make_repo)
  _make_drift_stubs '[reviewer-agent: blocked]'

  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99

  [ "$status" -eq 0 ]
  ! echo "$output" | grep -qF 'verdict-drift detected'
}

# ---------------------------------------------------------------------------
# Source-of-truth pins
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: drift detection wiring is present (GH#128)" {
  # The wrapper greps post-LLM-review bodies against REVIEWER_AGENT_VERDICT_REGEX.
  grep -qF 'REVIEWER_AGENT_VERDICT_REGEX' "$LOOP_ROOT/runners/run-reviewer.sh"
  # The drift log message is the literal substring downstream operators / log
  # mining tools will key on. Pinning it here so a refactor can't silently
  # rename it without updating dashboards.
  grep -qF 'verdict-drift detected' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "templates/reviewer.md: pins the five canonical verdict tokens (GH#128)" {
  # The template must enumerate the canonical token set literally so the LLM
  # can't drift by paraphrase. Each must appear at least once in the template
  # body (independent of formatting).
  for tok in clean nits comment changes blocked; do
    grep -qF "[reviewer-agent: ${tok}]" "$LOOP_ROOT/templates/reviewer.md"
  done
  # The "no other tokens permitted" assertion is the rule itself — pin its
  # presence so a future edit can't soften it.
  grep -qF 'No other tokens permitted' "$LOOP_ROOT/templates/reviewer.md"
}
