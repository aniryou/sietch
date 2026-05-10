#!/usr/bin/env bats
# GH#147 — `--interactive` flag for `st dev` (Modes 1/2/3).
#
# `st dev` runs unattended by default: the wrapper invokes
# `claude -p "$KICKOFF" --output-format stream-json | tee | jq | tee` and
# pipes the result through several gates (eligibility predicate, lock
# acquisition, Mode 3 triage) that short-circuit the LLM when their
# preconditions aren't met. These gates are correct for dispatcher loops
# but block a human who wants to drive the same wired-up prompt
# interactively — most painfully on Mode 3 PRs that triage rejects.
#
# `--interactive` skips all gates, drops `-p` + the pipe, and `exec`s
# claude with the kickoff already sent. These tests pin both halves:
#   - arg parsing accepts `--interactive` from any position
#   - wrapper does NOT call the eligibility predicate, lock dirs, triage,
#     or post-LLM blocks
#   - wrapper does NOT write *.log / *.jsonl files
#   - any pre-existing worktree survives the run regardless of exit code
#
# To make the tests scriptable around an interactive `claude`, we PATH-
# stub `claude` to `exec`-print its argv + env and exit 0. The wrapper
# uses `exec claude ...`, so that stub replaces the bash process and the
# wrapper's post-LLM blocks naturally don't run — that's the contract
# we're pinning, no extra plumbing needed.

load 'helpers'

