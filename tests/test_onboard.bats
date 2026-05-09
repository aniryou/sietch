#!/usr/bin/env bats
# onboard.sh + bin/st onboard — repo-prerequisite audit.
#
# Each check_* is a small function in runners/lib/onboard.sh. We invoke them
# via `bash $ONBOARD_LIB <command>` so each test gets a clean shell — same
# pattern eligibility.sh uses for its CLI.

load 'helpers'

setup() {
  ONBOARD_LIB="$LOOP_ROOT/runners/lib/onboard.sh"
  REPO=$(make_repo)
  # Set non-placeholder values in the test repo's loop.config (helpers already
  # rewrites REPO_OWNER/REPO_NAME, but check_loop_config is the one feature
  # under test — keep the substitution close to where the test expects it).
  export LOOP_HOME="$LOOP_ROOT"
  export REPO_ROOT="$REPO"
}

# Build a gh stub on a per-test PATH that:
#   - returns 0 for `gh auth status`
#   - returns the supplied label list for `gh label list ... --json ...`
#   - records each `gh label create <name> ...` invocation in $LABELS_CREATED_LOG
# $1 = comma-separated existing label names (may be empty).
_install_gh_stub() {
  local existing="$1"
  local stub_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_dir"
  export LABELS_CREATED_LOG="$BATS_TEST_TMPDIR/labels-created.log"
  : > "$LABELS_CREATED_LOG"

  local labels_json='[]'
  if [ -n "$existing" ]; then
    labels_json=$(
      printf '%s' "$existing" \
        | tr ',' '\n' \
        | jq -R '{name: ., color: "000000", description: ""}' \
        | jq -s '.'
    )
  fi
  printf '%s' "$labels_json" > "$BATS_TEST_TMPDIR/labels.json"

  cat > "$stub_dir/gh" <<'STUB'
#!/usr/bin/env bash
# Minimal gh stub. Recognised invocations:
#   gh auth status                           → exit 0
#   gh label list --repo X --json N --limit M → cat $LABELS_FIXTURE
#   gh label create <name> ...               → echo <name> >> $LABELS_CREATED_LOG
case "$1 $2" in
  "auth status") exit 0 ;;
  "label list")  cat "$LABELS_FIXTURE" ;;
  "label create") shift 2; echo "$1" >> "$LABELS_CREATED_LOG" ;;
  *) echo "[gh-stub] unexpected: $*" >&2; exit 99 ;;
esac
STUB
  chmod +x "$stub_dir/gh"
  export LABELS_FIXTURE="$BATS_TEST_TMPDIR/labels.json"
  export PATH="$stub_dir:$PATH"
}

# Build a passing repo: every prerequisite present.
_setup_passing_repo() {
  mkdir -p "$REPO/.beads"
  : > "$REPO/.pre-commit-config.yaml"
  mkdir -p "$REPO/.git/hooks"
  printf '#!/bin/sh\n# pre-commit auto-generated\nexec pre-commit run\n' \
    > "$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  mkdir -p "$REPO/.github/workflows"
  cat > "$REPO/.github/workflows/ci.yml" <<'YAML'
name: ci
on:
  push:
    branches: [main]
  pull_request:
jobs:
  noop:
    runs-on: ubuntu-latest
    steps:
      - run: 'true'
YAML
  mkdir -p "$REPO/tests"
  : > "$REPO/tests/test_foo.py"
}

# ---------------------------------------------------------------------------
# check_loop_config
# ---------------------------------------------------------------------------

@test "check_loop_config: passes when REPO_OWNER/REPO_NAME are non-placeholder" {
  run bash "$ONBOARD_LIB" check_loop_config
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '✓'
}

@test "check_loop_config: fails when loop.config is missing entirely" {
  rm -rf "$REPO/.loop"
  run bash "$ONBOARD_LIB" check_loop_config
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF '✗'
}

