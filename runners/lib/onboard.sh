#!/usr/bin/env bash
# lib/onboard.sh — audit a consumer repo for loop's prerequisites.
#
# Each `check_<name>` function:
#   - reads context from $REPO_ROOT (consumer repo) and $LOOP_HOME (framework),
#   - prints exactly ONE summary line ("✓ <name>" or "✗ <name> — <why>"),
#   - on failure prints a "  fix: <copy-pasteable snippet>" indented line,
#   - returns 0 (pass) or 1 (fail).
#
# Read-only by default. The single exception is `check_labels`, which calls
# `gh label create` for any canonical label missing on $REPO_SLUG. Existing
# labels are never modified (color/description drift is reported only).
#
# CLI:
#   bash onboard.sh run                    # run every check; exit 0 iff all pass
#   bash onboard.sh check_<name>           # run a single check
#   bash onboard.sh -v run                 # verbose: show what each check inspected
#
# Required env: REPO_ROOT, LOOP_HOME (set by bin/st).

set -u
\unalias -a 2>/dev/null || true

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via bin/st}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via bin/st}"

LABELS_TEMPLATE="${LABELS_TEMPLATE:-$LOOP_HOME/templates/labels.json}"
ONBOARD_VERBOSE="${ONBOARD_VERBOSE:-0}"

_pass() { printf '✓ %s\n' "$1"; }
_fail() {
  local name="$1" why="$2" fix="${3:-}"
  printf '✗ %s — %s\n' "$name" "$why"
  [ -n "$fix" ] && printf '  fix: %s\n' "$fix"
  return 1
}
_v() { [ "$ONBOARD_VERBOSE" = "1" ] && printf '  · %s\n' "$1"; return 0; }

# ---------------------------------------------------------------------------
# Source loop.config so checks can see REPO_SLUG, WORKTREE_BASE, etc.
# Tolerated to fail — check_loop_config reports the failure cleanly.
# ---------------------------------------------------------------------------
_load_loop_config() {
  local cfg="$REPO_ROOT/.loop/loop.config"
  if [ -f "$cfg" ]; then
    # shellcheck disable=SC1090
    . "$cfg"
    return 0
  fi
  return 1
}
_load_loop_config || true

# ---------------------------------------------------------------------------
# check_loop_config
# ---------------------------------------------------------------------------
check_loop_config() {
  local cfg="$REPO_ROOT/.loop/loop.config"
  _v "inspecting $cfg"
  if [ ! -f "$cfg" ]; then
    _fail check_loop_config ".loop/loop.config not found at $cfg" \
      "run 'st init' from your repo root, then edit .loop/loop.config"
    return 1
  fi
  if [ "${REPO_OWNER:-}" = "your-github-org-or-user" ] \
     || [ "${REPO_NAME:-}" = "your-repo-name" ] \
     || [ -z "${REPO_OWNER:-}" ] \
     || [ -z "${REPO_NAME:-}" ]; then
    _fail check_loop_config "REPO_OWNER/REPO_NAME still hold example placeholders" \
      "edit $cfg and set REPO_OWNER/REPO_NAME to this repo's GitHub slug"
    return 1
  fi
  _pass check_loop_config
}

# ---------------------------------------------------------------------------
# check_beads
# ---------------------------------------------------------------------------
check_beads() {
  _v "inspecting $REPO_ROOT/.beads"
  if [ -d "$REPO_ROOT/.beads" ]; then
    _pass check_beads
  else
    _fail check_beads ".beads/ not found in repo root" \
      "run 'bd init' to bootstrap the beads task tracker"
  fi
}

# ---------------------------------------------------------------------------
# check_gh_auth
# ---------------------------------------------------------------------------
check_gh_auth() {
  _v "running 'gh auth status'"
  if gh auth status >/dev/null 2>&1; then
    _pass check_gh_auth
  else
    _fail check_gh_auth "gh CLI is not authenticated" \
      "run 'gh auth login'"
  fi
}

# ---------------------------------------------------------------------------
# check_labels — auto-creates missing canonical labels
# ---------------------------------------------------------------------------
check_labels() {
  _v "inspecting $LABELS_TEMPLATE against ${REPO_SLUG:-<unset>}"
  if [ ! -f "$LABELS_TEMPLATE" ]; then
    _fail check_labels "labels template missing at $LABELS_TEMPLATE" \
      "reinstall loop or restore the file from origin/main"
    return 1
  fi
  if [ -z "${REPO_SLUG:-}" ]; then
    _fail check_labels "REPO_SLUG is unset (loop.config missing or malformed)" \
      "fix .loop/loop.config first, then re-run"
    return 1
  fi

  local existing canonical missing name color desc created=0
  if ! existing=$(
    gh label list --repo "$REPO_SLUG" --json name --limit 200 2>/dev/null \
      | jq -r '.[].name'
  ); then
    _fail check_labels "could not list labels on $REPO_SLUG" \
      "run 'gh auth status' and confirm access"
    return 1
  fi
  canonical=$(jq -r '.[].name' "$LABELS_TEMPLATE")

  while IFS= read -r name; do
    [ -z "$name" ] && continue
    if ! printf '%s\n' "$existing" | grep -qFx "$name"; then
      color=$(jq -r --arg n "$name" '.[] | select(.name==$n) | .color' "$LABELS_TEMPLATE")
      desc=$( jq -r --arg n "$name" '.[] | select(.name==$n) | .description' "$LABELS_TEMPLATE")
      if gh label create "$name" --repo "$REPO_SLUG" \
            --color "$color" --description "$desc" >/dev/null 2>&1; then
        printf '  + created label %s\n' "$name"
        created=$((created + 1))
      else
        _fail check_labels "could not create label $name" \
          "run 'gh label create $name --repo $REPO_SLUG --color $color' manually"
        return 1
      fi
    fi
  done <<<"$canonical"

  if [ "$created" -gt 0 ]; then
    _pass "check_labels (created $created)"
  else
    _pass check_labels
  fi
}

