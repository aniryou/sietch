#!/usr/bin/env bash
# Triage a PR's merge conflict against main and decide if it's safe for
# autonomous resolution by the dev-agent (Mode 3).
#
# Strict-mode rules — if ANY are true the conflict is UNTRACTABLE:
#   - any conflict in a test file (tests/, test_*.py, *_test.py)
#   - any conflict in CI / secrets / .github / .env
#   - any conflict in core code files (eval.py, Dockerfile, .pre-commit-config.yaml)
#   - total conflict lines (ours + theirs combined, summed across files) > 10
#
# Otherwise: TRACTABLE.
#
# The rebase is probed in a temporary worktree at /tmp/dev-agent/triage-pr<PR>;
# the main repo and the PR's remote branch are NOT modified.
#
# Usage: st triage <PR#>
# Exit:  0 = tractable, 1 = untractable, 2 = misuse / setup error.
#
# Contract: the wrapper at runners/run-developer.sh branches on this exit code
# with an explicit three-way `case` (rc=0 → invoke LLM, rc=1 → draft PR + post
# auto-resolution-declined comment, rc=2 → exit only / no PR-state mutation).
# Conflating rc=1 and rc=2 into a single "untractable" arm regresses GH#57:
# transient gh/git outages permanently draft the PR with a misleading
# explanation. If you change the exit codes here, update the wrapper's case
# arms in lockstep.

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.loop/loop.config"

CORE_FILES_REGEX="$TRIAGE_CORE_FILES_REGEX"
TESTS_REGEX="$TRIAGE_TESTS_REGEX"
CI_SECRETS_REGEX="$TRIAGE_CI_SECRETS_REGEX"
LINE_LIMIT="$TRIAGE_LINE_LIMIT"

usage() {
  echo "Usage: $0 <PR#>" >&2
  exit 2
}

PR="${1:-}"
[[ "$PR" =~ ^[0-9]+$ ]] || usage

TMP="${WORKTREE_BASE}/triage-pr${PR}"

# shellcheck disable=SC2329 # invoked via trap
cleanup() {
  cd "$REPO" 2>/dev/null || cd /
  git -C "$REPO" worktree remove --force "$TMP" 2>/dev/null || true
  rm -rf "$TMP" 2>/dev/null || true
  git -C "$REPO" worktree prune 2>/dev/null || true
}
trap cleanup EXIT INT TERM

emit() {
  local result="$1"
  shift
  local reason="$1"
  shift
  echo "[triage] result=${result} reason=${reason} issue=#${ISSUE_NUM:-unknown} conflict_files=${CONFLICT_FILES_CSV:-} conflict_lines=${CONFLICT_LINES:-0}"
}

# Step 1: read PR metadata
PR_JSON=$(gh pr view "$PR" --repo "$REPO_SLUG" --json headRefName,body,baseRefName 2>/dev/null) || {
  echo "[triage] error: cannot read PR #${PR}" >&2
  exit 2
}
HEAD_REF=$(echo "$PR_JSON" | jq -r .headRefName)
BASE_REF=$(echo "$PR_JSON" | jq -r .baseRefName)
PR_BODY=$(echo "$PR_JSON" | jq -r .body)
ISSUE_NUM=$(echo "$PR_BODY" | grep -oE 'Closes #[0-9]+' | head -1 | grep -oE '[0-9]+' || echo unknown)

# Step 2: fetch and prepare temp worktree
git -C "$REPO" fetch origin --quiet || {
  echo "[triage] error: git fetch failed" >&2
  exit 2
}
mkdir -p "$WORKTREE_BASE"
git -C "$REPO" worktree add --detach "$TMP" "origin/${HEAD_REF}" >/dev/null 2>&1 || {
  echo "[triage] error: cannot create worktree at ${TMP}" >&2
  exit 2
}

# Step 3: probe rebase
if git -C "$TMP" rebase "origin/${BASE_REF}" >/dev/null 2>&1; then
  CONFLICT_FILES_CSV=""
  CONFLICT_LINES=0
  emit tractable no-conflict
  exit 0
fi

# Rebase failed — examine conflicts.
# Use a while-read loop instead of `mapfile` for bash 3.2 (macOS) compatibility.
CONFLICT_FILES=()
while IFS= read -r file; do
  [ -n "$file" ] && CONFLICT_FILES+=("$file")
done < <(git -C "$TMP" diff --name-only --diff-filter=U)

if [ ${#CONFLICT_FILES[@]} -eq 0 ]; then
  # Defensive: rebase failed but no unmerged files reported. Shouldn't happen, but bail.
  CONFLICT_FILES_CSV=""
  CONFLICT_LINES=0
  emit untractable "rebase-failed-no-unmerged-files"
  exit 1
fi

CONFLICT_FILES_CSV=$(
  IFS=,
  echo "${CONFLICT_FILES[*]}"
)

# Rule 1: test files — never
for f in "${CONFLICT_FILES[@]}"; do
  if echo "$f" | grep -qE "$TESTS_REGEX"; then
    emit untractable "test-file-conflict:${f}"
    exit 1
  fi
done

# Rule 2: CI / secrets — never
for f in "${CONFLICT_FILES[@]}"; do
  if echo "$f" | grep -qE "$CI_SECRETS_REGEX"; then
    emit untractable "ci-or-secrets-conflict:${f}"
    exit 1
  fi
done

# Rule 3: core code files — never
for f in "${CONFLICT_FILES[@]}"; do
  if echo "$f" | grep -qE "$CORE_FILES_REGEX"; then
    emit untractable "core-file-conflict:${f}"
    exit 1
  fi
done

# Rule 4: total conflict lines.
# Counts every non-marker line inside a conflict region — both the "ours"
# and "theirs" sides. The ======= separator does NOT toggle in_conflict,
# so a 5-vs-5 symmetric conflict contributes 10 lines. This is intentional
# (conservative); see TRIAGE_LINE_LIMIT in loop.config.example.
CONFLICT_LINES=0
for f in "${CONFLICT_FILES[@]}"; do
  in_conflict=0
  while IFS= read -r line; do
    case "$line" in
      "<<<<<<< "*) in_conflict=1 ;;
      ">>>>>>> "*) in_conflict=0 ;;
      "=======") ;; # separator — don't count, don't toggle (intentional)
      *)
        if [ "$in_conflict" = "1" ]; then
          CONFLICT_LINES=$((CONFLICT_LINES + 1))
        fi
        ;;
    esac
  done <"${TMP}/${f}"
done

if [ "$CONFLICT_LINES" -gt "$LINE_LIMIT" ]; then
  emit untractable "too-many-conflict-lines:${CONFLICT_LINES}"
  exit 1
fi

emit tractable "mechanical-conflict-${CONFLICT_LINES}-lines"
exit 0
