#!/usr/bin/env bash
# Shared bats helpers. Sourced by every *.bats file via load 'helpers'.

# Absolute path to the repo root (one level up from tests/).
LOOP_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
export LOOP_ROOT

# Make a throwaway consumer-repo dir under $BATS_TEST_TMPDIR and echo its path.
# loop.config is a copy of templates/loop.config.example with placeholders
# rewritten to test-owner/test-repo so REPO_SLUG is well-formed.
make_repo() {
  local repo="$BATS_TEST_TMPDIR/repo-$$"
  mkdir -p "$repo/.loop"
  awk '
    /^REPO_OWNER=/   { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/    { print "REPO_NAME=\"test-repo\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"
  echo "$repo"
}
