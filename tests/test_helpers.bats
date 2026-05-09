#!/usr/bin/env bats
# tests/helpers.bash — pin the hermetic-default contract for make_repo.
#
# Background — see GH#105. Before this contract, make_repo copied
# templates/loop.config.example into a per-test repo dir but only rewrote
# REPO_OWNER and REPO_NAME — WORKTREE_BASE kept the production default
# /tmp/dev-agent/test-owner-test-repo, leaking onto host /tmp paths. Tests
# that exercised code reading WORKTREE_BASE / LOCK_DIR / DISPATCH_LOCK_DIR
# either accepted the leak or appended their own per-test override (~20
# sites across 7 files).
#
# This file pins the contract that make_repo produces a config whose
# WORKTREE_BASE — and therefore LOCK_DIR and DISPATCH_LOCK_DIR — resolve
# under $BATS_TEST_TMPDIR by default, so tests stay hermetic without each
# one re-implementing the override.

load 'helpers'

@test "make_repo: WORKTREE_BASE resolves under \$BATS_TEST_TMPDIR" {
  local repo
  repo=$(make_repo)
  # shellcheck disable=SC1091
  . "$repo/.loop/loop.config"
  case "$WORKTREE_BASE" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *)
      printf 'WORKTREE_BASE leaked outside BATS_TEST_TMPDIR: %s\n' "$WORKTREE_BASE"
      printf 'BATS_TEST_TMPDIR=%s\n' "$BATS_TEST_TMPDIR"
      return 1
      ;;
  esac
}

@test "make_repo: LOCK_DIR resolves under \$BATS_TEST_TMPDIR" {
  local repo
  repo=$(make_repo)
  # shellcheck disable=SC1091
  . "$repo/.loop/loop.config"
  case "$LOCK_DIR" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *)
      printf 'LOCK_DIR leaked outside BATS_TEST_TMPDIR: %s\n' "$LOCK_DIR"
      return 1
      ;;
  esac
}

@test "make_repo: DISPATCH_LOCK_DIR resolves under \$BATS_TEST_TMPDIR" {
  local repo
  repo=$(make_repo)
  # shellcheck disable=SC1091
  . "$repo/.loop/loop.config"
  case "$DISPATCH_LOCK_DIR" in
    "$BATS_TEST_TMPDIR"/*) ;;
    *)
      printf 'DISPATCH_LOCK_DIR leaked outside BATS_TEST_TMPDIR: %s\n' "$DISPATCH_LOCK_DIR"
      return 1
      ;;
  esac
}

@test "make_repo: parallel calls in distinct processes produce non-overlapping WORKTREE_BASE" {
  # Simulates parallel bats workers (each its own process => different $$).
  # Two `bash -c` invocations are by definition different processes, so they
  # must yield distinct WORKTREE_BASE paths.
  local wb1 wb2
  wb1=$(
    LOOP_ROOT="$LOOP_ROOT" \
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
    BATS_TEST_DIRNAME="$BATS_TEST_DIRNAME" \
    bash -c '
      . "$LOOP_ROOT/tests/helpers.bash"
      repo=$(make_repo)
      . "$repo/.loop/loop.config"
      printf "%s" "$WORKTREE_BASE"
    '
  )
  wb2=$(
    LOOP_ROOT="$LOOP_ROOT" \
    BATS_TEST_TMPDIR="$BATS_TEST_TMPDIR" \
    BATS_TEST_DIRNAME="$BATS_TEST_DIRNAME" \
    bash -c '
      . "$LOOP_ROOT/tests/helpers.bash"
      repo=$(make_repo)
      . "$repo/.loop/loop.config"
      printf "%s" "$WORKTREE_BASE"
    '
  )
  [ -n "$wb1" ]
  [ -n "$wb2" ]
  if [ "$wb1" = "$wb2" ]; then
    printf 'WORKTREE_BASE collided across processes:\n  wb1=%s\n  wb2=%s\n' "$wb1" "$wb2"
    return 1
  fi
}
