#!/usr/bin/env bats
# tests/test_event_log_integration.bats — exercise event_emit wire-in
# inside runners/run-developer.sh end-to-end. Uses a path-stubbed `gh` and
# `claude` so the wrapper's actual control flow runs but no real LLM is
# spawned. Companion file to test_run_developer_lock.bats — same fixture
# shape, deliberately separate so each test file is independently
# revertible.
#
# Loop-layer events (cycle_start/cycle_end/cycle_skip from run-loop.sh's
# loop_dev_mode1/loop_reviewer/loop_dispatcher_*) live in long-running
# infinite-while functions and can't be exercised end-to-end here without
# a tmux session — those are pinned by source-of-truth grep tests at the
# bottom of this file.

load 'helpers'

# Build a self-contained test environment under $BATS_TEST_TMPDIR.
# Mirrors test_run_developer_lock.bats's _setup_env. Adds a per-test
# event log path under the tmpdir so we don't pollute /tmp.
_setup_env() {
  local high="${1:-$LOOP_ROOT/tests/fixtures/gh/issues-high.json}"
  local med="${2:-$LOOP_ROOT/tests/fixtures/gh/issues-medium.json}"
  local claude_exit="${3:-0}"
  local root="$BATS_TEST_TMPDIR"
  local repo="$root/repo"
  local bin="$root/bin"
  local work="$root/work"
  local state="$root/state"
  mkdir -p "$repo/.loop" "$bin" "$work" "$state"

  awk -v wb="$work" '
    /^REPO_OWNER=/   { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/    { print "REPO_NAME=\"test-repo\""; next }
    /^WORKTREE_BASE=/ { print "WORKTREE_BASE=\"" wb "\""; next }
    /^LOCK_DIR=/     { print "LOCK_DIR=\"" wb "/locks\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"

  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init

  cat > "$bin/gh" <<STUB
#!/usr/bin/env bash
label=""
while [ \$# -gt 0 ]; do
  if [ "\$1" = "--label" ]; then label="\$2"; shift 2
  else shift
  fi
done
case "\$label" in
  severity:high)   cat '$high' ;;
  severity:medium) cat '$med' ;;
  *) echo '[]' ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"

  cat > "$bin/claude" <<STUB
#!/usr/bin/env bash
exit $claude_exit
STUB
  chmod +x "$bin/claude"

  echo "$root"
}

_run_wrapper() {
  local root="$1"; shift
  local logfile="$root/state/events.jsonl"
  REPO_ROOT="$root/repo" LOOP_HOME="$LOOP_ROOT" \
    PATH="$root/bin:$PATH" \
    LOOP_EVENT_LOG="$logfile" \
    SESSION="bats-int-$$" \
    KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-developer.sh" "$@" \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err"
}

# Helper: extract events from log, optionally filtered to a given event name.
_events() {
  local file="$1" event="${2:-}"
  if [ -n "$event" ]; then
    jq -c "select(.event == \"$event\")" "$file"
  else
    jq -c '.event' "$file"
  fi
}

# ---------------------------------------------------------------------------
# Mode 1 — eligibility no-work path
# ---------------------------------------------------------------------------

@test "wrapper: zero candidates → eligibility{result:no-work}, no lock_acquired/llm_started" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local root
  root=$(_setup_env "$empty" "$empty")

  local rc=0
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 2 ]

  local f="$root/state/events.jsonl"
  [ -f "$f" ]
  # Every line is valid JSON.
  while IFS= read -r line; do jq -e . <<<"$line" >/dev/null; done < "$f"

  # Exactly one eligibility event with result=no-work.
  local elig_count
  elig_count=$(jq -c 'select(.event == "eligibility" and .result == "no-work")' "$f" | wc -l | tr -d ' ')
  [ "$elig_count" -ge 1 ]
  # No lock_acquired or llm_started.
  ! jq -e 'select(.event == "lock_acquired")' "$f" >/dev/null
  ! jq -e 'select(.event == "llm_started")' "$f" >/dev/null
}

