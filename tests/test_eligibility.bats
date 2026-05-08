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

@test "eligibility_dev_candidates: blocked:human-labeled candidates filtered out" {
  # GH#36 P0: dev-candidates must mirror dev-count's blocked:human filter,
  # otherwise the wrapper mkdir-locks an issue the safety-net flow already
  # marked permanently ineligible, exports DEV_AGENT_TARGET_ISSUE, and the
  # LLM (which skips its own discovery) re-trips the safety-net rule and
  # exits — the exact rediscovery loop GH#28 closed for the count path.
  local repo
  repo=$(make_repo)
  local lock_dir="$BATS_TEST_TMPDIR/empty-locks-blocked"
  mkdir -p "$lock_dir"
  echo "LOCK_DIR=\"$lock_dir\"" >> "$repo/.loop/loop.config"
  # High fixture: 991 has blocked:human, 992 is eligible.
  # Medium fixture: 993 has blocked:human, 994 is eligible.
  # Expected output: 992 (high), then 994 (medium).
  local high="$BATS_TEST_TMPDIR/blocked-high.json"
  local med="$BATS_TEST_TMPDIR/blocked-med.json"
  cat > "$high" <<'JSON'
[
  {"number":991,"assignees":[],"labels":[{"name":"severity:high"},{"name":"blocked:human"}]},
  {"number":992,"assignees":[],"labels":[{"name":"severity:high"}]}
]
JSON
  cat > "$med" <<'JSON'
[
  {"number":993,"assignees":[],"labels":[{"name":"severity:medium"},{"name":"blocked:human"}]},
  {"number":994,"assignees":[],"labels":[{"name":"severity:medium"}]}
]
JSON
  local tmpbin
  tmpbin=$(_make_gh_dev_stub "$high" "$med")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev-candidates
  [ "$status" -eq 0 ]
  [ "$(printf '%s' "$output" | tr '\n' ' ')" = "992 994" ]
}

