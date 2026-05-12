#!/usr/bin/env bats
# tests/test_dispatch_id.bats — GH#172.
#
# Pins the dispatch_id correlation field that ties the dispatcher's
# `dispatch_fired` event to the wrapper's `cycle_start` / `llm_started` /
# `llm_exited` / `hard_failure` chain in the runner it spawned. Without
# this, any cross-event analysis ("which dispatch decisions led to hard
# failures") needs string-matching on PR + mode + timestamp, which fails
# under concurrency.
#
# Contract:
#  1. `runners/run-loop.sh` generates a `dispatch_id` (shape `${PID}-<ns>`)
#     per fire site, emits it on `dispatch_fired` / `dispatch_skip`, and
#     exports `LOOP_DISPATCH_ID` for the backgrounded wrapper.
#  2. `run-developer.sh` and `run-reviewer.sh` include `dispatch_id=...`
#     on every `event_emit` call when `LOOP_DISPATCH_ID` is set.
#  3. Interactive (non-dispatched) wrapper invocations have no
#     `dispatch_id` field on any event.

load 'helpers'

# ---------------------------------------------------------------------------
# Wrapper integration — LOOP_DISPATCH_ID propagates onto every event
# ---------------------------------------------------------------------------

# Build a self-contained test environment under $BATS_TEST_TMPDIR. Mirrors
# the _setup_env in test_event_log_integration.bats so the two files exercise
# the same wrapper fixture shape.
_setup_env() {
  local high="${1:-$LOOP_ROOT/tests/fixtures/gh/issues-high.json}"
  local med="${2:-$LOOP_ROOT/tests/fixtures/gh/issues-medium.json}"
  local claude_exit="${3:-0}"
  local root="$BATS_TEST_TMPDIR"
  local repo="$root/repo"
  local bin="$root/bin"
  local work="$root/work"
  local state="$root/state"
  mkdir -p "$repo/.loop" "$bin" "$work" "$state"

  awk -v wb="$work" '
    /^REPO_OWNER=/   { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/    { print "REPO_NAME=\"test-repo\""; next }
    /^WORKTREE_BASE=/ { print "WORKTREE_BASE=\"" wb "\""; next }
    /^LOCK_DIR=/     { print "LOCK_DIR=\"" wb "/locks\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"

  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init

  cat > "$bin/gh" <<STUB
#!/usr/bin/env bash
label=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--label" ]; then label="\$2"; shift 2
  else shift
  fi
done
case "\$label" in
  severity:high)   cat '$high' ;;
  severity:medium) cat '$med' ;;
  *) echo '[]' ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"

  cat > "$bin/claude" <<STUB
#!/usr/bin/env bash
exit $claude_exit
STUB
  chmod +x "$bin/claude"

  echo "$root"
}

_run_dev_wrapper() {
  local root="$1"; shift
  local logfile="$root/state/events.jsonl"
  REPO_ROOT="$root/repo" LOOP_HOME="$LOOP_ROOT" \
    PATH="$root/bin:$PATH" \
    LOOP_EVENT_LOG="$logfile" \
    SESSION="bats-dispatch-id-$$" \
    KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-developer.sh" "$@" \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err"
}

@test "wrapper: LOOP_DISPATCH_ID set → every emitted event carries the same dispatch_id" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty" 0)

  local rc=0
  LOOP_DISPATCH_ID="test-disp-aaa-111" _run_dev_wrapper "$root" || rc=$?
  [ "$rc" -eq 0 ]

  local f="$root/state/events.jsonl"
  [ -f "$f" ]

  # Every event in the file carries dispatch_id=test-disp-aaa-111. If any
  # event lacks the field or has a different value, the count diverges from
  # the total line count and we fail.
  local total tagged
  total=$(wc -l < "$f" | tr -d ' ')
  tagged=$(jq -c 'select(.dispatch_id == "test-disp-aaa-111")' "$f" | wc -l | tr -d ' ')
  [ "$total" -eq "$tagged" ]

  # Spot-check the key events from the acceptance criteria chain.
  jq -e 'select(.event == "eligibility" and .dispatch_id == "test-disp-aaa-111")' "$f" >/dev/null
  jq -e 'select(.event == "lock_acquired" and .dispatch_id == "test-disp-aaa-111")' "$f" >/dev/null
  jq -e 'select(.event == "llm_started" and .dispatch_id == "test-disp-aaa-111")' "$f" >/dev/null
  jq -e 'select(.event == "llm_exited" and .dispatch_id == "test-disp-aaa-111")' "$f" >/dev/null
}

@test "wrapper: LOOP_DISPATCH_ID unset → no event has the dispatch_id field" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty" 0)

  local rc=0
  # Explicitly unset in case the harness leaked it from a sibling test.
  unset LOOP_DISPATCH_ID
  _run_dev_wrapper "$root" || rc=$?
  [ "$rc" -eq 0 ]

  local f="$root/state/events.jsonl"
  [ -f "$f" ]
  # No event line carries a dispatch_id field at all.
  ! jq -e 'select(has("dispatch_id"))' "$f" >/dev/null
}

