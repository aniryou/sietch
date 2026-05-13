#!/usr/bin/env bats
# tests/test_flags_events.bats — GH#187: flag reads emit `flag_read` events
# and subsequent events carry a `flags_active` object reflecting the
# process-local cache.
#
# Two collaborating modules:
#   runners/lib/flags.sh      — ff_enabled / ff_variant / ff_value
#   runners/lib/event_log.sh  — event_emit, LOOP_EVENT_SCHEMA_VERSION
#
# Contract being pinned here:
#   1. Every ff_* call appends a `flag_read` NDJSON line with name + value.
#   2. _LOOP_FF_ACTIVE accumulates reads in-process; event_emit serializes
#      it as a `flags_active` JSON object on every subsequent event.
#   3. LOOP_EVENT_SCHEMA_VERSION bumped to 3 (new required field changes
#      the contract per docs/event-schema.md).
#   4. A flag read with an unwritable LOOP_EVENT_LOG does NOT cause set -e
#      callers to abort — same best-effort discipline as event_emit itself.

load 'helpers'

@test "LOOP_EVENT_SCHEMA_VERSION is 3 (GH#187 added flag_read + flags_active)" {
  bash -c '
    . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
    [ "$LOOP_EVENT_SCHEMA_VERSION" = "3" ]
  '
}

# ---------------------------------------------------------------------------
# flag_read emission
# ---------------------------------------------------------------------------

@test "ff_enabled FOO=1 emits flag_read with name=foo, value=1, schema_version=3" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=1 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO || true
    '

  [ -f "$file" ]
  local line
  line=$(grep '"event":"flag_read"' "$file" | head -1)
  [ -n "$line" ]
  jq -e . <<<"$line" >/dev/null
  [ "$(jq -r .name <<<"$line")" = "foo" ]
  # value is the boolean rc as a number (0 or 1); we accept either JSON
  # number or string form, since the issue states `value=0|1` without
  # pinning a type.
  [ "$(jq -r '.value | tostring' <<<"$line")" = "1" ]
  [ "$(jq -r .schema_version <<<"$line")" = "3" ]
  [ -n "$(jq -r .ts <<<"$line")" ]
  [ -n "$(jq -r .role <<<"$line")" ]
  [ -n "$(jq -r .session <<<"$line")" ]
  [ -n "$(jq -r .repo <<<"$line")" ]
}

@test "ff_enabled FOO=0 emits flag_read with value=0" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=0 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO || true
    '

  local line
  line=$(grep '"event":"flag_read"' "$file" | head -1)
  [ "$(jq -r .name <<<"$line")" = "foo" ]
  [ "$(jq -r '.value | tostring' <<<"$line")" = "0" ]
}

@test "ff_enabled when LOOP_FF_FOO unset emits flag_read value=0" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO || true
    '

  local line
  line=$(grep '"event":"flag_read"' "$file" | head -1)
  [ "$(jq -r '.value | tostring' <<<"$line")" = "0" ]
}

@test "ff_variant emits flag_read with name and value=control by default" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_variant FOO 42 >/dev/null
    '

  local line
  line=$(grep '"event":"flag_read"' "$file" | head -1)
  [ "$(jq -r .name <<<"$line")" = "foo" ]
  [ "$(jq -r .value <<<"$line")" = "control" ]
}

@test "ff_value emits flag_read with the resolved value (configured wins over default)" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_MODE=fast \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_value MODE control >/dev/null
    '

  local line
  line=$(grep '"event":"flag_read"' "$file" | head -1)
  [ "$(jq -r .name <<<"$line")" = "mode" ]
  [ "$(jq -r .value <<<"$line")" = "fast" ]
}

@test "ff_value emits flag_read with the default when flag unset" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_value MODE control >/dev/null
    '

  local line
  line=$(grep '"event":"flag_read"' "$file" | head -1)
  [ "$(jq -r .name <<<"$line")" = "mode" ]
  [ "$(jq -r .value <<<"$line")" = "control" ]
}

@test "name field is lowercased even when caller passes upper-snake" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_MY_FLAG=1 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled MY_FLAG || true
    '

  local line
  line=$(grep '"event":"flag_read"' "$file" | head -1)
  [ "$(jq -r .name <<<"$line")" = "my_flag" ]
}

# ---------------------------------------------------------------------------
# flags_active object on subsequent events
# ---------------------------------------------------------------------------

@test "event_emit after a flag read includes flags_active with that flag" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=1 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO || true
      event_emit dev pr_merged pr=1
    '

  local last
  last=$(tail -1 "$file")
  jq -e '.event == "pr_merged"' <<<"$last" >/dev/null
  jq -e '.flags_active | type == "object"' <<<"$last" >/dev/null
  [ "$(jq -r .flags_active.foo <<<"$last")" = "1" ]
}

@test "flags_active is omitted when no flags have been read" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit dev pr_merged pr=1
    '

  local line
  line=$(cat "$file")
  jq -e 'has("flags_active") | not' <<<"$line" >/dev/null
}

