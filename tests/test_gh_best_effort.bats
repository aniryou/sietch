#!/usr/bin/env bats
# gh_helpers.sh — gh_best_effort logs failures of best-effort gh recovery
# calls without changing their semantics (always returns 0). Replaces the
# `gh ... >/dev/null 2>&1 || true` pattern in run-developer.sh that hid
# network/auth/rate-limit failures from operators (GH#99).

load 'helpers'

setup() {
  # shellcheck disable=SC1091
  source "$LOOP_ROOT/runners/lib/gh_helpers.sh"
}

# ---------------------------------------------------------------------------
# Unit-style: PATH-mock `gh`, exercise the helper directly.
# ---------------------------------------------------------------------------

@test "gh_best_effort: success path emits no breadcrumb, returns 0" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$tmpbin/gh"

  local stderr_file="$BATS_TEST_TMPDIR/stderr-success"
  PATH="$tmpbin:$PATH" gh_best_effort gh pr comment 99 --body x 2>"$stderr_file"
  local rc=$?
  [ "$rc" -eq 0 ]
  [ ! -s "$stderr_file" ]
}

@test "gh_best_effort: failure emits one breadcrumb on stderr, still returns 0" {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
echo "internal gh error noise" >&2
exit 1
STUB
  chmod +x "$tmpbin/gh"

  local stderr_file="$BATS_TEST_TMPDIR/stderr-fail"
  PATH="$tmpbin:$PATH" gh_best_effort gh pr comment 99 --body x 2>"$stderr_file"
  local rc=$?
  [ "$rc" -eq 0 ]

  # Exactly one line — gh's own stderr is suppressed (not propagated),
  # only the helper's own breadcrumb is emitted.
  local lines
  lines=$(wc -l <"$stderr_file" | tr -d ' ')
  [ "$lines" -eq 1 ]
  grep -qF '[wrapper] gh-best-effort FAILED' "$stderr_file"
  grep -qF 'rc=1' "$stderr_file"
  grep -qF 'cmd="gh pr comment 99 --body x"' "$stderr_file"
  ! grep -qF 'internal gh error noise' "$stderr_file"
}

@test "gh_best_effort: non-1 failure rc value is preserved in the breadcrumb" {
  # Guard against future regressions that hardcode rc=1; gh exits 4 on auth
  # failures, 7 on network errors, etc., and the operator needs the actual rc.
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
exit 7
STUB
  chmod +x "$tmpbin/gh"

  local stderr_file="$BATS_TEST_TMPDIR/stderr-rc7"
  PATH="$tmpbin:$PATH" gh_best_effort gh pr ready --undo 99 2>"$stderr_file"
  local rc=$?
  [ "$rc" -eq 0 ]
  grep -qF 'rc=7' "$stderr_file"
  grep -qF 'cmd="gh pr ready --undo 99"' "$stderr_file"
}

@test "gh_best_effort: caller under set -e is not aborted by gh failure" {
  # The whole point of the helper is that callers can use it without
  # `|| true` boilerplate, including under `set -e`. Confirm the function's
  # `cmd || rc=$?` shape doesn't trip errexit.
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$tmpbin/gh"

  set -e
  PATH="$tmpbin:$PATH" gh_best_effort gh pr comment 99 --body x 2>/dev/null
  local rc=$?
  set +e
  [ "$rc" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Source-of-truth: confirm run-developer.sh sources the helper and migrates
# the four enumerated best-effort sites away from the raw `|| true` shape.
# These wrap the unit tests above into an integration assertion: the helper
# only matters if the wrapper actually uses it.
# ---------------------------------------------------------------------------

@test "run-developer.sh sources gh_helpers.sh" {
  grep -qF 'lib/gh_helpers.sh' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh: four best-effort sites use gh_best_effort" {
  # GH#99 enumerates exactly four sites: 2 × `gh pr ready --undo` and
  # 2 × `gh pr comment` (Mode 3 triage-untractable draft, Mode 3 hard-fail
  # draft + comment, Mode 2 follow-up hard-fail comment).
  local n_ready n_comment
  n_ready=$(grep -cE 'gh_best_effort gh pr ready --undo' "$LOOP_ROOT/runners/run-developer.sh")
  n_comment=$(grep -cE 'gh_best_effort gh pr comment' "$LOOP_ROOT/runners/run-developer.sh")
  [ "$n_ready" -ge 2 ]
  [ "$n_comment" -ge 2 ]
}

@test "run-developer.sh: no remaining single-line gh pr comment/ready with raw '|| true'" {
  # Single-line `gh pr (comment|ready --undo) ... >/dev/null 2>&1 || true`
  # sites are exactly the four GH#99 targets. The dev-failed:N label
  # maintenance lines use `gh issue edit`/`gh issue comment` (out of scope
  # per GH#99), so this regex is precise. The triage-comment heredoc at
  # ~line 327 is multi-line and therefore not matched.
  ! grep -E 'gh pr (comment|ready --undo).*>/dev/null 2>&1 \|\| true' \
    "$LOOP_ROOT/runners/run-developer.sh"
}

@test "gh_best_effort sourced under set -e: integration with wrapper-style invocation" {
  # Mirror the wrapper's invocation shape: source the helper file, then call
  # it with `gh pr comment <N> ...` against a stub that returns rc=1.
  # Confirm the breadcrumb hits stderr exactly once and rc is 0.
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$tmpbin/gh"

  local script="$BATS_TEST_TMPDIR/wrapper-fragment.sh"
  cat >"$script" <<EOF
#!/usr/bin/env bash
set -u
set -o pipefail
source "$LOOP_ROOT/runners/lib/gh_helpers.sh"
gh_best_effort gh pr comment 9 --body "auto-resolution declined"
gh_best_effort gh pr ready --undo 9
EOF
  chmod +x "$script"

  local out_file="$BATS_TEST_TMPDIR/integration-stderr"
  PATH="$tmpbin:$PATH" "$script" 2>"$out_file"
  local rc=$?
  [ "$rc" -eq 0 ]
  # Two failed gh invocations → two breadcrumbs.
  local lines
  lines=$(grep -c 'gh-best-effort FAILED' "$out_file")
  [ "$lines" -eq 2 ]
}
