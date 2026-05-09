#!/usr/bin/env bats
# Registry-driven template-rule guards.
#
# Each @test below dispatches to one rule in tests/lib/template_rules.bash by
# name. Adding a new rule:
#   1. Append a `rule ...` line to tests/lib/template_rules.bash (one line).
#   2. Append a `@test "[<rule name>]" { run_rule_registry_check "<rule name>"; }`
#      line below (one line; bats 1.x does not allow runtime-dynamic @test
#      generation, so the wrapper is mechanical).
# The substantive rule definition (kind, pattern, file) lives in the registry;
# the wrapper here just gives bats a discoverable @test block whose
# description carries the rule name into the failure output.

load 'helpers'
load 'lib/template_rules'

# GH#67: bd dep direction in agent templates.
@test "[GH#67: bd dep direction (parent first) — developer.md]" {
  run_rule_registry_check "GH#67: bd dep direction (parent first) — developer.md"
}
@test "[GH#67: no reversed bd dep form — developer.md]" {
  run_rule_registry_check "GH#67: no reversed bd dep form — developer.md"
}
@test "[GH#67: bd dep direction (parent first) — reviewer.md]" {
  run_rule_registry_check "GH#67: bd dep direction (parent first) — reviewer.md"
}
@test "[GH#67: no reversed bd dep form — reviewer.md]" {
  run_rule_registry_check "GH#67: no reversed bd dep form — reviewer.md"
}

# GH#71: gh pr checks --json field in agent templates.
# GH#117: reviewer-orchestrator.md was removed; the per-PR sanity check
# now lives in templates/reviewer.md.
@test "[GH#71: gh pr checks (per-PR sanity check) — reviewer.md]" {
  run_rule_registry_check "GH#71: gh pr checks (per-PR sanity check) — reviewer.md"
}
@test "[GH#71: no conclusion field on gh pr checks — reviewer.md]" {
  run_rule_registry_check "GH#71: no conclusion field on gh pr checks — reviewer.md"
}
@test "[GH#71: gh pr checks --json state,bucket — developer.md]" {
  run_rule_registry_check "GH#71: gh pr checks --json state,bucket — developer.md"
}
@test "[GH#71: no conclusion field on gh pr checks — developer.md]" {
  run_rule_registry_check "GH#71: no conclusion field on gh pr checks — developer.md"
}
