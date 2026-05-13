#!/usr/bin/env bats
# dispatcher.sh — exercise the jq filters that drive loop_dispatcher_followup
# and loop_dispatcher_conflicts in run-loop.sh.
#
# The dispatchers pipe `gh pr list --json ...` through these filters via
# `gh --jq`. Tests source the same helpers and run them against fixture PR
# lists with plain jq. Mirrors the test_eligibility.bats pattern.

load 'helpers'

setup() {
  # shellcheck source=/dev/null
  . "$LOOP_ROOT/runners/lib/dispatcher.sh"
}

# ---------------------------------------------------------------------------
# follow-up dispatcher: dev-agent/* PRs that are not draft
# ---------------------------------------------------------------------------

@test "followup filter: keeps non-draft dev-agent PRs, drops drafts and non-dev-agent" {
  local filter nums
  filter=$(_dispatch_followup_jq "dev-agent")
  nums=$(jq -r "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch.json" | tr '\n' ' ')
  # Fixture: 11 (ok), 12 (draft → out), 13 (ok — conflicting still gets follow-up
  # consideration; mergeable is irrelevant for this filter), 14 (draft → out),
  # 15 (non-dev-agent → out), 16 (non-dev-agent → out). Expect 11, 13.
  [ "$nums" = "11 13 " ]
}

@test "followup filter: empty input emits nothing" {
  local filter nums
  filter=$(_dispatch_followup_jq "dev-agent")
  nums=$(jq -r "$filter" <<<'[]')
  [ -z "$nums" ]
}

@test "followup filter: respects custom branch prefix" {
  local filter nums
  filter=$(_dispatch_followup_jq "feature")
  nums=$(jq -r "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch.json" | tr '\n' ' ')
  # With prefix=feature: 15 (non-draft), 16 (non-draft) match.
  [ "$nums" = "15 16 " ]
}

# ---------------------------------------------------------------------------
# conflict dispatcher: dev-agent/* PRs that are CONFLICTING and not draft
# ---------------------------------------------------------------------------

@test "conflicts filter: keeps only non-draft CONFLICTING dev-agent PRs" {
  local filter nums
  filter=$(_dispatch_conflicts_jq "dev-agent")
  nums=$(jq -r "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch.json" | tr '\n' ' ')
  # Fixture: only 13 is dev-agent/* AND non-draft AND CONFLICTING.
  [ "$nums" = "13 " ]
}

@test "conflicts filter: drops drafts even when conflicting" {
  local filter
  filter=$(_dispatch_conflicts_jq "dev-agent")
  ! jq -e "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch.json" 2>/dev/null \
    | grep -qx '14'
}

@test "conflicts filter: drafted CONFLICTING dev-agent PR is excluded (Mode 3 abort regression guard)" {
  # Precondition for GH#44 fix: when Mode 3 aborts and drafts the PR, the
  # conflicts dispatcher must not re-fire the LLM on it. This guards the
  # `isDraft == false` clause in _dispatch_conflicts_jq from regressing.
  local filter nums
  filter=$(_dispatch_conflicts_jq "dev-agent")
  nums=$(jq -r "$filter" <<<'[{"number":1,"headRefName":"dev-agent/gh-1-x","mergeable":"CONFLICTING","isDraft":true}]')
  [ -z "$nums" ]
  nums=$(jq -r "$filter" <<<'[{"number":1,"headRefName":"dev-agent/gh-1-x","mergeable":"CONFLICTING","isDraft":false}]')
  [ "$nums" = "1" ]
}

@test "conflicts filter: empty input emits nothing" {
  local filter nums
  filter=$(_dispatch_conflicts_jq "dev-agent")
  nums=$(jq -r "$filter" <<<'[]')
  [ -z "$nums" ]
}

# ---------------------------------------------------------------------------
# GH#111: per-PR cap predicate exclusion. After the wrapper escalates a Mode 3
# hard-failure cap, it applies BLOCKED_HUMAN_LABEL to the PR. The conflicts
# dispatcher's predicate must drop those PRs so the loop stops re-firing the
# LLM until a human removes the label. Mirrors the BLOCKED_HUMAN_LABEL pattern
# in eligibility_dev_count and the REVIEWER_ESCALATION_LABEL pattern in
# eligibility_review_pending (GH#94).
# ---------------------------------------------------------------------------

