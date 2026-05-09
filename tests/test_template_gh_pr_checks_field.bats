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
#
# GH#117: the reviewer-orchestrator.md template was deleted; the per-PR
# `gh pr checks` invocation now lives in templates/reviewer.md (Step 1).

load 'helpers'

setup() {
  REVIEWER_TPL="$LOOP_ROOT/templates/reviewer.md"
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

# --- reviewer.md --------------------------------------------------------

@test "reviewer template uses 'gh pr checks' (per-PR sanity check)" {
  grep -qE 'gh pr checks' "$REVIEWER_TPL"
}

@test "reviewer template does not pass the unknown 'conclusion' field to gh pr checks" {
  # The bad form would re-introduce GH#71. Match on the literal field list
  # so a deliberate mention in commentary (e.g. "not conclusion") is still
  # allowed if the actual command uses bucket.
  ! grep -qE 'gh pr checks[^`]*--json state,conclusion' "$REVIEWER_TPL"
}

# --- developer.md -------------------------------------------------------

@test "developer template uses 'gh pr checks ... --json state,bucket' in the CI poll fallback" {
  grep -qE 'gh pr checks[^`]*--json state,bucket' "$DEV_TPL"
}

@test "developer template does not pass the unknown 'conclusion' field to gh pr checks" {
  ! grep -qE 'gh pr checks[^`]*--json state,conclusion' "$DEV_TPL"
}
