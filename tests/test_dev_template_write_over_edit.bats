#!/usr/bin/env bats
# GH#137: Tell the dev-agent to prefer one Write over many Edits when
# rewriting most of a large file.
#
# Several recent dev-agent sessions made 8–34 sequential `Edit` calls to
# one big runner or template file (worst case: 34 Edits to
# `templates/developer.md` in a single session). Each Edit re-pulls the
# file's surrounding turn context, so 8–34 small Edits on a 30 KB file
# silently burn several million cache-read tokens before the suite even
# runs. Drafting the full target once and `Write`-ing it would cut both
# the turn count and the cache burn.
#
# This file pins the new template guidance so a regression that drops
# the rule fails CI immediately. The rule belongs in the same "minimise
# context bloat" cluster as the existing tee / pre-commit / body-file
# rules.

load 'helpers'

setup() {
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

@test "developer template tells the agent to prefer one Write over many Edits" {
  # The exact-bold opener is the single anchoring phrase the issue
  # acceptance criteria requires.
  grep -qE 'Prefer one `Write` over many `Edit`s' "$DEV_TPL" \
    || { echo "templates/developer.md missing 'Prefer one \`Write\` over many \`Edit\`s' guidance" >&2; false; }
}

@test "developer template names the trigger condition (>5 regions, >300 lines)" {
  # The trigger has to be specific so the agent can decide. A vague
  # "when the file is big" rule would not change behaviour.
  grep -qE 'more than ~5 regions' "$DEV_TPL" \
    || { echo "templates/developer.md missing 'more than ~5 regions' trigger" >&2; false; }
  grep -qE '>300 lines' "$DEV_TPL" \
    || { echo "templates/developer.md missing '>300 lines' trigger" >&2; false; }
}

@test "Write-over-Edit rule cites the cache-cost reason" {
  # The rationale must reference the cache-read cost so the agent can
  # generalise it to other large files (runners, templates, scripts),
  # not just the example.
  grep -qiE 'cache[- ]read|cache.*token|re-?pulls.*context' "$DEV_TPL" \
    || { echo "templates/developer.md missing cache-cost rationale for Write-over-Edit rule" >&2; false; }
}

@test "Write-over-Edit rule lives in the body-file cluster, not at the bottom of the file" {
  # The acceptance criteria requires the rule to appear in the same
  # cluster as the existing test-output / body-file rules, not in a
  # standalone section at the bottom. Anchor it relative to the existing
  # body-file paragraph (line ~258) and make sure it precedes the Hard
  # Rules section by a comfortable margin.
  rule_line=$(grep -nE 'Prefer one `Write` over many `Edit`s' "$DEV_TPL" | head -1 | cut -d: -f1)
  body_file_line=$(grep -nE 'Compose the body in a file' "$DEV_TPL" | head -1 | cut -d: -f1)
  hard_rules_line=$(grep -nE '^## Hard Rules' "$DEV_TPL" | head -1 | cut -d: -f1)
  [ -n "$rule_line" ] && [ -n "$body_file_line" ] && [ -n "$hard_rules_line" ]
  # Within ~10 lines of the body-file paragraph it's clustering with.
  delta=$(( rule_line - body_file_line ))
  [ "$delta" -ge 0 ] && [ "$delta" -le 10 ] \
    || { echo "Write-over-Edit rule at line $rule_line is not in the body-file cluster (line $body_file_line); delta=$delta" >&2; false; }
  # And clearly not at the bottom (well before Hard Rules).
  [ "$rule_line" -lt "$hard_rules_line" ] \
    || { echo "Write-over-Edit rule appears after the Hard Rules section" >&2; false; }
}
