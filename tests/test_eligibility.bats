#!/usr/bin/env bats
# eligibility.sh — exercise the lock-filter logic in eligibility_dev_count
# and the jq filter that powers eligibility_review_pending.

load 'helpers'

# ---------------------------------------------------------------------------
# eligibility_dev_count: lock-dir post-filter (loop-06r)
# ---------------------------------------------------------------------------
# Pure-jq tests — these exercise the same lock-dir-skip logic the script uses
# without needing to mock `gh`. The script extracts numbers via
#   jq -r '.[].number'
# then iterates with `[ -d "${LOCK_DIR}/gh-${n}.lock" ] && continue`.
# We replicate that loop here against a fixture issue list and a real
# LOCK_DIR populated with selected lock dirs.

@test "dev-count filter excludes already-locked issues" {
  local lock_dir="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$lock_dir/gh-101.lock" "$lock_dir/gh-103.lock"
  local nums
  nums=$(jq -r '.[].number' < "$LOOP_ROOT/tests/fixtures/gh/issues-with-locks.json")
  local filtered=0 n
  for n in $nums; do
    [ -d "$lock_dir/gh-${n}.lock" ] && continue
    filtered=$((filtered + 1))
  done
  # Fixture has 4 issues (101-104); 101 and 103 are locked → expect 2.
  [ "$filtered" -eq 2 ]
}

@test "dev-count filter is permissive when no locks exist" {
  local lock_dir="$BATS_TEST_TMPDIR/empty-locks"
  mkdir -p "$lock_dir"
  local nums
  nums=$(jq -r '.[].number' < "$LOOP_ROOT/tests/fixtures/gh/issues-with-locks.json")
  local filtered=0 n
  for n in $nums; do
    [ -d "$lock_dir/gh-${n}.lock" ] && continue
    filtered=$((filtered + 1))
  done
  [ "$filtered" -eq 4 ]
}

# ---------------------------------------------------------------------------
# eligibility_dev_count: REST-list path replaces --search (loop-d8j)
# Two `gh issue list --label X` calls (one per severity) are unioned with
# `sort -u`. Assigned issues are dropped via `select(.assignees == [])`.
# These tests exercise the same jq + sort -u pipeline against fixture JSON.
# ---------------------------------------------------------------------------

@test "dev-count assignee filter drops issues with assignees" {
  local nums
  nums=$(jq -r '.[] | select(.assignees == []) | .number' \
           < "$LOOP_ROOT/tests/fixtures/gh/issues-high.json")
  # Fixture: 101, 102 unassigned; 105 has an assignee. Expect 101, 102.
  [ "$(printf '%s' "$nums" | sort -u | tr '\n' ' ')" = "101 102 " ]
}

@test "dev-count union of high+medium with overlap collapses via sort -u" {
  local high_nums med_nums all
  high_nums=$(jq -r '.[] | select(.assignees == []) | .number' \
                < "$LOOP_ROOT/tests/fixtures/gh/issues-high.json")
  med_nums=$(jq -r '.[] | select(.assignees == []) | .number' \
               < "$LOOP_ROOT/tests/fixtures/gh/issues-medium.json")
  all=$(printf '%s\n%s\n' "$high_nums" "$med_nums" | sort -u | grep . || true)
  # high unassigned: 101, 102. medium unassigned: 102, 103. Union: 101,102,103.
  [ "$(printf '%s' "$all" | tr '\n' ' ')" = "101 102 103" ]
}

@test "dev-count empty fixtures yield zero candidates" {
  local nums all
  nums=$(jq -r '.[] | select(.assignees == []) | .number' <<<'[]')
  all=$(printf '%s\n%s\n' "$nums" "$nums" | sort -u | grep . || true)
  [ -z "$all" ]
}

# ---------------------------------------------------------------------------
# eligibility_review_pending: jq filter for "no agent review covers head"
# Compares review.submittedAt against the PR head commit's committedDate.
# ---------------------------------------------------------------------------
REVIEW_FILTER='[.[]
  | . as $pr
  | ((($pr.commits // [])[-1] | .committedDate) // null) as $head_date
  | ($pr.reviews // [] | [.[] | select(.body | test($re)) | .submittedAt]) as $review_dates
  | select(
      $head_date == null
      or ($review_dates | map(select(. != null and . > $head_date)) | length == 0)
    )
] | length'

@test "review filter: PR with review at current head is filtered OUT" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(jq --arg re "$re" "$REVIEW_FILTER" \
        < "$LOOP_ROOT/tests/fixtures/gh/prs-current.json")
  [ "$n" -eq 0 ]
}

@test "review filter: PR with review at stale head is INCLUDED" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(jq --arg re "$re" "$REVIEW_FILTER" \
        < "$LOOP_ROOT/tests/fixtures/gh/prs-stale.json")
  [ "$n" -eq 1 ]
}

@test "review filter: mixed list returns only the un-reviewed PRs" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(jq --arg re "$re" "$REVIEW_FILTER" \
        < "$LOOP_ROOT/tests/fixtures/gh/prs-mixed.json")
  # 200 has current review (excluded), 201 has stale (included), 202 has no
  # reviews at all (included). Expect 2.
  [ "$n" -eq 2 ]
}

# ---------------------------------------------------------------------------
# CLI shape — unknown mode exits 2.
# ---------------------------------------------------------------------------
@test "eligibility.sh CLI errors on unknown mode" {
  local repo
  repo=$(make_repo)
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run bash "$LOOP_ROOT/runners/lib/eligibility.sh" bogus
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF '[eligibility] unknown mode'
}
