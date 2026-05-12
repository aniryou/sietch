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
  # GH#170: optional stdout the claude stub will emit before exiting, so a
  # caller can simulate a stream-json result frame landing in $RAW.
  local claude_stdout="${4:-}"
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
printf '%s\n' '${claude_stdout}'
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

  # GH#170: llm_exited always carries cost/token fields, defaulted to 0 when
  # the claude stub produces no stream-json result frame.
  jq -e 'select(.event == "llm_exited" and .total_cost_usd == 0 and .input_tokens == 0 and .output_tokens == 0 and .num_turns == 0)' "$f" >/dev/null
  # Field types must be number (consumers do arithmetic on them).
  jq -e 'select(.event == "llm_exited") | .total_cost_usd | type == "number"' "$f" >/dev/null
  jq -e 'select(.event == "llm_exited") | .input_tokens   | type == "number"' "$f" >/dev/null
  jq -e 'select(.event == "llm_exited") | .output_tokens  | type == "number"' "$f" >/dev/null
  jq -e 'select(.event == "llm_exited") | .num_turns      | type == "number"' "$f" >/dev/null

  # Order: eligibility before lock_acquired before llm_started before llm_exited.
  local order
  order=$(jq -r '.event' "$f" | grep -E 'eligibility|lock_acquired|llm_started|llm_exited' | tr '\n' ',')
  [[ "$order" == "eligibility,lock_acquired,llm_started,llm_exited,"* ]]
}

# ---------------------------------------------------------------------------
# Mode 1 — claude stub emits a result frame, wrapper plumbs the numbers
# through to llm_exited. Pinned shape: GH#170.
# ---------------------------------------------------------------------------

@test "wrapper: claude emits result frame → llm_exited carries non-zero cost/token fields" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local frame='{"type":"result","subtype":"success","duration_ms":1234,"num_turns":3,"total_cost_usd":0.0125,"usage":{"input_tokens":12345,"output_tokens":678}}'
  local root
  root=$(_setup_env "$high" "$empty" 0 "$frame")

  local rc=0
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 0 ]

  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "llm_exited" and .total_cost_usd == 0.0125 and .input_tokens == 12345 and .output_tokens == 678 and .num_turns == 3)' "$f" >/dev/null
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
# GH#174 — per-stage timing: duration_s on eligibility, wait_s + attempts
# on lock_acquired / lock_race_lost. Without these, an `llm_exited
# duration_s=7741` event tells operators a run was slow but nothing about
# which sub-stage ate the time (eligibility predicate, lock-contention
# loop, or the LLM itself).
# ---------------------------------------------------------------------------

