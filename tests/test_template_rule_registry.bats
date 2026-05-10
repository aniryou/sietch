#!/usr/bin/env bats
# GENERATED — do not edit by hand.
# Regenerate with: tests/lib/gen_template_rule_tests.sh
# Source of truth: tests/lib/template_rules.bash
#
# Rule definitions (kind, pattern, file) live in the registry. This file is
# the bats-discoverable surface — one @test block per registry entry, each
# delegating to run_rule_registry_check by name. Adding a rule is one line:
# append `rule …` to the registry and run the generator (or trust CI's
# tests/test_template_rule_registry_sync.bats to flag the drift).

load 'helpers'
load 'lib/template_rules'

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
@test "[GH#80: --repo rule call-out present — developer.md]" {
  run_rule_registry_check "GH#80: --repo rule call-out present — developer.md"
}
@test "[GH#80: no in-template gh examples pass --repo — developer.md]" {
  run_rule_registry_check "GH#80: no in-template gh examples pass --repo — developer.md"
}
@test "[GH#80: cd \"\$WORKTREE\" lines capped at 3 (one per worktree creation) — developer.md]" {
  run_rule_registry_check "GH#80: cd \"\$WORKTREE\" lines capped at 3 (one per worktree creation) — developer.md"
}
@test "[GH#47: ## TL;DR section present — issue-author.md]" {
  run_rule_registry_check "GH#47: ## TL;DR section present — issue-author.md"
}
@test "[GH#47: title-style rule (70-char + plain-English) — issue-author.md]" {
  run_rule_registry_check "GH#47: title-style rule (70-char + plain-English) — issue-author.md"
}
@test "[GH#47: title warns against opaque acronyms — issue-author.md]" {
  run_rule_registry_check "GH#47: title warns against opaque acronyms — issue-author.md"
}
@test "[GH#47: draft preview surfaces the title for plain-English review — issue-author.md]" {
  run_rule_registry_check "GH#47: draft preview surfaces the title for plain-English review — issue-author.md"
}
@test "[GH#47: Title and TL;DR examples section present — issue-author.md]" {
  run_rule_registry_check "GH#47: Title and TL;DR examples section present — issue-author.md"
}
@test "[GH#47: ## TL;DR section present in PR body — developer.md]" {
  run_rule_registry_check "GH#47: ## TL;DR section present in PR body — developer.md"
}
@test "[GH#47: ## Changes section present in PR body — developer.md]" {
  run_rule_registry_check "GH#47: ## Changes section present in PR body — developer.md"
}
@test "[GH#47: PR body no longer leads with ## Summary — developer.md]" {
  run_rule_registry_check "GH#47: PR body no longer leads with ## Summary — developer.md"
}
@test "[GH#47: PR title still uses the Fix GH# prefix — developer.md]" {
  run_rule_registry_check "GH#47: PR title still uses the Fix GH# prefix — developer.md"
}
@test "[GH#47: PR title plain-English rules (70-char + plain-English) — developer.md]" {
  run_rule_registry_check "GH#47: PR title plain-English rules (70-char + plain-English) — developer.md"
}
@test "[GH#47: ## Test plan heading anchors Step 7a CI flip — developer.md]" {
  run_rule_registry_check "GH#47: ## Test plan heading anchors Step 7a CI flip — developer.md"
}
@test "[GH#133: no body-tag OR fallback (sanity check) — reviewer.md]" {
  run_rule_registry_check "GH#133: no body-tag OR fallback (sanity check) — reviewer.md"
}
@test "[GH#133: no body-tag OR fallback (Hard Rules parenthetical) — reviewer.md]" {
  run_rule_registry_check "GH#133: no body-tag OR fallback (Hard Rules parenthetical) — reviewer.md"
}
@test "[GH#135: no phantom 'beads memory tag' claim mechanism — developer.md]" {
  run_rule_registry_check "GH#135: no phantom 'beads memory tag' claim mechanism — developer.md"
}
@test "[GH#137: Prefer Write over Edit opener — developer.md]" {
  run_rule_registry_check "GH#137: Prefer Write over Edit opener — developer.md"
}
@test "[GH#137: Write-over-Edit trigger condition — developer.md]" {
  run_rule_registry_check "GH#137: Write-over-Edit trigger condition — developer.md"
}
@test "[GH#137: Write-over-Edit cache-cost rationale — developer.md]" {
  run_rule_registry_check "GH#137: Write-over-Edit cache-cost rationale — developer.md"
}
