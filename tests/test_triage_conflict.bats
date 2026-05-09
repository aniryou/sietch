#!/usr/bin/env bats
# run-conflict-triage.sh — rule-pattern + line-counter coverage.
#
# The full script invokes `gh pr view` and `git rebase` against a real remote;
# end-to-end coverage requires standing up an upstream + clone fixture and
# is deferred to a follow-on issue. These tests cover the deterministic
# pieces: the file-classification regexes and the conflict-line counter.

load 'helpers'

setup() {
  REPO=$(make_repo)
  # Source the loop.config to expose the regexes the script uses.
  # shellcheck disable=SC1091
  . "$REPO/.loop/loop.config"
}

# ---------------------------------------------------------------------------
# File-classification regexes (Rules 1–3)
# ---------------------------------------------------------------------------

@test "TESTS_REGEX matches typical pytest layouts" {
  for f in tests/test_foo.py test/foo_test.py app/tests/inner/test_x.py foo_test.py; do
    echo "$f" | grep -qE "$TRIAGE_TESTS_REGEX" || { echo "missed: $f" >&2; return 1; }
  done
}

@test "TESTS_REGEX does NOT match plain source paths" {
  for f in src/foo.py app/handlers.py utils/helpers.py; do
    if echo "$f" | grep -qE "$TRIAGE_TESTS_REGEX"; then
      echo "false-positive: $f" >&2; return 1
    fi
  done
  # NOTE: TESTS_REGEX is intentionally permissive — paths like
  # lib/test_helpers/util.py DO match (the `test_.*\.py$` clause uses a
  # greedy `.*`). Rejecting more conflicts as untractable is the safer
  # default, so we don't assert against those edge cases.
}

@test "CI_SECRETS_REGEX matches workflow files and secret-like paths" {
  for f in .github/workflows/ci.yml .env infra/credentials.json my.secrets; do
    echo "$f" | grep -qE "$TRIAGE_CI_SECRETS_REGEX" || { echo "missed: $f" >&2; return 1; }
  done
}

@test "CORE_FILES_REGEX matches Dockerfile and pre-commit config at repo root" {
  echo "Dockerfile"               | grep -qE "$TRIAGE_CORE_FILES_REGEX"
  echo ".pre-commit-config.yaml"  | grep -qE "$TRIAGE_CORE_FILES_REGEX"
}

@test "CORE_FILES_REGEX does NOT match nested Dockerfile paths" {
  ! echo "subdir/Dockerfile" | grep -qE "$TRIAGE_CORE_FILES_REGEX"
}

# ---------------------------------------------------------------------------
# Conflict-line counter (Rule 4) — loop-s3g semantics: counts BOTH sides
# ---------------------------------------------------------------------------
# Mirrors the algorithm at runners/run-conflict-triage.sh:Rule 4 exactly.
count_conflict_lines() {
  local file="$1"
  local in_conflict=0 lines=0
  while IFS= read -r line; do
    case "$line" in
      "<<<<<<< "*) in_conflict=1 ;;
      ">>>>>>> "*) in_conflict=0 ;;
      "=======")   ;; # separator — does NOT toggle (intentional)
      *)
        if [ "$in_conflict" = "1" ]; then
          lines=$((lines + 1))
        fi
        ;;
    esac
  done < "$file"
  echo "$lines"
}

@test "counter: symmetric 5+5 conflict counts as 10 (ours+theirs)" {
  local n
  n=$(count_conflict_lines "$LOOP_ROOT/tests/fixtures/conflict-symmetric-5x5.txt")
  [ "$n" -eq 10 ]
}

@test "counter: tiny 1+1 conflict counts as 2" {
  local n
  n=$(count_conflict_lines "$LOOP_ROOT/tests/fixtures/conflict-tiny.txt")
  [ "$n" -eq 2 ]
}

@test "counter: 5+5 conflict stays within TRIAGE_LINE_LIMIT" {
  # The "counts both sides" semantic (n=10 for a 5-vs-5 conflict) is already
  # asserted at lines 77-81. Here we only assert it sits below the
  # configured cap, so this test stays valid as TRIAGE_LINE_LIMIT moves.
  local n
  n=$(count_conflict_lines "$LOOP_ROOT/tests/fixtures/conflict-symmetric-5x5.txt")
  [ "$n" -le "$TRIAGE_LINE_LIMIT" ]
}

# ---------------------------------------------------------------------------
# CLI shape
# ---------------------------------------------------------------------------
@test "run-conflict-triage.sh exits 2 on missing PR arg" {
  REPO_ROOT="$REPO" LOOP_HOME="$LOOP_ROOT" \
    run bash "$LOOP_ROOT/runners/run-conflict-triage.sh"
  [ "$status" -eq 2 ]
  echo "$output" | grep -qF 'Usage:'
}

@test "run-conflict-triage.sh exits 2 on non-numeric PR arg" {
  REPO_ROOT="$REPO" LOOP_HOME="$LOOP_ROOT" \
    run bash "$LOOP_ROOT/runners/run-conflict-triage.sh" not-a-number
  [ "$status" -eq 2 ]
}
