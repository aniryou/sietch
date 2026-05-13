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
# Telemetry on flag reads is intentionally deferred to a later child issue —
# this module is the bare convention.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"

# _ff_upper <s> — print <s> with [a-z] mapped to [A-Z]. POSIX-portable; avoids
# bash 4+ `${var^^}` so this works on macOS's stock bash 3.2.
_ff_upper() {
  printf '%s' "$1" | tr '[:lower:]' '[:upper:]'
}

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

ff_enabled() {
  local flag="${1:-}"
  [ -n "$flag" ] || return 2
  local upper var val
  upper=$(_ff_upper "$flag")
  var="LOOP_FF_${upper}"
  val=$(_ff_lookup "$var")
  [ "$val" = "1" ]
}

ff_variant() {
  local flag="${1:-}"
  # issue_id is read for future hash-based assignment (see header). Today the
  # value is ignored; we still require the slot so the signature is stable.
  local _issue_id="${2:-}"
  [ -n "$flag" ] || return 2
  local upper var variants
  upper=$(_ff_upper "$flag")
  var="LOOP_FF_${upper}_VARIANTS"
  variants=$(_ff_lookup "$var")
  if [ -z "$variants" ]; then
    printf '%s\n' "control"
    return 0
  fi
  # Variants configured but no assignment policy yet (lands in a later
  # child); return control so callers behave like the flag is off.
  printf '%s\n' "control"
}

ff_value() {
  local flag="${1:-}"
  local default="${2-}"
  [ -n "$flag" ] || return 2
  local upper var val
  upper=$(_ff_upper "$flag")
  var="LOOP_FF_${upper}"
  val=$(_ff_lookup "$var")
  if [ -n "$val" ]; then
    printf '%s\n' "$val"
  else
    printf '%s\n' "$default"
  fi
}
