#!/usr/bin/env bats
# tests/test_schema_drift.bats — CI guard for the event-schema doc (GH#176).
#
# Every `event_emit <role> <event> [k=v ...]` call in runners/ is the wire
# format consumed by the external "control tower" tool. docs/event-schema.md
# is the contract. Before this guard, the only enforcement was a smoke test
# (test_event_log.bats) that grep'd for a hard-coded list of event names —
# new events / new fields drifted in silently (`bash_overshoot`,
# `verdict_drift`, `mode`/`rc` on `eligibility`).
#
# This test walks every `event_emit` site in runners/ statically and asserts:
#   1. The event name appears as `` `<event>` `` in docs/event-schema.md.
#   2. Every literal `key=` field passed to event_emit appears as `` `<key>` ``
#      in docs/event-schema.md.
#
# Dynamic array-splat expansions (`"${_dispatch_kv[@]:+...}"`,
# `"${_llm_target_kv[@]}"`, `"${_llm_cost_kv[@]}"`) emit a known set of
# fields whose names never appear as bare `key=` in the call site; those
# implicit fields are listed in IMPLICIT_FIELDS so they aren't false-flagged.

load 'helpers'

# Fields that splat in via shell-array expansion and are documented under
# their owning event rows. Static `key=` extraction below cannot see them.
IMPLICIT_FIELDS="dispatch_id pr issue run_id total_cost_usd input_tokens output_tokens num_turns"

# Required base fields written by event_emit itself (`runners/lib/event_log.sh`).
# These are documented once under "Required fields" and not repeated per row.
BASE_FIELDS="ts session repo role event schema_version"

# Emit one line per event_emit call as "<event>|<space-separated field names>".
# Skips comment lines and the helper definition (`event_emit() { ... }` in
# event_log.sh). Trailing quotes/backslashes are stripped from the event name.
#
# Two notes on the tokenizer:
#   1. Backslash-continued lines are joined first (via awk getline) so multi-
#      line event_emit calls — e.g. the four `triage_result` emits in
#      run-developer.sh that split duration_s / conflict_files / conflict_lines
#      / triage_files_count onto continuation lines — are tokenized as one
#      logical call. Without this, continuation-line fields slip past the
#      drift guard.
#   2. The input file list is discovered dynamically via `grep -rl` so a new
#      runner that starts emitting (e.g. run-conflict-triage.sh or a future
#      runner) is picked up automatically.
_collect_event_emits() {
  # Use a while-read loop instead of `mapfile` for bash 3.2 (macOS)
  # compatibility — mirrors the pattern called out in run-conflict-triage.sh.
  local files=() f
  while IFS= read -r f; do
    [ -n "$f" ] && files+=("$f")
  done < <(grep -rl 'event_emit ' "$LOOP_ROOT"/runners/ 2>/dev/null | sort)
  [ "${#files[@]}" -gt 0 ] || return 0
  awk '
    {
      # Join backslash-continued lines before pattern matching, so a multi-
      # line event_emit reaches the tokenizer as a single record.
      while ($0 ~ /\\$/) {
        sub(/\\$/, "")
        if ((getline cont) <= 0) break
        $0 = $0 cont
      }
    }
    /event_emit / && !/^[[:space:]]*#/ {
      idx = index($0, "event_emit ")
      if (idx == 0) next
      rest = substr($0, idx + length("event_emit "))
      n = split(rest, tok, /[ \t]+/)
      if (n < 2) next
      event = tok[2]
      gsub(/["\\]/, "", event)
      # Skip non-event tokens (e.g. the helper definition `event_emit() {`,
      # or a string concatenation like `event_emit "$@"` in the lib).
      if (event !~ /^[a-zA-Z_][a-zA-Z_0-9]*$/) next
      keys = ""
      for (i = 3; i <= n; i++) {
        t = tok[i]
        if (match(t, /^[a-zA-Z_][a-zA-Z_0-9]*=/)) {
          k = substr(t, 1, RLENGTH - 1)
          keys = (keys == "" ? k : keys " " k)
        }
      }
      print event "|" keys
    }
  ' "${files[@]}"
}

# True iff `word` is in the space-separated `list`.
_in_list() {
  local word="$1" list="$2" item
  for item in $list; do
    [ "$item" = "$word" ] && return 0
  done
  return 1
}

@test "every event_emit event name is documented in docs/event-schema.md" {
  local doc="$LOOP_ROOT/docs/event-schema.md"
  [ -f "$doc" ]
  local missing=""
  local events
  events=$(_collect_event_emits | cut -d'|' -f1 | sort -u)
  local ev
  for ev in $events; do
    # Require backtick-quoted mention: forces the doc to name the event
    # explicitly rather than incidentally matching a word in prose.
    if ! grep -qF "\`${ev}\`" "$doc"; then
      missing="${missing}  - ${ev}"$'\n'
    fi
  done
  if [ -n "$missing" ]; then
    echo "Event(s) emitted by runners/ but not documented in docs/event-schema.md:"
    printf '%s' "$missing"
    echo
    echo "Each event must appear as \`<event-name>\` in the schema doc."
    return 1
  fi
}

@test "every event_emit field name is documented in docs/event-schema.md" {
  local doc="$LOOP_ROOT/docs/event-schema.md"
  local missing=""
  local event keys k
  while IFS='|' read -r event keys; do
    [ -z "$keys" ] && continue
    for k in $keys; do
      _in_list "$k" "$IMPLICIT_FIELDS" && continue
      _in_list "$k" "$BASE_FIELDS" && continue
      if ! grep -qF "\`${k}\`" "$doc"; then
        missing="${missing}  - ${event}.${k}"$'\n'
      fi
    done
  done < <(_collect_event_emits)
  if [ -n "$missing" ]; then
    echo "Field(s) passed to event_emit but not documented in docs/event-schema.md:"
    printf '%s' "$missing"
    echo
    echo "Each field must appear as \`<field-name>\` in the schema doc (in the event's"
    echo "extra-fields column or as an explicitly-listed optional field)."
    return 1
  fi
}
