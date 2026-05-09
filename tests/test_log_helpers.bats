#!/usr/bin/env bats
# GH#100 — `loop_marker_last <pattern> [<file>]` reads the LAST matching line
# from an append-only log, not the first.
#
# Background: wrappers parse markers out of append-only logs to decide on
# follow-up actions. The original sites used `grep ... | head -1`, which is
# wrong for append-only logs — the canonical value is the last matching line.
# When the orchestrator's log accumulates multiple `sub-agent-failed` markers
# across attempts within the same session, `head -1` returns stale state and
# the wrapper acts on a PR# that no longer reflects the current failure.
#
# These tests pin the contract: multiple matches → last wins; one match →
# returned unchanged; zero matches and missing files → empty output, rc=0
# (so the helper composes cleanly with `[ -n "$X" ]` checks at call sites).

load 'helpers'

setup() {
  # shellcheck disable=SC1091
  . "$LOOP_ROOT/runners/lib/log_helpers.sh"
}

@test "loop_marker_last: multiple matches → returns the last line" {
  local file="$BATS_TEST_TMPDIR/log"
  cat >"$file" <<'EOF'
[orchestrator] result=sub-agent-failed pr=#10 reason=context-exhausted
[orchestrator] dispatched pr=#15 sub-agent-result=commented
[orchestrator] result=sub-agent-failed pr=#20 reason=context-exhausted
EOF

  run loop_marker_last 'result=sub-agent-failed pr=#[0-9]+' "$file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pr=#20"* ]]
  [[ "$output" != *"pr=#10"* ]]
}

@test "loop_marker_last: single match → returns that line" {
  local file="$BATS_TEST_TMPDIR/log"
  printf '[orchestrator] result=sub-agent-failed pr=#42 reason=oom\n' >"$file"

  run loop_marker_last 'result=sub-agent-failed pr=#[0-9]+' "$file"
  [ "$status" -eq 0 ]
  [[ "$output" == *"pr=#42"* ]]
}

@test "loop_marker_last: zero matches → empty output, rc=0" {
  local file="$BATS_TEST_TMPDIR/log"
  cat >"$file" <<'EOF'
[orchestrator] dispatched pr=#15 sub-agent-result=commented
[orchestrator] dispatched pr=#16 sub-agent-result=clean
EOF

  run loop_marker_last 'no-such-marker' "$file"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "loop_marker_last: missing file → empty output, rc=0" {
  run loop_marker_last 'foo' "$BATS_TEST_TMPDIR/does-not-exist.log"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "loop_marker_last: empty file → empty output, rc=0" {
  local file="$BATS_TEST_TMPDIR/empty.log"
  : >"$file"

  run loop_marker_last 'foo' "$file"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "loop_marker_last: stdin (no file arg) → reads from stdin, last match wins" {
  # Supports the run-developer.sh:340 call site, where the source is
  # TRIAGE_OUTPUT in a variable, not a file on disk. Stdin mode keeps the
  # call site free of a temp-file dance.
  run bash -c '
    . "'"$LOOP_ROOT"'/runners/lib/log_helpers.sh"
    printf "%s\n" \
      "reason=test-files" \
      "reason=ci-workflows" \
      "reason=line-cap-exceeded" \
      | loop_marker_last "reason=[^ ]+"
  '
  [ "$status" -eq 0 ]
  [ "$output" = "reason=line-cap-exceeded" ]
}

@test "loop_marker_last: stdin via '-' → same as no file arg" {
  run bash -c '
    . "'"$LOOP_ROOT"'/runners/lib/log_helpers.sh"
    printf "%s\n" "marker=a" "marker=b" "other" "marker=c" \
      | loop_marker_last "marker=[a-z]+" -
  '
  [ "$status" -eq 0 ]
  [ "$output" = "marker=c" ]
}

@test "loop_marker_last: stdin with zero matches → empty output, rc=0" {
  run bash -c '
    . "'"$LOOP_ROOT"'/runners/lib/log_helpers.sh"
    printf "no-match-here\n" | loop_marker_last "WONT_MATCH"
  '
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
