#!/usr/bin/env bash
# lib/flags.sh — read `LOOP_FF_*` feature flags from the environment so other
# parts of loop don't reinvent `[[ "${LOOP_FF_X:-0}" == "1" ]]` inline (GH#186).
# Sourced (not executed). Wrappers source `.loop/loop.config` first, then this
# module — at that point every `LOOP_FF_<NAME>` declared in config is visible
# as a normal env var.
#
# Convention: `LOOP_FF_<UPPER_SNAKE_NAME>=...`. The `LOOP_FF_` prefix
# distinguishes feature flags from ordinary tunables (which use bare names
# like `DEV_MAX_TURNS`). Helpers uppercase the caller-supplied name so
# `ff_enabled my_flag` resolves to `LOOP_FF_MY_FLAG`.
#
# Helpers:
#   ff_enabled <name>             — exit 0 iff LOOP_FF_<NAME>=1; else exit 1.
#                                   Strict "1"-only; "true"/"yes"/"on" do not
#                                   count. The single-value rule stops drift
#                                   between callers that might disagree on
#                                   what counts as truthy.
#   ff_variant <name> <issue_id>  — print the assigned variant from
#                                   LOOP_FF_<NAME>_VARIANTS. Hash-based
#                                   assignment lands in a later child issue;
#                                   today this is always `control`. The
#                                   <issue_id> arg is reserved for that
#                                   future deterministic assignment so
#                                   callers can wire it in now without a
#                                   signature change.
#   ff_value <name> <default>     — print LOOP_FF_<NAME> if set and non-empty;
#                                   else print <default> (default-of-default
#                                   is empty string).
#
# GH#187: every ff_* call records (lowercased name, resolved value) in the
# process-local `_LOOP_FF_ACTIVE` cache and best-effort emits a `flag_read`
# event via event_emit. Subsequent event_emit calls serialize the cache as
# a `flags_active` JSON object, so cohort membership joins to outcomes
# without re-instrumenting every caller. Best-effort means a write failure
# (unwritable `LOOP_EVENT_LOG`, jq missing) MUST NOT change a ff_* helper's
# exit code or stdout — the contract callers rely on.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/event_log.sh"

# Process-local cache of flag reads since this shell started. Exported so
# backgrounded child shells (dispatched wrappers, etc.) inherit cohort
# membership the parent has already established. Newline-separated
# `name=value` entries; names are lowercased to align with the JSON
# `flags_active` field event_emit produces. Newline-delimited (not assoc
# array) so this lib remains portable to macOS's stock bash 3.2.
_LOOP_FF_ACTIVE="${_LOOP_FF_ACTIVE:-}"
export _LOOP_FF_ACTIVE

# _ff_upper / _ff_lower — POSIX-portable case mapping. Avoids bash 4+
# `${var^^}` / `${var,,}` so this works on macOS's stock bash 3.2.
_ff_upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }
_ff_lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# _ff_lookup <var-name> — print the value of the named variable, or empty
# string if unset. Wraps the indirect expansion so the rest of the file
# stays readable and we have exactly one place to evolve the lookup.
_ff_lookup() {
  local name="$1"
  # `${!name-}` is bash indirect expansion with an unset-default of "" so
  # `set -u` (inherited from _preamble.sh) doesn't abort on an undeclared
  # LOOP_FF_* var.
  printf '%s' "${!name-}"
}

# _ff_cache_set <lower-name> <value> — record name=value in _LOOP_FF_ACTIVE,
# replacing any prior entry for the same name. O(N) over current cohort
# size, which is bounded by the number of distinct flags read in this
# process — small enough that the linear scan is fine and avoids the
# bash-4 associative-array dependency.
_ff_cache_set() {
  local name="$1" value="$2"
  local out="" line
  if [ -n "${_LOOP_FF_ACTIVE:-}" ]; then
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      [ "${line%%=*}" = "$name" ] && continue
      out+="${line}"$'\n'
    done <<< "$_LOOP_FF_ACTIVE"
  fi
  out+="${name}=${value}"
  _LOOP_FF_ACTIVE="$out"
  export _LOOP_FF_ACTIVE
}

# _ff_emit_read <lower-name> <value> — best-effort flag_read emit. The
# role falls back to `flags` when the wrapper hasn't set `LOOP_ROLE`, so
# direct library tests still produce a well-formed event. event_emit is
# already best-effort per its header contract; the `|| true` here is
# defense-in-depth in case a future change tightens that.
_ff_emit_read() {
  local name="$1" value="$2"
  event_emit "${LOOP_ROLE:-flags}" flag_read name="$name" value="$value" \
    >/dev/null 2>&1 || true
}

ff_enabled() {
  local flag="${1:-}"
  [ -n "$flag" ] || return 2
  local upper lower var val state rc
  upper=$(_ff_upper "$flag")
  lower=$(_ff_lower "$flag")
  var="LOOP_FF_${upper}"
  val=$(_ff_lookup "$var")
  # `state` is the wire value (0/1) recorded in flags_active and the
  # flag_read event; `rc` is the bash exit code (0=enabled, 1=disabled).
  # Inverted between the two so analysts see the flag's *state* in the
  # log while callers can still `if ff_enabled FOO; then ...`.
  if [ "$val" = "1" ]; then state=1; rc=0; else state=0; rc=1; fi
  # Update cache BEFORE emit so the flag_read line itself carries the
  # flag in `flags_active` — gives consumers a self-consistent view.
  _ff_cache_set "$lower" "$state"
  _ff_emit_read "$lower" "$state"
  return $rc
}

ff_variant() {
  local flag="${1:-}"
  # issue_id is read for future hash-based assignment (see header). Today the
  # value is ignored; we still require the slot so the signature is stable.
  local _issue_id="${2:-}"
  [ -n "$flag" ] || return 2
  local upper lower variant
  upper=$(_ff_upper "$flag")
  lower=$(_ff_lower "$flag")
  # LOOP_FF_<NAME>_VARIANTS is read here so a future child issue can
  # branch on the configured set; today's policy is unconditional
  # "control" (the placeholder until deterministic assignment lands).
  # We still resolve the var so a configured-but-unused value doesn't
  # silently rot.
  _ff_lookup "LOOP_FF_${upper}_VARIANTS" >/dev/null
  variant="control"
  _ff_cache_set "$lower" "$variant"
  _ff_emit_read "$lower" "$variant"
  printf '%s\n' "$variant"
}

ff_value() {
  local flag="${1:-}"
  local default="${2-}"
  [ -n "$flag" ] || return 2
  local upper lower var val out
  upper=$(_ff_upper "$flag")
  lower=$(_ff_lower "$flag")
  var="LOOP_FF_${upper}"
  val=$(_ff_lookup "$var")
  if [ -n "$val" ]; then
    out="$val"
  else
    out="$default"
  fi
  _ff_cache_set "$lower" "$out"
  _ff_emit_read "$lower" "$out"
  printf '%s\n' "$out"
}
