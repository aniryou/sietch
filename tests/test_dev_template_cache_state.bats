#!/usr/bin/env bats
# bats file_tags=regression
# GH#83: Tell the dev-agent template to trust wrapper-set state and to cache
# the PR body once during Step 7a, instead of re-echoing env vars / re-`ls`ing
# the lock dir / re-fetching a PR body that hasn't changed.
#
# Two recurring waste patterns observed in dev-agent runs:
#   (a) The first ~2 Bash calls of every wrapped run re-verified state the
#       wrapper had just set (`echo $DEV_AGENT_TARGET_ISSUE`, `ls $LOCK_DIR`).
#   (b) During Step 7a's PR-body edit on PR #77, the body was fetched 3× —
#       only the first fetch was needed; the other two should have read the
#       local cached file.
#
# This file pins the template guidance that fixes both patterns so a
# regression that drops either rule fails CI immediately.

load 'helpers'

setup() {
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

# Extract the body of a section heading. Reads from the matched heading
# (exclusive) up to the next `### ` heading (exclusive). Mirrors the helper
# in test_dev_template_tee_test_output.bats.
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

# Extract the "Wrapper pre-lock shortcut" paragraph + its bullet block.
# This block lives between the "## Single-Pass Issue Scan" heading and the
# "The unset-env steps below..." sentence.
wrapper_prelock_block() {
  awk '
    /^\*\*Wrapper pre-lock shortcut\.\*\*/ { capturing = 1 }
    capturing { print }
    capturing && /^The unset-env steps below/ { exit }
  ' "$DEV_TPL"
}

# --- Wrapper pre-lock: forbid re-verification of wrapper-set state -----------

@test "wrapper pre-lock block forbids re-echoing DEV_AGENT_* env vars" {
  body=$(wrapper_prelock_block)
  [ -n "$body" ]
  echo "$body" | grep -qiE 'do.*not.*echo.*\$?DEV_AGENT_|not.*echo.*env' \
    || { echo "wrapper pre-lock block missing 'do not echo DEV_AGENT_* env vars' rule" >&2; false; }
}

@test "wrapper pre-lock block forbids re-listing or re-reading the lock dir" {
  body=$(wrapper_prelock_block)
  [ -n "$body" ]
  echo "$body" | grep -qiE '\bls\b.*LOCK|cat.*LOCK|cat.*run_id|not.*ls.*lock|not.*cat.*lock' \
    || { echo "wrapper pre-lock block missing 'do not ls/cat the lock dir' rule" >&2; false; }
}

@test "wrapper pre-lock block cites the wrapper kickoff message" {
  body=$(wrapper_prelock_block)
  [ -n "$body" ]
  # The exact string the wrapper prints (run-developer.sh:247). Pinning a
  # substring keeps doc and code in sync without depending on the full line.
  echo "$body" | grep -qE '\[wrapper\] eligibility: locked GH#' \
    || { echo "wrapper pre-lock block missing the kickoff message it cites" >&2; false; }
}

@test "wrapper kickoff message in template matches what run-developer.sh prints" {
  # Defense against drift: the template references the kickoff message text;
  # if someone edits run-developer.sh's wording, this test fails so the
  # template is updated in the same PR.
  grep -qE '^[[:space:]]*echo "\[wrapper\] eligibility: locked GH#' \
    "$LOOP_ROOT/runners/run-developer.sh" \
    || { echo "run-developer.sh no longer prints the kickoff message the template cites" >&2; false; }
}

@test "wrapper pre-lock block ends with the 'unset-env steps' sentinel the awk loop expects" {
  # Defense against drift: wrapper_prelock_block() terminates on the literal
  # "^The unset-env steps below" sentence. If a future template edit reworded
  # that sentence, the awk loop would run to EOF and assertions in this file
  # would start matching against unrelated content. Pin the anchor here.
  grep -qE '^The unset-env steps below' "$DEV_TPL" \
    || { echo "template no longer contains the 'The unset-env steps below' sentinel that wrapper_prelock_block() relies on" >&2; false; }
}

# --- Step 7a: reuse Step 5's local PR-body file, never re-fetch --------------
# PR #84 already established that Step 5 writes /tmp/pr-body-<num>.md and
# Step 7a edits that same file in place — i.e. zero PR-body fetches per
# cycle. These tests pin that rule so a future edit can't regress to the
# fetch-then-edit flow.

@test "Step 7a reuses the /tmp/pr-body-<num>.md file Step 5 wrote (no re-fetch)" {
  body=$(section_body '^### Step 7a')
  [ -n "$body" ]
  echo "$body" | grep -qE '/tmp/pr-body-<num>\.md' \
    || { echo "Step 7a missing the '/tmp/pr-body-<num>.md' path that Step 5 wrote" >&2; false; }
  echo "$body" | grep -qiE 'same file Step 5 wrote|step 5 wrote it|from Step 5' \
    || { echo "Step 7a missing the 'reuse Step 5's file' instruction" >&2; false; }
}

@test "Step 7a forbids re-fetching the PR body via gh pr view --json body" {
  body=$(section_body '^### Step 7a')
  [ -n "$body" ]
  # The acceptance criterion from issue #83: gh pr view --json body must be
  # invoked AT MOST ONCE per Step 7a cycle. Main's wording achieves this more
  # strongly (zero fetches), so the rule we pin is "never re-fetch".
  echo "$body" | grep -qiE 'never re-?fetch|do not re-?fetch' \
    || { echo "Step 7a missing 'never re-fetch the body' rule" >&2; false; }
  # And the rule must specifically name 'gh pr view ... --json body' so the
  # prohibition is unambiguous against future paraphrases.
  echo "$body" | grep -qE 'gh pr view.*--json[[:space:]]+body' \
    || { echo "Step 7a missing the literal 'gh pr view ... --json body' prohibition" >&2; false; }
}

@test "Step 7a instructs pushing the body with one gh pr edit --body-file call" {
  body=$(section_body '^### Step 7a')
  [ -n "$body" ]
  echo "$body" | grep -qE 'gh pr edit.*--body-file' \
    || { echo "Step 7a missing 'gh pr edit ... --body-file' push instruction" >&2; false; }
}

@test "Step 7a forbids more than one gh pr edit --body-file per cycle" {
  body=$(section_body '^### Step 7a')
  [ -n "$body" ]
  # The "more than once" / "at most once" / "never ... more than once"
  # phrasing is what makes this an explicit rule, not a soft suggestion.
  echo "$body" | grep -qiE 'more than once|at most once|never.*more than once' \
    || { echo "Step 7a missing 'at most once per cycle' enforcement" >&2; false; }
}