@test "eligibility_dev_candidates: every candidate has blocked:human → empty output, exit 1" {
  # End-to-end version of the filter test: when EVERY candidate in both the
  # high and medium queries carries the blocked:human label, the wrapper must
  # see zero candidates (exit 1) so it short-circuits without mkdir-locking
  # and without spawning the LLM.
  local repo
  repo=$(make_repo)
  local lock_dir="$BATS_TEST_TMPDIR/empty-locks-all-blocked"
  mkdir -p "$lock_dir"
  echo "LOCK_DIR=\"$lock_dir\"" >> "$repo/.loop/loop.config"
  local high="$BATS_TEST_TMPDIR/all-blocked-high.json"
  local med="$BATS_TEST_TMPDIR/all-blocked-med.json"
  echo '[{"number":991,"assignees":[],"labels":[{"name":"severity:high"},{"name":"blocked:human"}]}]' > "$high"
  echo '[{"number":992,"assignees":[],"labels":[{"name":"severity:medium"},{"name":"blocked:human"}]}]' > "$med"
  local tmpbin
  tmpbin=$(_make_gh_dev_stub "$high" "$med")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" dev-candidates
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# eligibility_review_pending: jq filter for "no agent review covers head AND
# CI has finished".
#
# Review-coverage half: compares review.submittedAt against the head commit's
# committedDate. The committedDate is no longer carried in the gh pr list
# payload — that hit GH#26's GraphQL 500k-node ceiling — so the predicate
# resolves it via a per-headRefOid `gh api graphql` call and injects the
# resulting map as the `$dates` jq variable, keyed by `headRefOid`.
#
# CI-gate half (GH#46): excludes any PR with a check in IN_PROGRESS / PENDING
# / QUEUED. Uses `.status // .state` because gh's statusCheckRollup carries
# `.status` for CheckRun (Actions) and `.state` for legacy StatusContext.
# Missing/null statusCheckRollup falls through to an empty list (no gating).
# ---------------------------------------------------------------------------
REVIEW_FILTER='[.[]
  | . as $pr
  | (($dates[$pr.headRefOid] // "") | (if . == "" then null else . end)) as $head_date
  | ($pr.reviews // [] | [.[] | select(.body | test($re)) | .submittedAt]) as $review_dates
  | ($pr.statusCheckRollup // [] | map(.status // .state)) as $check_states
  | select(
      $head_date == null
      or ($review_dates | map(select(. != null and . > $head_date)) | length == 0)
    )
  | select(
      ($check_states | index("IN_PROGRESS") | not)
      and ($check_states | index("PENDING") | not)
      and ($check_states | index("QUEUED") | not)
    )
] | length'

# Per-fixture oid → committedDate maps. Each PR's headRefOid in the fixture is
# resolved here to the date the production code would fetch via gh api graphql.
DATES_CURRENT='{"0011223344556677889900112233445566778899":"2026-05-07T10:00:00Z"}'
DATES_STALE='{"aabbccddeeff00112233445566778899aabbccdd":"2026-05-07T12:00:00Z"}'
DATES_MIXED='{"0011223344556677889900112233445566778899":"2026-05-07T10:00:00Z","aabbccddeeff00112233445566778899aabbccdd":"2026-05-07T12:00:00Z","ffeeddccbbaa99887766554433221100ffeeddcc":"2026-05-07T09:00:00Z"}'

@test "review filter: PR with review at current head is filtered OUT" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(jq --arg re "$re" --argjson dates "$DATES_CURRENT" "$REVIEW_FILTER" \
        < "$LOOP_ROOT/tests/fixtures/gh/prs-current.json")
  [ "$n" -eq 0 ]
}

@test "review filter: PR with review at stale head is INCLUDED" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER" \
        < "$LOOP_ROOT/tests/fixtures/gh/prs-stale.json")
  [ "$n" -eq 1 ]
}

@test "review filter: mixed list returns only the un-reviewed PRs" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(jq --arg re "$re" --argjson dates "$DATES_MIXED" "$REVIEW_FILTER" \
        < "$LOOP_ROOT/tests/fixtures/gh/prs-mixed.json")
  # 200 has current review (excluded), 201 has stale (included), 202 has no
  # reviews at all (included). Expect 2.
  [ "$n" -eq 2 ]
}

@test "review filter: PR whose headRefOid is missing from \$dates → INCLUDED" {
  # Defensive guard. If the gh api graphql call fails or the oid is orphaned,
  # \$dates simply omits the key. The filter must fall through to head_date=null
  # (which selects the PR for review) rather than crashing or excluding it.
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(jq --arg re "$re" --argjson dates '{}' "$REVIEW_FILTER" \
        < "$LOOP_ROOT/tests/fixtures/gh/prs-current.json")
  [ "$n" -eq 1 ]
}

# ---------------------------------------------------------------------------
# eligibility_review_pending CI gate (GH#46): the predicate must exclude PRs
# whose statusCheckRollup contains any IN_PROGRESS / PENDING / QUEUED check.
# Failed CI (COMPLETED+FAILURE) is still reviewable. Missing/null/empty
# statusCheckRollup is treated as "no gating" — same posture as the orchestrator
# behaviour the gate mirrors.
#
# Tests mutate the prs-stale.json fixture (which has a stale review and would
# otherwise be INCLUDED by the review-coverage half) so the CI gate's effect
# is observable in isolation: a non-finished check must drop the count from
# 1 to 0; a finished check leaves it at 1.
# ---------------------------------------------------------------------------

# Helper: rewrite the statusCheckRollup field of the stale-fixture PR.
# Accepts a JSON literal (typically an array of one or more {status: ...}
# entries) and returns the mutated PR list on stdout.
_with_check_rollup() {
  local rollup_json="$1"
  jq --argjson rollup "$rollup_json" '.[0].statusCheckRollup = $rollup' \
     "$LOOP_ROOT/tests/fixtures/gh/prs-stale.json"
}

@test "review filter: stale review + IN_PROGRESS check is filtered OUT (GH#46)" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(_with_check_rollup '[{"__typename":"CheckRun","status":"IN_PROGRESS"}]' \
      | jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER")
  [ "$n" -eq 0 ]
}

@test "review filter: stale review + PENDING check is filtered OUT (GH#46)" {
  # PENDING is the StatusContext idiom (legacy commit-status API), so it
  # surfaces under .state, not .status. The .status // .state normalization
  # must catch both shapes.
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(_with_check_rollup '[{"__typename":"StatusContext","state":"PENDING"}]' \
      | jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER")
  [ "$n" -eq 0 ]
}

@test "review filter: stale review + QUEUED check is filtered OUT (GH#46)" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(_with_check_rollup '[{"__typename":"CheckRun","status":"QUEUED"}]' \
      | jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER")
  [ "$n" -eq 0 ]
}

@test "review filter: stale review + COMPLETED+SUCCESS check is INCLUDED (GH#46)" {
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(_with_check_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' \
      | jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER")
  [ "$n" -eq 1 ]
}

@test "review filter: stale review + COMPLETED+FAILURE check is INCLUDED (GH#46)" {
  # Failed CI is still reviewable — only RUNNING states gate. This matches
  # the orchestrator's pre-existing behaviour: a red PR should still be
  # picked up by the reviewer agent.
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(_with_check_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]' \
      | jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER")
  [ "$n" -eq 1 ]
}

@test "review filter: stale review + mixed (IN_PROGRESS + COMPLETED) is filtered OUT (GH#46)" {
  # Any one running check gates — the predicate must not require ALL checks
  # to be running before excluding the PR.
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(_with_check_rollup '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"},{"__typename":"CheckRun","status":"IN_PROGRESS"}]' \
      | jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER")
  [ "$n" -eq 0 ]
}

@test "review filter: stale review + empty statusCheckRollup is INCLUDED (GH#46)" {
  # Empty array means GitHub has no checks reported (e.g., a repo with no CI).
  # The gate must not exclude such PRs — there is nothing to wait on.
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(_with_check_rollup '[]' \
      | jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER")
  [ "$n" -eq 1 ]
}

@test "review filter: stale review + null statusCheckRollup is INCLUDED (GH#46)" {
  # Defensive guard. If the gh response somehow omits the field or sets it
  # to null, the filter's `// []` fallback must keep the PR eligible rather
  # than crashing or silently excluding it.
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local n
  n=$(jq '.[0].statusCheckRollup = null' "$LOOP_ROOT/tests/fixtures/gh/prs-stale.json" \
      | jq --arg re "$re" --argjson dates "$DATES_STALE" "$REVIEW_FILTER")
  [ "$n" -eq 1 ]
}

# ---------------------------------------------------------------------------
# eligibility_review_pending (function-level, GH#26): exercise the predicate
# end-to-end via PATH-mocked gh, confirming exit-code semantics match the
# rest of the predicate family (0=work, 1=skip, 2=fail) AND that the gh
# query no longer requests the bloated `commits` connection.
# ---------------------------------------------------------------------------

# Helper: write a gh stub that:
#   - serves a fixed `gh pr list` body (the PR list with headRefOid + reviews),
#     honoring the --jq flag the way real gh does (post-filter via jq).
#   - resolves `gh api graphql -F oid=<X> ...` against an oid→date JSON map.
#
# Returns the bin dir to prepend to PATH.
_make_review_gh_stub() {
  # $1 = path to a JSON file containing the gh pr list response
  # $2 = path to a JSON file mapping headRefOid → committedDate
  local prs_path="$1"
  local dates_path="$2"
  local tmpbin="$BATS_TEST_TMPDIR/review-bin-$$"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<STUB
#!/usr/bin/env bash
ARGS=("\$@")
SUB1="\${ARGS[0]:-}"
SUB2="\${ARGS[1]:-}"

# Real gh post-filters output through jq when --jq <expr> is set.
JQ_EXPR=""
for ((i=0; i<\${#ARGS[@]}; i++)); do
  if [ "\${ARGS[i]}" = "--jq" ]; then JQ_EXPR="\${ARGS[i+1]:-}"; fi
done

emit() {
  if [ -n "\$JQ_EXPR" ]; then
    printf '%s\n' "\$1" | jq -r "\$JQ_EXPR"
  else
    printf '%s\n' "\$1"
  fi
}

case "\$SUB1 \$SUB2" in
  "pr list")
    emit "\$(cat '$prs_path')"
    exit 0
    ;;
  "api graphql")
    OID=""
    for ((i=0; i<\${#ARGS[@]}; i++)); do
      if [ "\${ARGS[i]}" = "-F" ] && [[ "\${ARGS[i+1]:-}" == oid=* ]]; then
        OID="\${ARGS[i+1]#oid=}"
      fi
    done
    DATE=\$(jq -r --arg oid "\$OID" '.[\$oid] // ""' '$dates_path')
    if [ -z "\$DATE" ]; then
      emit '{"data":{"repository":{"object":null}}}'
    else
      emit "\$(printf '{"data":{"repository":{"object":{"committedDate":"%s"}}}}' "\$DATE")"
    fi
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  echo "$tmpbin"
}

@test "eligibility_review_pending: empty PR list exits 1 (skip), prints '0'" {
  local repo
  repo=$(make_repo)
  local prs="$BATS_TEST_TMPDIR/prs-empty.json"
  local dates="$BATS_TEST_TMPDIR/dates-empty.json"
  printf '[]\n' >"$prs"
  printf '{}\n' >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

@test "eligibility_review_pending: all PRs covered by review exits 1, prints '0'" {
  local repo
  repo=$(make_repo)
  local prs="$LOOP_ROOT/tests/fixtures/gh/prs-current.json"
  local dates="$BATS_TEST_TMPDIR/dates-current.json"
  printf '%s' "$DATES_CURRENT" >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

@test "eligibility_review_pending: PR with stale review exits 0, prints '1'" {
  local repo
  repo=$(make_repo)
  local prs="$LOOP_ROOT/tests/fixtures/gh/prs-stale.json"
  local dates="$BATS_TEST_TMPDIR/dates-stale.json"
  printf '%s' "$DATES_STALE" >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "eligibility_review_pending: mixed list (1 current, 1 stale, 1 no-review) exits 0, prints '2'" {
  local repo
  repo=$(make_repo)
  local prs="$LOOP_ROOT/tests/fixtures/gh/prs-mixed.json"
  local dates="$BATS_TEST_TMPDIR/dates-mixed.json"
  printf '%s' "$DATES_MIXED" >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 0 ]
  [ "$output" = "2" ]
}

# ---------------------------------------------------------------------------
# eligibility_review_pending CI gate (GH#46): function-level tests using the
# PATH-mocked gh stub. These exercise the predicate end-to-end so the wrapper
# preflight gets the correct exit-code semantics — the whole point of GH#46
# is that runners/run-reviewer.sh skips with `result=no-work` instead of
# spawning the orchestrator LLM while CI is still running.
#
# Helper: make a one-PR fixture from prs-stale.json with a custom rollup and
# return the path. The stale-fixture's review is older than the head, so the
# review-coverage half always votes INCLUDE — making the CI gate's effect
# observable in isolation (exit 0 ⇔ CI completed, exit 1 ⇔ CI gating).
# ---------------------------------------------------------------------------
_with_rollup_to_file() {
  local rollup_json="$1"
  local out_path="$2"
  jq --argjson rollup "$rollup_json" '.[0].statusCheckRollup = $rollup' \
     "$LOOP_ROOT/tests/fixtures/gh/prs-stale.json" > "$out_path"
}

@test "eligibility_review_pending: PR with IN_PROGRESS check exits 1, prints '0' (GH#46)" {
  local repo
  repo=$(make_repo)
  local prs="$BATS_TEST_TMPDIR/prs-ci-running.json"
  _with_rollup_to_file '[{"__typename":"CheckRun","status":"IN_PROGRESS"}]' "$prs"
  local dates="$BATS_TEST_TMPDIR/dates-stale.json"
  printf '%s' "$DATES_STALE" >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

@test "eligibility_review_pending: PR with PENDING check exits 1, prints '0' (GH#46)" {
  local repo
  repo=$(make_repo)
  local prs="$BATS_TEST_TMPDIR/prs-ci-pending.json"
  _with_rollup_to_file '[{"__typename":"StatusContext","state":"PENDING"}]' "$prs"
  local dates="$BATS_TEST_TMPDIR/dates-stale.json"
  printf '%s' "$DATES_STALE" >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

@test "eligibility_review_pending: PR with QUEUED check exits 1, prints '0' (GH#46)" {
  local repo
  repo=$(make_repo)
  local prs="$BATS_TEST_TMPDIR/prs-ci-queued.json"
  _with_rollup_to_file '[{"__typename":"CheckRun","status":"QUEUED"}]' "$prs"
  local dates="$BATS_TEST_TMPDIR/dates-stale.json"
  printf '%s' "$DATES_STALE" >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 1 ]
  [ "$output" = "0" ]
}

@test "eligibility_review_pending: PR with COMPLETED+SUCCESS exits 0, prints '1' (GH#46)" {
  local repo
  repo=$(make_repo)
  local prs="$BATS_TEST_TMPDIR/prs-ci-success.json"
  _with_rollup_to_file '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"SUCCESS"}]' "$prs"
  local dates="$BATS_TEST_TMPDIR/dates-stale.json"
  printf '%s' "$DATES_STALE" >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "eligibility_review_pending: PR with COMPLETED+FAILURE exits 0, prints '1' (GH#46)" {
  # Failed CI is reviewable — only RUNNING states gate. The orchestrator
  # has always reviewed red PRs; the predicate must mirror that.
  local repo
  repo=$(make_repo)
  local prs="$BATS_TEST_TMPDIR/prs-ci-failure.json"
  _with_rollup_to_file '[{"__typename":"CheckRun","status":"COMPLETED","conclusion":"FAILURE"}]' "$prs"
  local dates="$BATS_TEST_TMPDIR/dates-stale.json"
  printf '%s' "$DATES_STALE" >"$dates"
  local tmpbin
  tmpbin=$(_make_review_gh_stub "$prs" "$dates")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 0 ]
  [ "$output" = "1" ]
}

@test "eligibility_review_pending: gh pr list failure exits 2, prints '?'" {
  local repo
  repo=$(make_repo)
  local tmpbin="$BATS_TEST_TMPDIR/bin-prfail"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") exit 1 ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 2 ]
  [ "$output" = "?" ]
}

@test "eligibility_review_pending: gh api graphql failure exits 2, prints '?'" {
  # gh pr list succeeds, but the per-oid GraphQL resolution fails. The
  # predicate must surface this as rc=2 — not silently fall back to a
  # missing date and treat the PR as un-reviewed (which would burn tokens
  # by spawning the reviewer LLM on a transient gh failure).
  local repo
  repo=$(make_repo)
  local prs="$LOOP_ROOT/tests/fixtures/gh/prs-current.json"
  local tmpbin="$BATS_TEST_TMPDIR/bin-graphqlfail"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr list") cat '$prs'; exit 0 ;;
  "api graphql") exit 1 ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" review
  [ "$status" -eq 2 ]
  [ "$output" = "?" ]
}

# ---------------------------------------------------------------------------
# Source-of-truth: regression guard against re-introducing the GraphQL
# 500k-node bloat.
#
# Pre-GH#26 the predicate ran `gh pr list ... --json number,commits,reviews`,
# which the GraphQL planner expanded to ~1M nodes (commits × reviews × 100
# PRs × neighbouring connections) and the gateway rejected outright. The fix
# replaced `commits` with `headRefOid` and resolves committedDate per oid via
# a separate `gh api graphql` call. These greps assert the function body
# still consumes the narrower shape.
# ---------------------------------------------------------------------------

@test "eligibility_review_pending: --json field set excludes 'commits' (GH#26 regression guard)" {
  awk '/^eligibility_review_pending\(\)/,/^}/' "$LOOP_ROOT/runners/lib/eligibility.sh" > "$BATS_TEST_TMPDIR/fn.sh"
  # Must request headRefOid (the new shape).
  grep -qF -- '--json number,headRefOid,reviews' "$BATS_TEST_TMPDIR/fn.sh"
  # Must NOT request commits (the bloating field).
  ! grep -qF -- '--json number,commits' "$BATS_TEST_TMPDIR/fn.sh"
  ! grep -qE -- '--json[[:space:]]*[A-Za-z,]*commits' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "eligibility_review_pending: resolves committedDate via gh api graphql (GH#26)" {
  awk '/^eligibility_review_pending\(\)/,/^}/' "$LOOP_ROOT/runners/lib/eligibility.sh" > "$BATS_TEST_TMPDIR/fn.sh"
  # The narrowed-fetch fix resolves committedDate per oid via gh api graphql.
  grep -qF 'gh api graphql' "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF 'committedDate' "$BATS_TEST_TMPDIR/fn.sh"
}

# ---------------------------------------------------------------------------
# Source-of-truth: regression guard for the GH#46 CI gate.
# Without this check, a future refactor could silently revert the predicate
# to review-only filtering and reintroduce the per-cycle orchestrator-LLM
# leak during in-flight CI windows. The greps assert that the function
# requests the statusCheckRollup field AND filters on the running states.
# ---------------------------------------------------------------------------
@test "eligibility_review_pending: --json field set requests statusCheckRollup (GH#46)" {
  awk '/^eligibility_review_pending\(\)/,/^}/' "$LOOP_ROOT/runners/lib/eligibility.sh" > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF 'statusCheckRollup' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "eligibility_review_pending: filter excludes IN_PROGRESS / PENDING / QUEUED (GH#46)" {
  awk '/^eligibility_review_pending\(\)/,/^}/' "$LOOP_ROOT/runners/lib/eligibility.sh" > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF 'IN_PROGRESS' "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF 'PENDING' "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF 'QUEUED' "$BATS_TEST_TMPDIR/fn.sh"
  # Both shapes must be normalized — gh's statusCheckRollup carries .status
  # for CheckRun and .state for legacy StatusContext.
  grep -qE '\.status[[:space:]]*//[[:space:]]*\.state' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "reviewer-orchestrator.md: in-prompt CI gate references the predicate (GH#46)" {
  # The orchestrator template must note that the in-prompt CI gate is now
  # also enforced by the eligibility predicate (defense-in-depth for direct
  # claude -p invocations that bypass the wrapper).
  grep -qF 'eligibility_review_pending' "$LOOP_ROOT/templates/reviewer-orchestrator.md"
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
# GH#49: hard-failure marker recognition. When `claude` exits non-zero in
# Mode 2 (max-turns, API outage, OOM) the LLM never reaches its graceful
# `🤖 Developer agent — follow-up <complete|gave-up|no-action>` comment,
# so the latest dev-comment timestamp doesn't advance past the review's
# submittedAt. The dispatcher then re-fires the LLM every poll cycle.
#
# Fix: the wrapper posts a failure-marker comment after `wait` returns
# non-zero. Because the marker body starts with "🤖 Developer agent"
# (matches DEV_AGENT_COMMENT_PREFIX), the existing `startswith($prefix)`
# filter in eligibility_followup_pr already picks it up — these tests pin
# that contract.
# ---------------------------------------------------------------------------

# Inject a failure-marker comment with the production-shape body, postdating
# the review (the post-hard-failure scenario the dispatcher would re-fire on
# pre-fix).
_with_failure_marker_after_review() {
  jq '.comments = [{
        "author": {"login": "claude"},
        "authorAssociation": "OWNER",
        "body": "🤖 Developer agent — follow-up failed mid-flow (exit=124). The dev-agent did not reach a graceful exit (likely max-turns exceeded, claude API failure, or OOM). The follow-up dispatcher will not re-fire on the current reviewer-agent review.",
        "createdAt": "2026-05-07T13:00:00Z"
      }]' \
    "$LOOP_ROOT/tests/fixtures/gh/pr-followup.json"
}

@test "followup filter: failure-marker comment supersedes review timestamp (re-fire blocked)" {
  # Fixture review is at 2026-05-07T12:00:00Z; failure marker posted at 13:00.
  # Predicate must see the dev-agent comment as newer → skip.
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(_with_failure_marker_after_review \
        | jq -r --arg re "$re" --arg prefix "$prefix" "$FOLLOWUP_FILTER")
  [ "$out" = $'changes\tno' ]
}

@test "followup filter: fresh review after failure marker re-arms dispatch" {
  # Failure marker at 13:00; a NEW reviewer-agent review at 14:00 supersedes
  # it again. Predicate must dispatch — otherwise the gate becomes permanently
  # sticky and human re-review never re-triggers Mode 2.
  local re='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
  local prefix='🤖 Developer agent'
  local out
  out=$(_with_failure_marker_after_review \
        | jq '.reviews += [{
              "author": {"login": "claude"},
              "authorAssociation": "OWNER",
              "body": "[reviewer-agent: changes] still need fixes",
              "submittedAt": "2026-05-07T14:00:00Z"
            }]' \
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

@test "eligibility_followup_pr: failure-marker is the latest dev-comment → exit 1 (GH#49)" {
  # End-to-end version of the "failure-marker supersedes review" filter test.
  # Pre-fix the wrapper exited without posting any comment on hard failure,
  # so latest_devcomment.createdAt stayed older than the review and the
  # predicate kept dispatching the LLM every poll cycle. After the fix the
  # wrapper posts the 🤖-prefixed failure marker, the predicate sees it as
  # the latest dev-agent comment, and the next poll skips.
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/failure-marker-cli.json"
  _with_failure_marker_after_review > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" followup 42
  [ "$status" -eq 1 ]
  [ "$output" = "changes" ]
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

@test "run-developer.sh: trap cleanup is registered BEFORE lock mkdir (GH#36 P1)" {
  # Pre-PR-36 fix the trap was registered ~135 lines after `mkdir LOCK_DIR/gh-…`
  # (review #36 P1). A SIGINT/SIGTERM in that gap leaked the lock until
  # STALE_LOCK_HOURS. The cleanup() function only releases locks tagged with
  # our DEV_AGENT_RUN_ID, so registering early is safe (siblings' locks
  # untouched). Source-of-truth check guards against a future refactor that
  # reopens the leak window.
  local trap_line mkdir_line
  trap_line=$(grep -nE '^trap cleanup' "$LOOP_ROOT/runners/run-developer.sh" | head -1 | cut -d: -f1)
  mkdir_line=$(grep -nE 'mkdir[^|;&]*"\$LOCK_DIR/gh-' "$LOOP_ROOT/runners/run-developer.sh" | head -1 | cut -d: -f1)
  [ -n "$trap_line" ]
  [ -n "$mkdir_line" ]
  [ "$trap_line" -lt "$mkdir_line" ]
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
