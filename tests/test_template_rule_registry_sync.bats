#!/usr/bin/env bats
# bats file_tags=regression
# GH#120: ensure tests/test_template_rule_registry.bats is in sync with the
# registry. The .bats file is generated from tests/lib/template_rules.bash
# by tests/lib/gen_template_rule_tests.sh; this guard catches the case where
# someone appends a `rule …` line to the registry without regenerating.

load 'helpers'

GEN="$LOOP_ROOT/tests/lib/gen_template_rule_tests.sh"
GENERATED="$LOOP_ROOT/tests/test_template_rule_registry.bats"

@test "GH#120: generator script exists and is executable" {
  [ -f "$GEN" ]
  [ -x "$GEN" ]
}

@test "GH#120: tests/test_template_rule_registry.bats matches generator output" {
  local actual="$BATS_TEST_TMPDIR/regenerated.bats"
  run "$GEN" "$actual"
  [ "$status" -eq 0 ]
  if ! diff -u "$GENERATED" "$actual"; then
    echo "tests/test_template_rule_registry.bats is out of sync with the registry." >&2
    echo "Regenerate with: tests/lib/gen_template_rule_tests.sh" >&2
    return 1
  fi
}

@test "GH#120: generator emits one @test block per registry entry" {
  local actual="$BATS_TEST_TMPDIR/regenerated.bats"
  "$GEN" "$actual"

  # Count `rule ` invocations in the registry (one per rule). Match only at
  # the start of a line so the function definition (`rule()`) and the doc
  # block don't get counted.
  local rule_count
  rule_count=$(grep -cE '^rule[[:space:]]' "$LOOP_ROOT/tests/lib/template_rules.bash")

  # Count @test blocks in the generated file.
  local test_count
  test_count=$(grep -cE '^@test[[:space:]]' "$actual")

  [ "$rule_count" -gt 0 ]
  [ "$rule_count" = "$test_count" ]
}
