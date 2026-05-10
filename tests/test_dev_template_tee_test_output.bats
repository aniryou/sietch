#!/usr/bin/env bats
# bats file_tags=regression
# GH#78: Tell the dev-agent to save test output once with `tee` and re-grep
# the saved file, not re-invoke the test runner to slice the same output
# differently.
#
# Across two recent dev-agent runs the agent invoked the full test suite 9
# times (4 + 5) but only 2 of those re-invocations followed an actual code
# edit — the other 7 were back-to-back runs against unchanged code, varying
# only in how the output was sliced. Each `bats tests/` run is ~349 lines
# and ~2–4K tokens; the redundant invocations cost ~20K tokens and several
# minutes per session.
#
# This file pins the template guidance so a regression that drops the
# `tee` rule from any test-running step (Mode 1 Step 3, Mode 2 F5, Mode 3
# R5) — or from the pre-commit step — fails CI immediately.

load 'helpers'

setup() {
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

# Extract the body of a section heading. Reads from the matched heading
# (exclusive) up to the next `### ` heading (exclusive). Used to scope
# grep checks to a single step instead of the whole file.
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

# --- Mode 1 Step 3: implementation step --------------------------------------

@test "Mode 1 Step 3 instructs piping test output through tee to a saved file" {
  body=$(section_body '^### Step 3 — Implement the functionality')
  [ -n "$body" ]
  echo "$body" | grep -qiE '\btee\b' \
    || { echo "Step 3 missing 'tee' guidance" >&2; false; }
  echo "$body" | grep -qiE 'saved file|saved output|the file|temp file|tee.*\.txt' \
    || { echo "Step 3 missing 'inspect the saved file' guidance" >&2; false; }
}

@test "Mode 1 Step 3 says re-invoke the test runner only when code changed" {
  body=$(section_body '^### Step 3 — Implement the functionality')
  [ -n "$body" ]
  # The rule must distinguish "after a code change" (legitimate) from
  # "to ask a different question of the same output" (waste).
  echo "$body" | grep -qiE 're-?invoke|re-?run' \
    || { echo "Step 3 missing re-invocation rule" >&2; false; }
  echo "$body" | grep -qiE 'edit(ed)?|chang(e|ed)|after.*code' \
    || { echo "Step 3 missing 'only after a code change' caveat" >&2; false; }
}

@test "Mode 1 Step 3 forbids chaining multiple test runs in one Bash call" {
  body=$(section_body '^### Step 3 — Implement the functionality')
  [ -n "$body" ]
  echo "$body" | grep -qiE 'never.*chain|do not chain|no.*chain.*bash|single.*bash.*call' \
    || { echo "Step 3 missing 'never chain runs in one Bash call' rule" >&2; false; }
}

# --- Mode 2 Step F5: follow-up tests step ------------------------------------

@test "Mode 2 Step F5 instructs piping test output through tee to a saved file" {
  body=$(section_body '^### Step F5')
  [ -n "$body" ]
  echo "$body" | grep -qiE '\btee\b' \
    || { echo "Step F5 missing 'tee' guidance" >&2; false; }
}

@test "Mode 2 Step F5 says inspect the saved file instead of re-running" {
  body=$(section_body '^### Step F5')
  [ -n "$body" ]
  echo "$body" | grep -qiE 're-?invoke|re-?run|grep.*saved|cat.*saved|grep.*file|cat.*file' \
    || { echo "Step F5 missing re-grep guidance" >&2; false; }
}

# --- Mode 3 Step R5: post-resolution test step -------------------------------

@test "Mode 3 Step R5 instructs piping test output through tee to a saved file" {
  body=$(section_body '^### Step R5')
  [ -n "$body" ]
  echo "$body" | grep -qiE '\btee\b' \
    || { echo "Step R5 missing 'tee' guidance" >&2; false; }
}

@test "Mode 3 Step R5 says inspect the saved file instead of re-running" {
  body=$(section_body '^### Step R5')
  [ -n "$body" ]
  echo "$body" | grep -qiE 're-?invoke|re-?run|grep.*saved|cat.*saved|grep.*file|cat.*file' \
    || { echo "Step R5 missing re-grep guidance" >&2; false; }
}

# --- Pre-commit step: same caching rule --------------------------------------

@test "Step 4 (commit / pre-commit) carries a parallel save-once rule for pre-commit" {
  body=$(section_body '^### Step 4')
  [ -n "$body" ]
  # Same shape as the test rule: tee the output, grep the saved file, only
  # re-run after fixing the offender.
  echo "$body" | grep -qiE '\btee\b' \
    || { echo "Step 4 missing 'tee' guidance for pre-commit" >&2; false; }
  echo "$body" | grep -qiE 're-?invoke|re-?run' \
    || { echo "Step 4 missing pre-commit re-invocation rule" >&2; false; }
}

# --- File-level smoke check --------------------------------------------------

@test "developer template tee guidance appears in all three modes (1, 2, 3)" {
  # Spot-check: at least three `tee` references in the template overall —
  # one each for Mode 1 Step 3, Mode 2 F5, Mode 3 R5. Step 4's pre-commit
  # tee is a fourth, so the lower bound is 3 (allows future minor edits).
  count=$(grep -cE '\btee\b' "$DEV_TPL")
  [ "$count" -ge 3 ]
}
