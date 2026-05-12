#!/usr/bin/env bats
# GH#173 — `triage_result` events carry duration_s + conflict_files +
# conflict_lines + triage_files_count.
#
# Pre-GH#173 the wrapper emitted `triage_result` with only pr/result/reason.
# The conflict file list and line count that triage already computed were
# stuck in a `[triage] result=…` stdout line that nothing machine-read, and
# there was no wall-clock timing on the triage step. This file pins:
#
#   1. Every `triage_result` event has a numeric `duration_s` field.
#   2. tractable + mechanical-conflict carries `conflict_files` (CSV string)
#      and `conflict_lines > 0` and `triage_files_count > 0`.
#   3. tractable + no-conflict carries `conflict_files=""` and
#      `conflict_lines=0` and `triage_files_count=0`.
#   4. untractable (e.g. test-file-conflict) and failed (rc=2) still carry
#      the count fields (defaulted to 0 / empty if triage couldn't compute).
#
# The wrapper extracts the counts from the LAST `[triage] result=` line in
# triage's stdout (same channel `loop_marker_last` consumes for `reason=`),
# so test stubs only need to echo a single line — no JSON sidecar required.

load 'helpers'

# Build a fake LOOP_HOME with a stubbed run-conflict-triage.sh that exits
# with the requested rc and prints the requested body. Mirrors the helper
# pattern in test_run_developer_triage_no_conflict.bats.
_make_loop_home_with_triage() {
  local triage_rc="$1" triage_body="$2"
  local fake="$BATS_TEST_TMPDIR/loop-home"
  rm -rf "$fake"
  mkdir -p "$fake/runners/lib" "$fake/templates"
  for f in "$LOOP_ROOT"/runners/*.sh; do
    [ -f "$f" ] || continue
    ln -sf "$f" "$fake/runners/$(basename "$f")"
  done
  for f in "$LOOP_ROOT"/runners/lib/*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$fake/runners/lib/$(basename "$f")"
  done
  for f in "$LOOP_ROOT"/templates/*; do
    [ -e "$f" ] || continue
    ln -sf "$f" "$fake/templates/$(basename "$f")"
  done
  rm -f "$fake/runners/run-conflict-triage.sh"
  {
    echo '#!/usr/bin/env bash'
    echo "echo $(printf %q "$triage_body")"
    echo "exit $triage_rc"
  } >"$fake/runners/run-conflict-triage.sh"
  chmod +x "$fake/runners/run-conflict-triage.sh"
  echo "$fake"
}

# PATH-mock `claude` (exits 0 — wrapper still reaches the post-LLM blocks)
# and `gh` (no-op stub so `pr view` calls in post-LLM paths don't try the
# network). Mirrors _make_path_stubs from test_run_developer_triage_no_conflict.
_make_path_stubs() {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat >"$tmpbin/claude" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$tmpbin/claude"
  cat >"$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
  chmod +x "$tmpbin/gh"
}

# Run the wrapper with LOOP_EVENT_LOG redirected to a per-test path so the
# `triage_result` event is observable from the test.
_run_wrapper_mode3() {
  local repo="$1" fake="$2" pr="${3:-7}"
  local logfile="$BATS_TEST_TMPDIR/events.jsonl"
  REPO_ROOT="$repo" LOOP_HOME="$fake" KEEP_ON_FAIL=0 \
    LOOP_EVENT_LOG="$logfile" SESSION="bats-triage-$$" \
    run env PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts "$pr"
  EVENT_LOG="$logfile"
}

# Extract the (single) `triage_result` event from the event log.
_triage_event() {
  jq -c 'select(.event == "triage_result")' "$EVENT_LOG"
}

# ---------------------------------------------------------------------------
# Acceptance: tractable + no-conflict
# ---------------------------------------------------------------------------

@test "triage_result(no-conflict): conflict_files=\"\", conflict_lines=0, triage_files_count=0, duration_s present (GH#173)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_triage 0 \
    '[triage] result=tractable reason=no-conflict issue=#7 conflict_files= conflict_lines=0 triage_files_count=0')
  _make_path_stubs
  _run_wrapper_mode3 "$repo" "$fake" 7

  [ "$status" -eq 0 ]
  local ev
  ev=$(_triage_event)
  [ -n "$ev" ] || { echo "no triage_result event found"; cat "$EVENT_LOG"; return 1; }

  jq -e 'select(.result == "tractable" and .reason == "no-conflict")' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_files == "")' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_lines == 0)' <<<"$ev" >/dev/null
  jq -e 'select(.triage_files_count == 0)' <<<"$ev" >/dev/null
  jq -e 'select(.duration_s | type == "number" and . >= 0)' <<<"$ev" >/dev/null
}

# ---------------------------------------------------------------------------
# Acceptance: tractable + mechanical-conflict (4-line, single file)
# ---------------------------------------------------------------------------

@test "triage_result(mechanical-conflict): conflict_files=\"requirements.txt\", conflict_lines=4, files_count=1 (GH#173)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_triage 0 \
    '[triage] result=tractable reason=mechanical-conflict-4-lines issue=#7 conflict_files=requirements.txt conflict_lines=4 triage_files_count=1')
  _make_path_stubs
  _run_wrapper_mode3 "$repo" "$fake" 7

  [ "$status" -eq 0 ]
  local ev
  ev=$(_triage_event)
  [ -n "$ev" ] || { echo "no triage_result event found"; cat "$EVENT_LOG"; return 1; }

  jq -e 'select(.result == "tractable")' <<<"$ev" >/dev/null
  # `reason` is the mechanical-conflict marker; we don't pin the full
  # "-N-lines" suffix here — the wrapper currently normalizes to
  # "mechanical-conflict" for the no-LLM emit path, but the test must
  # accept either form so the wrapper retains flexibility.
  jq -e 'select(.reason | startswith("mechanical-conflict"))' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_files == "requirements.txt")' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_lines == 4)' <<<"$ev" >/dev/null
  jq -e 'select(.triage_files_count == 1)' <<<"$ev" >/dev/null
  jq -e 'select(.duration_s | type == "number" and . >= 0)' <<<"$ev" >/dev/null
}

# ---------------------------------------------------------------------------
# Acceptance: tractable + mechanical-conflict with 2-file CSV
# ---------------------------------------------------------------------------

@test "triage_result(mechanical-conflict, 2 files): conflict_files CSV parses, triage_files_count=2 (GH#173)" {
  local repo fake
  repo=$(make_repo)
  fake=$(_make_loop_home_with_triage 0 \
    '[triage] result=tractable reason=mechanical-conflict-6-lines issue=#7 conflict_files=requirements.txt,foo.py conflict_lines=6 triage_files_count=2')
  _make_path_stubs
  _run_wrapper_mode3 "$repo" "$fake" 7

  [ "$status" -eq 0 ]
  local ev
  ev=$(_triage_event)
  [ -n "$ev" ]

  jq -e 'select(.conflict_files == "requirements.txt,foo.py")' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_lines == 6)' <<<"$ev" >/dev/null
  jq -e 'select(.triage_files_count == 2)' <<<"$ev" >/dev/null
  jq -e 'select(.duration_s | type == "number")' <<<"$ev" >/dev/null
}

# ---------------------------------------------------------------------------
# Acceptance: untractable (test-file-conflict)
# ---------------------------------------------------------------------------

@test "triage_result(untractable test-file-conflict): reason starts with 'test-file-conflict', counts still present (GH#173)" {
  local repo fake
  repo=$(make_repo)
  # Triage emits the conflict file and 0 lines when bailing on Rule 1
  # (test-file-conflict) — the line counter only runs after Rule 4. Pin
  # the realistic shape: files_count >= 1, conflict_lines may be 0.
  fake=$(_make_loop_home_with_triage 1 \
    '[triage] result=untractable reason=test-file-conflict:tests/test_foo.py issue=#7 conflict_files=tests/test_foo.py conflict_lines=0 triage_files_count=1')
  _make_path_stubs
  _run_wrapper_mode3 "$repo" "$fake" 7

  [ "$status" -eq 1 ]
  local ev
  ev=$(_triage_event)
  [ -n "$ev" ] || { echo "no triage_result event found"; cat "$EVENT_LOG"; return 1; }

  jq -e 'select(.result == "untractable")' <<<"$ev" >/dev/null
  jq -e 'select(.reason | startswith("test-file-conflict"))' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_files == "tests/test_foo.py")' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_lines == 0)' <<<"$ev" >/dev/null
  jq -e 'select(.triage_files_count == 1)' <<<"$ev" >/dev/null
  jq -e 'select(.duration_s | type == "number" and . >= 0)' <<<"$ev" >/dev/null
}

# ---------------------------------------------------------------------------
# Acceptance: failed (rc=2, transient gh/git outage, no [triage] result line)
# ---------------------------------------------------------------------------

@test "triage_result(failed): no [triage] result= line → counts default to 0/empty, duration_s still present (GH#173)" {
  local repo fake
  repo=$(make_repo)
  # rc=2 triage prints an error to stderr (caught by 2>&1) but does NOT
  # emit a `[triage] result=…` summary line — that's only emitted by emit().
  # Wrapper must default the count fields cleanly when the line is absent.
  fake=$(_make_loop_home_with_triage 2 \
    '[triage] error: cannot read PR #7')
  _make_path_stubs
  _run_wrapper_mode3 "$repo" "$fake" 7

  [ "$status" -eq 2 ]
  local ev
  ev=$(_triage_event)
  [ -n "$ev" ] || { echo "no triage_result event found"; cat "$EVENT_LOG"; return 1; }

  jq -e 'select(.result == "failed")' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_files == "")' <<<"$ev" >/dev/null
  jq -e 'select(.conflict_lines == 0)' <<<"$ev" >/dev/null
  jq -e 'select(.triage_files_count == 0)' <<<"$ev" >/dev/null
  jq -e 'select(.duration_s | type == "number" and . >= 0)' <<<"$ev" >/dev/null
}

# ---------------------------------------------------------------------------
# Source-of-truth: pin the new emit shape so a future refactor can't drop
# duration_s / conflict_* fields silently.
# ---------------------------------------------------------------------------

@test "run-developer.sh: every triage_result emit carries duration_s (GH#173)" {
  # All `event_emit dev triage_result` lines must include `duration_s=`.
  # awk reads multi-line continuations so an emit spread over two lines
  # is still matched as one logical statement.
  local missing
  missing=$(
    awk '
      /event_emit[[:space:]]+dev[[:space:]]+triage_result/ {
        line=$0
        while (line ~ /\\$/ && (getline next_line) > 0) { line = line " " next_line }
        if (line !~ /duration_s=/) print NR ": " line
      }
    ' "$LOOP_ROOT/runners/run-developer.sh"
  )
  [ -z "$missing" ] || { echo "triage_result emits missing duration_s:"; echo "$missing"; return 1; }
}

@test "run-developer.sh: every triage_result emit carries conflict_files/conflict_lines/triage_files_count (GH#173)" {
  local missing
  missing=$(
    awk '
      /event_emit[[:space:]]+dev[[:space:]]+triage_result/ {
        line=$0
        while (line ~ /\\$/ && (getline next_line) > 0) { line = line " " next_line }
        if (line !~ /conflict_files=/ || line !~ /conflict_lines=/ || line !~ /triage_files_count=/) print NR ": " line
      }
    ' "$LOOP_ROOT/runners/run-developer.sh"
  )
  [ -z "$missing" ] || { echo "triage_result emits missing conflict_files/conflict_lines/triage_files_count:"; echo "$missing"; return 1; }
}

@test "run-conflict-triage.sh: emit() prints triage_files_count alongside conflict_files/conflict_lines (GH#173)" {
  # The script's emit() must include all three fields so the wrapper can
  # parse them off the LAST `[triage] result=` line.
  grep -qE 'conflict_files=' "$LOOP_ROOT/runners/run-conflict-triage.sh"
  grep -qE 'conflict_lines=' "$LOOP_ROOT/runners/run-conflict-triage.sh"
  grep -qE 'triage_files_count=' "$LOOP_ROOT/runners/run-conflict-triage.sh"
}

@test "docs/event-schema.md documents duration_s + conflict_files + conflict_lines + triage_files_count on triage_result (GH#173)" {
  local schema="$LOOP_ROOT/docs/event-schema.md"
  # The schema row for triage_result must list the new fields.
  grep -qF 'triage_result' "$schema"
  grep -qF 'duration_s' "$schema"
  grep -qF 'conflict_files' "$schema"
  grep -qF 'conflict_lines' "$schema"
  grep -qF 'triage_files_count' "$schema"
}