@test "check_loop_config: fails when REPO_OWNER is the example placeholder" {
  cp "$LOOP_ROOT/templates/loop.config.example" "$REPO/.loop/loop.config"
  run bash "$ONBOARD_LIB" check_loop_config
  [ "$status" -eq 1 ]
  echo "$output" | grep -qiF 'placeholder'
}

# ---------------------------------------------------------------------------
# check_beads
# ---------------------------------------------------------------------------

@test "check_beads: passes when .beads/ exists" {
  mkdir -p "$REPO/.beads"
  run bash "$ONBOARD_LIB" check_beads
  [ "$status" -eq 0 ]
}

@test "check_beads: fails when .beads/ is missing" {
  run bash "$ONBOARD_LIB" check_beads
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_pre_commit_config
# ---------------------------------------------------------------------------

@test "check_pre_commit_config: passes for .pre-commit-config.yaml" {
  : > "$REPO/.pre-commit-config.yaml"
  run bash "$ONBOARD_LIB" check_pre_commit_config
  [ "$status" -eq 0 ]
}

@test "check_pre_commit_config: also passes for .pre-commit-config.yml" {
  : > "$REPO/.pre-commit-config.yml"
  run bash "$ONBOARD_LIB" check_pre_commit_config
  [ "$status" -eq 0 ]
}

@test "check_pre_commit_config: fails when both variants are missing" {
  run bash "$ONBOARD_LIB" check_pre_commit_config
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_pre_commit_hook
# ---------------------------------------------------------------------------

@test "check_pre_commit_hook: passes when hook contains pre-commit marker" {
  mkdir -p "$REPO/.git/hooks"
  printf '#!/bin/sh\n# pre-commit framework auto-generated\nexec pre-commit run\n' \
    > "$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  run bash "$ONBOARD_LIB" check_pre_commit_hook
  [ "$status" -eq 0 ]
}

@test "check_pre_commit_hook: fails when hook file is missing" {
  mkdir -p "$REPO/.git/hooks"
  run bash "$ONBOARD_LIB" check_pre_commit_hook
  [ "$status" -eq 1 ]
}

@test "check_pre_commit_hook: fails when hook lacks pre-commit marker" {
  mkdir -p "$REPO/.git/hooks"
  printf '#!/bin/sh\nexit 0\n' > "$REPO/.git/hooks/pre-commit"
  chmod +x "$REPO/.git/hooks/pre-commit"
  run bash "$ONBOARD_LIB" check_pre_commit_hook
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_workflows
# ---------------------------------------------------------------------------

@test "check_workflows: passes when first workflow runs on pull_request" {
  mkdir -p "$REPO/.github/workflows"
  cat > "$REPO/.github/workflows/ci.yml" <<'YAML'
on:
  push: { branches: [main] }
  pull_request:
YAML
  run bash "$ONBOARD_LIB" check_workflows
  [ "$status" -eq 0 ]
}

@test "check_workflows: also passes for .yaml extension" {
  mkdir -p "$REPO/.github/workflows"
  cat > "$REPO/.github/workflows/ci.yaml" <<'YAML'
on:
  pull_request:
YAML
  run bash "$ONBOARD_LIB" check_workflows
  [ "$status" -eq 0 ]
}

@test "check_workflows: fails when no workflow files exist" {
  run bash "$ONBOARD_LIB" check_workflows
  [ "$status" -eq 1 ]
}

@test "check_workflows: fails when first workflow does not list pull_request" {
  mkdir -p "$REPO/.github/workflows"
  cat > "$REPO/.github/workflows/ci.yml" <<'YAML'
on:
  push: { branches: [main] }
YAML
  run bash "$ONBOARD_LIB" check_workflows
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_test_dir
# ---------------------------------------------------------------------------

@test "check_test_dir: passes when tests/ has at least one file" {
  mkdir -p "$REPO/tests"
  : > "$REPO/tests/test_foo.py"
  run bash "$ONBOARD_LIB" check_test_dir
  [ "$status" -eq 0 ]
}

@test "check_test_dir: passes for singular test/ directory" {
  mkdir -p "$REPO/test"
  : > "$REPO/test/test_foo.py"
  run bash "$ONBOARD_LIB" check_test_dir
  [ "$status" -eq 0 ]
}

@test "check_test_dir: does NOT match test_data/ alone" {
  mkdir -p "$REPO/test_data"
  : > "$REPO/test_data/sample.json"
  run bash "$ONBOARD_LIB" check_test_dir
  [ "$status" -eq 1 ]
}

@test "check_test_dir: fails when tests/ exists but is empty" {
  mkdir -p "$REPO/tests"
  run bash "$ONBOARD_LIB" check_test_dir
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_worktree_base
# ---------------------------------------------------------------------------

@test "check_worktree_base: passes when WORKTREE_BASE can be created" {
  run bash "$ONBOARD_LIB" check_worktree_base
  [ "$status" -eq 0 ]
}

@test "check_worktree_base: fails when parent dir is unwritable" {
  if [ "$(id -u)" = "0" ]; then
    skip "running as root; cannot create unwritable dir"
  fi
  local ro="$BATS_TEST_TMPDIR/ro"
  mkdir -p "$ro"
  chmod 555 "$ro"
  printf '\nWORKTREE_BASE="%s"\n' "$ro/sub" >> "$REPO/.loop/loop.config"
  run bash "$ONBOARD_LIB" check_worktree_base
  chmod 755 "$ro"
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_worktree_base_unique — multi-repo collision guard (GH#74)
#
# Drops a .loop-owner marker inside WORKTREE_BASE on first run, naming this
# repo. Subsequent runs from the same repo see their own marker and pass;
# runs from a different repo pointed at the same WORKTREE_BASE see another
# owner's marker and fail with a clear message.
# ---------------------------------------------------------------------------

@test "check_worktree_base_unique: passes on first run and drops owner marker" {
  local base="$BATS_TEST_TMPDIR/wb-uniq"
  printf '\nWORKTREE_BASE="%s"\n' "$base" >> "$REPO/.loop/loop.config"
  run bash "$ONBOARD_LIB" check_worktree_base_unique
  [ "$status" -eq 0 ]
  [ -f "$base/.loop-owner" ]
  grep -qFx 'test-owner/test-repo' "$base/.loop-owner"
}

@test "check_worktree_base_unique: passes on re-run from the same repo" {
  local base="$BATS_TEST_TMPDIR/wb-uniq"
  printf '\nWORKTREE_BASE="%s"\n' "$base" >> "$REPO/.loop/loop.config"
  bash "$ONBOARD_LIB" check_worktree_base_unique  # first run: drops marker
  run bash "$ONBOARD_LIB" check_worktree_base_unique  # second run: idempotent
  [ "$status" -eq 0 ]
}

@test "check_worktree_base_unique: fails when another repo already owns the base" {
  local base="$BATS_TEST_TMPDIR/wb-uniq"
  printf '\nWORKTREE_BASE="%s"\n' "$base" >> "$REPO/.loop/loop.config"
  mkdir -p "$base"
  echo "other-org/other-repo" > "$base/.loop-owner"
  run bash "$ONBOARD_LIB" check_worktree_base_unique
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF '✗'
  echo "$output" | grep -qF 'other-org/other-repo'
}

# ---------------------------------------------------------------------------
# check_gh_auth
# ---------------------------------------------------------------------------

@test "check_gh_auth: passes when 'gh auth status' returns 0" {
  _install_gh_stub ""
  run bash "$ONBOARD_LIB" check_gh_auth
  [ "$status" -eq 0 ]
}

@test "check_gh_auth: fails when 'gh auth status' returns nonzero" {
  local stub_dir="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$stub_dir"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$stub_dir/gh"
  chmod +x "$stub_dir/gh"
  PATH="$stub_dir:$PATH" run bash "$ONBOARD_LIB" check_gh_auth
  [ "$status" -eq 1 ]
}

# ---------------------------------------------------------------------------
# check_labels — black-box: read templates/labels.json, diff vs gh stub,
# auto-create the missing ones.
# ---------------------------------------------------------------------------

# Canonical label set provisioned by `st init` (templates/labels.json):
# 7 base labels (severity, type) + 3 dev-failed:N retry-counter labels (GH#56).
_CANONICAL_LABELS="severity:high,severity:medium,severity:low,bug,enhancement,testing,documentation,dev-failed:1,dev-failed:2,dev-failed:3"

@test "check_labels: passes without creating when all canonical labels exist" {
  _install_gh_stub "$_CANONICAL_LABELS"
  run bash "$ONBOARD_LIB" check_labels
  [ "$status" -eq 0 ]
  [ ! -s "$LABELS_CREATED_LOG" ]
}

@test "check_labels: creates each missing canonical label and passes" {
  _install_gh_stub "severity:high,severity:medium"
  run bash "$ONBOARD_LIB" check_labels
  [ "$status" -eq 0 ]
  # Canonical set is 10 labels; existing fixture had 2 → expect 8 creations.
  [ "$(wc -l < "$LABELS_CREATED_LOG" | tr -d ' ')" -eq 8 ]
  grep -qFx 'testing' "$LABELS_CREATED_LOG"
  grep -qFx 'documentation' "$LABELS_CREATED_LOG"
  grep -qFx 'severity:low' "$LABELS_CREATED_LOG"
  grep -qFx 'dev-failed:1' "$LABELS_CREATED_LOG"
  grep -qFx 'dev-failed:3' "$LABELS_CREATED_LOG"
}

@test "check_labels: creates all when none exist" {
  _install_gh_stub ""
  run bash "$ONBOARD_LIB" check_labels
  [ "$status" -eq 0 ]
  [ "$(wc -l < "$LABELS_CREATED_LOG" | tr -d ' ')" -eq 10 ]
}

# ---------------------------------------------------------------------------
# templates/labels.json — schema sanity
# ---------------------------------------------------------------------------

@test "templates/labels.json: parses as JSON and is the canonical 10-label set" {
  local file="$LOOP_ROOT/templates/labels.json"
  [ -f "$file" ]
  jq -e 'type == "array" and length == 10' "$file" >/dev/null
  jq -e '
    [.[].name] as $names |
    ($names | contains(["severity:high","severity:medium","severity:low",
                        "bug","enhancement","testing","documentation",
                        "dev-failed:1","dev-failed:2","dev-failed:3"]))
  ' "$file" >/dev/null
  jq -e '.[] | (.name|type) == "string" and (.color|type) == "string"' \
    "$file" >/dev/null
}

# ---------------------------------------------------------------------------
# Aggregator: onboard_run / onboard.sh run
# ---------------------------------------------------------------------------

@test "onboard run: exits 0 when all checks pass" {
  _setup_passing_repo
  _install_gh_stub "$_CANONICAL_LABELS"
  run bash "$ONBOARD_LIB" run
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '✓'
}

@test "onboard run: exits 1 when one check fails" {
  _setup_passing_repo
  rm -rf "$REPO/.beads"
  _install_gh_stub "$_CANONICAL_LABELS"
  run bash "$ONBOARD_LIB" run
  [ "$status" -eq 1 ]
  echo "$output" | grep -qF '✗'
}

# ---------------------------------------------------------------------------
# bin/st onboard wiring — walks up to find .loop/loop.config
# ---------------------------------------------------------------------------

@test "bin/st onboard: works from a sub-directory of the repo" {
  _setup_passing_repo
  _install_gh_stub "$_CANONICAL_LABELS"
  mkdir -p "$REPO/sub/dir"
  cd "$REPO/sub/dir"
  run "$LOOP_ROOT/bin/st" onboard
  [ "$status" -eq 0 ]
  echo "$output" | grep -qF '✓'
}

@test "bin/st onboard: returns 1 when prerequisites are missing" {
  # Don't set up the passing repo — many checks will fail.
  _install_gh_stub "$_CANONICAL_LABELS"
  cd "$REPO"
  run "$LOOP_ROOT/bin/st" onboard
  [ "$status" -eq 1 ]
}
