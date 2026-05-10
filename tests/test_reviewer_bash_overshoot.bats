#!/usr/bin/env bats
# GH#127 — reviewer wrapper counts Bash tool_use events from the stream-json
# raw file after `wait` and emits a structured `bash_overshoot` event when
# the count exceeds REVIEWER_BASH_CALL_GUIDANCE. Naming-only: the variable
# is now called *_GUIDANCE to honestly signal "soft cap" — nothing
# interrupts mid-review. The wrapper does not change exit code or post a
# stub based on Bash count; the only side effects are the stderr log line
# and the event_emit row.
#
# Background: we historically called this knob REVIEWER_BASH_CALL_BUDGET,
# which read like a hard limit. It wasn't — only templates/reviewer.md
# referenced it, as a self-cap suggestion the reviewer agent could ignore.
# 29/42 substantive runs blew past 25; max observed was 46. Reviews still
# produced useful verdicts, so we kept the soft semantics but added the
# observability we were missing: rename the knob and have the wrapper
# count the actual Bash usage so we can tune the prompt or threshold over
# time without breaking flowing reviews.

load 'helpers'

# Build a tmp PATH dir with:
#   - `gh` shim that:
#       (a) responds to `pr view` (the post-GH#117 single-PR eligibility
#           preflight) with an OPEN, non-draft PR carrying no existing
#           reviews, no escalation label, and a COMPLETED+SUCCESS check —
#           so the eligibility classifier returns "proceed" and the wrapper
#           proceeds to claude. Same shape doubles as the response for the
#           wrapper's later `gh pr view <PR> --json reviews` call in the
#           hard_failure stub-count path (no result line + 0 prior stubs,
#           keeping GH#94 escalation dormant so this file can focus on
#           overshoot signaling).
#       (b) captures any `pr review` / `pr comment` argv to a sentinel file
#           in case other tests want it (this file does not assert on it).
#   - `claude` shim whose stdout is the stream-json payload for the test.
#     Each Bash tool_use event lives on its own line, mimicking the real
#     stream-json format.
_make_path_stubs() {
  local claude_exit="$1"
  local claude_stdout="$2"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"

  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
ARGS=("\$@")
SUB1="\${ARGS[0]:-}"
SUB2="\${ARGS[1]:-}"

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
    emit '[{"number":99,"headRefOid":"abc123","reviews":[],"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}]'
    exit 0
    ;;
  "api graphql")
    emit '{"data":{"repository":{"object":{"committedDate":"2026-05-07T10:00:00Z"}}}}'
    exit 0
    ;;
  "pr view")
    # Eligibility-shaped response (post-GH#117 wrapper requests
    # number,state,isDraft,headRefOid,reviews,labels,statusCheckRollup).
    # Non-cap state: no existing reviews, no escalation label, CI complete +
    # successful — eligibility classifier returns "proceed", and the GH#94
    # stub-count path stays dormant so this file can focus on overshoot
    # signaling.
    emit '{"number":99,"state":"OPEN","isDraft":false,"headRefOid":"abc123","reviews":[],"labels":[],"statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]}'
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

# Build N stream-json assistant tool_use events for Bash, one per line.
# The wrapper's jq filter is exactly:
#   select(.type=="assistant") | .message.content[]? |
#   select(.type=="tool_use" and .name=="Bash") | .id
# so each line must be a valid assistant message containing one Bash
# tool_use with a unique id.
_bash_tool_use_events() {
  local n="$1"
  local i
  for ((i=0; i<n; i++)); do
    printf '{"type":"assistant","message":{"content":[{"type":"tool_use","id":"toolu_test_%d","name":"Bash","input":{"command":"echo hi"}}]}}\n' "$i"
  done
}

# Helper: run the reviewer wrapper with a per-test event log under tmpdir.
# Passes `99` as the positional <PR> argument — post-GH#117 the wrapper
# requires a numeric PR and exits 2 with no LLM spawned otherwise.
_run_wrapper() {
  local repo="$1"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    LOOP_EVENT_LOG="$BATS_TEST_TMPDIR/state/events.jsonl" \
    SESSION="bats-overshoot-$$" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
      LOOP_EVENT_LOG="$BATS_TEST_TMPDIR/state/events.jsonl" \
      SESSION="bats-overshoot-$$" \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99
}

