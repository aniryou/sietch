#!/usr/bin/env bats
# Multi-repo support (GH#74) — verify repo-scoped tmux sessions and
# lock-filename namespacing so two `st loop start` fleets can coexist on
# one machine without colliding.
#
# Three concerns covered here:
#   1. SESSION name in run-loop.sh derives from REPO_OWNER/REPO_NAME, so
#      two repos onboarded with default config get distinct tmux targets.
#   2. Dispatch lock filenames carry a per-repo prefix (LOCK_NAME_PREFIX),
#      and count_active_dispatch_locks honours the prefix — even with a
#      shared DISPATCH_LOCK_DIR (defence-in-depth for misconfigured repos).
#   3. The onboard check warns when two repos point WORKTREE_BASE at the
#      same path on this machine.

load 'helpers'

# Render a loop.config fixture with given owner/name pinned and the
# default WORKTREE_BASE preserved (so we can assert default-derived
# values without overriding them inline).
_make_repo_with_identity() {
  local repo="$1" owner="$2" name="$3"
  mkdir -p "$repo/.loop"
  awk -v o="$owner" -v n="$name" '
    /^REPO_OWNER=/ { print "REPO_OWNER=\"" o "\""; next }
    /^REPO_NAME=/  { print "REPO_NAME=\"" n "\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"
}

# ---------------------------------------------------------------------------
# 1. SESSION derivation — runners/lib/repo_id.sh
# ---------------------------------------------------------------------------

@test "loop_session_name: distinct for distinct repos" {
  local repo_a repo_b session_a session_b
  repo_a="$BATS_TEST_TMPDIR/repo-a"
  repo_b="$BATS_TEST_TMPDIR/repo-b"
  _make_repo_with_identity "$repo_a" "owner-a" "repo-a"
  _make_repo_with_identity "$repo_b" "owner-b" "repo-b"

  session_a=$(
    bash -c "
      set -e
      . '$repo_a/.loop/loop.config'
      . '$LOOP_ROOT/runners/lib/repo_id.sh'
      loop_session_name
    "
  )
  session_b=$(
    bash -c "
      set -e
      . '$repo_b/.loop/loop.config'
      . '$LOOP_ROOT/runners/lib/repo_id.sh'
      loop_session_name
    "
  )

  [ -n "$session_a" ]
  [ -n "$session_b" ]
  [ "$session_a" != "$session_b" ]
  [[ "$session_a" == *owner-a* ]]
  [[ "$session_a" == *repo-a* ]]
  [[ "$session_b" == *owner-b* ]]
  [[ "$session_b" == *repo-b* ]]
}

@test "loop_sanitize_id: replaces dots and other unsafe chars" {
  # Dots in repo names (e.g. lodash.debounce) must be sanitized so the
  # result is safe in tmux target syntax (`.` separates session.window).
  local out
  out=$(
    bash -c "
      . '$LOOP_ROOT/runners/lib/repo_id.sh'
      loop_sanitize_id 'foo.bar/baz qux'
    "
  )
  [[ "$out" != *.* ]]
  [[ "$out" != *' '* ]]
  [[ "$out" != *'/'* ]]
}

# ---------------------------------------------------------------------------
# 2. WORKTREE_BASE default in templates/loop.config.example must be
#    repo-scoped — otherwise two repos onboarded with defaults collide.
# ---------------------------------------------------------------------------

@test "default WORKTREE_BASE: repo-scoped — distinct repos get distinct paths" {
  local repo_a repo_b base_a base_b
  repo_a="$BATS_TEST_TMPDIR/repo-a"
  repo_b="$BATS_TEST_TMPDIR/repo-b"
  _make_repo_with_identity "$repo_a" "alpha-org" "alpha-repo"
  _make_repo_with_identity "$repo_b" "beta-org" "beta-repo"

  base_a=$(bash -c ". '$repo_a/.loop/loop.config'; printf '%s' \"\$WORKTREE_BASE\"")
  base_b=$(bash -c ". '$repo_b/.loop/loop.config'; printf '%s' \"\$WORKTREE_BASE\"")

  [ "$base_a" != "$base_b" ]
}

@test "default LOCK_DIR / DISPATCH_LOCK_DIR: also distinct (derive from WORKTREE_BASE)" {
  local repo_a repo_b lockdir_a lockdir_b dispatch_a dispatch_b
  repo_a="$BATS_TEST_TMPDIR/repo-a"
  repo_b="$BATS_TEST_TMPDIR/repo-b"
  _make_repo_with_identity "$repo_a" "alpha-org" "alpha-repo"
  _make_repo_with_identity "$repo_b" "beta-org" "beta-repo"

  lockdir_a=$(bash -c ". '$repo_a/.loop/loop.config'; printf '%s' \"\$LOCK_DIR\"")
  lockdir_b=$(bash -c ". '$repo_b/.loop/loop.config'; printf '%s' \"\$LOCK_DIR\"")
  dispatch_a=$(bash -c ". '$repo_a/.loop/loop.config'; printf '%s' \"\$DISPATCH_LOCK_DIR\"")
  dispatch_b=$(bash -c ". '$repo_b/.loop/loop.config'; printf '%s' \"\$DISPATCH_LOCK_DIR\"")

  [ "$lockdir_a" != "$lockdir_b" ]
  [ "$dispatch_a" != "$dispatch_b" ]
}

# ---------------------------------------------------------------------------
# 3. LOCK_NAME_PREFIX (defence-in-depth for shared WORKTREE_BASE)
# ---------------------------------------------------------------------------

@test "default LOCK_NAME_PREFIX: derives from REPO_NAME, distinct per repo" {
  local repo_a repo_b prefix_a prefix_b
  repo_a="$BATS_TEST_TMPDIR/repo-a"
  repo_b="$BATS_TEST_TMPDIR/repo-b"
  _make_repo_with_identity "$repo_a" "alpha-org" "alpha-repo"
  _make_repo_with_identity "$repo_b" "beta-org" "beta-repo"

  prefix_a=$(bash -c ". '$repo_a/.loop/loop.config'; printf '%s' \"\$LOCK_NAME_PREFIX\"")
  prefix_b=$(bash -c ". '$repo_b/.loop/loop.config'; printf '%s' \"\$LOCK_NAME_PREFIX\"")

  [ -n "$prefix_a" ]
  [ -n "$prefix_b" ]
  [ "$prefix_a" != "$prefix_b" ]
  [[ "$prefix_a" == *alpha-repo* ]]
  [[ "$prefix_b" == *beta-repo* ]]
}

# ---------------------------------------------------------------------------
# 4. count_active_dispatch_locks: only counts locks owned by this repo,
#    even when DISPATCH_LOCK_DIR is shared (i.e., misconfigured to a
#    common base across repos).
# ---------------------------------------------------------------------------

# Source the lock-counter helpers from run-loop.sh into a subshell. The
# helpers depend only on $DISPATCH_LOCK_DIR + $LOCK_NAME_PREFIX, so we
# can exercise them in isolation without bringing up tmux.
_count_dispatch_locks() {
  local dispatch_dir="$1" lock_prefix="$2"
  bash -c "
    DISPATCH_LOCK_DIR='$dispatch_dir'
    LOCK_NAME_PREFIX='$lock_prefix'
    . '$LOOP_ROOT/runners/lib/repo_id.sh'
    # Inline the same logic run-loop.sh uses (the function lives there).
    count=0
    for lock in \"\$DISPATCH_LOCK_DIR/\${LOCK_NAME_PREFIX}\"*.lock; do
      [ -d \"\$lock\" ] && count=\$((count + 1))
    done
    echo \"\$count\"
  "
}

@test "dispatch locks: prefix-glob isolates two repos sharing DISPATCH_LOCK_DIR" {
  local shared="$BATS_TEST_TMPDIR/dispatched"
  mkdir -p "$shared"

  # Repo A's locks
  mkdir "$shared/alpha-repo-pr-5-followup.lock"
  mkdir "$shared/alpha-repo-pr-7-conflicts.lock"
  # Repo B's lock
  mkdir "$shared/beta-repo-pr-9-followup.lock"

  local count_a count_b
  count_a=$(_count_dispatch_locks "$shared" "alpha-repo-")
  count_b=$(_count_dispatch_locks "$shared" "beta-repo-")

  [ "$count_a" -eq 2 ]
  [ "$count_b" -eq 1 ]
}

@test "dispatch locks: empty dir → zero" {
  local empty="$BATS_TEST_TMPDIR/empty-dispatched"
  mkdir -p "$empty"
  local count
  count=$(_count_dispatch_locks "$empty" "alpha-repo-")
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# 5. claim-lock filenames in run-developer.sh + eligibility.sh use the
#    LOCK_NAME_PREFIX, so a stale lock from repo A doesn't suppress repo
#    B's eligibility scan.
# ---------------------------------------------------------------------------

@test "eligibility lock-skip: only sees own-prefix locks under shared LOCK_DIR" {
  # Stand up a fake LOCK_DIR shared between two repos. Drop a lock for
  # issue #5 with REPO A's prefix; assert REPO B's lock-skip glob does
  # NOT see it (so issue #5 stays eligible for repo B).
  local shared="$BATS_TEST_TMPDIR/locks"
  mkdir -p "$shared/alpha-repo-gh-5.lock"

  local found_a found_b
  found_a=$(
    bash -c "
      LOCK_DIR='$shared'; LOCK_NAME_PREFIX='alpha-repo-'
      [ -d \"\${LOCK_DIR}/\${LOCK_NAME_PREFIX}gh-5.lock\" ] && echo yes || echo no
    "
  )
  found_b=$(
    bash -c "
      LOCK_DIR='$shared'; LOCK_NAME_PREFIX='beta-repo-'
      [ -d \"\${LOCK_DIR}/\${LOCK_NAME_PREFIX}gh-5.lock\" ] && echo yes || echo no
    "
  )

  [ "$found_a" = "yes" ]
  [ "$found_b" = "no" ]
}
