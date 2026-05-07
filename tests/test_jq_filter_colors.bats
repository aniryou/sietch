#!/usr/bin/env bats
# tests/test_jq_filter_colors.bats — exercise the colored JQ_FILTER produced
# by runners/lib/jq_filter.sh. Verifies per-event-type ANSI tag wrapping,
# NO_COLOR opt-out, and that both run-developer.sh and run-reviewer.sh source
# the same shared library (no copy-paste drift).

load 'helpers'

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

ESC=$'\e'

# Source jq_filter.sh in a clean subshell with the given NO_COLOR setting,
# pipe one or more JSON lines through `jq -r "$JQ_FILTER"`, echo the result.
# Args: <unset|set:VALUE> <json>
run_jq_filter() {
  local nc="$1" json="$2"
  if [ "$nc" = "unset" ]; then
    bash -c '
      unset NO_COLOR
      . "'"$LOOP_ROOT"'/runners/lib/jq_filter.sh"
      printf "%s" "$1" | jq -r --unbuffered "$JQ_FILTER"
    ' _ "$json"
  else
    local val="${nc#set:}"
    NO_COLOR="$val" bash -c '
      . "'"$LOOP_ROOT"'/runners/lib/jq_filter.sh"
      printf "%s" "$1" | jq -r --unbuffered "$JQ_FILTER"
    ' _ "$json"
  fi
}

# ---------------------------------------------------------------------------
# Per-event-type colorization (NO_COLOR unset)
# ---------------------------------------------------------------------------

@test "[init] event wraps the entire line in dim-grey ANSI and preserves payload" {
  local out
  out=$(run_jq_filter unset \
    '{"type":"system","subtype":"init","model":"sonnet-4-6","tools":["Bash","Read"],"cwd":"/tmp/x"}')
  # Whole line is colorized: tag color opens, only one reset, at end-of-line.
  [[ "$out" == "${ESC}[2;37m[init] "* ]]
  [[ "$out" == *"${ESC}[0m" ]]
  [[ "$out" == *"model=sonnet-4-6"* ]]
  [[ "$out" == *"tools=2"* ]]
  [[ "$out" == *"cwd=/tmp/x"* ]]
  # No mid-line reset between tag and payload.
  [[ "$out" != *"[init]${ESC}[0m"* ]]
}

@test "[text] event whole line is yellow with payload colored too" {
  local out
  out=$(run_jq_filter unset \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"hello world"}]}}')
  # Exact form: tag+payload wrapped in a single yellow span.
  [ "$out" = "${ESC}[33m[text] hello world${ESC}[0m" ]
}

@test "[tool] event whole line is cyan including tool name + args" {
  local out
  out=$(run_jq_filter unset \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}')
  [[ "$out" == "${ESC}[36m[tool] Bash"* ]]
  [[ "$out" == *"${ESC}[0m" ]]
  [[ "$out" == *"command"*"ls -la"* ]]
  # Payload "command":"ls -la" must NOT be preceded by a reset.
  [[ "$out" != *"${ESC}[0m"*"command"* ]]
}

@test "[result] event whole line is dim-grey including tool output" {
  local out
  out=$(run_jq_filter unset \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"line1\nline2"}]}]}}')
  # gsub turns \n into ' ⏎ '
  [ "$out" = "${ESC}[2;37m[result] line1 ⏎ line2${ESC}[0m" ]
}

@test "[done] success whole line is green" {
  local out
  out=$(run_jq_filter unset \
    '{"type":"result","subtype":"success","duration_ms":42,"num_turns":3,"total_cost_usd":0.12}')
  [ "$out" = "${ESC}[32m[done] success duration=42ms turns=3 cost=\$0.12${ESC}[0m" ]
}

@test "[done] error_max_turns whole line is red" {
  local out
  out=$(run_jq_filter unset \
    '{"type":"result","subtype":"error_max_turns","duration_ms":99,"num_turns":1,"total_cost_usd":0}')
  [[ "$out" == "${ESC}[31m[done] error_max_turns"* ]]
  [[ "$out" == *"${ESC}[0m" ]]
  # No mid-line reset between [done] and trailing reset.
  [[ "$out" != *"[done]${ESC}[0m"* ]]
}

@test "[done] non-success subtypes (e.g. error_during_execution) also get red full line" {
  local out
  out=$(run_jq_filter unset \
    '{"type":"result","subtype":"error_during_execution","duration_ms":1,"num_turns":1,"total_cost_usd":0}')
  [[ "$out" == "${ESC}[31m[done] error_during_execution"* ]]
  [[ "$out" == *"${ESC}[0m" ]]
  [[ "$out" != *"${ESC}[32m"* ]]
}

