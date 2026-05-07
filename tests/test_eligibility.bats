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
# eligibility_dev_count: blocked:human label post-filter (GH#28)
# Issues carrying the BLOCKED_HUMAN_LABEL label have already been flagged for
# human action by the safety-net flow. They must be skipped to break the
# rediscovery loop that re-spawns the LLM every cycle on the same blocked
# issue. The post-filter is a label-name lookup added next to the existing
# assignee filter; this test exercises the same jq pipeline against fixture
# JSON.
# ---------------------------------------------------------------------------

@test "dev-count blocked:human filter drops labeled issues" {
  local nums
  nums=$(jq -r '.[]
    | select(.assignees == [])
    | select((.labels // [] | map(.name)) | index("blocked:human") | not)
    | .number' \
    < "$LOOP_ROOT/tests/fixtures/gh/issues-with-blocked-label.json")
  # Fixture: 201 (no blocked label), 202 + 203 (blocked label) → expect 201 only.
  [ "$(printf '%s' "$nums" | sort -u | tr '\n' ' ')" = "201 " ]
}

@test "dev-count blocked:human filter is permissive when label is absent" {
  # issues-high.json has no `labels` field; the filter must fall through and
  # count both unassigned issues (101, 102), proving the filter doesn't
  # accidentally drop label-less fixtures.
  local nums
  nums=$(jq -r '.[]
    | select(.assignees == [])
    | select((.labels // [] | map(.name)) | index("blocked:human") | not)
    | .number' \
    < "$LOOP_ROOT/tests/fixtures/gh/issues-high.json")
  [ "$(printf '%s' "$nums" | sort -u | tr '\n' ' ')" = "101 102 " ]
}

@test "eligibility.sh: dev-count references BLOCKED_HUMAN_LABEL" {
  # Source-of-truth: the predicate must consume the configurable label name
  # (default 'blocked:human'), not silently hard-code a different string.
  grep -qF 'BLOCKED_HUMAN_LABEL' "$LOOP_ROOT/runners/lib/eligibility.sh"
  grep -qF 'blocked:human' "$LOOP_ROOT/runners/lib/eligibility.sh"
}

@test "developer.md: safety-net flow applies blocked:human label before exit" {
  # Source-of-truth: the prompt must instruct the agent to label the GH issue,
  # not just bd-flag the parent. Without this the eligibility predicate
  # rediscovers the blocked issue every cycle (GH#28). The template uses the
  # ${BLOCKED_HUMAN_LABEL} placeholder so renderer + config stay in lockstep;
  # also assert `gh issue edit ... --add-label` is the mechanism.
  grep -qF 'BLOCKED_HUMAN_LABEL' "$LOOP_ROOT/templates/developer.md"
  grep -qF -- '--add-label' "$LOOP_ROOT/templates/developer.md"
}

@test "eligibility_dev_count: blocked:human-only fixture exits 1 (no work)" {
  # End-to-end via the CLI with a stubbed gh: every eligible issue has the
  # blocked:human label, so the predicate must report 0 and exit 1 — proving
  # the label filter actually short-circuits the wrapper LLM spawn.
  local repo
  repo=$(make_repo)
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    # Mirror gh: every eligible issue carries the blocked:human label.
    echo '[{"number":9991,"assignees":[],"labels":[{"name":"blocked:human"}]}]'
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

@test "eligibility_dev_count: removing blocked:human re-makes issue eligible" {
  # Regression guard for the un-block path: same fixture as the previous test
  # minus the blocked:human label → count 1, exit 0 (LLM is invoked again).
  local repo
  repo=$(make_repo)
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "issue list")
    echo '[{"number":9992,"assignees":[],"labels":[{"name":"severity:medium"}]}]'
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
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
# eligibility_dev_candidates: high-then-medium ordering, dedupe, lock + assignee
# filtering. The wrapper consumes this list to claim a lock BEFORE spawning the
# LLM (GH#31): every printed number must be a viable claim target so the
# wrapper's mkdir loop can pick one without re-querying gh.
#
# Pure-shell tests exercise the same awk-dedupe + lock-skip pipeline the
# function uses, so we don't need to mock `gh` for the ordering logic.
# ---------------------------------------------------------------------------

@test "dev-candidates: high-then-medium with overlap dedupes preserving high-first order" {
  local high_nums med_nums all
  high_nums=$(jq -r '.[] | select(.assignees == []) | .number' \
                < "$LOOP_ROOT/tests/fixtures/gh/issues-high.json")
  med_nums=$(jq -r '.[] | select(.assignees == []) | .number' \
               < "$LOOP_ROOT/tests/fixtures/gh/issues-medium.json")
  # awk dedupe preserves first occurrence, so high (101, 102) appears before
  # the medium-only (103). 102 is in both files; should appear once, in its
  # high-side position.
  all=$(printf '%s\n%s\n' "$high_nums" "$med_nums" | awk 'NF && !seen[$0]++')
  [ "$(printf '%s' "$all" | tr '\n' ' ')" = "101 102 103" ]
}

@test "dev-candidates: lock-dir filter excludes already-locked issues from output" {
  local lock_dir="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$lock_dir/gh-101.lock" "$lock_dir/gh-103.lock"
  local high_nums med_nums all filtered_lines n
  high_nums=$(jq -r '.[] | select(.assignees == []) | .number' \
                < "$LOOP_ROOT/tests/fixtures/gh/issues-high.json")
  med_nums=$(jq -r '.[] | select(.assignees == []) | .number' \
               < "$LOOP_ROOT/tests/fixtures/gh/issues-medium.json")
  all=$(printf '%s\n%s\n' "$high_nums" "$med_nums" | awk 'NF && !seen[$0]++')
  filtered_lines=""
  for n in $all; do
    [ -d "$lock_dir/gh-${n}.lock" ] && continue
    filtered_lines+="$n"$'\n'
  done
  # 101 (locked) and 103 (locked) excluded; 102 remains.
  [ "$(printf '%s' "$filtered_lines" | tr '\n' ' ')" = "102 " ]
}

@test "dev-candidates: empty fixtures yield empty output" {
  local high_nums med_nums all
  high_nums=$(jq -r '.[] | select(.assignees == []) | .number' <<<'[]')
  med_nums=$(jq -r '.[] | select(.assignees == []) | .number' <<<'[]')
  all=$(printf '%s\n%s\n' "$high_nums" "$med_nums" | awk 'NF && !seen[$0]++')
  [ -z "$all" ]
}

# ---------------------------------------------------------------------------
# eligibility_dev_candidates (function-level): exercises the predicate
# end-to-end via PATH-mocked gh. Confirms the new CLI mode `dev-candidates`
# prints one candidate-number per line, exits 0 when work exists / 1 when none
# / 2 on gh failure — same shape as `dev`/`review`/`followup`.
# ---------------------------------------------------------------------------

# Helper: writes a gh shim that returns the high-issues fixture for
# `--label severity:high` and the medium-issues fixture for `--label severity:medium`,
# matching the two label-scoped queries inside eligibility_dev_candidates.
_make_gh_dev_stub() {
  local high="$1"
  local med="$2"
  local tmpbin="$BATS_TEST_TMPDIR/bin-dev"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<STUB
#!/usr/bin/env bash
# Minimal gh stub — just enough to satisfy eligibility_dev_candidates.
# Args: 'issue list --repo X --state open --label LABEL --json ... --limit ...'
label=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--label" ]; then
    label="\$2"; shift 2
  else
    shift
  fi
done
case "\$label" in
  severity:high)   cat '$high' ;;
  severity:medium) cat '$med' ;;
  *) echo '[]' ;;
esac
exit 0
STUB
  chmod +x "$tmpbin/gh"
  echo "$tmpbin"
}

@test "eligibility_dev_candidates: prints high-then-medium one-per-line, exits 0" {
  local repo
  repo=$(make_repo)
  local lock_dir="$BATS_TEST_TMPDIR/empty-locks"
  mkdir -p "$lock_dir"
  # Override LOCK_DIR in the consumer config so the predicate sees an empty lock dir.
  echo "LOCK_DIR=\"$lock_dir\"" >> "$repo/.loop/loop.config"
  local tmpbin
  tmpbin=$(_make_gh_dev_stub \
    "$LOOP_ROOT/tests/fixtures/gh/issues-high.json" \
    "$LOOP_ROOT/tests/fixtures/gh/issues-medium.json")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev-candidates
  [ "$status" -eq 0 ]
  # Output: 101, 102, 103 — high candidates first, medium-only candidate after.
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = "101 102 103" ]
}

@test "eligibility_dev_candidates: locked candidate excluded from output" {
  local repo
  repo=$(make_repo)
  local lock_dir="$BATS_TEST_TMPDIR/some-locks"
  mkdir -p "$lock_dir/gh-101.lock"
  echo "LOCK_DIR=\"$lock_dir\"" >> "$repo/.loop/loop.config"
  local tmpbin
  tmpbin=$(_make_gh_dev_stub \
    "$LOOP_ROOT/tests/fixtures/gh/issues-high.json" \
    "$LOOP_ROOT/tests/fixtures/gh/issues-medium.json")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev-candidates
  [ "$status" -eq 0 ]
  # 101 is locked → excluded. Order preserved: 102 (high) then 103 (medium-only).
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = "102 103" ]
}

@test "eligibility_dev_candidates: every candidate locked → empty output, exit 1" {
  local repo
  repo=$(make_repo)
  local lock_dir="$BATS_TEST_TMPDIR/all-locks"
  mkdir -p "$lock_dir/gh-101.lock" "$lock_dir/gh-102.lock" "$lock_dir/gh-103.lock"
  echo "LOCK_DIR=\"$lock_dir\"" >> "$repo/.loop/loop.config"
  local tmpbin
  tmpbin=$(_make_gh_dev_stub \
    "$LOOP_ROOT/tests/fixtures/gh/issues-high.json" \
    "$LOOP_ROOT/tests/fixtures/gh/issues-medium.json")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev-candidates
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "eligibility_dev_candidates: empty fixtures → empty output, exit 1" {
  local repo
  repo=$(make_repo)
  local lock_dir="$BATS_TEST_TMPDIR/empty-locks2"
  mkdir -p "$lock_dir"
  echo "LOCK_DIR=\"$lock_dir\"" >> "$repo/.loop/loop.config"
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local tmpbin
  tmpbin=$(_make_gh_dev_stub "$empty" "$empty")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev-candidates
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

@test "eligibility_dev_candidates: gh failure exits 2, prints '?'" {
  local repo
  repo=$(make_repo)
  local tmpbin="$BATS_TEST_TMPDIR/bin-fail-dev"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev-candidates
  [ "$status" -eq 2 ]
  [ "$output" = "?" ]
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

# ---------------------------------------------------------------------------
# Source-of-truth check: run-developer.sh's preflight (Mode 1) must acquire a
# filesystem lock BEFORE the `claude -p` invocation — otherwise the TOCTOU
# race in GH#31 reappears. This guards against a future refactor that puts
# lock acquisition back inside the LLM only.
# ---------------------------------------------------------------------------
@test "run-developer.sh: preflight calls eligibility dev-candidates" {
  grep -qE 'eligibility\.sh.* dev-candidates' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: preflight does mkdir on \$LOCK_DIR/gh-*.lock" {
  grep -qE 'mkdir[^|;&]*"\$LOCK_DIR/gh-' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: lock acquisition (mkdir LOCK_DIR/gh-) precedes claude invocation" {
  local mkdir_line claude_line
  mkdir_line=$(grep -nE 'mkdir[^|;&]*"\$LOCK_DIR/gh-' "$LOOP_ROOT/runners/run-developer.sh" | head -1 | cut -d: -f1)
  claude_line=$(grep -n '^[[:space:]]*claude -p' "$LOOP_ROOT/runners/run-developer.sh" | head -1 | cut -d: -f1)
  [ -n "$mkdir_line" ]
  [ -n "$claude_line" ]
  [ "$mkdir_line" -lt "$claude_line" ]
}

@test "run-developer.sh: exports DEV_AGENT_TARGET_ISSUE before claude invocation" {
  # The wrapper must set DEV_AGENT_TARGET_ISSUE so the LLM skips the rediscovery
  # flow (template Mode 1 short-circuits when this env var is set).
  grep -qE 'DEV_AGENT_TARGET_ISSUE' "$LOOP_ROOT/runners/run-developer.sh"
  local export_line claude_line
  export_line=$(grep -nE 'DEV_AGENT_TARGET_ISSUE=' "$LOOP_ROOT/runners/run-developer.sh" | head -1 | cut -d: -f1)
  claude_line=$(grep -n '^[[:space:]]*claude -p' "$LOOP_ROOT/runners/run-developer.sh" | head -1 | cut -d: -f1)
  [ -n "$export_line" ]
  [ -n "$claude_line" ]
  [ "$export_line" -lt "$claude_line" ]
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
