#!/usr/bin/env bats
# st init — auto-fill placeholders from repo state, bootstrap missing
# prerequisites, and run the embedded onboard check at the end. (GH#164)
#
# Companion to test_init_claude_block.bats, which covers the CLAUDE.md
# block side of `st init`. This file covers the new "do everything bd init
# does in one command" surface area.

load 'helpers'

setup() {
  ST="$LOOP_ROOT/bin/st"
  REPO="$BATS_TEST_TMPDIR/repo-$$"
  mkdir -p "$REPO"
  # Hermetic stubs for bd / pre-commit / gh so we never touch the user's
  # network or real beads store. Each stub records invocations into a
  # per-test log file so tests can assert "X was called" without spying
  # on PATH internals.
  STUB_BIN="$BATS_TEST_TMPDIR/stub-bin"
  mkdir -p "$STUB_BIN"
  BD_INVOKED_LOG="$BATS_TEST_TMPDIR/bd-invocations.log"
  PRECOMMIT_INVOKED_LOG="$BATS_TEST_TMPDIR/precommit-invocations.log"
  : >"$BD_INVOKED_LOG"
  : >"$PRECOMMIT_INVOKED_LOG"
  export BD_INVOKED_LOG PRECOMMIT_INVOKED_LOG

  # bd stub: `bd init` creates .beads/, records the call, exits 0.
  cat >"$STUB_BIN/bd" <<'STUB'
#!/usr/bin/env bash
echo "$@" >>"$BD_INVOKED_LOG"
case "$1" in
  init)
    mkdir -p .beads
    : >.beads/issues.jsonl
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUB_BIN/bd"

  # pre-commit stub: `pre-commit install` writes a hook with the marker.
  cat >"$STUB_BIN/pre-commit" <<'STUB'
#!/usr/bin/env bash
echo "$@" >>"$PRECOMMIT_INVOKED_LOG"
case "$1" in
  install)
    mkdir -p .git/hooks
    printf '#!/bin/sh\n# pre-commit framework auto-generated\nexec pre-commit run\n' \
      >.git/hooks/pre-commit
    chmod +x .git/hooks/pre-commit
    exit 0
    ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUB_BIN/pre-commit"

  # gh stub: auth status passes, label list returns empty, label create succeeds.
  cat >"$STUB_BIN/gh" <<'STUB'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status") exit 0 ;;
  "label list")  echo "[]" ;;
  "label create") exit 0 ;;
  *) exit 0 ;;
esac
STUB
  chmod +x "$STUB_BIN/gh"

  export PATH="$STUB_BIN:$PATH"
}

# Initialize $REPO as a git repo with the given origin URL (if any).
# Override WORKTREE_BASE in any pre-existing loop.config to a hermetic path
# so embedded onboard's check_worktree_base doesn't write to /tmp/dev-agent/*.
_git_init_with_remote() {
  local origin_url="$1"
  ( cd "$REPO" && git init -q )
  if [ -n "$origin_url" ]; then
    ( cd "$REPO" && git remote add origin "$origin_url" )
  fi
}

# Append a hermetic WORKTREE_BASE override to the (autofilled) loop.config
# so embedded onboard's check_worktree_base + check_worktree_base_unique
# don't write into the user's /tmp/dev-agent/*.
_pin_worktree_base_to_tmpdir() {
  local cfg="$REPO/.loop/loop.config"
  printf '\nWORKTREE_BASE="%s"\n' "$BATS_TEST_TMPDIR/wb-$$" >>"$cfg"
}

# Pre-create .loop/loop.config from the template (placeholders intact),
# then pin WORKTREE_BASE for hermeticity. Used by autofill tests that
# need to call `st init` over a config whose REPO_OWNER/etc are still
# the template placeholders.
_seed_template_config() {
  mkdir -p "$REPO/.loop"
  cp "$LOOP_ROOT/templates/loop.config.example" "$REPO/.loop/loop.config"
  _pin_worktree_base_to_tmpdir
}

# ---------------------------------------------------------------------------
# REPO_OWNER / REPO_NAME from `git remote get-url origin`
# ---------------------------------------------------------------------------

@test "autofill: ssh remote git@github.com:foo/bar.git → REPO_OWNER=foo, REPO_NAME=bar" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'REPO_OWNER="foo"' "$REPO/.loop/loop.config"
  grep -qFx 'REPO_NAME="bar"' "$REPO/.loop/loop.config"
}

@test "autofill: https remote https://github.com/foo/bar.git → REPO_OWNER=foo, REPO_NAME=bar" {
  _seed_template_config
  _git_init_with_remote "https://github.com/foo/bar.git"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'REPO_OWNER="foo"' "$REPO/.loop/loop.config"
  grep -qFx 'REPO_NAME="bar"' "$REPO/.loop/loop.config"
}

