#!/usr/bin/env bats
# GH#17 — runners/run-loop.sh dispatcher loops must re-source
# runners/lib/dispatcher.sh on every cycle, so a fix to the helper library
# takes effect without restarting the long-running tmux session.
#
# Two layers of coverage:
#   1. Pattern-in-isolation: a minimal `while`-loop fixture mirroring the
#      dispatcher pattern picks up an overwritten library on the next
#      iteration, AND falls back to cached helpers (with a WARN line) when
#      the library is mid-edit / syntactically broken.
#   2. Source-of-truth: run-loop.sh actually contains the re-source statement
#      inside both `loop_dispatcher_followup` and `loop_dispatcher_conflicts`
#      function bodies — not just at startup.
#
# We deliberately do NOT exercise the live tmux session here. Per the issue's
# test plan, the loop pattern is exercised in isolation; the static check
# guards against the re-source line being deleted from run-loop.sh later.

load 'helpers'

# ---------------------------------------------------------------------------
# Layer 1 — pattern in isolation
# ---------------------------------------------------------------------------

@test "re-source pattern: overwriting the library mid-loop is picked up next iteration" {
  local libdir="$BATS_TEST_TMPDIR/lib-$$"
  mkdir -p "$libdir"
  local lib="$libdir/dispatcher.sh"

  cat > "$lib" <<'SH'
_helper() { echo "v1"; }
SH

  # Drive 3 iterations, mutating the file between them.
  local out
  out=$(
    set -u
    # shellcheck source=/dev/null
    . "$lib"
    iter1=$(_helper)

    # Mid-run patch: ship a new helper.
    cat > "$lib" <<'SH2'
_helper() { echo "v2"; }
SH2

    # shellcheck source=/dev/null
    . "$lib" || echo "WARN_RESOURCE_FAILED"
    iter2=$(_helper)

    # Mid-run patch again — same channel.
    cat > "$lib" <<'SH3'
_helper() { echo "v3"; }
SH3

    # shellcheck source=/dev/null
    . "$lib" || echo "WARN_RESOURCE_FAILED"
    iter3=$(_helper)

    printf '%s|%s|%s\n' "$iter1" "$iter2" "$iter3"
  )

  [ "$out" = "v1|v2|v3" ]
}

@test "re-source pattern: broken library mid-run logs WARN and keeps cached helper" {
  local libdir="$BATS_TEST_TMPDIR/lib-broken-$$"
  mkdir -p "$libdir"
  local lib="$libdir/dispatcher.sh"

  cat > "$lib" <<'SH'
_helper() { echo "v1"; }
SH

  local out
  out=$(
    set -u
    # shellcheck source=/dev/null
    . "$lib"
    iter1=$(_helper)

    # Overwrite with syntactically-broken content (unterminated quote).
    printf '_helper() { echo "broken \n' > "$lib"

    # Re-source must NOT crash the loop; it must log WARN and continue.
    warn=""
    # shellcheck source=/dev/null
    . "$lib" 2>/dev/null || warn="WARN_RESOURCE_FAILED"
    iter2=$(_helper)

    printf '%s|%s|%s\n' "$iter1" "$iter2" "$warn"
  )

  # Cached v1 must survive; warn must fire.
  [ "$out" = "v1|v1|WARN_RESOURCE_FAILED" ]
}

# ---------------------------------------------------------------------------
# Layer 2 — source-of-truth: run-loop.sh actually has the re-source line in
# both dispatcher loop bodies.
# ---------------------------------------------------------------------------

# Print the body of a top-level shell function from run-loop.sh, naively
# delimited by `^<name>() {` ... matching closing `^}`. Good enough for this
# file's coding style (every function-defining `}` sits in column 0).
_extract_function_body() {
  local name="$1"
  awk -v name="$name" '
    $0 ~ ("^"name"\\(\\)[[:space:]]*\\{") { in_fn=1; next }
    in_fn && /^\}[[:space:]]*$/ { in_fn=0; exit }
    in_fn { print }
  ' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: loop_dispatcher_followup re-sources lib/dispatcher.sh inside its cycle" {
  local body
  body=$(_extract_function_body loop_dispatcher_followup)
  [ -n "$body" ]
  echo "$body" | grep -qE '\.[[:space:]]+"\$LOOP_HOME/runners/lib/dispatcher\.sh"'
}

@test "run-loop.sh: loop_dispatcher_conflicts re-sources lib/dispatcher.sh inside its cycle" {
  local body
  body=$(_extract_function_body loop_dispatcher_conflicts)
  [ -n "$body" ]
  echo "$body" | grep -qE '\.[[:space:]]+"\$LOOP_HOME/runners/lib/dispatcher\.sh"'
}

@test "run-loop.sh: re-source has graceful fallback (|| <warn>) so a broken library doesn't crash the pane" {
  # Both dispatcher loop bodies must guard the re-source with `||` so a
  # syntax error mid-edit logs a warning and keeps the cached helpers
  # rather than killing the loop.
  local body
  for fn in loop_dispatcher_followup loop_dispatcher_conflicts; do
    body=$(_extract_function_body "$fn")
    echo "$body" | grep -E '\.[[:space:]]+"\$LOOP_HOME/runners/lib/dispatcher\.sh"' \
      | grep -q '||'
  done
}

@test "run-loop.sh: startup source of lib/dispatcher.sh is unchanged (still hard-fails on broken library at start)" {
  # The line outside any function — i.e. before the first `loop_*()` definition
  # — must still source dispatcher.sh without `||`, so a broken library at
  # script start fails loudly (per acceptance criterion).
  awk '
    /^loop_[a-z_]+\(\)[[:space:]]*\{/ { exit }
    { print }
  ' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -E '^\.[[:space:]]+"\$LOOP_HOME/runners/lib/dispatcher\.sh"[[:space:]]*$' \
    | grep -qv '||'
}
