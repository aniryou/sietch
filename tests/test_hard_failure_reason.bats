#!/usr/bin/env bats
# GH#171 — `reason` field on `hard_failure` events.
#
# Pre-GH#171 every `hard_failure` event recorded only `exit_code=1` (or
# whichever non-zero code claude returned), conflating wildly different
# failure modes — claude `--max-turns`, claude API/network error, OOM
# kill, Mode 2 give-up, Mode 3 give-up, reviewer no-result-line — into
# one indistinguishable signal. This file pins the contract that:
#
#   1. `classify_llm_failure_reason` returns the documented enum value
#      for every input the wrapper calls it with.
#   2. Each `hard_failure` emit site in `run-developer.sh` passes a
#      `reason=<value>` from the closed enum:
#        - Mode 1 (line 579): classified from LLM_EXIT / raw / stderr.
#        - Mode 2 (line 758): always `mode2-give-up`.
#        - Mode 3 (line 712): always `mode3-give-up`.
#   3. `run-reviewer.sh` keeps emitting `reason=no-result-line` on the
#      already-existing site (regression guard).
#   4. `docs/event-schema.md` documents the enum.

load 'helpers'

# ---------------------------------------------------------------------------
# Unit tests — classify_llm_failure_reason() in runners/lib/hard_failure.sh.
# ---------------------------------------------------------------------------

_classify() {
  bash -c '. "'"$LOOP_ROOT"'/runners/lib/hard_failure.sh"; classify_llm_failure_reason "$@"' _ "$@"
}

@test "classify: exit 124 → max-turns (GNU timeout signal proxy)" {
  [ "$(_classify 124 '' '')" = "max-turns" ]
}

@test "classify: exit 137 → pipeline-crash (SIGKILL / OOM)" {
  [ "$(_classify 137 '' '')" = "pipeline-crash" ]
}

@test "classify: exit 143 → pipeline-crash (SIGTERM)" {
  [ "$(_classify 143 '' '')" = "pipeline-crash" ]
}

@test "classify: exit 1 → api-error (claude's generic non-zero)" {
  [ "$(_classify 1 '' '')" = "api-error" ]
}

@test "classify: exit 2 → api-error" {
  [ "$(_classify 2 '' '')" = "api-error" ]
}

@test "classify: exit 99 (unrecognized) → unknown" {
  [ "$(_classify 99 '' '')" = "unknown" ]
}

@test "classify: raw stream-json with error_max_turns marker wins over exit code 1" {
  local raw="$BATS_TEST_TMPDIR/raw.jsonl"
  cat >"$raw" <<'EOF'
{"type":"system","subtype":"init","model":"mock"}
{"type":"result","subtype":"error_max_turns","duration_ms":120000}
EOF
  [ "$(_classify 1 "$raw" '')" = "max-turns" ]
}

@test "classify: raw stream-json with max_turns_exceeded marker wins over exit 99" {
  local raw="$BATS_TEST_TMPDIR/raw.jsonl"
  printf '{"type":"result","is_error":true,"reason":"max_turns_exceeded"}\n' >"$raw"
  [ "$(_classify 99 "$raw" '')" = "max-turns" ]
}

@test "classify: stderr 'max turns' phrase wins over exit code 1 when raw has no marker" {
  local raw="$BATS_TEST_TMPDIR/raw.jsonl" err="$BATS_TEST_TMPDIR/raw.stderr"
  printf '{"type":"system","subtype":"init"}\n' >"$raw"
  printf 'Error: maximum turns reached (200/200)\n' >"$err"
  [ "$(_classify 1 "$raw" "$err")" = "max-turns" ]
}

@test "classify: missing raw/stderr paths fall through to exit-code heuristic" {
  [ "$(_classify 124 '/nope/nope' '/nope/nope')" = "max-turns" ]
  [ "$(_classify 1   '/nope/nope' '/nope/nope')" = "api-error" ]
}

# ---------------------------------------------------------------------------
# Wrapper integration — Mode 1 / Mode 2 / Mode 3 each emit a `reason` value
# from the documented enum on `hard_failure`.
#
# Stubs claude (configurable exit) and gh (no-op + records argv). Uses the
# same shape as test_event_log_integration.bats so the wrapper actually
# runs end-to-end and writes events to a per-test LOOP_EVENT_LOG.
# ---------------------------------------------------------------------------