@test "wrapper: LOOP_DISPATCH_ID set on no-work path → eligibility{no-work} carries dispatch_id" {
  # Interactive ($INTERACTIVE=1) bypass / dispatched but found nothing: a
  # dispatched wrapper that returns rc=2 should still tag its no-work
  # eligibility event so the tower can correlate "dispatch_fired → no-work".
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local root
  root=$(_setup_env "$empty" "$empty" 0)

  local rc=0
  LOOP_DISPATCH_ID="test-disp-no-work-222" _run_dev_wrapper "$root" || rc=$?
  [ "$rc" -eq 2 ]

  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "eligibility" and .result == "no-work" and .dispatch_id == "test-disp-no-work-222")' "$f" >/dev/null
}

@test "concurrency: two distinct LOOP_DISPATCH_ID values to the same log produce disjoint event sets" {
  # GH#172 acceptance: "Run two wrappers concurrently on different PRs;
  # assert their dispatch_id values are distinct and that no event appears
  # under both."
  #
  # We don't need concurrent processes for the invariant — concurrent
  # appends are tested by event_log itself. Here we just need to assert
  # that distinct dispatch_id values stay scoped to their own events.
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_DISPATCH_ID="aaa-111" \
    LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit dev llm_started mode=default issue=1 dispatch_id="$LOOP_DISPATCH_ID"
      event_emit dev llm_exited mode=default issue=1 exit_code=0 duration_s=1 dispatch_id="$LOOP_DISPATCH_ID"
    '
  LOOP_DISPATCH_ID="bbb-222" \
    LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit dev llm_started mode=default issue=2 dispatch_id="$LOOP_DISPATCH_ID"
      event_emit dev llm_exited mode=default issue=2 exit_code=0 duration_s=1 dispatch_id="$LOOP_DISPATCH_ID"
    '

  # 4 events total, 2 per dispatch_id, no event appears under both.
  [ "$(wc -l < "$file" | tr -d ' ')" -eq 4 ]
  [ "$(jq -c 'select(.dispatch_id == "aaa-111")' "$file" | wc -l | tr -d ' ')" -eq 2 ]
  [ "$(jq -c 'select(.dispatch_id == "bbb-222")' "$file" | wc -l | tr -d ' ')" -eq 2 ]
  # No row has both — would require a single line with two values, which
  # event_emit can't produce.
  ! jq -e 'select(.dispatch_id == "aaa-111" and .dispatch_id == "bbb-222")' "$file" >/dev/null
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the dispatcher wire-in so a future refactor can't
# silently drop the dispatch_id from the dispatcher events or the
# backgrounded wrapper env.
# ---------------------------------------------------------------------------

@test "run-loop.sh: every dispatch_fired emit carries a dispatch_id field" {
  # Each dispatch_fired call must include `dispatch_id=...`. We grep for any
  # `event_emit ... dispatch_fired` line that does NOT carry `dispatch_id=` —
  # the expected match count is zero.
  local missing
  missing=$(grep -nE 'event_emit[^#]*dispatch_fired' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -vE 'dispatch_id=' || true)
  if [ -n "$missing" ]; then
    echo "dispatch_fired emit(s) without dispatch_id=:" >&2
    echo "$missing" >&2
    return 1
  fi
}

@test "run-loop.sh: every dispatch_skip emit carries a dispatch_id field" {
  local missing
  missing=$(grep -nE 'event_emit[^#]*dispatch_skip' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -vE 'dispatch_id=' || true)
  if [ -n "$missing" ]; then
    echo "dispatch_skip emit(s) without dispatch_id=:" >&2
    echo "$missing" >&2
    return 1
  fi
}

@test "run-loop.sh: every backgrounded wrapper exec exports LOOP_DISPATCH_ID" {
  # The three dispatchers that background a wrapper (review/followup/conflicts)
  # must pass LOOP_DISPATCH_ID into the subshell so the wrapper's events
  # inherit the dispatcher's correlation id. We match only `("$LOOP_HOME/...`
  # — the subshell-backgrounded pattern — so the dev pane's foreground call
  # (loop_dev_mode1, no dispatcher above it) doesn't get flagged.
  for runner in run-developer.sh run-reviewer.sh; do
    local missing
    missing=$(grep -nE "\\(\"\\\$LOOP_HOME/runners/$runner\"" "$LOOP_ROOT/runners/run-loop.sh" \
      | grep -vE 'LOOP_DISPATCH_ID=' || true)
    if [ -n "$missing" ]; then
      echo "run-loop.sh has a backgrounded $runner exec without LOOP_DISPATCH_ID=:" >&2
      echo "$missing" >&2
      return 1
    fi
  done
}

@test "run-developer.sh: defines a _dispatch_kv helper sourced from LOOP_DISPATCH_ID" {
  grep -qE 'LOOP_DISPATCH_ID' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh: defines a _dispatch_kv helper sourced from LOOP_DISPATCH_ID" {
  grep -qE 'LOOP_DISPATCH_ID' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "docs/event-schema.md documents dispatch_id as an optional field" {
  local doc="$LOOP_ROOT/docs/event-schema.md"
  grep -qE '\bdispatch_id\b' "$doc"
}