# Build a fake LOOP_HOME that:
#   - symlinks real runners/lib/* and templates/* (so render-prompt.sh
#     and the developer.md template resolve correctly)
#   - overrides runners/run-conflict-triage.sh and runners/lib/eligibility.sh
#     with stubs that always exit 1 (to prove the gate is bypassed under
#     --interactive: any exit-1 from the real predicates would short-
#     circuit the wrapper without invoking claude in the headless path).
_make_interactive_loop_home() {
  local fake="$BATS_TEST_TMPDIR/loop-home"
  rm -rf "$fake"
  mkdir -p "$fake/runners/lib" "$fake/templates"
  for f in "$LOOP_ROOT"/runners/*.sh; do
    [ -f "$f" ] || continue
    ln -sf "$f" "$fake/runners/$(basename "$f")"
  done
  for f in "$LOOP_ROOT"/runners/lib/*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$fake/runners/lib/$(basename "$f")"
  done
  for f in "$LOOP_ROOT"/templates/*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$fake/templates/$(basename "$f")"
  done

  # Eligibility stub: always rc=1 (no eligible work). If the wrapper
  # honors --interactive correctly it never calls this, but in the
  # headless path it would short-circuit and exit 2.
  rm -f "$fake/runners/lib/eligibility.sh"
  cat >"$fake/runners/lib/eligibility.sh" <<'STUB'
#!/usr/bin/env bash
# eligibility-stub: always reports "no work" so the wrapper would
# short-circuit in the headless path. --interactive must skip this.
echo "[eligibility-stub] called with: $*" >&2
exit 1
STUB
  chmod +x "$fake/runners/lib/eligibility.sh"

  # Triage stub: always rc=1 (untractable) with a test-file conflict
  # reason. In the headless path the wrapper would draft the PR + post
  # an "auto-resolution declined" comment and exit 1. --interactive must
  # skip this entirely.
  rm -f "$fake/runners/run-conflict-triage.sh"
  cat >"$fake/runners/run-conflict-triage.sh" <<'STUB'
#!/usr/bin/env bash
echo "[triage-stub] result=untractable reason=test-file-conflict:tests/foo.py"
exit 1
STUB
  chmod +x "$fake/runners/run-conflict-triage.sh"

  echo "$fake"
}

# claude stub: dump argv (the kickoff prompt + render-prompt.sh output)
# and env vars (DEV_AGENT_TARGET_ISSUE / WORKTREE / GH_REPO) to files
# under $BATS_TEST_TMPDIR/state/. Records the cwd too so we can confirm
# the wrapper `cd`'d before exec.
_make_path_stubs() {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"
  cat >"$tmpbin/claude" <<STUB
#!/usr/bin/env bash
{
  printf 'argv: '
  for a in "\$@"; do printf '%s\n' "\$a"; done
} >'$state/claude-argv'
{
  printf 'INTERACTIVE=%s\n' "\${INTERACTIVE:-<unset>}"
  printf 'DEV_AGENT_TARGET_ISSUE=%s\n' "\${DEV_AGENT_TARGET_ISSUE:-<unset>}"
  printf 'WORKTREE=%s\n' "\${WORKTREE:-<unset>}"
  printf 'GH_REPO=%s\n' "\${GH_REPO:-<unset>}"
  printf 'PWD=%s\n' "\$PWD"
} >'$state/claude-env'
touch '$state/claude-was-called'
exit 0
STUB
  chmod +x "$tmpbin/claude"
  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
{
  printf 'CALL: '
  printf '%s ' "\$@"
  printf '\n'
} >>'$state/gh-args'
exit 0
STUB
  chmod +x "$tmpbin/gh"
}

# ---------------------------------------------------------------------------
# Arg parsing — `--interactive` accepted from any position; rejection of
# malformed Mode 1 invocations (no issue#, non-numeric).
# ---------------------------------------------------------------------------

@test "arg parse: --interactive without issue# → exit 2 with usage error" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" --interactive

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  echo "$output" | grep -qE 'requires.*<issue#>|interactive.*issue'
}

@test "arg parse: --interactive with non-numeric issue# → exit 2" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" --interactive abc

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
}

@test "arg parse: --interactive 39 (Mode 1) → claude invoked, DEV_AGENT_TARGET_ISSUE=39" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" --interactive 39

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  grep -qF 'DEV_AGENT_TARGET_ISSUE=39' "$BATS_TEST_TMPDIR/state/claude-env"
  # WORKTREE_BASE in make_repo is $BATS_TEST_TMPDIR/wb-$$ → gh-39 under it.
  grep -qE "WORKTREE=.+/wb-[0-9]+/gh-39$" "$BATS_TEST_TMPDIR/state/claude-env"
  # The kickoff string for Mode 1 must be present in the claude argv —
  # this proves the prompt was passed through without -p, just as a
  # positional first-arg.
  grep -qF 'Begin the single-pass scan now' "$BATS_TEST_TMPDIR/state/claude-argv"
}

@test "arg parse: follow-up 31 --interactive (flag after PR#) → MODE=follow-up, TARGET_PR=31" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" follow-up 31 --interactive

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  # Mode 2 doesn't set DEV_AGENT_TARGET_ISSUE — the prompt derives ISSUE_NUM
  # from the PR body. Just confirm the kickoff carries the FOLLOW-UP MODE marker.
  grep -qF 'FOLLOW-UP MODE on PR #31' "$BATS_TEST_TMPDIR/state/claude-argv"
}

@test "arg parse: follow-up --interactive 31 (flag before PR#) → also accepted" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" follow-up --interactive 31

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  grep -qF 'FOLLOW-UP MODE on PR #31' "$BATS_TEST_TMPDIR/state/claude-argv"
}

@test "arg parse: resolve 27 --interactive (alias for resolve-conflicts) → MODE=resolve-conflicts" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve 27 --interactive

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  grep -qF 'MODE 3 (resolve merge conflicts) on PR #27' "$BATS_TEST_TMPDIR/state/claude-argv"
}

@test "arg parse: resolve-conflicts 27 --interactive (canonical mode keyword) → MODE=resolve-conflicts" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 27 --interactive

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  grep -qF 'MODE 3 (resolve merge conflicts) on PR #27' "$BATS_TEST_TMPDIR/state/claude-argv"
}

# ---------------------------------------------------------------------------
# Gate skipping — eligibility predicate (Mode 1) and triage (Mode 3) must
# NOT short-circuit the LLM under --interactive, even though their stubs
# would short-circuit in the headless path.
# ---------------------------------------------------------------------------

@test "Mode 1 --interactive: eligibility-stub rc=1 is bypassed → claude still invoked" {
  # The eligibility-stub always exits 1 (no work). In the headless path
  # the wrapper would log 'no eligible issues' and exit 2 without
  # invoking claude. --interactive must skip the predicate entirely.
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" --interactive 39

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  # The predicate must not have run — the stub would have written to
  # stderr, but more reliably: the headless 'no eligible issues' log
  # line must not appear.
  ! echo "$output" | grep -qF 'no eligible issues'
}

@test "Mode 1 --interactive: lock dir is NOT created (no lock acquired)" {
  # The wrapper's lock acquisition path mkdir's
  # ${LOCK_DIR}/${LOCK_NAME_PREFIX}gh-N.lock. Under --interactive that
  # whole block must be skipped — confirm by absence of the dir after
  # the run. Default LOCK_DIR per loop.config.example template is
  # ${WORKTREE_BASE}/locks, which make_repo points at $BATS_TEST_TMPDIR.
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" --interactive 39

  [ "$status" -eq 0 ]
  # The locks/ dir is created lazily by mkdir -p just before lock
  # acquisition; if it exists at all, the lock arm ran.
  [ ! -d "$BATS_TEST_TMPDIR/wb-$$/locks/test-repo-gh-39.lock" ]
}

@test "Mode 3 --interactive: triage-stub rc=1 (test-file conflict) is bypassed → no draft, no comment, claude invoked" {
  # The triage-stub always exits 1 with reason=test-file-conflict.
  # In the headless path the wrapper would: post a 'auto-resolution
  # declined' gh comment, draft the PR with `gh pr ready --undo`, and
  # exit 1. --interactive must skip ALL of those side effects and
  # proceed to invoke claude.
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve 27 --interactive

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
  # The triage gate's two side effects (gh pr ready --undo + gh pr
  # comment with the auto-resolution-declined body) must NOT have fired.
  if [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]; then
    ! grep -qF 'pr ready --undo 27' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'pr comment 27' "$BATS_TEST_TMPDIR/state/gh-args"
    ! grep -qF 'auto-resolution declined' "$BATS_TEST_TMPDIR/state/gh-args"
  fi
}

# ---------------------------------------------------------------------------
# Side effects under --interactive: no log/jsonl files written; pre-
# existing worktree survives.
# ---------------------------------------------------------------------------

@test "Mode 1 --interactive: writes no *.log or *.jsonl files in LOOP_LOG_DIR" {
  # The headless tee|jq|tee pipeline writes dev-agent-*.log and
  # dev-agent-*.jsonl under LOOP_LOG_DIR. --interactive replaces the
  # pipeline with an exec, so neither file gets created.
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  # LOOP_LOG_DIR is set by helpers.bash to BATS_FILE_TMPDIR. Snapshot
  # the contents before/after to detect any new dev-agent-* files
  # written during this run.
  local logs_before
  logs_before=$(find "$LOOP_LOG_DIR" -maxdepth 1 -name 'dev-agent-*' 2>/dev/null | sort)

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" --interactive 39

  [ "$status" -eq 0 ]
  local logs_after
  logs_after=$(find "$LOOP_LOG_DIR" -maxdepth 1 -name 'dev-agent-*' 2>/dev/null | sort)
  [ "$logs_before" = "$logs_after" ]
}

@test "Mode 1 --interactive: pre-existing worktree dir survives wrapper exit" {
  # The cleanup trap must short-circuit under --interactive. Pre-create
  # the worktree dir at WORKTREE_BASE/gh-39 to simulate a leftover from
  # a prior interactive session, then confirm it's still there after the
  # wrapper exits.
  local repo fake wt
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs
  wt="$BATS_TEST_TMPDIR/wb-$$/gh-39"
  mkdir -p "$wt"
  : >"$wt/sentinel-file"

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" --interactive 39

  [ "$status" -eq 0 ]
  [ -d "$wt" ]
  [ -f "$wt/sentinel-file" ]
}

# ---------------------------------------------------------------------------
# Headless behavior must NOT change — regression guard. Without
# --interactive the wrapper still pipes through the eligibility / triage
# gates, with the same exit-2 / declined-comment / draft side effects.
# ---------------------------------------------------------------------------

@test "headless regression guard: no --interactive → eligibility-stub rc=1 still short-circuits, no claude" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_interactive_loop_home)
  _make_path_stubs

  REPO_ROOT="$repo" LOOP_HOME="$fake" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh"

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/claude-was-called" ]
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the new flag wiring so a future refactor can't
# silently regress — the in-script grep cost is negligible and prevents
# the "interactive flag stops working but headless tests still pass"
# class of breakage.
# ---------------------------------------------------------------------------

@test "run-developer.sh: --interactive parsing is wired up" {
  grep -qF -- '--interactive' "$LOOP_ROOT/runners/run-developer.sh"
  grep -qF 'INTERACTIVE=1' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: --interactive uses exec to replace the wrapper process" {
  # Pin that the interactive code path uses `exec` (no headless pipeline,
  # no post-LLM blocks). Without exec, post-LLM logic would still run on
  # claude exit and double-act on operator-driven failures. The exec call
  # may break across lines for backslash-continued arg lists, so check the
  # two halves separately.
  grep -qF 'exec env' "$LOOP_ROOT/runners/run-developer.sh"
  grep -qF 'claude "$KICKOFF"' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "bin/st: usage block documents --interactive on each dev subcommand" {
  grep -qF -- '--interactive' "$LOOP_ROOT/bin/st"
}