@test "conflicts filter: 2nd-arg label excludes PRs carrying that label (GH#111)" {
  local filter nums
  filter=$(_dispatch_conflicts_jq "dev-agent" "blocked:human")
  # Two CONFLICTING + non-draft dev-agent PRs; one carries the label.
  nums=$(jq -r "$filter" <<<'[
    {"number":1,"headRefName":"dev-agent/gh-1-x","mergeable":"CONFLICTING","isDraft":false,"labels":[{"name":"blocked:human"}]},
    {"number":2,"headRefName":"dev-agent/gh-2-y","mergeable":"CONFLICTING","isDraft":false,"labels":[{"name":"enhancement"}]}
  ]' | tr '\n' ' ')
  [ "$nums" = "2 " ]
}

@test "conflicts filter: 2nd-arg label empty disables filter (backward-compat)" {
  # Tests / older callers can omit the label arg and get the original behavior.
  local filter nums
  filter=$(_dispatch_conflicts_jq "dev-agent" "")
  nums=$(jq -r "$filter" <<<'[
    {"number":1,"headRefName":"dev-agent/gh-1-x","mergeable":"CONFLICTING","isDraft":false,"labels":[{"name":"blocked:human"}]}
  ]' | tr '\n' ' ')
  [ "$nums" = "1 " ]
}

@test "conflicts filter: missing labels field on a PR defaults to INCLUDED (GH#111)" {
  # Defensive: PRs returned by gh that don't carry a labels field (or it's
  # null) must fall through to "no escalation label" and stay eligible.
  local filter nums
  filter=$(_dispatch_conflicts_jq "dev-agent" "blocked:human")
  nums=$(jq -r "$filter" <<<'[
    {"number":1,"headRefName":"dev-agent/gh-1-x","mergeable":"CONFLICTING","isDraft":false}
  ]' | tr '\n' ' ')
  [ "$nums" = "1 " ]
}

@test "run-loop.sh: conflicts dispatcher --json field set includes labels (GH#111)" {
  # Without `labels` in the field set the predicate's exclusion filter never
  # sees the label and the cap-escalation has no effect at the dispatcher.
  awk '/^loop_dispatcher_conflicts\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qE -- '--json[[:space:]]+[A-Za-z,]*labels' "$BATS_TEST_TMPDIR/fn.sh"
}

@test "run-loop.sh: conflicts dispatcher passes BLOCKED_HUMAN_LABEL to _dispatch_conflicts_jq (GH#111)" {
  awk '/^loop_dispatcher_conflicts\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    > "$BATS_TEST_TMPDIR/fn.sh"
  grep -qF 'BLOCKED_HUMAN_LABEL' "$BATS_TEST_TMPDIR/fn.sh"
}

# ---------------------------------------------------------------------------
# merger dispatcher: dev-agent/* PRs that are not draft (verdict + CI gating
# happens later, in eligibility_merge_pr — this filter is just the candidate
# scan, mirroring _dispatch_followup_jq).
# ---------------------------------------------------------------------------

@test "merge filter: keeps non-draft dev-agent PRs, drops drafts and non-dev-agent" {
  local filter nums
  filter=$(_dispatch_merge_jq "dev-agent")
  nums=$(jq -r "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch.json" | tr '\n' ' ')
  # Same set as the followup filter — verdict / CI / staleness gating is the
  # job of eligibility_merge_pr, not this candidate scan.
  [ "$nums" = "11 13 " ]
}

@test "merge filter: empty input emits nothing" {
  local filter nums
  filter=$(_dispatch_merge_jq "dev-agent")
  nums=$(jq -r "$filter" <<<'[]')
  [ -z "$nums" ]
}

@test "merge filter: respects custom branch prefix" {
  local filter nums
  filter=$(_dispatch_merge_jq "feature")
  nums=$(jq -r "$filter" < "$LOOP_ROOT/tests/fixtures/gh/prs-dispatch.json" | tr '\n' ' ')
  [ "$nums" = "15 16 " ]
}

# ---------------------------------------------------------------------------
# Source-of-truth check: run-loop.sh must consume the helpers, not the
# malformed `gh --jq --arg` form that silently dropped every PR.
# ---------------------------------------------------------------------------

