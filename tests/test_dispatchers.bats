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
  grep -qF '_dispatch_followup_jq'  "$LOOP_ROOT/runners/run-loop.sh"
  grep -qF '_dispatch_conflicts_jq' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qF '_dispatch_merge_jq'     "$LOOP_ROOT/runners/run-loop.sh"
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