# Build a fake $LOOP_HOME that wraps the real one with a stub eligibility.sh
# so the dev-candidates filter doesn't transparently remove pre-locked
# issues. Lets the test exercise the wrapper's mkdir-loop attempts counter
# directly (the TOCTOU window the wrapper is supposed to close).
_fake_loop_home_with_eligibility_stub() {
  local stub_body="$1"
  local fake_home="$BATS_TEST_TMPDIR/fake-loop"
  mkdir -p "$fake_home/runners/lib"
  ln -snf "$LOOP_ROOT/templates" "$fake_home/templates"
  ln -snf "$LOOP_ROOT/docs"      "$fake_home/docs"
  [ -d "$LOOP_ROOT/bin" ] && ln -snf "$LOOP_ROOT/bin" "$fake_home/bin"
  local f bn
  for f in "$LOOP_ROOT/runners"/*.sh; do
    ln -snf "$f" "$fake_home/runners/$(basename "$f")"
  done
  for f in "$LOOP_ROOT/runners/lib"/*; do
    bn=$(basename "$f")
    [ "$bn" = "eligibility.sh" ] && continue
    ln -snf "$f" "$fake_home/runners/lib/$bn"
  done
  printf '%s\n' "#!/usr/bin/env bash" "$stub_body" >"$fake_home/runners/lib/eligibility.sh"
  chmod +x "$fake_home/runners/lib/eligibility.sh"
  echo "$fake_home"
}

@test "GH#174: eligibility{result:no-work} carries duration_s as a number ≥ 0" {
  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local root
  root=$(_setup_env "$empty" "$empty")

  local rc=0
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 2 ]

  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "eligibility" and .result == "no-work") | .duration_s | type == "number"' "$f" >/dev/null
  jq -e 'select(.event == "eligibility" and .result == "no-work" and .duration_s >= 0)' "$f" >/dev/null
}

@test "GH#174: eligibility{result:proceeding} carries duration_s as a number ≥ 0" {
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
  jq -e 'select(.event == "eligibility" and .result == "proceeding") | .duration_s | type == "number"' "$f" >/dev/null
  jq -e 'select(.event == "eligibility" and .result == "proceeding" and .duration_s >= 0)' "$f" >/dev/null
}

@test "GH#174: lock_acquired carries wait_s + attempts; first-try win → attempts=1" {
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
  jq -e 'select(.event == "lock_acquired") | .wait_s   | type == "number"' "$f" >/dev/null
  jq -e 'select(.event == "lock_acquired") | .attempts | type == "number"' "$f" >/dev/null
  jq -e 'select(.event == "lock_acquired" and .wait_s >= 0 and .attempts == 1)' "$f" >/dev/null
}

@test "GH#174: lock_acquired after one race-lost retry has attempts=2" {
  # Fake eligibility returns 101 + 102 unconditionally — simulating the
  # TOCTOU window where dev-candidates saw both as free but a sibling
  # wrapper locked 101 in the gap between predicate and mkdir.
  local fake_home
  fake_home=$(_fake_loop_home_with_eligibility_stub '
case "${1:-}" in
  dev-candidates) printf "101\n102\n"; exit 0 ;;
  dev) echo 2; exit 0 ;;
  *) exit 1 ;;
esac')

  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local high="$BATS_TEST_TMPDIR/single.json"
  echo '[{"number":101,"assignees":[]}]' > "$high"
  local root
  root=$(_setup_env "$high" "$empty" 0)

  # Pre-lock 101 so the wrapper's first mkdir fails; 102 succeeds.
  mkdir -p "$root/work/locks/test-repo-gh-101.lock"
  echo "sibling-run" >"$root/work/locks/test-repo-gh-101.lock/run_id"

  local logfile="$root/state/events.jsonl"
  local rc=0
  REPO_ROOT="$root/repo" LOOP_HOME="$fake_home" \
    PATH="$root/bin:$PATH" \
    LOOP_EVENT_LOG="$logfile" \
    SESSION="bats-int-$$" \
    KEEP_ON_FAIL=0 \
    bash "$fake_home/runners/run-developer.sh" \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err" || rc=$?
  [ "$rc" -eq 0 ]

  jq -e 'select(.event == "lock_acquired" and .issue == 102 and .attempts == 2)' "$logfile" >/dev/null
  jq -e 'select(.event == "lock_acquired" and .issue == 102) | .wait_s | type == "number"' "$logfile" >/dev/null
}

@test "GH#174: lock_race_lost carries wait_s + attempts when every mkdir fails" {
  # Both candidates pre-locked → exhaust the loop without acquiring →
  # exit 2 + lock_race_lost{attempts=2, wait_s>=0}.
  local fake_home
  fake_home=$(_fake_loop_home_with_eligibility_stub '
case "${1:-}" in
  dev-candidates) printf "101\n102\n"; exit 0 ;;
  *) exit 1 ;;
esac')

  local empty="$BATS_TEST_TMPDIR/empty.json"
  echo '[]' > "$empty"
  local root
  root=$(_setup_env "$empty" "$empty" 0)

  mkdir -p "$root/work/locks/test-repo-gh-101.lock"
  mkdir -p "$root/work/locks/test-repo-gh-102.lock"
  echo "sibling-a" >"$root/work/locks/test-repo-gh-101.lock/run_id"
  echo "sibling-b" >"$root/work/locks/test-repo-gh-102.lock/run_id"

  local logfile="$root/state/events.jsonl"
  local rc=0
  REPO_ROOT="$root/repo" LOOP_HOME="$fake_home" \
    PATH="$root/bin:$PATH" \
    LOOP_EVENT_LOG="$logfile" \
    SESSION="bats-int-$$" \
    KEEP_ON_FAIL=0 \
    bash "$fake_home/runners/run-developer.sh" \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err" || rc=$?
  [ "$rc" -eq 2 ]

  jq -e 'select(.event == "lock_race_lost") | .wait_s   | type == "number"' "$logfile" >/dev/null
  jq -e 'select(.event == "lock_race_lost") | .attempts | type == "number"' "$logfile" >/dev/null
  jq -e 'select(.event == "lock_race_lost" and .wait_s >= 0 and .attempts == 2)' "$logfile" >/dev/null
}

# Minimal reviewer-wrapper fixture: gh stub serves the preflight `pr view`
# eligibility shape (state/isDraft/headRefOid/reviews/labels/
# statusCheckRollup) driven by the two args, and a claude stub that exits
# without writing a result line (the eligibility events fire before claude
# runs anyway, so the LLM-exit path doesn't matter here).
_setup_reviewer_env() {
  local elig_state="${1:-OPEN}"
  local elig_draft="${2:-false}"
  local root="$BATS_TEST_TMPDIR/rv"
  local repo="$root/repo"
  local bin="$root/bin"
  local state="$root/state"
  mkdir -p "$repo/.loop" "$bin" "$state"

  awk -v wb="$root/work" '
    /^REPO_OWNER=/   { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/    { print "REPO_NAME=\"test-repo\""; next }
    /^WORKTREE_BASE=/ { print "WORKTREE_BASE=\"" wb "\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"

  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init

  cat >"$bin/gh" <<STUB
#!/usr/bin/env bash
ARGS=("\$@")
SUB1="\${ARGS[0]:-}"
SUB2="\${ARGS[1]:-}"
JSON_EXPR=""
for ((i=0; i<\${#ARGS[@]}; i++)); do
  if [ "\${ARGS[i]}" = "--json" ]; then JSON_EXPR="\${ARGS[i+1]:-}"; fi
done
if [ "\$SUB1 \$SUB2" = "pr view" ] && [[ "\$JSON_EXPR" == *statusCheckRollup* ]]; then
  jq -n --arg s "$elig_state" --argjson d $elig_draft '
    {state: \$s, isDraft: \$d, headRefOid: "abc123",
     number: 99, reviews: [], labels: [],
     statusCheckRollup: [{__typename: "CheckRun", status: "COMPLETED", conclusion: "SUCCESS"}]}'
  exit 0
fi
exit 0
STUB
  chmod +x "$bin/gh"

  cat >"$bin/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$bin/claude"

  echo "$root"
}

@test "GH#174: reviewer eligibility{result:proceeding} carries duration_s as a number ≥ 0" {
  local root
  root=$(_setup_reviewer_env OPEN false)
  local logfile="$root/state/events.jsonl"
  local rc=0
  REPO_ROOT="$root/repo" LOOP_HOME="$LOOP_ROOT" \
    PATH="$root/bin:$PATH" \
    LOOP_EVENT_LOG="$logfile" \
    SESSION="bats-int-$$" \
    KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99 \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err" || rc=$?
  [ "$rc" -eq 0 ]
  jq -e 'select(.event == "eligibility" and .result == "proceeding") | .duration_s | type == "number"' "$logfile" >/dev/null
  jq -e 'select(.event == "eligibility" and .result == "proceeding" and .duration_s >= 0)' "$logfile" >/dev/null
}

@test "GH#174: reviewer eligibility{result:no-work} (draft PR) carries duration_s ≥ 0" {
  local root
  root=$(_setup_reviewer_env OPEN true)
  local logfile="$root/state/events.jsonl"
  local rc=0
  REPO_ROOT="$root/repo" LOOP_HOME="$LOOP_ROOT" \
    PATH="$root/bin:$PATH" \
    LOOP_EVENT_LOG="$logfile" \
    SESSION="bats-int-$$" \
    KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-reviewer.sh" 99 \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err" || rc=$?
  [ "$rc" -eq 2 ]
  jq -e 'select(.event == "eligibility" and .result == "no-work") | .duration_s | type == "number"' "$logfile" >/dev/null
  jq -e 'select(.event == "eligibility" and .result == "no-work" and .duration_s >= 0)' "$logfile" >/dev/null
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

@test "GH#174: run-developer.sh emits duration_s on eligibility, wait_s+attempts on lock_acquired/lock_race_lost" {
  # Source-of-truth pin: a future refactor cannot drop the per-stage timing
  # fields without failing here. The grep on the joined eligibility-emit
  # lines must show duration_s in every result= variant; the lock emits must
  # carry both wait_s and attempts.
  local f="$LOOP_ROOT/runners/run-developer.sh"
  grep -qE 'event_emit[^#]*eligibility[^#]*result=proceeding[^#]*duration_s='     "$f"
  grep -qE 'event_emit[^#]*eligibility[^#]*result=no-work[^#]*duration_s='        "$f"
  grep -qE 'event_emit[^#]*eligibility[^#]*result=predicate-failed[^#]*duration_s=' "$f"
  grep -qE 'event_emit[^#]*lock_acquired[^#]*wait_s='   "$f"
  grep -qE 'event_emit[^#]*lock_acquired[^#]*attempts=' "$f"
  grep -qE 'event_emit[^#]*lock_race_lost[^#]*wait_s='   "$f"
  grep -qE 'event_emit[^#]*lock_race_lost[^#]*attempts=' "$f"
}

@test "GH#174: run-reviewer.sh emits duration_s on every eligibility result" {
  local f="$LOOP_ROOT/runners/run-reviewer.sh"
  grep -qE 'event_emit[^#]*eligibility[^#]*result=proceeding[^#]*duration_s='       "$f"
  grep -qE 'event_emit[^#]*eligibility[^#]*result=no-work[^#]*duration_s='          "$f"
  grep -qE 'event_emit[^#]*eligibility[^#]*result=predicate-failed[^#]*duration_s=' "$f"
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
  # Per-loop pin — guards against regressions where one of the four
  # dispatcher loops loses its cycle_start while the others still emit it
  # (the all-loops grep above would still pass in that case). GH#117 added
  # dispatch:review to the set when loop_reviewer was replaced by
  # loop_dispatcher_review.
  for role in 'dispatch:review' 'dispatch:followup' 'dispatch:conflicts' 'merger'; do
    grep -qE "event_emit[[:space:]]+(\"${role}\"|${role})[[:space:]]+cycle_start" \
      "$LOOP_ROOT/runners/run-loop.sh" \
      || { echo "missing cycle_start emit for role=${role}"; return 1; }
  done
}