# ---------------------------------------------------------------------------
# Behavioral: 26 Bash tool_use events → wrapper logs overshoot + emits event.
# Default REVIEWER_BASH_CALL_GUIDANCE in the example config is 25.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: 26 Bash tool_use events → stderr log + bash_overshoot event (count=26 guidance=25)" {
  local repo
  repo=$(make_repo)
  local stream
  stream=$(_bash_tool_use_events 26)
  _make_path_stubs 0 "$stream"

  _run_wrapper "$repo"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  # Stderr line — operator-visible, single line, mentions both numbers.
  echo "$output" | grep -qE 'reviewer used 26 Bash calls.*guidance.*25'
  # Structured event — append-only NDJSON line in the per-session event log.
  [ -f "$BATS_TEST_TMPDIR/state/events.jsonl" ]
  local hits
  hits=$(jq -c 'select(.role=="reviewer" and .event=="bash_overshoot")' \
    "$BATS_TEST_TMPDIR/state/events.jsonl")
  [ -n "$hits" ]
  echo "$hits" | jq -e '.count == 26' >/dev/null
  echo "$hits" | jq -e '.guidance == 25' >/dev/null
  # PR attribution must come from the wrapper's $TARGET_PR (the positional
  # argument), NOT from log-greps for orchestrator markers that no longer
  # exist post-GH#117. Pinning this catches the regression the reviewer
  # caught on the previous cycle, where the bash_overshoot row carried no
  # pr field because the orchestrator-marker grep returned empty.
  # event_log.sh numeric-coerces values matching ^-?[0-9]+$, so pr lands as
  # a JSON number, not a string.
  echo "$hits" | jq -e '.pr == 99' >/dev/null
  # Exactly one overshoot event (no duplicate per pipeline buffer).
  [ "$(printf '%s\n' "$hits" | wc -l | tr -d ' ')" -eq 1 ]
}

# ---------------------------------------------------------------------------
# Behavioral: 5 Bash tool_use events → no overshoot signal at all.
# ---------------------------------------------------------------------------

@test "run-reviewer.sh: 5 Bash tool_use events → no overshoot log, no bash_overshoot event" {
  local repo
  repo=$(make_repo)
  local stream
  stream=$(_bash_tool_use_events 5)
  _make_path_stubs 0 "$stream"

  _run_wrapper "$repo"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  # No overshoot log on stderr.
  ! echo "$output" | grep -qE 'reviewer used .* Bash calls.*guidance'
  # Either no event log was created, or it contains no bash_overshoot rows.
  if [ -f "$BATS_TEST_TMPDIR/state/events.jsonl" ]; then
    local hits
    hits=$(jq -c 'select(.role=="reviewer" and .event=="bash_overshoot")' \
      "$BATS_TEST_TMPDIR/state/events.jsonl" || true)
    [ -z "$hits" ]
  fi
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the rename and the counter wiring so a future refactor
# can't silently regress either. The wrapper itself must reference the
# *_GUIDANCE name and contain the jq+wc count of Bash tool_use events.
# ---------------------------------------------------------------------------

@test "rename: no production file still says REVIEWER_BASH_CALL_BUDGET" {
  # The whole point of the rename is to stop the prompt and the variable
  # name from disagreeing. If anything in production paths still uses the
  # old name, the rename didn't land. Excludes tests/ (which legitimately
  # references the old name in historical-context comments and in negation
  # assertions like `! grep ... 'REVIEWER_BASH_CALL_BUDGET'`) and .beads/
  # (the issue tracker can carry past-tense narrative text mentioning the
  # renamed identifier in memory records — that's not a production code
  # path, so a hit there is a false positive, GH#148).
  ! grep -rqF --exclude-dir=tests --exclude-dir=.beads 'REVIEWER_BASH_CALL_BUDGET' "$LOOP_ROOT"
}

@test "run-reviewer.sh: counter wiring is present (jq tool_use count + bash_overshoot event_emit)" {
  # Counter shape (jq filter on the raw stream-json file).
  grep -qF 'tool_use' "$LOOP_ROOT/runners/run-reviewer.sh"
  grep -qF '"Bash"' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Event-emit name.
  grep -qF 'bash_overshoot' "$LOOP_ROOT/runners/run-reviewer.sh"
  # Reads the new variable name.
  grep -qF 'REVIEWER_BASH_CALL_GUIDANCE' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "templates/reviewer.md: prompt copy uses guidance language, not 'cap yourself'" {
  # The prompt and the variable name must agree about the soft semantics.
  grep -qF 'REVIEWER_BASH_CALL_GUIDANCE' "$LOOP_ROOT/templates/reviewer.md"
  ! grep -qF 'cap yourself' "$LOOP_ROOT/templates/reviewer.md"
}

@test "render-prompt.sh REPO_KEYS: includes REVIEWER_BASH_CALL_GUIDANCE (not the old name)" {
  grep -qF 'REVIEWER_BASH_CALL_GUIDANCE' "$LOOP_ROOT/runners/lib/render-prompt.sh"
  ! grep -qF 'REVIEWER_BASH_CALL_BUDGET' "$LOOP_ROOT/runners/lib/render-prompt.sh"
}

@test "loop.config.example: defines REVIEWER_BASH_CALL_GUIDANCE (not the old name)" {
  grep -qE '^REVIEWER_BASH_CALL_GUIDANCE=' "$LOOP_ROOT/templates/loop.config.example"
  ! grep -qE '^REVIEWER_BASH_CALL_BUDGET=' "$LOOP_ROOT/templates/loop.config.example"
}
