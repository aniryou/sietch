#!/usr/bin/env bats
# GH#126 — wrapper log/raw paths must respect LOOP_LOG_DIR.
#
# Bug: `runners/run-developer.sh` and `runners/run-reviewer.sh` hard-code
# LOG=/tmp/... and RAW=/tmp/..., so bats test runs (which invoke the wrappers
# many times via stub-claude) drop fixture logs into /tmp alongside real
# production logs. After two days of test runs, /tmp had ~2500 fixture files
# vs ~88 real ones — log-mining sweeps initially looked like the loop was
# failing thousands of times.
#
# Fix: derive the log directory from `${LOOP_LOG_DIR:-/tmp}`. Production
# callers (no LOOP_LOG_DIR set) keep writing to /tmp; tests set
# LOOP_LOG_DIR via helpers.bash so fixture logs stay hermetic per-test.

load 'helpers'

# ---------------------------------------------------------------------------
# Source-of-truth: the wrappers must reference LOOP_LOG_DIR and must not
# hard-code `/tmp/dev-agent-` or `/tmp/reviewer-agent-` in any LOG/RAW path.
# ---------------------------------------------------------------------------

@test "run-developer.sh: LOG/RAW paths derive from LOOP_LOG_DIR" {
  grep -qF 'LOOP_LOG_DIR' "$LOOP_ROOT/runners/run-developer.sh"
  # No `LOG="/tmp/dev-agent-...` or `RAW="/tmp/dev-agent-...` lines.
  ! grep -qE '^[[:space:]]*(LOG|RAW)="/tmp/dev-agent-' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: declares a /tmp default for LOOP_LOG_DIR (production-compat)" {
  # Default-if-unset (`: "${LOOP_LOG_DIR:=/tmp}"`) keeps real callers writing
  # under /tmp when they don't set the override — same convention used for
  # KEEP_ON_FAIL elsewhere in the wrapper.
  grep -qE '^[[:space:]]*:?[[:space:]]*"\$\{LOOP_LOG_DIR:=?-?/tmp\}"' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh: LOG/RAW paths derive from LOOP_LOG_DIR" {
  grep -qF 'LOOP_LOG_DIR' "$LOOP_ROOT/runners/run-reviewer.sh"
  ! grep -qE '^[[:space:]]*(LOG|RAW)="/tmp/reviewer-agent-' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-reviewer.sh: declares a /tmp default for LOOP_LOG_DIR (production-compat)" {
  grep -qE '^[[:space:]]*:?[[:space:]]*"\$\{LOOP_LOG_DIR:=?-?/tmp\}"' "$LOOP_ROOT/runners/run-reviewer.sh"
}

# ---------------------------------------------------------------------------
# helpers.bash must export LOOP_LOG_DIR pointing under bats' tmp tree, so any
# test that invokes a wrapper without an explicit LOOP_LOG_DIR still keeps
# fixture logs out of /tmp. Same hermeticity pattern as WORKTREE_BASE (GH#105).
# ---------------------------------------------------------------------------

@test "helpers.bash: exports LOOP_LOG_DIR not pointing at /tmp" {
  # helpers.bash has already been loaded by `load 'helpers'` at the top of
  # this file. LOOP_LOG_DIR should be set and must NOT point at /tmp.
  [ -n "${LOOP_LOG_DIR:-}" ]
  case "$LOOP_LOG_DIR" in
    /tmp|/tmp/*) false ;;
    *) true ;;
  esac
}

@test "helpers.bash: LOOP_LOG_DIR is exported (visible to subshells)" {
  # Wrappers run in subshells (`run env ... bash run-developer.sh`); the
  # override must propagate. `bash -c 'echo $LOOP_LOG_DIR'` yields empty if
  # the var is set-but-not-exported.
  local subshell_value
  subshell_value=$(bash -c 'printf %s "${LOOP_LOG_DIR:-}"')
  [ "$subshell_value" = "$LOOP_LOG_DIR" ]
  [ -n "$subshell_value" ]
}

# ---------------------------------------------------------------------------
# Behavioral guard: the dev-agent worktree path stays at $WORKTREE_BASE/...,
# *not* under $LOOP_LOG_DIR. The two are independent — LOOP_LOG_DIR routes
# wrapper LOG/RAW only, never the per-issue worktree (which is GH#105's
# WORKTREE_BASE concern). Catch a future "let's collapse them" regression.
# ---------------------------------------------------------------------------

@test "run-developer.sh: WORKTREE export uses WORKTREE_BASE, not LOOP_LOG_DIR" {
  # The wrapper exports WORKTREE for the dev-agent template (GH#82). It must
  # be derived from WORKTREE_BASE (per-repo, lock-coordinated) — not from
  # LOOP_LOG_DIR (per-test/per-process log root).
  grep -qE 'export WORKTREE="\$\{?WORKTREE_BASE\}?/gh-' "$LOOP_ROOT/runners/run-developer.sh"
  ! grep -qE 'export WORKTREE=.*LOOP_LOG_DIR' "$LOOP_ROOT/runners/run-developer.sh"
}
