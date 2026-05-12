#!/usr/bin/env bats
# GH#175 — when eligibility_review_pending_list cannot reach gh, it echoes "?"
# as its failure sentinel (see runners/lib/eligibility.sh). The review
# dispatcher previously consumed that "?" as if it were a PR number and
# emitted dispatch_fired pr=?, which violates the schema (pr is a required
# numeric field) and corrupts any downstream consumer that groups events by
# PR. The fix is two-pronged:
#
#   1. loop_dispatcher_review in run-loop.sh filters non-numeric pr values
#      out of the per-PR loop and emits dispatch_skip kind=review
#      reason=missing-pr instead of dispatch_fired.
#   2. event_emit in lib/event_log.sh refuses to write any event carrying
#      pr=? (defense in depth) and logs to stderr; never breaks the loop.

load 'helpers'

_extract_function_body() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ ("^"name"\\(\\)[[:space:]]*\\{") { in_fn=1; next }
    in_fn && /^\}[[:space:]]*$/ { in_fn=0; exit }
    in_fn { print }
  ' "$LOOP_ROOT/runners/run-loop.sh"
}

# ---------------------------------------------------------------------------
# Layer 1 — event_emit defensive guard
# ---------------------------------------------------------------------------

@test "event_emit refuses dispatch_fired event when pr=? (writes nothing, warns to stderr)" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  local err
  err=$(
    LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit "dispatch:review" dispatch_fired kind=review pr="?"
    ' 2>&1 1>/dev/null
  )
  # Event line MUST NOT have been written (file is either absent or empty).
  [ ! -s "$file" ]
  # Stderr MUST contain a recognisable warning mentioning pr=?.
  grep -qF 'event_emit:' <<<"$err"
  grep -qF 'pr=?' <<<"$err"
}

@test "event_emit refuses dispatch_skip event when pr=? too (any dispatch event)" {
  # The guard targets the pr=? sentinel itself, not just dispatch_fired.
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  local err
  err=$(
    LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
      event_emit "dispatch:review" dispatch_skip kind=review pr="?" reason=missing-pr
    ' 2>&1 1>/dev/null
  )
  [ ! -s "$file" ]
  grep -qF 'pr=?' <<<"$err"
}

@test "event_emit returns 0 even when refusing pr=? (best-effort never breaks the loop)" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b bash -c '
    set -e
    . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
    event_emit "dispatch:review" dispatch_fired kind=review pr="?"
  ' 2>/dev/null
  # bash -e would propagate a non-zero return.
  [ "$?" -eq 0 ]
}

@test "event_emit still emits dispatch_fired for numeric pr (no regression)" {
  local file="$BATS_TEST_TMPDIR/events.jsonl"
  LOOP_EVENT_LOG="$file" SESSION=t REPO_SLUG=a/b bash -c '
    . "'"$LOOP_ROOT"'/runners/lib/event_log.sh"
    event_emit "dispatch:review" dispatch_fired kind=review pr="42"
  '
  [ -s "$file" ]
  jq -e '.event == "dispatch_fired" and .pr == 42' < "$file" >/dev/null
}

# ---------------------------------------------------------------------------
# Layer 2 — pattern test: the dispatcher's guard skips non-numeric pr lines
# (mirrors the lock-acquire pattern tests in test_dispatch_lock_dir_heal.bats)
# ---------------------------------------------------------------------------

@test "dispatcher pattern: pr='?' triggers skip path, not fire path" {
  local out
  out=$(
    set -u
    pr="?"
    if [ -z "$pr" ] || [[ ! "$pr" =~ ^[0-9]+$ ]]; then
      echo "SKIP reason=missing-pr"
    else
      echo "FIRE pr=$pr"
    fi
  )
  [ "$out" = "SKIP reason=missing-pr" ]
}

@test "dispatcher pattern: empty pr triggers skip path" {
  local out
  out=$(
    set -u
    pr=""
    if [ -z "$pr" ] || [[ ! "$pr" =~ ^[0-9]+$ ]]; then
      echo "SKIP reason=missing-pr"
    else
      echo "FIRE pr=$pr"
    fi
  )
  [ "$out" = "SKIP reason=missing-pr" ]
}

@test "dispatcher pattern: numeric pr triggers fire path" {
  local out
  out=$(
    set -u
    pr="42"
    if [ -z "$pr" ] || [[ ! "$pr" =~ ^[0-9]+$ ]]; then
      echo "SKIP reason=missing-pr"
    else
      echo "FIRE pr=$pr"
    fi
  )
  [ "$out" = "FIRE pr=42" ]
}

# ---------------------------------------------------------------------------
# Layer 3 — source-of-truth: loop_dispatcher_review carries the guard
# ---------------------------------------------------------------------------

@test "run-loop.sh: loop_dispatcher_review filters non-numeric pr before lock acquisition" {
  local body
  body=$(_extract_function_body loop_dispatcher_review)
  [ -n "$body" ]
  # The guard regex on $pr — pinned to `^[0-9]+$` so a future edit can't
  # quietly weaken it.
  echo "$body" | grep -qE '\[\[[[:space:]]+!.*"\$pr".*\^\[0-9\]\+\$'
}

@test "run-loop.sh: loop_dispatcher_review emits dispatch_skip reason=missing-pr on non-numeric pr" {
  local body
  body=$(_extract_function_body loop_dispatcher_review)
  [ -n "$body" ]
  echo "$body" | grep -qF 'reason=missing-pr'
}

@test "run-loop.sh: loop_dispatcher_review numeric-pr guard precedes the mkdir lock acquire" {
  local body
  body=$(_extract_function_body loop_dispatcher_review)
  [ -n "$body" ]
  local guard_lineno mkdir_lineno
  guard_lineno=$(echo "$body" | grep -nF 'reason=missing-pr' | head -1 | cut -d: -f1)
  mkdir_lineno=$(echo "$body" | grep -nE 'mkdir[[:space:]]+"\$lock"' | head -1 | cut -d: -f1)
  [ -n "$guard_lineno" ]
  [ -n "$mkdir_lineno" ]
  # Guard MUST appear before the mkdir lock, otherwise pr=? still acquires
  # a `pr-?-review.lock` and the dispatcher still fans out a reviewer for "?".
  [ "$guard_lineno" -lt "$mkdir_lineno" ]
}

# ---------------------------------------------------------------------------
# Layer 4 — event_log.sh source-of-truth: the guard is in event_emit, not a
# caller wrapper. Pinned so a refactor that removes the central guard fails
# loudly (defense in depth was a deliberate choice in this fix).
# ---------------------------------------------------------------------------

@test "event_log.sh: event_emit contains a pr=? defensive guard" {
  grep -qF 'pr=?' "$LOOP_ROOT/runners/lib/event_log.sh"
}

# ---------------------------------------------------------------------------
# Layer 5 — schema doc: docs/event-schema.md documents the missing-pr reason
# ---------------------------------------------------------------------------

@test "docs/event-schema.md: documents dispatch_skip reason=missing-pr (GH#175)" {
  grep -qF 'missing-pr' "$LOOP_ROOT/docs/event-schema.md"
}
