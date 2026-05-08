#!/usr/bin/env bats
# Pins the `gh pr checks --json <field>` invocation in agent templates.
#
# GH#71: Two templates instructed agents to call
# `gh pr checks <num> --json state,conclusion`, but `gh pr checks` does not
# expose `conclusion` — the valid CI-state field is `bucket`
# (pass/fail/pending/skipping/cancel). The bad call errored, and when it ran
# alongside parallel `gh` calls the harness cancelled the whole batch,
# costing ~3 tool calls per attempt before agents recovered with `bucket`.
#
# This test pins the correct field so a future template edit can't silently
# regress to the GH-API-style `conclusion` (used by `pr view`/`pr status`,
# but not by `pr checks`).

load 'helpers'

setup() {
  ORCH_TPL="$LOOP_ROOT/templates/reviewer-orchestrator.md"
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

# --- reviewer-orchestrator.md -------------------------------------------

@test "reviewer-orchestrator template uses 'gh pr checks ... --json state,bucket'" {
  grep -qE 'gh pr checks[^`]*--json state,bucket' "$ORCH_TPL"
}

@test "reviewer-orchestrator template does not pass the unknown 'conclusion' field to gh pr checks" {
  # The bad form would re-introduce GH#71. Match on the literal field list
  # so a deliberate mention in commentary (e.g. "not conclusion") is still
  # allowed if the actual command uses bucket.
  ! grep -qE 'gh pr checks[^`]*--json state,conclusion' "$ORCH_TPL"
}

# --- developer.md -------------------------------------------------------

@test "developer template uses 'gh pr checks ... --json state,bucket' in the CI poll fallback" {
  grep -qE 'gh pr checks[^`]*--json state,bucket' "$DEV_TPL"
}

@test "developer template does not pass the unknown 'conclusion' field to gh pr checks" {
  ! grep -qE 'gh pr checks[^`]*--json state,conclusion' "$DEV_TPL"
}
