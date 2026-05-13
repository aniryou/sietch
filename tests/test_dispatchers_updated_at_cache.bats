#!/usr/bin/env bats
# GH#181: verdict-skip cache for the followup and merger dispatchers. The
# cache keys per-PR skip decisions by .updatedAt so the dispatcher can avoid
# re-running `gh pr view` (the per-PR REST call inside eligibility_followup_pr
# / eligibility_merge_pr) for unchanged PRs each cycle. These tests pin:
#
#   1. The new jq helpers emit `<number>\t<updatedAt>` for each non-draft
#      dev-agent PR — same candidate set as the existing single-field
#      helpers, just plumbed with the freshness key.
#   2. run-loop.sh wires the new helpers in for both dispatchers AND adds
#      `updatedAt` to the `gh pr list --json` field set (otherwise the
#      helpers would emit `null` and every cache lookup would miss).
#   3. The dispatcher emits `dispatch_skip ... reason=cached-skip` on a
#      cache hit so the cache hit rate is observable in the event log.
#   4. docs/event-schema.md documents the new `cached-skip` reason value.

load 'helpers'

setup() {
  # shellcheck source=/dev/null
  . "$LOOP_ROOT/runners/lib/dispatcher.sh"
}

# ---------------------------------------------------------------------------
# New jq helpers — emit `<number>\t<updatedAt>` for non-draft dev-agent PRs.
# ---------------------------------------------------------------------------

@test "followup-with-updated filter: emits <number>\\t<updatedAt> per eligible PR" {
  local filter rows expected
  filter=$(_dispatch_followup_with_updated_jq "dev-agent")
  rows=$(jq -r "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch-with-updated.json")
  expected=$(printf '11\t2026-05-13T10:00:00Z\n13\t2026-05-13T10:10:00Z')
  [ "$rows" = "$expected" ]
}

@test "followup-with-updated filter: empty input emits nothing" {
  local filter rows
  filter=$(_dispatch_followup_with_updated_jq "dev-agent")
  rows=$(jq -r "$filter" <<<'[]')
  [ -z "$rows" ]
}

@test "followup-with-updated filter: respects custom branch prefix" {
  local filter rows expected
  filter=$(_dispatch_followup_with_updated_jq "feature")
  rows=$(jq -r "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch-with-updated.json")
  expected=$(printf '15\t2026-05-13T10:20:00Z\n16\t2026-05-13T10:25:00Z')
  [ "$rows" = "$expected" ]
}

@test "followup-with-updated filter: missing updatedAt coalesces to '?' (defensive)" {
  # Defensive: if a PR returned by gh somehow lacks updatedAt, the second
  # column must still be non-empty so the `while IFS=\\t read -r pr updated`
  # in run-loop.sh parses cleanly. Otherwise an empty updatedAt would
  # collapse the TSV column and the cache key would be ambiguous.
  local filter rows expected
  filter=$(_dispatch_followup_with_updated_jq "dev-agent")
  rows=$(jq -r "$filter" <<<'[{"number":42,"headRefName":"dev-agent/gh-42-x","isDraft":false}]')
  expected=$(printf '42\t?')
  [ "$rows" = "$expected" ]
}

@test "merge-with-updated filter: emits <number>\\t<updatedAt> per eligible PR" {
  local filter rows expected
  filter=$(_dispatch_merge_with_updated_jq "dev-agent")
  rows=$(jq -r "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch-with-updated.json")
  # Merger uses the same candidate filter as followup (verdict / CI gating
  # happens later, inside eligibility_merge_pr), so the row set matches.
  expected=$(printf '11\t2026-05-13T10:00:00Z\n13\t2026-05-13T10:10:00Z')
  [ "$rows" = "$expected" ]
}

@test "merge-with-updated filter: empty input emits nothing" {
  local filter rows
  filter=$(_dispatch_merge_with_updated_jq "dev-agent")
  rows=$(jq -r "$filter" <<<'[]')
  [ -z "$rows" ]
}

# ---------------------------------------------------------------------------
# run-loop.sh wiring — both dispatchers must consume the new helpers AND
# carry `updatedAt` through their `gh pr list --json` set. Without the
# field, the helper emits `null` and the cache is always a miss.
# ---------------------------------------------------------------------------

@test "run-loop.sh: followup dispatcher --json field set includes updatedAt (GH#181)" {
  awk '/^loop_dispatcher_followup\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qE -- '--json[[:space:]]+[A-Za-z,]*updatedAt' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "run-loop.sh: followup dispatcher invokes _dispatch_followup_with_updated_jq (GH#181)" {
  awk '/^loop_dispatcher_followup\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF '_dispatch_followup_with_updated_jq' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "run-loop.sh: merger dispatcher --json field set includes updatedAt (GH#181)" {
  awk '/^loop_dispatcher_merge\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qE -- '--json[[:space:]]+[A-Za-z,]*updatedAt' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "run-loop.sh: merger dispatcher invokes _dispatch_merge_with_updated_jq (GH#181)" {
  awk '/^loop_dispatcher_merge\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF '_dispatch_merge_with_updated_jq' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "run-loop.sh: followup dispatcher emits cached-skip on cache hit (GH#181)" {
  # The cache-hit branch must emit `dispatch_skip ... reason=cached-skip` so
  # the new skip path shows up in /tmp/loop-events-*.jsonl alongside the
  # existing verdict-driven skips. Without the emit, the observability story
  # in the acceptance criteria fails — there is no way to read the cache
  # hit rate from the event log.
  awk '/^loop_dispatcher_followup\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF 'reason=cached-skip' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "run-loop.sh: merger dispatcher emits cached-skip on cache hit (GH#181)" {
  awk '/^loop_dispatcher_merge\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF 'reason=cached-skip' "$BATS_TEST_TMPDIR/fn.sh"
}

# ---------------------------------------------------------------------------
# event-schema.md must document cached-skip alongside the existing
# dispatch_skip reasons. Without this, downstream tower consumers see an
# unknown value and the acceptance criterion "document the new reason value
# in docs/event-schema.md" fails.
# ---------------------------------------------------------------------------

@test "docs/event-schema.md: documents cached-skip dispatch_skip reason (GH#181)" {
  grep -qF 'cached-skip' "$LOOP_ROOT/docs/event-schema.md"
}
