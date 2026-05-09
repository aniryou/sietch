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

LOOP_EVENT_SCHEMA_VERSION=1

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
