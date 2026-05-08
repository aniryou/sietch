#!/usr/bin/env bats
# GH#80: Cut redundant `cd $WORKTREE && `, `PAGER=cat GIT_PAGER=cat `, and
# `--repo aniryou/loop` prefixes from dev-agent commands.
#
# The Claude Code Bash tool persists CWD across tool calls, the wrapper
# already exports PAGER/GIT_PAGER into claude's env, and `gh` reads GH_REPO
# natively. Across two recent dev-agent runs ~50 Bash calls per run carried
# ~70 chars of pure-boilerplate prefix that wasn't doing useful work
# (~3.5K chars / ~1K tokens per run). The fix is two-part:
#
#   1. runners/run-developer.sh exports `GH_REPO="$REPO_SLUG"` so `gh`
#      commands in the agent's tool calls don't need `--repo …`.
#   2. templates/developer.md tells the agent in Step 1 that CWD persists
#      across Bash calls (don't re-prepend `cd $WORKTREE && …`) and that
#      PAGER/GIT_PAGER/GH_REPO are already in its env (don't re-prepend
#      `PAGER=cat GIT_PAGER=cat ` or pass `--repo …`).
#
# These tests pin both halves so a regression that drops either fails CI.

load 'helpers'

setup() {
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
  DEV_WRAP="$LOOP_ROOT/runners/run-developer.sh"
}

# --- Wrapper export ----------------------------------------------------------

@test "run-developer.sh exports GH_REPO from REPO_SLUG before invoking claude" {
  # The wrapper must export GH_REPO so `gh` in the agent's env reads it as
  # the implicit repo. Anywhere before the `claude -p` invocation works,
  # but it must be `export` (not just an inline-env on `claude`) so child
  # processes spawned through the agent's Bash tool inherit it.
  grep -qE '^[[:space:]]*export[[:space:]]+GH_REPO=' "$DEV_WRAP" \
    || { echo "run-developer.sh missing 'export GH_REPO=…'" >&2; false; }
  # And it must derive from REPO_SLUG (not a hard-coded slug — multi-repo
  # support, GH#74 + onboard.sh, depends on this being driven from
  # loop.config).
  grep -qE '^[[:space:]]*export[[:space:]]+GH_REPO="\$\{?REPO_SLUG\}?"' "$DEV_WRAP" \
    || { echo "run-developer.sh GH_REPO export must read \$REPO_SLUG, not a literal slug" >&2; false; }
}

@test "run-developer.sh GH_REPO export precedes the claude -p invocation" {
  # Order matters: an export that lands AFTER `claude -p` exits won't help
  # the agent. Find the first GH_REPO export line and the first `claude -p`
  # line; the export must come first.
  export_line=$(grep -nE '^[[:space:]]*export[[:space:]]+GH_REPO=' "$DEV_WRAP" \
                | head -1 | cut -d: -f1)
  claude_line=$(grep -nE '^[[:space:]]*claude[[:space:]]+-p' "$DEV_WRAP" \
                | head -1 | cut -d: -f1)
  [ -n "$export_line" ]
  [ -n "$claude_line" ]
  [ "$export_line" -lt "$claude_line" ] \
    || { echo "GH_REPO export at line $export_line is AFTER claude -p at line $claude_line" >&2; false; }
}

# --- Template guidance: don't re-prepend `cd $WORKTREE && …` -----------------

# Extract the body of a section heading. Mirrors the helper in
# test_dev_template_tee_test_output.bats.
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

@test "Mode 1 Step 1 tells the agent CWD persists across Bash calls (don't re-cd)" {
  body=$(section_body '^### Step 1 — Create a git worktree')
  [ -n "$body" ]
  # The rule must mention that CWD persists or that `cd` should run once.
  echo "$body" | grep -qiE 'persist.*(cwd|working directory|directory)|cwd.*persist|working directory.*persist|once.*stay|cd.*once' \
    || { echo "Step 1 missing 'CWD persists / cd once' guidance" >&2; false; }
  # And it must explicitly forbid re-prepending `cd $WORKTREE && …`.
  echo "$body" | grep -qE 'cd[[:space:]]+(\\)?"?\$WORKTREE"?[[:space:]]*(\\)?&&' \
    || { echo "Step 1 missing the literal 'cd \$WORKTREE && …' anti-pattern" >&2; false; }
}

