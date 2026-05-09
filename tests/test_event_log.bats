#!/usr/bin/env bats
# tests/test_event_log.bats — exercise runners/lib/event_log.sh.
#
# event_emit <role> <event> [k=v ...] appends one NDJSON line to
# ${LOOP_EVENT_LOG:-/tmp/loop-events-${SESSION:-default}.jsonl}. Required
# fields ts/session/repo/role/event/schema_version are always present.
# Numeric-looking values become JSON numbers; everything else stays a string.
# A failed write must not change event_emit's exit code (best-effort
# instrumentation must never break the loop).

load 'helpers'

# Source event_log.sh in a clean subshell, redirect output to a unique file,
# echo nothing — caller asserts on file contents.
_emit() {
  local outfile="$1"; shift
  local repo="${REPO_SLUG_OVERRIDE:-acme/widgets}"
  LOOP_EVENT_LOG="$outfile" \
    SESSION="${SESSION_OVERRIDE:-test-session}" \
    REPO_SLUG="$repo" \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit "$@"
    ' _ "$@"
}

@test "event_emit cycle_start writes valid JSON with required fields" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  _emit "$file" dev-1 cycle_start cycle_id=42

  [ -f "$file" ]
  local line
  line=$(cat "$file")
  jq -e . <<<"$line" >/dev/null
  [ "$(jq -r .role <<<"$line")" = "dev-1" ]
  [ "$(jq -r .event <<<"$line")" = "cycle_start" ]
  [ "$(jq -r .session <<<"$line")" = "test-session" ]
  [ "$(jq -r .repo <<<"$line")" = "acme/widgets" ]
  [ "$(jq -r '.cycle_id | tostring' <<<"$line")" = "42" ]
  # Required: ts, schema_version
  [ -n "$(jq -r .ts <<<"$line")" ]
  [ "$(jq -r .ts <<<"$line")" != "null" ]
  jq -e '.schema_version | type == "number"' <<<"$line" >/dev/null
}

@test "event_emit cycle_end coerces exit_code and duration_s to JSON numbers" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  _emit "$file" dev-1 cycle_end cycle_id=7 exit_code=0 duration_s=12

  local line
  line=$(cat "$file")
  jq -e '.exit_code | type == "number"' <<<"$line" >/dev/null
  jq -e '.duration_s | type == "number"' <<<"$line" >/dev/null
  [ "$(jq -r .exit_code <<<"$line")" = "0" ]
  [ "$(jq -r .duration_s <<<"$line")" = "12" ]
}

@test "event_emit preserves ':' in role (e.g. dispatch:followup)" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  _emit "$file" "dispatch:followup" dispatch_fired pr=42 verdict=clean

  local line
  line=$(cat "$file")
  jq -e . <<<"$line" >/dev/null
  [ "$(jq -r .role <<<"$line")" = "dispatch:followup" ]
  [ "$(jq -r .verdict <<<"$line")" = "clean" ]
  jq -e '.pr | type == "number"' <<<"$line" >/dev/null
}

@test "event_emit preserves apostrophes/colons/spaces in string values" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  _emit "$file" reviewer hard_failure reason="sub-agent crashed: ctx exhausted (won't retry)"

  local line
  line=$(cat "$file")
  jq -e . <<<"$line" >/dev/null
  [ "$(jq -r .reason <<<"$line")" = "sub-agent crashed: ctx exhausted (won't retry)" ]
}

@test "event_emit on unwritable target file does not change exit code (set -e safe)" {
  # event_emit must be best-effort — a missing parent dir or permission glitch
  # must not propagate to the caller.
  local bad="/some/dir/that/does/not/exist/file.jsonl"
  set +e
  ec=0
  LOOP_EVENT_LOG="$bad" \
    SESSION=t REPO_SLUG=a/b \
    bash -ec '
      set -e
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit dev-1 cycle_start cycle_id=1
      echo OK
    ' _
  ec=$?
  [ "$ec" -eq 0 ]
}

