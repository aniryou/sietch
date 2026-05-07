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
# eligibility_followup_pr: verdict-aware gate for the follow-up dispatcher
# (GH#24). The filter classifies the latest reviewer-agent review on a PR
# and decides whether to dispatch a Mode 2 dev-agent. Verdicts {clean,nits}
# always skip; {changes,comment,blocked} dispatch iff the review is newer
# than the latest dev-agent comment (otherwise the dev already responded).
#
# Tests exercise the same jq filter the predicate uses, kept in lockstep
# with runners/lib/eligibility.sh. Each test mutates the canonical fixture
# (one [reviewer-agent: changes] review newer than one dev-comment) to
# inject the scenario-specific verdict / timestamp ordering.
# ---------------------------------------------------------------------------
FOLLOWUP_FILTER='
  (.reviews // []
    | map(select(.body | test($re)))
    | sort_by(.submittedAt)
    | last) as $latest_review
  | (.comments // []
    | map(select(.body | startswith($prefix)))
    | sort_by(.createdAt)
    | last) as $latest_devcomment
  | if $latest_review == null then "none\tno"
    else
      ($latest_review.body | match($re).captures[0].string) as $verdict
      | if ($verdict == "clean" or $verdict == "nits") then "\($verdict)\tno"
        elif ($latest_devcomment == null
              or $latest_review.submittedAt > $latest_devcomment.createdAt) then
          "\($verdict)\tyes"
        else "\($verdict)\tno"
        end
    end
'

# Helper: rewrite the latest review body in the fixture to a given verdict
# and emit the modified JSON. Keeps each test focused on the verdict logic
# without forking N near-identical fixture files.
_with_verdict() {
  local verdict="$1"
  jq --arg body "[reviewer-agent: ${verdict}] generated" \
     '.reviews[-1].body = $body' \
     "$LOOP_ROOT/tests/fixtures/gh/pr-followup.json"
}

# Helper: backdate the review to make the dev-comment newer (the
# "dev-already-responded" case).
_with_review_older_than_devcomment() {
  jq '.reviews[-1].submittedAt = "2026-05-07T10:00:00Z"
      | .comments[-1].createdAt = "2026-05-07T11:00:00Z"' \
     "$LOOP_ROOT/tests/fixtures/gh/pr-followup.json"
}

@test "followup filter: clean verdict skipped (review newer than dev-comment)" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(_with_verdict clean | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'clean\tno' ]
}

@test "followup filter: nits verdict skipped (review newer than dev-comment)" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(_with_verdict nits | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'nits\tno' ]
}

@test "followup filter: changes verdict dispatches when review is newer" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(_with_verdict changes | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'changes\tyes' ]
}

@test "followup filter: comment verdict dispatches when review is newer" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(_with_verdict comment | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'comment\tyes' ]
}

@test "followup filter: blocked verdict dispatches when review is newer" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(_with_verdict blocked | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'blocked\tyes' ]
}

@test "followup filter: changes verdict skipped when dev-comment is newer" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(_with_review_older_than_devcomment \
        | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'changes\tno' ]
}

@test "followup filter: PR with no reviewer-agent review is skipped" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(jq '.reviews = []' "$LOOP_ROOT/tests/fixtures/gh/pr-followup.json" \
        | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'none\tno' ]
}

@test "followup filter: dispatches when no dev-agent comment exists yet" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(jq '.comments = []' "$LOOP_ROOT/tests/fixtures/gh/pr-followup.json" \
        | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'changes\tyes' ]
}

# ---------------------------------------------------------------------------
# eligibility_followup_pr (function-level): exercises the predicate
# end-to-end via PATH-mocked gh, confirming exit-code semantics match
# eligibility_dev_count / eligibility_review_pending (0=work, 1=skip, 2=fail).
# ---------------------------------------------------------------------------
_make_gh_stub() {
  # Args: <fixture-json-path>. Writes a gh shim that returns the fixture for
  # any `pr view ... --json reviews,comments` invocation.
  local fixture="$1"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")
    cat '$fixture'
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  echo "$tmpbin"
}

@test "eligibility_followup_pr: clean verdict exits 1 (skip), prints 'clean'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/clean.json"
  _with_verdict clean > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup 42
  [ "$status" -eq 1 ]
  [ "$output" = "clean" ]
}

@test "eligibility_followup_pr: nits verdict exits 1 (skip), prints 'nits'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/nits.json"
  _with_verdict nits > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup 42
  [ "$status" -eq 1 ]
  [ "$output" = "nits" ]
}

@test "eligibility_followup_pr: changes verdict (review newer) exits 0, prints 'changes'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/changes.json"
  _with_verdict changes > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup 42
  [ "$status" -eq 0 ]
  [ "$output" = "changes" ]
}

@test "eligibility_followup_pr: comment verdict (review newer) exits 0" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/comment.json"
  _with_verdict comment > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup 42
  [ "$status" -eq 0 ]
  [ "$output" = "comment" ]
}

@test "eligibility_followup_pr: blocked verdict (review newer) exits 0" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/blocked.json"
  _with_verdict blocked > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup 42
  [ "$status" -eq 0 ]
  [ "$output" = "blocked" ]
}

@test "eligibility_followup_pr: changes verdict but dev-comment newer exits 1" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/already-responded.json"
  _with_review_older_than_devcomment > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup 42
  [ "$status" -eq 1 ]
  [ "$output" = "changes" ]
}

@test "eligibility_followup_pr: gh failure exits 2, prints '?'" {
  local repo
  repo=$(make_repo)
  local tmpbin="$BATS_TEST_TMPDIR/bin-fail"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup 42
  [ "$status" -eq 2 ]
  [ "$output" = "?" ]
}

@test "eligibility_followup_pr: missing PR# arg exits 2, prints '?'" {
  local repo
  repo=$(make_repo)
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup
  [ "$status" -eq 2 ]
  [ "$output" = "?" ]
}

# ---------------------------------------------------------------------------
# Source-of-truth check: run-loop.sh's follow-up dispatcher must consume the
# new predicate, not the old timestamp-only check (regression guard for the
# bug GH#24 actually fixes).
# ---------------------------------------------------------------------------
@test "run-loop.sh: follow-up dispatcher invokes eligibility_followup_pr" {
  grep -qF 'eligibility_followup_pr' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: follow-up dispatcher re-sources lib/eligibility.sh per cycle (hot-reload)" {
  # The dispatcher must pick up on-disk fixes to the predicate without a
  # tmux-pane restart, mirroring the existing lib/dispatcher.sh hot-reload.
  awk '/loop_dispatcher_followup\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -qF 'lib/eligibility.sh'
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
