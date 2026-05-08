#!/usr/bin/env bats
# Mode-invariant tests for templates/developer.md.
#
# GH#59: Mode 1's worktree-creation block historically did not run
# `git fetch origin` before `git worktree add ... origin/main`. In a long
# `st loop` session the local origin/main ref drifts behind the remote (the
# merger pane uses server-side `gh pr merge`; dispatchers don't fetch), so
# new branches were cut from a stale base. The PR opened MERGEABLE in CI
# but server-side merge then flagged it CONFLICTING after sibling merges
# landed, triggering an avoidable Mode 3 LLM run (~$0.50–$2.00 each).
#
# This file pins the invariant so a regression that drops the fetch from
# any mode (1, 2, or 3) fails CI immediately.

load 'helpers'

setup() {
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
}

# --- Mode-coverage assertion ----------------------------------------------

@test "developer template fetches origin in all three modes (1, 2, 3)" {
  # One fetch per mode: Mode 1 worktree create, Mode 2 F3, Mode 3 R1.
  count=$(grep -cE '^git -C "\$REPO" fetch origin$' "$DEV_TPL")
  [ "$count" -ge 3 ]
}

# --- Per-worktree-add structural check ------------------------------------

@test "every 'git worktree add' in the developer template is preceded by 'git fetch origin' within 10 lines" {
  # For every line that calls `git -C "$REPO" worktree add ...`, the 10 lines
  # immediately preceding it must contain `git -C "$REPO" fetch origin`.
  # Catches a future copy-paste of the worktree block without the fetch.
  fail=0
  while IFS=: read -r lineno _; do
    [ -z "$lineno" ] && continue
    start=$(( lineno - 10 ))
    [ "$start" -lt 1 ] && start=1
    if ! sed -n "${start},$(( lineno - 1 ))p" "$DEV_TPL" \
         | grep -qE '^git -C "\$REPO" fetch origin$'; then
      echo "MISSING fetch before worktree add at $DEV_TPL:$lineno" >&2
      fail=1
    fi
  done < <(grep -nE '^git -C "\$REPO" worktree add' "$DEV_TPL")
  [ "$fail" -eq 0 ]
}

# --- Mode 1 regression guard ---------------------------------------------

@test "Mode 1 worktree block fetches origin before cutting a branch from origin/main" {
  # Locate the exact Mode 1 line that cuts from origin/main, then assert the
  # 10 lines just before it contain a fetch. This is the precise regression
  # the GH#59 fix targets.
  m1_line=$(grep -nE '^git -C "\$REPO" worktree add -b "\$BRANCH" "\$WORKTREE" origin/main' "$DEV_TPL" \
            | head -1 | cut -d: -f1)
  [ -n "$m1_line" ]
  start=$(( m1_line - 10 ))
  [ "$start" -lt 1 ] && start=1
  sed -n "${start},$(( m1_line - 1 ))p" "$DEV_TPL" \
    | grep -qE '^git -C "\$REPO" fetch origin$'
}

# --- Doc rationale check --------------------------------------------------

@test "Mode 1 fetch carries a comment explaining why" {
  # The `fetch origin` line in Mode 1 must carry inline rationale (the cost
  # of dropping it is non-obvious — token amplification through Mode 3).
  # We check that *some* comment line within 6 lines above the Mode 1 fetch
  # mentions origin/main drifting or sibling/Mode 3.
  m1_line=$(grep -nE '^git -C "\$REPO" worktree add -b "\$BRANCH" "\$WORKTREE" origin/main' "$DEV_TPL" \
            | head -1 | cut -d: -f1)
  fetch_line=$(awk -v end="$m1_line" '
    NR < end && /^git -C "\$REPO" fetch origin$/ { last = NR }
    END { print last }
  ' "$DEV_TPL")
  [ -n "$fetch_line" ] && [ "$fetch_line" -gt 0 ]
  start=$(( fetch_line - 6 ))
  [ "$start" -lt 1 ] && start=1
  sed -n "${start},$(( fetch_line - 1 ))p" "$DEV_TPL" \
    | grep -qiE 'stale|drift|sibling|mode 3|merger'
}

# --- Worktree-path-for-reads guidance (GH#70) -----------------------------

@test "Mode 1 worktree section tells the agent to use the worktree path for reads/edits/writes" {
  # GH#70: The harness keys "have I read this?" by absolute path string.
  # If the agent explores via canonical repo paths and then edits worktree
  # paths, the first edit per file errors with "File has not been read yet"
  # and forces a redundant Read. The Mode 1 worktree block must explicitly
  # tell the agent that all subsequent file ops use the worktree path.
  m1_line=$(grep -nE '^git -C "\$REPO" worktree add -b "\$BRANCH" "\$WORKTREE" origin/main' "$DEV_TPL" \
            | head -1 | cut -d: -f1)
  [ -n "$m1_line" ]
  # Find the next "### Step 2" heading after the Mode 1 worktree add.
  step2_line=$(awk -v start="$m1_line" 'NR > start && /^### Step 2/ { print NR; exit }' "$DEV_TPL")
  [ -n "$step2_line" ]
  block=$(sed -n "${m1_line},${step2_line}p" "$DEV_TPL")
  echo "$block" | grep -qiE 'worktree path' \
    || { echo "Mode 1 worktree block missing 'worktree path' mention" >&2; false; }
  echo "$block" | grep -qiE '\b(read|edit|write)' \
    || { echo "Mode 1 worktree block missing reads/edits/writes mention" >&2; false; }
}