# ---------------------------------------------------------------------------
# check_pre_commit_config
# ---------------------------------------------------------------------------
check_pre_commit_config() {
  local f
  for f in "$REPO_ROOT/.pre-commit-config.yaml" "$REPO_ROOT/.pre-commit-config.yml"; do
    _v "inspecting $f"
    if [ -f "$f" ]; then
      _pass check_pre_commit_config
      return 0
    fi
  done
  _fail check_pre_commit_config ".pre-commit-config.yaml not found at repo root" \
    "create one (see https://pre-commit.com) so dev-agent commits get auto-formatted"
}

# ---------------------------------------------------------------------------
# check_pre_commit_hook
# ---------------------------------------------------------------------------
check_pre_commit_hook() {
  local hook="$REPO_ROOT/.git/hooks/pre-commit"
  _v "inspecting $hook"
  if [ ! -f "$hook" ]; then
    _fail check_pre_commit_hook ".git/hooks/pre-commit not installed" \
      "run 'pre-commit install' to install the framework's hook"
    return 1
  fi
  if ! grep -qi 'pre-commit' "$hook"; then
    _fail check_pre_commit_hook "hook exists but has no 'pre-commit' marker (likely the stock sample)" \
      "run 'pre-commit install --overwrite'"
    return 1
  fi
  _pass check_pre_commit_hook
}

# ---------------------------------------------------------------------------
# check_workflows — at least one workflow runs on pull_request
# ---------------------------------------------------------------------------
check_workflows() {
  local dir="$REPO_ROOT/.github/workflows"
  _v "inspecting $dir"
  if [ ! -d "$dir" ]; then
    _fail check_workflows "no .github/workflows/ directory" \
      "add a CI workflow so PRs have a real merge signal"
    return 1
  fi
  local first
  first=$(find "$dir" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) \
            2>/dev/null | sort | head -n1)
  if [ -z "$first" ]; then
    _fail check_workflows "no .yml/.yaml workflow file in $dir" \
      "add a CI workflow file (e.g. ci.yml)"
    return 1
  fi
  _v "first workflow: $first"
  # Look for `pull_request` as a top-level on: trigger. Accepts both
  # block and inline forms (e.g. `on: [push, pull_request]`).
  if ! grep -qE '(^|[[:space:]])pull_request([[:space:]]*:|,|\])' "$first"; then
    _fail check_workflows "first workflow ($(basename "$first")) does not trigger on pull_request" \
      "add 'pull_request:' under the 'on:' key"
    return 1
  fi
  _pass check_workflows
}

# ---------------------------------------------------------------------------
# check_test_dir — `tests/` or `test/` exists with ≥1 regular file (recursive)
# ---------------------------------------------------------------------------
check_test_dir() {
  local d found=""
  for d in "$REPO_ROOT/tests" "$REPO_ROOT/test"; do
    _v "inspecting $d"
    if [ -d "$d" ]; then
      if [ -n "$(find "$d" -type f -print -quit 2>/dev/null)" ]; then
        found="$d"
        break
      fi
    fi
  done
  if [ -n "$found" ]; then
    _pass check_test_dir
  else
    _fail check_test_dir "no tests/ or test/ directory with at least one file" \
      "create tests/ and add at least one test so CI's signal is meaningful"
  fi
}

# ---------------------------------------------------------------------------
# check_worktree_base — WORKTREE_BASE is writable (or its parent is)
# ---------------------------------------------------------------------------
check_worktree_base() {
  local base="${WORKTREE_BASE:-/tmp/dev-agent}"
  _v "inspecting $base"
  # Already exists and writable → pass
  if [ -d "$base" ] && [ -w "$base" ]; then
    _pass check_worktree_base
    return 0
  fi
  # Try to create it; success means parent is writable
  if mkdir -p "$base" 2>/dev/null && [ -w "$base" ]; then
    _pass check_worktree_base
    return 0
  fi
  _fail check_worktree_base "WORKTREE_BASE ($base) is not writable" \
    "set WORKTREE_BASE in .loop/loop.config to a writable path (e.g. /tmp/dev-agent)"
}

# ---------------------------------------------------------------------------
# Aggregator
# ---------------------------------------------------------------------------
ONBOARD_CHECKS=(
  check_loop_config
  check_beads
  check_gh_auth
  check_labels
  check_pre_commit_config
  check_pre_commit_hook
  check_workflows
  check_test_dir
  check_worktree_base
)

onboard_run() {
  local fn rc=0
  for fn in "${ONBOARD_CHECKS[@]}"; do
    "$fn" || rc=1
  done
  return "$rc"
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1:-}" = "-v" ]; then
    ONBOARD_VERBOSE=1
    shift
  fi
  case "${1:-run}" in
    run)        onboard_run; exit $? ;;
    check_*)    "$1"; exit $? ;;
    -h|--help|help|"")
      cat <<'EOF'
Usage: onboard.sh [-v] <command>

Commands:
  run              Run all checks; exit 0 iff all pass.
  check_<name>     Run a single check; exit 0/1.

Available checks:
  check_loop_config         check_beads             check_gh_auth
  check_labels              check_pre_commit_config check_pre_commit_hook
  check_workflows           check_test_dir          check_worktree_base

Flags:
  -v               Verbose: print the path each check inspected.

Required env: REPO_ROOT, LOOP_HOME (set automatically when invoked via bin/st).
EOF
      exit 0 ;;
    *) echo "[onboard] unknown command: $1" >&2; exit 2 ;;
  esac
fi