@test "event_emit emits one line per call (no embedded newlines)" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  _emit "$file" dev-1 cycle_start cycle_id=1
  _emit "$file" dev-1 cycle_end cycle_id=1 exit_code=0 duration_s=5

  [ "$(wc -l < "$file" | tr -d ' ')" -eq 2 ]
  # Every line is valid JSON.
  while IFS= read -r line; do
    jq -e . <<<"$line" >/dev/null
  done < "$file"
}

@test "event_emit defaults file to /tmp/loop-events-\${SESSION:-default}.jsonl when LOOP_EVENT_LOG unset" {
  # Use a clean SESSION so we don't collide with a real run on this box.
  local sess="bats-default-$$"
  local default_file="/tmp/loop-events-${sess}.jsonl"
  rm -f "$default_file"
  ec=0
  unset LOOP_EVENT_LOG
  SESSION="$sess" REPO_SLUG=a/b \
    bash -c '
      unset LOOP_EVENT_LOG
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit dev-1 cycle_start cycle_id=1
    ' _ || ec=$?
  [ "$ec" -eq 0 ]
  [ -f "$default_file" ]
  rm -f "$default_file"
}

@test "event_emit floats coerce to JSON numbers" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  _emit "$file" dev-1 llm_exited mode=default exit_code=0 duration_s=12.5

  local line
  line=$(cat "$file")
  jq -e '.duration_s | type == "number"' <<<"$line" >/dev/null
  [ "$(jq -r .duration_s <<<"$line")" = "12.5" ]
}

@test "event_emit handles values starting with '-' that are not numbers as strings" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  _emit "$file" dev-1 cycle_skip reason=-no-work

  local line
  line=$(cat "$file")
  jq -e . <<<"$line" >/dev/null
  [ "$(jq -r .reason <<<"$line")" = "-no-work" ]
  jq -e '.reason | type == "string"' <<<"$line" >/dev/null
}

@test "event_emit with no extra k=v args still emits required base fields" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  _emit "$file" dev-1 lock_race_lost

  local line
  line=$(cat "$file")
  jq -e . <<<"$line" >/dev/null
  [ "$(jq -r .role <<<"$line")" = "dev-1" ]
  [ "$(jq -r .event <<<"$line")" = "lock_race_lost" ]
  jq -e '.schema_version | type == "number"' <<<"$line" >/dev/null
}

@test "event_emit with too few args (only role) returns 0 silently" {
  set +e
  ec=0
  LOOP_EVENT_LOG="$BATS_TEST_TMPDIR/events.jsonl" \
    SESSION=t REPO_SLUG=a/b \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit dev-1
      echo OK
    ' _
  ec=$?
  [ "$ec" -eq 0 ]
}

@test "LOOP_EVENT_LOG=/dev/null is a successful no-op (smoke)" {
  ec=0
  LOOP_EVENT_LOG=/dev/null \
    SESSION=t REPO_SLUG=a/b \
    bash -c '
      set -e
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit dev-1 cycle_start cycle_id=1
      event_emit dev-1 cycle_end cycle_id=1 exit_code=0 duration_s=5
      echo OK
    ' _ || ec=$?
  [ "$ec" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Source-of-truth: each runner sources lib/event_log.sh.
# Pin so future refactors can't silently drop the wire-in.
# ---------------------------------------------------------------------------

@test "run-loop.sh sources lib/event_log.sh" {
  grep -qF 'runners/lib/event_log.sh' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-developer.sh sources lib/event_log.sh" {
  grep -qF 'runners/lib/event_log.sh' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh sources lib/event_log.sh" {
  grep -qF 'runners/lib/event_log.sh' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "docs/event-schema.md exists and lists the core events" {
  local doc="$LOOP_ROOT/docs/event-schema.md"
  [ -f "$doc" ]
  grep -qE '\bcycle_start\b' "$doc"
  grep -qE '\bcycle_end\b' "$doc"
  grep -qE '\bcycle_skip\b' "$doc"
  grep -qE '\beligibility\b' "$doc"
  grep -qE '\block_acquired\b' "$doc"
  grep -qE '\bllm_started\b' "$doc"
  grep -qE '\bllm_exited\b' "$doc"
  grep -qE '\bdispatch_fired\b' "$doc"
  grep -qE '\bhard_failure\b' "$doc"
}
