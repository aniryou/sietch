#!/usr/bin/env bash
# Shared bats helpers. Sourced by every *.bats file via load 'helpers'.

# Absolute path to the repo root (one level up from tests/).
SIETCH_ROOT="$( cd "$BATS_TEST_DIRNAME/.." && pwd )"
export SIETCH_ROOT

# Make a throwaway consumer-rig dir under $BATS_TEST_TMPDIR and echo its path.
# rig.config is a copy of templates/rig.config.example with placeholders
# rewritten to test-owner/test-repo so REPO_SLUG is well-formed.
make_rig() {
  local rig="$BATS_TEST_TMPDIR/rig-$$"
  mkdir -p "$rig/.sietch"
  awk '
    /^REPO_OWNER=/   { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/    { print "REPO_NAME=\"test-repo\""; next }
    { print }
  ' "$SIETCH_ROOT/templates/rig.config.example" > "$rig/.sietch/rig.config"
  echo "$rig"
}