# --- Template guidance: trust inherited env (no PAGER, GH_REPO, --repo) ------

@test "Mode 1 Step 1 tells the agent PAGER/GIT_PAGER are already in its env" {
  body=$(section_body '^### Step 1 — Create a git worktree')
  [ -n "$body" ]
  echo "$body" | grep -qE 'PAGER=cat[[:space:]]+GIT_PAGER=cat' \
    || { echo "Step 1 missing the 'PAGER=cat GIT_PAGER=cat' anti-pattern" >&2; false; }
  echo "$body" | grep -qiE 'inherit|already in.*env|already set|in your env|wrapper.*invokes' \
    || { echo "Step 1 missing rationale that PAGER vars are inherited" >&2; false; }
}

@test "Mode 1 Step 1 tells the agent GH_REPO replaces --repo on gh calls" {
  body=$(section_body '^### Step 1 — Create a git worktree')
  [ -n "$body" ]
  echo "$body" | grep -qE 'GH_REPO' \
    || { echo "Step 1 missing 'GH_REPO' mention" >&2; false; }
  # The rule must explicitly forbid passing `--repo` on gh commands.
  echo "$body" | grep -qE -- '--repo' \
    || { echo "Step 1 missing the '--repo' anti-pattern" >&2; false; }
}

# --- Template sweep: no in-template `gh … --repo …` examples -----------------
#
# The "trust inherited env" rule must not be contradicted by the template's
# own `gh` example commands. Across Modes 1/2/3 the agent will mirror what
# the template shows; if examples still pass `--repo …`, the agent re-emits
# the prefix and blows the GH#80 acceptance criteria.
#
# Test 36 is the load-bearing assertion: no `gh … --repo` invocation
# anywhere in the template. Test 35 is a thin sanity check that the rule
# call-out still exists (≥ 1 narrative `--repo` mention); we deliberately
# don't pin the count to exactly 1, because a future legitimate addition
# (e.g., a bullet "the wrapper's own `gh ... --repo` calls in `runners/`")
# is not a regression. Test 36 catches the only thing that actually harms
# agent runs.

@test "templates/developer.md: rule call-out for --repo still present" {
  count=$(grep -cE -- '--repo' "$DEV_TPL")
  [ "$count" -ge 1 ] \
    || { echo "Expected ≥ 1 '--repo' mention (the Step 1 rule call-out); found $count" >&2; false; }
}

@test "templates/developer.md: no gh examples pass --repo (would contradict the rule)" {
  # Match `gh <subcommand> … --repo …` invocations anywhere in the template,
  # whether at line-start or inside a `$(...)` command substitution. The
  # Step 1 rule mentions `--repo` in narrative prose with `gh` wrapped in
  # backticks (`gh\``), so the `gh[[:space:]]+[a-z]+` segment doesn't match
  # the rule call-out itself.
  if grep -nE 'gh[[:space:]]+[a-z]+[^|]*--repo' "$DEV_TPL"; then
    echo "Found in-template 'gh … --repo …' example(s) above. The rule at line ~210 says the agent should not pass --repo; examples must match." >&2
    false
  fi
}

# --- Template sweep: legitimate `cd "$WORKTREE"` only at worktree creation ---
#
# The CWD-persistence rule says exactly one cd per worktree creation. There
# are three creation points: Mode 1 Step 1, Mode 2 F3, Mode 3 R1. Any extra
# `cd "$WORKTREE"` line in the template is a redundant prefix — the same
# pattern the agent would mirror.

@test "templates/developer.md: at most 3 'cd \"\$WORKTREE\"' lines (one per mode worktree creation)" {
  # Count lines that ARE the cd command (not narrative prose mentioning it).
  # The narrative mentions it inside backticks (`cd "$WORKTREE"`) on the
  # same line as other text; those don't match `^[[:space:]]*cd "...`.
  count=$(grep -cE '^[[:space:]]*cd[[:space:]]+"\$WORKTREE"[[:space:]]*$' "$DEV_TPL")
  [ "$count" -le 3 ] \
    || { echo "Expected ≤ 3 standalone 'cd \"\$WORKTREE\"' lines (one per worktree creation: Mode 1 Step 1, Mode 2 F3, Mode 3 R1); found $count" >&2; false; }
}