@test "autofill: https remote without .git suffix is also parsed" {
  _seed_template_config
  _git_init_with_remote "https://github.com/baz/qux"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'REPO_OWNER="baz"' "$REPO/.loop/loop.config"
  grep -qFx 'REPO_NAME="qux"' "$REPO/.loop/loop.config"
}

@test "autofill: ssh remote with dotted repo name git@github.com:vercel/next.js.git → REPO_NAME=next.js" {
  _seed_template_config
  _git_init_with_remote "git@github.com:vercel/next.js.git"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'REPO_OWNER="vercel"' "$REPO/.loop/loop.config"
  grep -qFx 'REPO_NAME="next.js"' "$REPO/.loop/loop.config"
}

@test "autofill: https remote with dotted repo name https://github.com/socketio/socket.io → REPO_NAME=socket.io" {
  _seed_template_config
  _git_init_with_remote "https://github.com/socketio/socket.io"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'REPO_OWNER="socketio"' "$REPO/.loop/loop.config"
  grep -qFx 'REPO_NAME="socket.io"' "$REPO/.loop/loop.config"
}

@test "autofill: no git remote → placeholders preserved, onboard reports check_loop_config ✗" {
  _seed_template_config
  _git_init_with_remote ""  # git init but no remote
  cd "$REPO"
  run bash "$ST" init
  # Placeholder values must remain untouched.
  grep -qFx 'REPO_OWNER="your-github-org-or-user"' "$REPO/.loop/loop.config"
  grep -qFx 'REPO_NAME="your-repo-name"' "$REPO/.loop/loop.config"
  # Embedded onboard must report check_loop_config as failing.
  echo "$output" | grep -qF '✗ check_loop_config'
}

@test "autofill: re-run preserves user-edited REPO_OWNER (not a placeholder)" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  # Pre-edit REPO_OWNER to a custom value before running init. The template's
  # REPO_NAME stays as a placeholder so autofill is free to overwrite that
  # one — the acceptance contract is that user-edited fields aren't clobbered,
  # not that the file is frozen.
  awk '
    /^REPO_OWNER=/ { print "REPO_OWNER=\"custom-owner\""; next }
    { print }
  ' "$REPO/.loop/loop.config" >"$REPO/.loop/loop.config.tmp"
  mv "$REPO/.loop/loop.config.tmp" "$REPO/.loop/loop.config"
  cd "$REPO"
  run bash "$ST" init
  # User-edited REPO_OWNER must still be "custom-owner" (no autofill clobber).
  grep -qFx 'REPO_OWNER="custom-owner"' "$REPO/.loop/loop.config"
  # The placeholder REPO_NAME, OTOH, is rightly overwritten from the remote.
  grep -qFx 'REPO_NAME="bar"' "$REPO/.loop/loop.config"
}

# ---------------------------------------------------------------------------
# TEST_CMD stack sniffing
# ---------------------------------------------------------------------------

@test "autofill: pyproject.toml → TEST_CMD=\"pytest -q\" (template default; no change)" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  : >"$REPO/pyproject.toml"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'TEST_CMD="pytest -q"' "$REPO/.loop/loop.config"
}

@test "autofill: requirements.txt → TEST_CMD=\"pytest -q\"" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  : >"$REPO/requirements.txt"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'TEST_CMD="pytest -q"' "$REPO/.loop/loop.config"
}

@test "autofill: package.json (no python) → TEST_CMD=\"npm test\"" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  : >"$REPO/package.json"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'TEST_CMD="npm test"' "$REPO/.loop/loop.config"
}

@test "autofill: go.mod (no python/node) → TEST_CMD=\"go test ./...\"" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  : >"$REPO/go.mod"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'TEST_CMD="go test ./..."' "$REPO/.loop/loop.config"
}

@test "autofill: only tests/*.bats → TEST_CMD=\"bats tests/\"" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  mkdir -p "$REPO/tests"
  : >"$REPO/tests/foo.bats"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'TEST_CMD="bats tests/"' "$REPO/.loop/loop.config"
}

@test "autofill: re-run preserves user-edited TEST_CMD (not the template default)" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  : >"$REPO/package.json"
  # Pre-edit TEST_CMD to something custom before running init.
  awk '
    /^TEST_CMD=/ { print "TEST_CMD=\"yarn test --ci\""; next }
    { print }
  ' "$REPO/.loop/loop.config" >"$REPO/.loop/loop.config.tmp"
  mv "$REPO/.loop/loop.config.tmp" "$REPO/.loop/loop.config"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'TEST_CMD="yarn test --ci"' "$REPO/.loop/loop.config"
}

# ---------------------------------------------------------------------------
# Bootstrap: bd init when .beads/ is missing
# ---------------------------------------------------------------------------

@test "bootstrap: missing .beads/ + bd on PATH → 'bd init' is invoked" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  [ ! -d "$REPO/.beads" ]
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'init' "$BD_INVOKED_LOG"
  [ -d "$REPO/.beads" ]
}

