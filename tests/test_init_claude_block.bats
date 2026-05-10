#!/usr/bin/env bats
# bats file_tags=regression
# st init — writes a LOOP marker-block into the consumer repo's CLAUDE.md.
#
# Marker contract (mirrors bd's CLAUDE.md block):
#   <!-- BEGIN LOOP INTEGRATION v:1 hash:<sha8> -->
#   ...rendered block...
#   <!-- END LOOP INTEGRATION -->
#
# Block content is rendered through runners/lib/render-prompt.sh, so any
# REPO_KEYS variable referenced by the template (e.g. BRANCH_PREFIX, LOCK_DIR)
# is substituted from the repo's .loop/loop.config.

load 'helpers'

setup() {
  ST="$LOOP_ROOT/bin/st"
  REPO="$BATS_TEST_TMPDIR/consumer-$$"
  mkdir -p "$REPO"
  # Pre-seed loop.config with test values so render-prompt.sh has something
  # concrete to substitute. Mirrors helpers.bash::make_repo, but we control
  # creation timing so we can exercise the "loop.config exists already" path.
  mkdir -p "$REPO/.loop"
  awk '
    /^REPO_OWNER=/   { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/    { print "REPO_NAME=\"test-repo\""; next }
    /^BRANCH_PREFIX=/ { print "BRANCH_PREFIX=\"my-custom-prefix\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$REPO/.loop/loop.config"
}

# Recompute the expected hash the same way bin/st does. Note: bin/st captures
# the rendered output with `rendered=$(...)` (which strips trailing newlines)
# then pipes via `printf '%s' "$rendered"` to shasum. Mirror that exactly so
# the hash check stays meaningful.
_expected_hash() {
  local rendered
  rendered=$(
    REPO_ROOT="$REPO" LOOP_HOME="$LOOP_ROOT" \
      bash "$LOOP_ROOT/runners/lib/render-prompt.sh" \
      "$LOOP_ROOT/templates/claude-md-block.md"
  )
  printf '%s' "$rendered" | shasum -a 256 | cut -c1-8
}

@test "fresh repo without CLAUDE.md: st init creates CLAUDE.md with BEGIN/END markers" {
  [ ! -f "$REPO/CLAUDE.md" ]
  cd "$REPO"
  run bash "$ST" init
  [ "$status" -eq 0 ]
  [ -f "$REPO/CLAUDE.md" ]
  grep -qF '<!-- BEGIN LOOP INTEGRATION v:1 hash:' "$REPO/CLAUDE.md"
  grep -qF '<!-- END LOOP INTEGRATION -->' "$REPO/CLAUDE.md"
}

@test "hash in BEGIN marker matches sha8 of rendered block content" {
  cd "$REPO"
  bash "$ST" init >/dev/null
  expected=$(_expected_hash)
  grep -qF "<!-- BEGIN LOOP INTEGRATION v:1 hash:${expected} -->" "$REPO/CLAUDE.md"
}

@test "existing CLAUDE.md without block: st init appends and preserves prior content" {
  cat >"$REPO/CLAUDE.md" <<'EOF'
# My Project

Some pre-existing content the user wrote.

## Build

Run `make` to build.
EOF
  cd "$REPO"
  run bash "$ST" init
  [ "$status" -eq 0 ]
  grep -qF '# My Project' "$REPO/CLAUDE.md"
  grep -qF 'Some pre-existing content the user wrote.' "$REPO/CLAUDE.md"
  grep -qF 'Run `make` to build.' "$REPO/CLAUDE.md"
  grep -qF '<!-- BEGIN LOOP INTEGRATION v:1 hash:' "$REPO/CLAUDE.md"
  grep -qF '<!-- END LOOP INTEGRATION -->' "$REPO/CLAUDE.md"
  # User content must precede the LOOP block (we append, never prepend).
  user_line=$(grep -n '# My Project' "$REPO/CLAUDE.md" | head -1 | cut -d: -f1)
  begin_line=$(grep -n 'BEGIN LOOP INTEGRATION' "$REPO/CLAUDE.md" | head -1 | cut -d: -f1)
  [ "$user_line" -lt "$begin_line" ]
}

@test "existing CLAUDE.md with block: st init is a no-op (idempotent, no duplicate)" {
  cd "$REPO"
  bash "$ST" init >/dev/null
  before=$(cat "$REPO/CLAUDE.md")
  # Run again — must not duplicate the block.
  run bash "$ST" init
  [ "$status" -eq 0 ]
  after=$(cat "$REPO/CLAUDE.md")
  [ "$before" = "$after" ]
  # Exactly one BEGIN and one END.
  [ "$(grep -cF 'BEGIN LOOP INTEGRATION' "$REPO/CLAUDE.md")" -eq 1 ]
  [ "$(grep -cF 'END LOOP INTEGRATION' "$REPO/CLAUDE.md")" -eq 1 ]
}

@test "existing CLAUDE.md with stale-hash block: st init still leaves it alone" {
  # A block whose hash no longer matches the current template — st sync's job
  # to refresh, not st init's. st init must not touch it.
  cat >"$REPO/CLAUDE.md" <<'EOF'
# Stale block test

<!-- BEGIN LOOP INTEGRATION v:1 hash:deadbeef -->
old content from a prior framework version
<!-- END LOOP INTEGRATION -->
EOF
  before=$(cat "$REPO/CLAUDE.md")
  cd "$REPO"
  run bash "$ST" init
  [ "$status" -eq 0 ]
  after=$(cat "$REPO/CLAUDE.md")
  [ "$before" = "$after" ]
}

@test "block parameterization: BRANCH_PREFIX from loop.config appears in rendered block" {
  cd "$REPO"
  bash "$ST" init >/dev/null
  # loop.config above set BRANCH_PREFIX="my-custom-prefix" — must appear literally.
  grep -qF 'my-custom-prefix' "$REPO/CLAUDE.md"
  # And no leftover ${BRANCH_PREFIX} placeholder for any REPO_KEYS variable.
  for key in BRANCH_PREFIX LOCK_DIR STALE_LOCK_HOURS REPO_SLUG; do
    if grep -qF "\${${key}}" "$REPO/CLAUDE.md"; then
      echo "key not substituted in CLAUDE.md block: $key" >&2
      return 1
    fi
  done
}

@test "no loop.config: st init creates one and the CLAUDE.md block" {
  rm -rf "$REPO/.loop"
  [ ! -f "$REPO/.loop/loop.config" ]
  cd "$REPO"
  run bash "$ST" init
  [ "$status" -eq 0 ]
  [ -f "$REPO/.loop/loop.config" ]
  [ -f "$REPO/CLAUDE.md" ]
  grep -qF 'BEGIN LOOP INTEGRATION' "$REPO/CLAUDE.md"
}

@test "AGENTS.md is NOT created or modified" {
  # Issue explicitly says AGENTS.md is out of scope — bd writes to both but we don't.
  [ ! -f "$REPO/AGENTS.md" ]
  cd "$REPO"
  bash "$ST" init >/dev/null
  [ ! -f "$REPO/AGENTS.md" ]
}
