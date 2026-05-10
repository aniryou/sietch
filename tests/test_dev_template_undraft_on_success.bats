#!/usr/bin/env bats
# bats file_tags=regression
# GH#88: Stop leaving PRs stuck as draft after follow-up cycle resolves them.
#
# Six dev-agent paths call `gh pr ready --undo` (drafting). Pre-#88, zero
# paths called `gh pr ready` (un-drafting). The asymmetry strands PRs that
# recover after being drafted — see PR #81 for the canonical trace (drafted
# by triage-untractable, follow-up cycle 1 fixed the reviewer's findings,
# CI green and MERGEABLE, but the PR sat as `isDraft: true` because no
# success path ever called `gh pr ready`).
#
# This file pins three new un-draft guards, one per success path:
# Mode 1 Step 7a, Mode 2 Step F8, Mode 3 Step R10. Each must:
#   - read isDraft + mergeable from `gh pr view`
#   - call `gh pr ready "$PR"` (no --undo) when
#     isDraft == true && mergeable == MERGEABLE
#   - skip on CONFLICTING (original conflict still present — drafting is
#     correct) and UNKNOWN (GitHub still recomputing — leave alone).
#
# A separate guard pins the `gh pr ready --undo` call-site count so a
# future edit can't accidentally convert a failure path's draft into a
# success-path un-draft.

load 'helpers'

setup() {
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

# Same helper as test_dev_template_token_trim.bats: scope grep checks to a
# single step body, from the matched heading (exclusive) up to the next
# `### ` heading (exclusive).
section_body() {
  local heading_pattern="$1"
  local start
  start=$(grep -nE "$heading_pattern" "$DEV_TPL" | head -1 | cut -d: -f1)
  [ -n "$start" ] || return 1
  awk -v start="$start" '
    NR == start { capturing = 1; next }
    capturing && /^### / { exit }
    capturing { print }
  ' "$DEV_TPL"
}

# Assert the section contains: a `gh pr ready "$PR"` call (no --undo),
# an `isDraft` reference, and a `mergeable` reference. The proximity is
# implicit: the helper reads from the section heading until the next `###`,
# which scopes everything to a single step body.
assert_undraft_block() {
  local section_pat="$1"
  local body
  body=$(section_body "$section_pat")
  [ -n "$body" ] || { echo "section '$section_pat' not found" >&2; false; }

  echo "$body" | grep -qE 'gh pr ready "\$PR"' \
    || { echo "section '$section_pat' missing 'gh pr ready \"\$PR\"' (un-draft)" >&2; false; }

  echo "$body" | grep -q 'isDraft' \
    || { echo "section '$section_pat' missing isDraft check" >&2; false; }

  echo "$body" | grep -q 'mergeable' \
    || { echo "section '$section_pat' missing mergeable check" >&2; false; }
}

# --- One un-draft block per success path -----------------------------------

@test "Mode 1 Step 7a contains the un-draft block" {
  assert_undraft_block '^### Step 7a'
}

@test "Mode 2 Step F8 contains the un-draft block" {
  assert_undraft_block '^### Step F8'
}

@test "Mode 3 Step R10 contains the un-draft block" {
  assert_undraft_block '^### Step R10'
}

# --- Failure-path regression guard -----------------------------------------

@test "no regression in 'gh pr ready --undo' failure-path call sites" {
  # Pre-#88 the template has 5 `gh pr ready --undo` lines (1 prose bullet
  # in Step 7b-give-up describing the action + 4 actual commands across
  # the give-up + Mode 3 abort paths). If a future edit converts a failure
  # path to a non-undo pr-ready call, this guard fires.
  count=$(grep -cE 'gh pr ready --undo' "$DEV_TPL")
  [ "$count" -ge 5 ] \
    || { echo "expected ≥ 5 'gh pr ready --undo' references; got $count" >&2; false; }
}

# --- MERGEABLE / CONFLICTING / UNKNOWN guard prose -------------------------

@test "template documents skipping CONFLICTING and UNKNOWN mergeable states" {
  # The fix must not blindly un-draft. CONFLICTING means the original
  # conflict is still there (drafting is still correct); UNKNOWN means
  # GitHub is mid-recompute (leave alone rather than race). A future
  # simplification that drops these states from the guard fails this test.
  grep -qE 'CONFLICTING' "$DEV_TPL" \
    || { echo "template never mentions CONFLICTING (mergeable guard)" >&2; false; }
  grep -qE 'UNKNOWN' "$DEV_TPL" \
    || { echo "template never mentions UNKNOWN (mergeable guard)" >&2; false; }
}

# --- Total un-draft hit count ---------------------------------------------

@test "at least 3 un-draft (gh pr ready \"\$PR\") call sites in template" {
  count=$(grep -cE 'gh pr ready "\$PR"' "$DEV_TPL")
  [ "$count" -ge 3 ] \
    || { echo "expected ≥ 3 'gh pr ready \"\$PR\"' un-draft sites; got $count" >&2; false; }
}
