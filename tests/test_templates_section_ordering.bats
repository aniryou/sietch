#!/usr/bin/env bats
# GH#47: section-ordering invariants for the user-facing templates.
#
# The plain-English/TL;DR contract requires `## TL;DR` to appear before the
# next major section in both templates: before `## Problem` in
# templates/issue-author.md and before `## Changes` in templates/developer.md.
# Pure regex presence/absence rules (TL;DR present, Summary absent, etc.)
# live in the template-rule registry — see tests/test_template_rule_registry.bats
# and tests/lib/template_rules.bash. The ordering checks below need
# line-number arithmetic across two grep results, which the registry's
# `require | forbid | count_max | require_all` kinds don't model, so they
# stay as a small standalone bats file.

load 'helpers'

setup() {
  ISSUE_TPL="$LOOP_ROOT/templates/issue-author.md"
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

@test "issue-author template puts ## TL;DR before ## Problem" {
  tldr_line=$(grep -n '^## TL;DR$' "$ISSUE_TPL" | head -1 | cut -d: -f1)
  problem_line=$(grep -n '^## Problem$' "$ISSUE_TPL" | head -1 | cut -d: -f1)
  [ -n "$tldr_line" ]
  [ -n "$problem_line" ]
  [ "$tldr_line" -lt "$problem_line" ]
}

@test "developer template ## TL;DR appears before ## Changes in the PR body block" {
  tldr_line=$(grep -n '^## TL;DR$' "$DEV_TPL" | head -1 | cut -d: -f1)
  changes_line=$(grep -n '^## Changes$' "$DEV_TPL" | head -1 | cut -d: -f1)
  [ -n "$tldr_line" ]
  [ -n "$changes_line" ]
  [ "$tldr_line" -lt "$changes_line" ]
}