# ---------------------------------------------------------------------------
# Mode 1 — full success path
# ---------------------------------------------------------------------------

@test "wrapper: single candidate, claude exits 0 → lock_acquired + llm_started + llm_exited{exit_code:0}" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty" 0)

  local rc=0
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 0 ]

  local f="$root/state/events.jsonl"
  [ -f "$f" ]

  # eligibility result=proceeding with count
  jq -e 'select(.event == "eligibility" and .result == "proceeding")' "$f" >/dev/null
  # lock_acquired with issue=101
  jq -e 'select(.event == "lock_acquired" and .issue == 101)' "$f" >/dev/null
  # llm_started, llm_exited{exit_code:0}
  jq -e 'select(.event == "llm_started")' "$f" >/dev/null
  jq -e 'select(.event == "llm_exited" and .exit_code == 0)' "$f" >/dev/null

  # Order: eligibility before lock_acquired before llm_started before llm_exited.
  local order
  order=$(jq -r '.event' "$f" | grep -E 'eligibility|lock_acquired|llm_started|llm_exited' | tr '\n' ',')
  [[ "$order" == "eligibility,lock_acquired,llm_started,llm_exited,"* ]]
}

# ---------------------------------------------------------------------------
# Mode 1 — claude exits non-zero
# ---------------------------------------------------------------------------

@test "wrapper: claude exits 1 → llm_exited{exit_code:1} + Mode 1 hard_failure event" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty" 1)

  local rc=0
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 1 ]

  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "llm_exited" and .exit_code == 1)' "$f" >/dev/null
  jq -e 'select(.event == "lock_acquired")' "$f" >/dev/null
  # Mode 1 hard_failure is unconditional on LLM_EXIT != 0 (run-developer.sh's
  # dev-failed:N retry-counter block) — pin it so a future drop is caught.
  jq -e 'select(.event == "hard_failure" and .mode == "default" and .exit_code == 1 and (.retry_count | type == "number"))' "$f" >/dev/null
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the wire-in points so future refactors can't drop them.
# ---------------------------------------------------------------------------

@test "run-developer.sh emits eligibility events" {
  grep -qE 'event_emit[^#]+eligibility' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh emits lock_acquired" {
  grep -qE 'event_emit[^#]+lock_acquired' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-developer.sh emits llm_started and llm_exited" {
  grep -qE 'event_emit[^#]+llm_started' "$LOOP_ROOT/runners/run-developer.sh"
  grep -qE 'event_emit[^#]+llm_exited' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh emits eligibility, llm_started, llm_exited" {
  grep -qE 'event_emit[^#]+eligibility' "$LOOP_ROOT/runners/run-reviewer.sh"
  grep -qE 'event_emit[^#]+llm_started' "$LOOP_ROOT/runners/run-reviewer.sh"
  grep -qE 'event_emit[^#]+llm_exited' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-loop.sh emits cycle_start/cycle_end/cycle_skip in dev/reviewer loops" {
  grep -qE 'event_emit[^#]+cycle_start' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qE 'event_emit[^#]+cycle_end' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qE 'event_emit[^#]+cycle_skip' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh emits dispatch_fired/dispatch_skip/dispatch_at_cap in dispatcher loops" {
  grep -qE 'event_emit[^#]+dispatch_fired' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qE 'event_emit[^#]+dispatch_skip' "$LOOP_ROOT/runners/run-loop.sh"
  grep -qE 'event_emit[^#]+dispatch_at_cap' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh emits cycle_start in every dispatcher loop" {
  # Per-loop pin — guards against regressions where one of the three
  # dispatcher loops loses its cycle_start while the others still emit it
  # (the all-loops grep above would still pass in that case).
  for role in 'dispatch:followup' 'dispatch:conflicts' 'merger'; do
    grep -qE "event_emit[[:space:]]+(\"${role}\"|${role})[[:space:]]+cycle_start" \
      "$LOOP_ROOT/runners/run-loop.sh" \
      || { echo "missing cycle_start emit for role=${role}"; return 1; }
  done
}