@test "every colored event line has exactly one ANSI reset, at end-of-line" {
  # Catches accidental mid-line resets — invariant for whole-line coloring.
  local fixture out
  fixture=$(printf '%s\n' \
    '{"type":"system","subtype":"init","model":"x","tools":[],"cwd":"/"}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"narration here"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"ls -la"}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"out"}]}]}}' \
    '{"type":"result","subtype":"success","duration_ms":1,"num_turns":1,"total_cost_usd":0}' \
    '{"type":"result","subtype":"error_x","duration_ms":1,"num_turns":1,"total_cost_usd":0}')
  out=$(run_jq_filter unset "$fixture")
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    # Count occurrences of ESC[0m in the line.
    local resets
    resets=$(printf '%s' "$line" | grep -oE $'\e\\[0m' | wc -l | tr -d ' ')
    if [ "$resets" -ne 1 ]; then
      echo "expected exactly 1 reset, got $resets, in: $(printf '%s' "$line" | cat -v)"
      return 1
    fi
    # Reset must be at end-of-line.
    if [[ "$line" != *$'\e[0m' ]]; then
      echo "expected line to end with reset, got: $(printf '%s' "$line" | cat -v)"
      return 1
    fi
  done <<< "$out"
}

# ---------------------------------------------------------------------------
# Tags from each pane are consistent (sourced from the same lib)
# ---------------------------------------------------------------------------

@test "[tool] color is the same regardless of NO_COLOR-unset preamble" {
  # Spawning twice from a clean subshell yields identical bytes.
  local a b
  a=$(run_jq_filter unset \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"X","input":{}}]}}')
  b=$(run_jq_filter unset \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"X","input":{}}]}}')
  [ "$a" = "$b" ]
}

# ---------------------------------------------------------------------------
# NO_COLOR opt-out (https://no-color.org/ — any value, even empty, disables)
# ---------------------------------------------------------------------------

@test "NO_COLOR=1 strips ANSI escapes from every event type" {
  local fixture
  fixture=$(printf '%s\n' \
    '{"type":"system","subtype":"init","model":"x","tools":[],"cwd":"/"}' \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"t"}]}}' \
    '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"X","input":{}}]}}' \
    '{"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"r"}]}]}}' \
    '{"type":"result","subtype":"success","duration_ms":1,"num_turns":1,"total_cost_usd":0}' \
    '{"type":"result","subtype":"error_x","duration_ms":1,"num_turns":1,"total_cost_usd":0}')
  local out
  out=$(run_jq_filter set:1 "$fixture")
  if printf '%s' "$out" | grep -q $'\e\['; then
    echo "expected no ANSI escapes, got:"
    printf '%s\n' "$out" | cat -v
    return 1
  fi
}

@test "NO_COLOR= (empty value) still disables colors per no-color.org" {
  local out
  out=$(run_jq_filter set: \
    '{"type":"assistant","message":{"content":[{"type":"text","text":"t"}]}}')
  if printf '%s' "$out" | grep -q $'\e\['; then
    return 1
  fi
}

@test "NO_COLOR=1 [init] line is byte-equivalent to pre-color format" {
  local out
  out=$(run_jq_filter set:1 \
    '{"type":"system","subtype":"init","model":"sonnet","tools":["A"],"cwd":"/x"}')
  [ "$out" = "[init] model=sonnet tools=1 cwd=/x" ]
}

@test "NO_COLOR=1 [done] line is byte-equivalent to pre-color format" {
  local out
  out=$(run_jq_filter set:1 \
    '{"type":"result","subtype":"success","duration_ms":42,"num_turns":3,"total_cost_usd":0.5}')
  [ "$out" = "[done] success duration=42ms turns=3 cost=\$0.5" ]
}

# ---------------------------------------------------------------------------
# Source-of-truth: both wrappers source the shared lib (no copy-paste drift)
# ---------------------------------------------------------------------------

@test "run-developer.sh sources lib/jq_filter.sh" {
  grep -qF 'runners/lib/jq_filter.sh' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh sources lib/jq_filter.sh" {
  grep -qF 'runners/lib/jq_filter.sh' "$LOOP_ROOT/runners/run-reviewer.sh"
}

@test "run-developer.sh has no inline JQ_FILTER body (must use shared lib)" {
  ! grep -qE 'if \.type == "system" and \.subtype == "init"' \
    "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh has no inline JQ_FILTER body (must use shared lib)" {
  ! grep -qE 'if \.type == "system" and \.subtype == "init"' \
    "$LOOP_ROOT/runners/run-reviewer.sh"
}
