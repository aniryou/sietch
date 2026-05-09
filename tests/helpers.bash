#!/usr/bin/env bash
# Shared bats helpers. Sourced by every *.bats file via load 'helpers'.

# Absolute path to the repo root (one level up from tests/).
LOOP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export LOOP_ROOT

# Re-route wrapper LOG/RAW paths under bats' tmp tree so fixture runs (which
# invoke run-developer.sh / run-reviewer.sh many times via stub-claude) don't
# pile fixture log files into /tmp alongside real production logs (GH#126).
# Mirrors the WORKTREE_BASE hermeticity pattern from GH#105 — set unconditionally
# at load time so every test inherits the redirect via `export`, including
# tests that pass env through `run env PATH=... bash ...`.
#
# BATS_FILE_TMPDIR is created per .bats file before tests run (bats >= 1.7),
# so it's available at load time. Per-test isolation isn't required for log
# files; per-file is enough to keep /tmp clean.
export LOOP_LOG_DIR="${BATS_FILE_TMPDIR:-${BATS_RUN_TMPDIR:-/tmp}}"

# Make a throwaway consumer-repo dir under $BATS_TEST_TMPDIR and echo its path.
# loop.config is a copy of templates/loop.config.example with placeholders
# rewritten to test-owner/test-repo so REPO_SLUG is well-formed.
#
# WORKTREE_BASE is also rewritten to a $BATS_TEST_TMPDIR-derived path so
# the config is hermetic by default — sourcing it sets LOCK_DIR and
# DISPATCH_LOCK_DIR (which derive from ${WORKTREE_BASE}) under
# $BATS_TEST_TMPDIR too. Without this, the production default
# /tmp/dev-agent/${REPO_OWNER}-${REPO_NAME} leaks onto the host's /tmp
# (GH#105). Tests that need a different WORKTREE_BASE / LOCK_DIR can still
# append their own override after make_repo returns; later assignments
# during config sourcing win.
make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo-$$"
  mkdir -p "$repo/.loop"
  awk -v wb="$BATS_TEST_TMPDIR/wb-$$" '
    /^REPO_OWNER=/    { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/     { print "REPO_NAME=\"test-repo\""; next }
    /^WORKTREE_BASE=/ { print "WORKTREE_BASE=\"" wb "\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"
  echo "$repo"
}
