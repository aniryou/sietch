#!/usr/bin/env bats
# GH#82: Trim long inline PR bodies and unused flag bloat from dev-agent.
#
# Three guidance shifts in templates/developer.md, each tied to a per-run
# token waste pattern observed in dev-agent logs:
#
# 1. Step 5 must compose the PR body via a file and pass it with
#    `--body-file`, never inline `--body "$(cat <<EOF...)"`. Inline heredocs
#    bloat the assistant's tool-call message by ~3000 chars per run.
# 2. Step 1 must point the agent at `$WORKTREE` (the wrapper exports it)
#    instead of re-typing the literal path 60+ times per run.
# 3. `gh ... --json` calls must request only the fields needed in the next
#    few steps. Pulling 6 fields when only 1 is read leaves 700+ chars of
#    unused output in context for every subsequent turn.
#
# These checks pin the template guidance so a regression that drops any of
# the three rules fails CI immediately.

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

# --- Step 5: PR body composed via --body-file --------------------------------

@test "Step 5 uses gh pr create --body-file (not an inline heredoc)" {
  body=$(section_body '^### Step 5')
  [ -n "$body" ]
  echo "$body" | grep -qE 'gh pr create.*--body-file' \
    || { echo "Step 5 missing 'gh pr create ... --body-file'" >&2; false; }
}

@test "Step 5 does NOT inline the PR body via --body \"\$(cat <<EOF...)\"" {
  body=$(section_body '^### Step 5')
  [ -n "$body" ]
  # The `gh pr create ... \\\n --body "$(cat <<EOF` anti-pattern spans lines,
  # so check independently: no `--body "$(` literal anywhere in Step 5.
  # `--body-file /path` is fine — the regex below only matches the inline form.
  if echo "$body" | grep -qE -- '--body "\$\('; then
    echo "Step 5 still inlines PR body via --body \"\$(...)\" form" >&2
    false
  fi
}

@test "Step 5 names a /tmp PR-body file the agent should write" {
  body=$(section_body '^### Step 5')
  [ -n "$body" ]
  # The flow is: Write the markdown body to /tmp/pr-body-<num>.md, then
  # `gh pr create --body-file /tmp/pr-body-<num>.md`. Same file is reused
  # by Step 7a's edit dance.
  echo "$body" | grep -qE '/tmp/pr-body' \
    || { echo "Step 5 missing /tmp/pr-body* filename" >&2; false; }
}

@test "Step 7a edits the PR body via --body-file (consistent with Step 5)" {
  body=$(section_body '^### Step 7a')
  [ -n "$body" ]
  echo "$body" | grep -qE 'gh pr edit.*--body-file' \
    || { echo "Step 7a still uses --body \"\$NEW_BODY\" instead of --body-file" >&2; false; }
}

# --- Mode 1 Step 1: $WORKTREE reuse ------------------------------------------

@test "Mode 1 Step 1 mentions the wrapper exports WORKTREE" {
  body=$(section_body '^### Step 1 — Create a git worktree')
  [ -n "$body" ]
  echo "$body" | grep -qiE 'wrapper.*export[s]?.*WORKTREE|export[s]?.*WORKTREE.*wrapper' \
    || { echo "Step 1 missing 'wrapper exports WORKTREE' note" >&2; false; }
}

@test "Mode 1 Step 1 tells the agent to use \$WORKTREE everywhere instead of the literal" {
  body=$(section_body '^### Step 1 — Create a git worktree')
  [ -n "$body" ]
  # Either explicit "use $WORKTREE" guidance or "do not re-type the literal" guidance.
  echo "$body" | grep -qE '\$WORKTREE' \
    || { echo "Step 1 never mentions \$WORKTREE" >&2; false; }
  echo "$body" | grep -qiE 'never re-type|do not re-type|never retype|do not retype|instead of.*literal' \
    || { echo "Step 1 missing 'do not re-type the literal' guidance" >&2; false; }
}

# --- --json field discipline -------------------------------------------------

@test "wrapper-pre-lock gh issue view uses ≤ 3 --json fields" {
  # The 'Read the issue body via gh issue view ...' line in the wrapper-pre-lock
  # shortcut paragraph. Pre-#82 it was 4 fields; post-fix it's ≤ 3.
  line=$(grep -n 'Read the issue body via.*gh issue view' "$DEV_TPL" | head -1 | cut -d: -f1)
  [ -n "$line" ] || { echo "wrapper-pre-lock 'Read the issue body' line missing" >&2; false; }
  json_args=$(sed -n "${line}p" "$DEV_TPL" | grep -oE -- '--json [a-zA-Z,]+' | head -1 | sed 's/--json //')
  [ -n "$json_args" ]
  field_count=$(echo "$json_args" | tr ',' '\n' | wc -l | tr -d ' ')
  [ "$field_count" -le 3 ] \
    || { echo "wrapper-pre-lock --json has $field_count fields ($json_args); expected ≤ 3" >&2; false; }
}

@test "Mode 1 Step 1 (full-scan fallback) gh issue list uses ≤ 3 --json fields" {
  # `gh issue list ... --json ...` typically spans two lines via a `\`
  # continuation in the template. Join continuations first so the grep
  # below sees the full command on a single line.
  joined=$(awk '/\\$/ { sub(/\\$/, ""); buf = buf $0; next } { print buf $0; buf = "" }' "$DEV_TPL")
  fail=0
  while IFS= read -r json_args; do
    [ -z "$json_args" ] && continue
    field_count=$(echo "$json_args" | tr ',' '\n' | wc -l | tr -d ' ')
    if [ "$field_count" -gt 3 ]; then
      echo "gh issue list --json has $field_count fields ($json_args); expected ≤ 3" >&2
      fail=1
    fi
  done < <(echo "$joined" | grep -E 'gh issue list .*--json' | grep -oE -- '--json [a-zA-Z,]+' | sed 's/--json //')
  [ "$fail" -eq 0 ]
}

@test "Mode 2 F0 first gh pr view uses ≤ 2 --json fields" {
  body=$(section_body '^### Step F0')
  [ -n "$body" ]
  # The first gh pr view in F0 must be tight: pre-#82 it was 6 fields, the
  # fix shrinks it to body (or body+headRefName).
  json_args=$(echo "$body" | grep -m1 'gh pr view.*--json' | grep -oE -- '--json [a-zA-Z,]+' | sed 's/--json //')
  [ -n "$json_args" ]
  field_count=$(echo "$json_args" | tr ',' '\n' | wc -l | tr -d ' ')
  [ "$field_count" -le 2 ] \
    || { echo "Mode 2 F0 first gh pr view --json has $field_count fields ($json_args); expected ≤ 2" >&2; false; }
}

@test "developer template documents --json field-discipline rule" {
  # Prose somewhere in the template teaches the rule. We tolerate a few
  # phrasings: "field discipline", "fields you'll use", "only the fields", etc.
  grep -qiE 'field[- ]discipline' "$DEV_TPL" \
    || grep -qiE 'fields you'\''ll use' "$DEV_TPL" \
    || grep -qiE '\-\-json.*only the fields' "$DEV_TPL" \
    || { echo "Template missing --json field-discipline guidance" >&2; false; }
}
