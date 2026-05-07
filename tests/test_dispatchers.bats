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

@test "conflicts filter: empty input emits nothing" {
  local filter nums
  filter=$(_dispatch_conflicts_jq "dev-agent")
  nums=$(jq -r "$filter" <<<'[]')
  [ -z "$nums" ]
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
}