@test "multiple flag reads accumulate in flags_active" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=1 LOOP_FF_BAR=1 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO || true
      ff_enabled BAR || true
      event_emit dev pr_merged pr=1
    '

  local last
  last=$(tail -1 "$file")
  jq -e '.event == "pr_merged"' <<<"$last" >/dev/null
  [ "$(jq -r .flags_active.foo <<<"$last")" = "1" ]
  [ "$(jq -r .flags_active.bar <<<"$last")" = "1" ]
}

@test "flag_read event itself includes the just-read flag in flags_active" {
  # The cache is updated BEFORE emit so the very first flag_read line on a
  # fresh shell already carries that flag in flags_active. Pins the order.
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=1 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO || true
    '

  local line
  line=$(grep '"event":"flag_read"' "$file" | head -1)
  jq -e '.event == "flag_read"' <<<"$line" >/dev/null
  [ "$(jq -r .flags_active.foo <<<"$line")" = "1" ]
}

@test "second read of the same flag overwrites the cached value" {
  # ff_variant returns "control" today, but if a later child issue extends
  # it to a real variant, repeated reads must not duplicate keys — latest
  # value wins.
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_MODE=fast \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_value MODE control >/dev/null
      ff_value MODE control >/dev/null
      event_emit dev pr_merged pr=1
    '

  local last
  last=$(tail -1 "$file")
  # Exactly one mode key with the expected value.
  [ "$(jq -r .flags_active.mode <<<"$last")" = "fast" ]
  [ "$(jq -r '.flags_active | keys | length' <<<"$last")" = "1" ]
}

# ---------------------------------------------------------------------------
# Best-effort discipline — instrumentation must never break the caller
# ---------------------------------------------------------------------------

@test "ff_enabled with unwritable LOOP_EVENT_LOG does not abort set -e callers" {
  ec=0
  LOOP_EVENT_LOG=/nonexistent/dir/file.jsonl \
    SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=1 \
    bash -ec '
      set -e
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO
      echo OK
    ' _ || ec=$?
  [ "$ec" -eq 0 ]
}

@test "ff_enabled returns flag rc even when event log write fails" {
  # Acceptance: "exit code matches the flag state (write failure swallowed
  # silently)" — for FOO=0 we want rc=1, for FOO=1 rc=0.
  ec=0
  LOOP_EVENT_LOG=/nonexistent/dir/file.jsonl \
    SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=0 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO
    ' || ec=$?
  [ "$ec" -eq 1 ]

  ec=0
  LOOP_EVENT_LOG=/nonexistent/dir/file.jsonl \
    SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=1 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO
    ' || ec=$?
  [ "$ec" -eq 0 ]
}

@test "ff_variant prints control to stdout even when event log write fails" {
  out=$(LOOP_EVENT_LOG=/nonexistent/dir/file.jsonl \
        SESSION=t REPO_SLUG=a/b \
        bash -c '
          . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
          ff_variant FOO 42
        ')
  [ "$out" = "control" ]
}

@test "ff_value prints value to stdout even when event log write fails" {
  out=$(LOOP_EVENT_LOG=/nonexistent/dir/file.jsonl \
        SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=hello \
        bash -c '
          . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
          ff_value FOO default
        ')
  [ "$out" = "hello" ]
}

# ---------------------------------------------------------------------------
# Acceptance-criteria jq queries (from the issue's Test plan)
# ---------------------------------------------------------------------------

@test "jq -c '.event==\"flag_read\"' \$LOOP_EVENT_LOG returns >=1 line after a flag read" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=1 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO || true
    '

  local count
  count=$(jq -c 'select(.event=="flag_read")' "$file" | wc -l | tr -d ' ')
  [ "$count" -ge 1 ]
}

@test "after ff_enabled + event_emit, last line parses with .flags_active.foo in {0,1}" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b LOOP_FF_FOO=1 \
    bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
      ff_enabled FOO || true
      event_emit dev pr_merged pr=1
    '

  local last
  last=$(tail -1 "$file")
  jq -e . <<<"$last" >/dev/null
  jq -e '.flags_active.foo | tostring | . == "0" or . == "1"' <<<"$last" >/dev/null
}

# ---------------------------------------------------------------------------
# Module wiring / docs
# ---------------------------------------------------------------------------

@test "flags.sh sources event_log.sh so event_emit is available to ff_* helpers" {
  grep -qF 'event_log.sh' "$LOOP_ROOT/runners/lib/flags.sh"
}

@test "docs/event-schema.md documents the flag_read event and flags_active field" {
  local doc="$LOOP_ROOT/docs/event-schema.md"
  [ -f "$doc" ]
  grep -qE '\bflag_read\b' "$doc"
  grep -qE '\bflags_active\b' "$doc"
}

@test "docs/event-schema.md history mentions GH#187 / schema 3" {
  grep -qE 'GH#187|schema.*3|`3`' "$LOOP_ROOT/docs/event-schema.md"
}