_setup_wrapper_env() {
  local claude_exit="${1:-1}"
  local root="$BATS_TEST_TMPDIR"
  local repo="$root/repo"
  local bin="$root/bin"
  local work="$root/work"
  local state="$root/state"
  mkdir -p "$repo/.loop" "$bin" "$work" "$state"

  awk -v wb="$work" '
    /^REPO_OWNER=/    { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/     { print "REPO_NAME=\"test-repo\""; next }
    /^WORKTREE_BASE=/ { print "WORKTREE_BASE=\"" wb "\""; next }
    /^LOCK_DIR=/      { print "LOCK_DIR=\"" wb "/locks\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"

  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init

  # Stash the high-severity fixture in a file so the gh stub can `cat` it
  # without bash-escaping confusion through the heredoc layer.
  printf '[{"number":101,"assignees":[]}]\n' >"$root/state/high.json"

  cat >"$bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "issue list")
    label=""
    while [ \$# -gt 0 ]; do
      if [ "\$1" = "--label" ]; then label="\$2"; shift 2; else shift; fi
    done
    case "\$label" in
      severity:high)   cat '$root/state/high.json' ;;
      severity:medium) echo '[]' ;;
      *)               echo '[]' ;;
    esac
    ;;
  "issue view")
    echo '{"labels":[]}'
    ;;
  "pr view")
    # Mode 2/3 pre-cap inspection (per-PR comment count + label check).
    echo '{"comments":[],"labels":[]}'
    ;;
  "pr list")
    echo '[]'
    ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"

  cat >"$bin/claude" <<STUB
#!/usr/bin/env bash
printf '{"type":"system","subtype":"init","model":"mock"}\n'
exit ${claude_exit}
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
    SESSION="bats-reason-$$" \
    KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-developer.sh" "$@" \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err"
}

@test "Mode 1: claude exit 1 → hard_failure event carries reason=api-error" {
  local root rc=0
  root=$(_setup_wrapper_env 1)
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 1 ]
  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "hard_failure" and .mode == "default" and .reason == "api-error" and .exit_code == 1)' "$f" >/dev/null
}

@test "Mode 1: claude exit 124 → reason=max-turns" {
  local root rc=0
  root=$(_setup_wrapper_env 124)
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 124 ]
  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "hard_failure" and .mode == "default" and .reason == "max-turns")' "$f" >/dev/null
}

@test "Mode 1: claude exit 137 → reason=pipeline-crash" {
  local root rc=0
  root=$(_setup_wrapper_env 137)
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 137 ]
  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "hard_failure" and .mode == "default" and .reason == "pipeline-crash")' "$f" >/dev/null
}

@test "Mode 1: unrecognized claude exit 99 → reason=unknown" {
  local root rc=0
  root=$(_setup_wrapper_env 99)
  _run_wrapper "$root" || rc=$?
  [ "$rc" -eq 99 ]
  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "hard_failure" and .mode == "default" and .reason == "unknown")' "$f" >/dev/null
}

@test "Mode 2 (follow-up): claude exit 124 → hard_failure reason=mode2-give-up" {
  local root rc=0
  root=$(_setup_wrapper_env 124)
  _run_wrapper "$root" follow-up 77 || rc=$?
  [ "$rc" -eq 124 ]
  local f="$root/state/events.jsonl"
  jq -e 'select(.event == "hard_failure" and .mode == "follow-up" and .pr == 77 and .reason == "mode2-give-up")' "$f" >/dev/null
}

# Mode 3 requires a tractable triage rc=0 stub so the wrapper falls through
# to the claude pipeline (otherwise the LLM doesn't run and no Mode 3
# hard_failure block fires). Mirrors test_dev_conflicts_escalation.bats.
_setup_mode3_env() {
  local claude_exit="${1:-124}"
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
  cat >"$fake/runners/run-conflict-triage.sh" <<'TRI'
#!/usr/bin/env bash
echo '[triage] result=tractable reason=mechanical-conflict-3-lines'
exit 0
TRI
  chmod +x "$fake/runners/run-conflict-triage.sh"

  local root="$BATS_TEST_TMPDIR/m3"
  rm -rf "$root"
  local repo="$root/repo" bin="$root/bin" work="$root/work" state="$root/state"
  mkdir -p "$repo/.loop" "$bin" "$work" "$state"
  awk -v wb="$work" '
    /^REPO_OWNER=/    { print "REPO_OWNER=\"test-owner\""; next }
    /^REPO_NAME=/     { print "REPO_NAME=\"test-repo\""; next }
    /^WORKTREE_BASE=/ { print "WORKTREE_BASE=\"" wb "\""; next }
    /^LOCK_DIR=/      { print "LOCK_DIR=\"" wb "/locks\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$repo/.loop/loop.config"
  git -C "$repo" init -q -b main
  git -C "$repo" -c user.email=t@t -c user.name=t commit --allow-empty -q -m init

  cat >"$bin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view") echo '{"comments":[],"labels":[]}' ;;
  *) : ;;
