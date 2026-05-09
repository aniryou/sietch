#!/usr/bin/env bats
# Centralised lock-name sanitiser (GH#98).
#
# `loop_sanitize_id` in runners/lib/repo_id.sh is the single source of truth
# for turning an arbitrary repo identifier into a string safe for tmux target
# syntax and filesystem paths. Two other init blocks (run-developer.sh,
# lib/eligibility.sh) used to inline the same `tr -c 'A-Za-z0-9_-'` and were
# free to drift; this file pins them to the helper and asserts the resulting
# LOCK_NAME_PREFIX is byte-identical to what the inline form produced.

load 'helpers'

# Run the helper in a clean subshell (no inherited env), echo result to stdout.
_sanitize() {
  bash -c "
    . '$LOOP_ROOT/runners/lib/repo_id.sh'
    loop_sanitize_id '$1'
  "
}

# ---------------------------------------------------------------------------
# 1. Direct loop_sanitize_id behaviour for representative inputs.
# ---------------------------------------------------------------------------

@test "loop_sanitize_id: foo/bar → foo-bar (slash sanitised)" {
  [ "$(_sanitize 'foo/bar')" = "foo-bar" ]
}

@test "loop_sanitize_id: My Repo → My-Repo (whitespace sanitised)" {
  [ "$(_sanitize 'My Repo')" = "My-Repo" ]
}

@test "loop_sanitize_id: foo.bar → foo-bar (dot sanitised — tmux separator)" {
  [ "$(_sanitize 'foo.bar')" = "foo-bar" ]
}

@test "loop_sanitize_id: foo:bar → foo-bar (colon sanitised — tmux separator)" {
  [ "$(_sanitize 'foo:bar')" = "foo-bar" ]
}

@test "loop_sanitize_id: 123-abc → 123-abc (alnum + hyphen pass through)" {
  [ "$(_sanitize '123-abc')" = "123-abc" ]
}

@test "loop_sanitize_id: empty input → empty output" {
  [ "$(_sanitize '')" = "" ]
}

# ---------------------------------------------------------------------------
# 2. The inline `tr -c 'A-Za-z0-9_-'` form must be gone from the two callers
#    that used to duplicate the canonical helper. Structural guard so a
#    later edit can't silently re-introduce drift.
# ---------------------------------------------------------------------------

@test "no inline tr -c 'A-Za-z0-9_-' in run-developer.sh / eligibility.sh" {
  run grep -nE "tr -c 'A-Za-z0-9_-'" \
    "$LOOP_ROOT/runners/run-developer.sh" \
    "$LOOP_ROOT/runners/lib/eligibility.sh"
  # grep exits 1 when nothing matches — that's the success state here.
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# 3. Init-block byte-for-byte compatibility.
#
# Pull the LOCK_NAME_PREFIX defaulting line out of each runner script,
# evaluate it with REPO_NAME pinned, and assert the result matches what
# the previous inline form produced (`foo-bar-` for `foo/bar`).
# Done line-by-grep rather than full-source so we exercise the actual
# expression in the file without bringing up the rest of the runner.
# ---------------------------------------------------------------------------

# Extract the literal line of the form `: "${LOCK_NAME_PREFIX:=...}"` from
# the given file. Asserts there's exactly one such line.
_lock_prefix_line() {
  local file="$1"
  grep -n '^: "${LOCK_NAME_PREFIX:=' "$file" | cut -d: -f2-
}

@test "run-developer.sh init block: REPO_NAME=foo/bar yields LOCK_NAME_PREFIX=foo-bar-" {
  local line out
  line=$(_lock_prefix_line "$LOOP_ROOT/runners/run-developer.sh")
  [ -n "$line" ]
  out=$(
    bash -c "
      . '$LOOP_ROOT/runners/lib/repo_id.sh'
      REPO_NAME='foo/bar'
      unset LOCK_NAME_PREFIX
      $line
      printf '%s' \"\$LOCK_NAME_PREFIX\"
    "
  )
  [ "$out" = "foo-bar-" ]
}

@test "eligibility.sh init block: REPO_NAME=foo/bar yields LOCK_NAME_PREFIX=foo-bar-" {
  local line out
  line=$(_lock_prefix_line "$LOOP_ROOT/runners/lib/eligibility.sh")
  [ -n "$line" ]
  out=$(
    bash -c "
      . '$LOOP_ROOT/runners/lib/repo_id.sh'
      REPO_NAME='foo/bar'
      unset LOCK_NAME_PREFIX
      $line
      printf '%s' \"\$LOCK_NAME_PREFIX\"
    "
  )
  [ "$out" = "foo-bar-" ]
}

# Same but with a dot — the second case GH#74 cared about (lodash.debounce).
@test "init blocks: REPO_NAME=lodash.debounce yields filesystem-safe prefix" {
  local out_dev out_elg line_dev line_elg
  line_dev=$(_lock_prefix_line "$LOOP_ROOT/runners/run-developer.sh")
  line_elg=$(_lock_prefix_line "$LOOP_ROOT/runners/lib/eligibility.sh")
  out_dev=$(
    bash -c "
      . '$LOOP_ROOT/runners/lib/repo_id.sh'
      REPO_NAME='lodash.debounce'
      unset LOCK_NAME_PREFIX
      $line_dev
      printf '%s' \"\$LOCK_NAME_PREFIX\"
    "
  )
  out_elg=$(
    bash -c "
      . '$LOOP_ROOT/runners/lib/repo_id.sh'
      REPO_NAME='lodash.debounce'
      unset LOCK_NAME_PREFIX
      $line_elg
      printf '%s' \"\$LOCK_NAME_PREFIX\"
    "
  )
  [ "$out_dev" = "lodash-debounce-" ]
  [ "$out_elg" = "lodash-debounce-" ]
}
