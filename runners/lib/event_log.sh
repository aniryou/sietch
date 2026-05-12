#!/usr/bin/env bash
# lib/event_log.sh — append-only NDJSON event emission for cross-pane
# observability (GH#92). Sourced by runners/run-loop.sh, run-developer.sh,
# and run-reviewer.sh. Defines:
#
#   event_emit <role> <event_name> [k=v ...]
#
# Appends one NDJSON line to:
#   ${LOOP_EVENT_LOG:-/tmp/loop-events-${SESSION:-default}.jsonl}
#
# Required fields written on every line: ts (ISO-8601), session, repo, role,
# event, schema_version. Extra k=v args become top-level fields. Values that
# parse as integers or floats become JSON numbers; everything else is a JSON
# string (passed through `jq --arg` so quotes/newlines/colons are escaped).
#
# A single `printf '%s\n' "$json" >> "$file"` write — POSIX guarantees atomic
# append for writes ≤ PIPE_BUF (4 KiB), well above any event we emit.
#
# Failure to write is silent. event_emit ALWAYS returns 0 — best-effort
# instrumentation must never break the loop. A missing parent directory or
# permissions glitch on the log file is invisible to the caller's `set -e`.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"

# v2 (GH#170, GH#171): `llm_exited` events now also carry `total_cost_usd`,
# `input_tokens`, `output_tokens`, `num_turns` extracted from the agent's
# stream-json result frame (GH#170); and `hard_failure` events now carry a
# `reason` from a closed enum (GH#171). Both are required-field set
# changes, so the version bumps per the contract in docs/event-schema.md.
LOOP_EVENT_SCHEMA_VERSION=2

# event_cost_fields_from_raw <stream-json-file>
#
# Parse the last `type:"result"` line out of the given stream-json file and
# print four `k=v` lines (one per field) suitable for splicing into an
# `event_emit ... llm_exited ...` arg list:
#
#   total_cost_usd=<float>
#   input_tokens=<int>
#   output_tokens=<int>
#   num_turns=<int>
#
# Each field defaults to `0` when the result frame is missing (claude crash
# before completion, mid-stream truncation) so consumers can rely on the
# fields existing on every llm_exited event. Tolerant of a partial last line
# via `fromjson?` — a truncated tail does not error.
event_cost_fields_from_raw() {
  local raw_file="${1:-}"
  local jq_out=""
  if [ -n "$raw_file" ] && [ -f "$raw_file" ] && [ -s "$raw_file" ]; then
    # shellcheck disable=SC2016 # $vars here are jq bindings, not shell expansions
    jq_out=$(
      jq -Rrs '
        [ split("\n")[] | select(length > 0) | (fromjson? // empty)
          | select(.type == "result") ] | last
        | if . == null then
            {total_cost_usd: 0, input_tokens: 0, output_tokens: 0, num_turns: 0}
          else
            { total_cost_usd: (.total_cost_usd // 0),
              input_tokens:   (.usage.input_tokens  // 0),
              output_tokens:  (.usage.output_tokens // 0),
              num_turns:      (.num_turns // 0) }
          end
        | "total_cost_usd=\(.total_cost_usd)",
          "input_tokens=\(.input_tokens)",
          "output_tokens=\(.output_tokens)",
          "num_turns=\(.num_turns)"
      ' "$raw_file" 2>/dev/null
    ) || jq_out=""
  fi
  if [ -n "$jq_out" ]; then
    printf '%s\n' "$jq_out"
  else
    printf 'total_cost_usd=0\ninput_tokens=0\noutput_tokens=0\nnum_turns=0\n'
  fi
}

event_emit() {
  if [ "$#" -lt 2 ]; then return 0; fi
  local role="$1" event="$2"
  shift 2
  local file="${LOOP_EVENT_LOG:-/tmp/loop-events-${SESSION:-default}.jsonl}"
  local ts
  ts=$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")

  local jq_args=(
    --arg ts "$ts"
    --arg session "${SESSION:-default}"
    --arg repo "${REPO_SLUG:-}"
    --arg role "$role"
    --arg event "$event"
    --argjson schema_version "$LOOP_EVENT_SCHEMA_VERSION"
  )
  # shellcheck disable=SC2016 # $vars here are jq bindings, not shell expansions
  local filter='{ts:$ts, session:$session, repo:$repo, role:$role, event:$event, schema_version:$schema_version}'

  local kv k v
  for kv in "$@"; do
    # Only split on the first '=' so values can contain '='.
    k="${kv%%=*}"
    v="${kv#*=}"
    # Skip malformed args (no '=' separator).
    [ "$kv" = "$k" ] && continue
    # Numeric coercion. Match unsigned/signed int and decimal float; anything
    # else (negative-prefixed strings, "1.2.3", "0xff", "-no-work", etc.)
    # falls through to --arg as a string.
    if [[ "$v" =~ ^-?[0-9]+$ ]] || [[ "$v" =~ ^-?[0-9]+\.[0-9]+$ ]]; then
      jq_args+=(--argjson "$k" "$v")
    else
      jq_args+=(--arg "$k" "$v")
    fi
    filter+=" | .${k} = \$${k}"
  done

  local json
  json=$(jq -cn "${jq_args[@]}" "$filter" 2>/dev/null) || return 0
  printf '%s\n' "$json" >>"$file" 2>/dev/null || true
  return 0
}