esac
exit 0
STUB
  chmod +x "$bin/gh"

  cat >"$bin/claude" <<STUB
#!/usr/bin/env bash
printf '{"type":"system","subtype":"init"}\n'
exit ${claude_exit}
STUB
  chmod +x "$bin/claude"

  printf '%s\n' "$root" "$fake"
}

@test "Mode 3 (resolve-conflicts): claude exit 124 → hard_failure reason=mode3-give-up" {
  local out root fake rc=0
  out=$(_setup_mode3_env 124)
  root=$(echo "$out" | sed -n '1p')
  fake=$(echo "$out" | sed -n '2p')
  local logfile="$root/state/events.jsonl"
  REPO_ROOT="$root/repo" LOOP_HOME="$fake" \
    PATH="$root/bin:$PATH" \
    LOOP_EVENT_LOG="$logfile" \
    SESSION="bats-m3-$$" \
    KEEP_ON_FAIL=0 \
    bash "$LOOP_ROOT/runners/run-developer.sh" resolve-conflicts 88 \
    >"$root/state/wrapper.out" 2>"$root/state/wrapper.err" || rc=$?
  [ "$rc" -eq 124 ]
  jq -e 'select(.event == "hard_failure" and .mode == "resolve-conflicts" and .pr == 88 and .reason == "mode3-give-up")' "$logfile" >/dev/null
}

# ---------------------------------------------------------------------------
# Reviewer: no-result-line regression guard.
#
# The reviewer wrapper's `event_emit reviewer hard_failure ... reason=no-result-line`
# call already exists (run-reviewer.sh:274); GH#171 only promotes the value
# into the documented enum. Pin the source-of-truth so a future refactor
# can't silently drop it. (A behavioral wrapper run for reviewer requires
# stubbing the full eligibility path; the source pin is enough for this
# field — the line itself runs only on the LLM-exited-0-but-no-result-line
# branch.)
# ---------------------------------------------------------------------------

@test "reviewer wrapper: emits hard_failure reason=no-result-line" {
  grep -qE 'event_emit reviewer hard_failure.*reason=no-result-line' "$LOOP_ROOT/runners/run-reviewer.sh"
}

# ---------------------------------------------------------------------------
# Schema doc: every enum value is listed under `hard_failure`, and schema
# version is now `2`.
# ---------------------------------------------------------------------------

@test "event-schema.md: documents the closed reason enum for hard_failure" {
  local doc="$LOOP_ROOT/docs/event-schema.md"
  [ -f "$doc" ]
  for v in max-turns api-error pipeline-crash mode2-give-up mode3-give-up no-result-line unknown; do
    grep -qE "^\| \`$v\`" "$doc" || { echo "missing enum value: $v"; return 1; }
  done
}

@test "event-schema.md: hard_failure row mentions reason (required)" {
  grep -E '^\| `hard_failure`' "$LOOP_ROOT/docs/event-schema.md" \
    | grep -qE '\breason\b'
}

@test "event_log.sh: LOOP_EVENT_SCHEMA_VERSION bumped to 2" {
  grep -qE '^LOOP_EVENT_SCHEMA_VERSION=2$' "$LOOP_ROOT/runners/lib/event_log.sh"
}

@test "event-schema.md: top-of-file Required Fields table reflects schema_version=2" {
  grep -qE 'Currently `2`' "$LOOP_ROOT/docs/event-schema.md"
}

# ---------------------------------------------------------------------------
# Source-of-truth: every emit site in run-developer.sh carries reason=.
# Catches a future refactor that drops the reason on one site while leaving
# the others.
# ---------------------------------------------------------------------------

@test "run-developer.sh: every hard_failure event_emit call carries a reason= argument" {
  # Three sites in Mode 1 / Mode 2 / Mode 3. Each line should contain
  # `reason=` somewhere after the event name.
  while IFS= read -r line; do
    echo "$line" | grep -qF 'reason=' \
      || { echo "missing reason= on: $line"; return 1; }
  done < <(grep -E 'event_emit dev hard_failure' "$LOOP_ROOT/runners/run-developer.sh")
}

@test "run-developer.sh: sources classify_llm_failure_reason from the shared helper" {
  grep -qF 'classify_llm_failure_reason' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "hard_failure.sh: defines classify_llm_failure_reason" {
  grep -qE '^classify_llm_failure_reason\(\)' "$LOOP_ROOT/runners/lib/hard_failure.sh"
}