@test "bootstrap: existing .beads/ → 'bd init' is NOT invoked (idempotent)" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  mkdir -p "$REPO/.beads"
  : >"$REPO/.beads/issues.jsonl"
  cd "$REPO"
  run bash "$ST" init
  [ ! -s "$BD_INVOKED_LOG" ]
}

@test "bootstrap: missing .beads/ AND bd not on PATH → init exits non-zero, fix line names bd" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  # Strip our bd stub by overriding PATH to exclude $STUB_BIN; but we still
  # need gh + pre-commit stubs, so build a fresh stub dir without bd.
  local nobd_stub="$BATS_TEST_TMPDIR/nobd-stub"
  mkdir -p "$nobd_stub"
  cp "$STUB_BIN/gh" "$nobd_stub/gh"
  cp "$STUB_BIN/pre-commit" "$nobd_stub/pre-commit"
  # Strip the parent PATH segments that include the host's bd (if any):
  # just point PATH at the no-bd stub plus a minimal core (/usr/bin:/bin).
  cd "$REPO"
  PATH="$nobd_stub:/usr/bin:/bin" run bash "$ST" init
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '✗ check_beads'
  # The fix: line names bd init.
  echo "$output" | grep -qF "bd init"
}

# ---------------------------------------------------------------------------
# Bootstrap: pre-commit install when config exists but hook missing
# ---------------------------------------------------------------------------

@test "bootstrap: .pre-commit-config.yaml exists + no hook → 'pre-commit install' is invoked" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  : >"$REPO/.pre-commit-config.yaml"
  # No .git/hooks/pre-commit yet (git init creates .git/ but not the hook).
  rm -f "$REPO/.git/hooks/pre-commit"
  cd "$REPO"
  run bash "$ST" init
  grep -qFx 'install' "$PRECOMMIT_INVOKED_LOG"
  [ -f "$REPO/.git/hooks/pre-commit" ]
}

@test "bootstrap: hook already installed with marker → 'pre-commit install' is NOT invoked" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  : >"$REPO/.pre-commit-config.yaml"
  mkdir -p "$REPO/.git/hooks"
  printf '#!/bin/sh\n# pre-commit framework auto-generated\nexec pre-commit run\n' \
    >"$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  cd "$REPO"
  run bash "$ST" init
  [ ! -s "$PRECOMMIT_INVOKED_LOG" ]
}

@test "bootstrap: no .pre-commit-config.yaml → 'pre-commit install' is NOT invoked" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  cd "$REPO"
  run bash "$ST" init
  [ ! -s "$PRECOMMIT_INVOKED_LOG" ]
}

# ---------------------------------------------------------------------------
# Embedded onboard run + exit code propagation
# ---------------------------------------------------------------------------

@test "embedded onboard: exits 0 with all ✓ when fixture has every prerequisite" {
  # Build a fixture that satisfies every onboard check.
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  # .beads/ already provisioned (so bd init is not needed)
  mkdir -p "$REPO/.beads"
  : >"$REPO/.beads/issues.jsonl"
  # pre-commit config + installed hook
  : >"$REPO/.pre-commit-config.yaml"
  mkdir -p "$REPO/.git/hooks"
  printf '#!/bin/sh\n# pre-commit framework auto-generated\nexec pre-commit run\n' \
    >"$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  # CI workflow with pull_request trigger
  mkdir -p "$REPO/.github/workflows"
  cat >"$REPO/.github/workflows/ci.yml" <<'YAML'
name: ci
on:
  pull_request:
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YAML
  # tests dir with at least one bats file (also drives TEST_CMD sniff)
  mkdir -p "$REPO/tests"
  : >"$REPO/tests/foo.bats"

  cd "$REPO"
  run bash "$ST" init
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '✓ check_loop_config'
  echo "$output" | grep -qF '✓ check_beads'
  echo "$output" | grep -qF '✓ check_workflows'
  echo "$output" | grep -qF '✓ check_test_dir'
  # No ✗ lines anywhere.
  ! echo "$output" | grep -qF '✗'
}

@test "embedded onboard: exits non-zero when at least one check fails" {
  # Bare fixture: no .pre-commit-config.yaml, no workflows, no tests dir.
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  cd "$REPO"
  run bash "$ST" init
  [ "$status" -ne 0 ]
  echo "$output" | grep -qF '✗'
}

# ---------------------------------------------------------------------------
# Idempotency on full re-run
# ---------------------------------------------------------------------------

@test "idempotency: second 'st init' is a no-op on loop.config" {
  _seed_template_config
  _git_init_with_remote "git@github.com:foo/bar.git"
  cd "$REPO"
  run bash "$ST" init
  before=$(cat "$REPO/.loop/loop.config")
  run bash "$ST" init
  after=$(cat "$REPO/.loop/loop.config")
  [ "$before" = "$after" ]
}