@test "run-loop.sh: dispatcher gh-pr-list calls do not use the broken '--jq --arg' form" {
  ! grep -nF -- "--jq --arg" "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: dispatcher gh-pr-list calls invoke the lib helpers" {
  # GH#181: followup and merger now use the `_with_updated` variants so the
  # verdict cache has the `updatedAt` freshness key. The conflicts dispatcher
  # keeps the original `_dispatch_conflicts_jq` — its decision doesn't depend
  # on a per-PR `gh pr view`, so it doesn't benefit from the cache.
  grep -qF '_dispatch_followup_with_updated_jq' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qF '_dispatch_conflicts_jq'             "$LOOP_ROOT/runners/run-loop.sh"
  grep -qF '_dispatch_merge_with_updated_jq'    "$LOOP_ROOT/runners/run-loop.sh"
}

# ---------------------------------------------------------------------------
# Reviewer dispatcher (GH#117): the previous single-pane loop_reviewer was
# replaced by loop_dispatcher_review, which scans candidates from
# eligibility_review_pending_list and fans out per-PR background invocations
# of `run-reviewer.sh <PR>`. These guards pin the wiring.
# ---------------------------------------------------------------------------

@test "run-loop.sh: loop_dispatcher_review exists and consumes review-list (GH#117)" {
  grep -qF 'loop_dispatcher_review()' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qF 'review-list' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: loop_reviewer is removed (GH#117)" {
  ! grep -qF 'loop_reviewer()' "$LOOP_ROOT/runners/run-loop.sh"
  ! grep -qE -- '--internal-role=reviewer\b' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: dispatch:review pane is wired in start_session (GH#117)" {
  grep -qF 'dispatch-review' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qF 'dispatch:review' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: review locks use the *-review.lock suffix (GH#117)" {
  grep -qF 'pr-${pr}-review.lock' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: review cap is independent (REVIEWER_DISPATCH_MAX_CONCURRENT) (GH#117)" {
  grep -qF 'REVIEWER_DISPATCH_MAX_CONCURRENT' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qF 'count_active_review_dispatch_locks' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: count_active_dispatch_locks excludes review locks (GH#117)" {
  # The followup/conflicts shared cap must not count review locks against
  # itself. The skip clause is what enforces the independent budget.
  grep -qE 'count_active_dispatch_locks\(\)' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qE '\*-review\.lock\) continue' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "loop.config.example: documents REVIEWER_DISPATCH_MAX_CONCURRENT (GH#117)" {
  grep -qF 'REVIEWER_DISPATCH_MAX_CONCURRENT' "$LOOP_ROOT/templates/loop.config.example"
}

# ---------------------------------------------------------------------------
# templates/developer.md: every Mode 3 abort path must draft the PR (GH#44).
# Without this, a CONFLICTING + non-draft PR matches the conflicts dispatcher's
# filter on every cycle and keeps re-firing the LLM until a human intervenes.
# Mode 1 give-up (Step 7b-give-up) already drafts; Mode 3's three abort blocks
# now must too.
# ---------------------------------------------------------------------------

@test "templates/developer.md: at least four 'gh pr ready --undo' calls (Mode 1 give-up + 3 Mode 3 aborts)" {
  local count
  count=$(grep -c 'gh pr ready --undo' "$LOOP_ROOT/templates/developer.md")
  # 1 mention in safety-net prose, 1 in Mode 1 give-up shell block, 3 in Mode 3
  # abort shell blocks. The guarantee we care about is "≥ 4" so future edits to
  # the prose don't trip this; the lower bound covers all four shell-call sites.
  [ "$count" -ge 4 ]
}

@test "templates/developer.md: each Mode 3 abort comment is followed by a draft call" {
  # Source-of-truth: catch a future edit that copy-pastes a new abort block
  # without the draft. Walk every '🤖 Mode 3 ... aborted' comment and check
  # that 'gh pr ready --undo' appears within the next 30 lines.
  local md="$LOOP_ROOT/templates/developer.md"
  while IFS=: read -r lineno _; do
    [ -z "$lineno" ] && continue
    local end=$((lineno + 30))
    local window
    window=$(sed -n "${lineno},${end}p" "$md")
    if ! grep -qF 'gh pr ready --undo' <<<"$window"; then
      echo "Mode 3 abort comment at line $lineno is missing 'gh pr ready --undo' within 30 lines" >&2
      return 1
    fi
  done < <(grep -nF '🤖 Mode 3 conflict resolution — aborted' "$md")
}
