#!/usr/bin/env bats
# Templates expose user-facing artifacts (issue and PR titles, issue and PR
# bodies). GH#47 requires they be plain-English readable: titles ≤70 chars
# with no opaque insider acronyms, and bodies must lead with a `## TL;DR`
# section so a maintainer or contributor scanning the issue/PR list can grasp
# the work without insider context.
#
# This test pins the structural contract so we don't silently regress.

load 'helpers'

setup() {
  ISSUE_TPL="$LOOP_ROOT/templates/issue-author.md"
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

# --- templates/issue-author.md --------------------------------------------

@test "issue-author template body has a ## TL;DR section" {
  run grep -cE '^## TL;DR$' "$ISSUE_TPL"
  [ "$status" -eq 0 ]
  # Exactly one normative ## TL;DR header in the template.
  [ "$output" -ge 1 ]
}

@test "issue-author template puts ## TL;DR before ## Problem" {
  tldr_line=$(grep -n '^## TL;DR$' "$ISSUE_TPL" | head -1 | cut -d: -f1)
  problem_line=$(grep -n '^## Problem$' "$ISSUE_TPL" | head -1 | cut -d: -f1)
  [ -n "$tldr_line" ]
  [ -n "$problem_line" ]
  [ "$tldr_line" -lt "$problem_line" ]
}

@test "issue-author style requirements include a title-style rule" {
  # Title-style guidance: a length cap plus a plain-English requirement.
  grep -qE '70 ?char' "$ISSUE_TPL"
  grep -qiE 'plain[- ]english|plain english' "$ISSUE_TPL"
}

@test "issue-author template warns against opaque acronyms in titles" {
  # We keep this loose — the rule must be stated, but the wording can vary.
  grep -qiE 'acronym|jargon|insider' "$ISSUE_TPL"
}

@test "issue-author template references checking the title in the draft preview" {
  # Step 8 shows the draft to the user; after GH#47 it must surface the
  # proposed title for plain-English review, not just the body.
  grep -qiE 'title.*(plain|reads|review)' "$ISSUE_TPL"
}

@test "issue-author template has Title and TL;DR examples" {
  grep -qiE 'Title and TL;DR examples|Title.*TL;DR' "$ISSUE_TPL"
}

# --- templates/developer.md ----------------------------------------------

@test "developer template PR body has a ## TL;DR section" {
  run grep -cE '^## TL;DR$' "$DEV_TPL"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "developer template PR body has a ## Changes section" {
  run grep -cE '^## Changes$' "$DEV_TPL"
  [ "$status" -eq 0 ]
  [ "$output" -ge 1 ]
}

@test "developer template PR body no longer leads with a ## Summary section" {
  # GH#47 reshaped ## Summary into ## TL;DR + ## Changes. The literal
  # `## Summary` heading must not survive in the PR body template.
  run grep -cE '^## Summary$' "$DEV_TPL"
  [ "$status" -ne 0 ] || [ "$output" -eq 0 ]
}

@test "developer template ## TL;DR appears before ## Changes in the PR body block" {
  tldr_line=$(grep -n '^## TL;DR$' "$DEV_TPL" | head -1 | cut -d: -f1)
  changes_line=$(grep -n '^## Changes$' "$DEV_TPL" | head -1 | cut -d: -f1)
  [ -n "$tldr_line" ]
  [ -n "$changes_line" ]
  [ "$tldr_line" -lt "$changes_line" ]
}

@test "developer template PR title still uses the Fix GH# prefix" {
  # Plain-English rules apply, but the traceability prefix stays.
  grep -qF 'Fix GH#' "$DEV_TPL"
}

@test "developer template states plain-English title rules" {
  # Mirrored from the issue-author template — both must require it.
  grep -qiE 'plain[- ]english|plain english' "$DEV_TPL"
  grep -qE '70 ?char' "$DEV_TPL"
}

@test "developer template Step 7a CI checkbox still anchors on ## Test plan" {
  # Acceptance criterion: the body restructure must not break the CI flip,
  # which keys off the `## Test plan` heading.
  grep -qE '^## Test plan$' "$DEV_TPL"
}
