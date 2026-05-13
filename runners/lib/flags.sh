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
#                                   LOOP_FF_<NAME>_VARIANTS (CSV). When no
#                                   variants are configured the helper is a
#                                   no-op returning `control`. Otherwise the
#                                   arm is picked by
#                                   `variants[ hash(issue_id||name) mod N ]`
#                                   so the same (flag, id) lands in the same
#                                   arm across every retry, follow-up cycle,
#                                   and conflict-triage rerun (GH#189). An
#                                   operator override
#                                   `LOOP_FF_<NAME>_FORCE=<arm>` pins the
#                                   result for debugging, bypassing the hash.
#   ff_value <name> <default>     — print LOOP_FF_<NAME> if set and non-empty;
#                                   else print <default> (default-of-default
#                                   is empty string).
#
# Telemetry: `ff_variant` emits one `flag_read` NDJSON event per call that
# actually makes a variant assignment (i.e. VARIANTS is configured). The
# event carries `flag`, `variant`, `assignment_source` (hash|force) and
# `issue_id`. The other helpers (`ff_enabled`, `ff_value`) remain silent
# pending GH#187's broader telemetry pass.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/event_log.sh"

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

# _ff_hash_index <flag> <issue_id> <n> — print the index in [0, n) for
# `(issue_id || flag)` under SHA-256, taking the first 8 hex chars (32 bits)
# and reducing mod n. POSIX-portable: shasum -a 256 is in perl-base on every
# Linux distro and stock on macOS; `head -c 8` works on both BSD and GNU; the
# `0x<hex>` literal is honoured by bash arithmetic on 3.2+.
_ff_hash_index() {
  local flag="$1" issue_id="$2" n="$3"
  local hex
  hex=$(printf '%s' "${issue_id}${flag}" | shasum -a 256 | head -c 8)
  printf '%d\n' $(( 0x${hex} % n ))
}

# _ff_emit_flag_read <flag-upper> <variant> <source> <issue_id> — best-effort
# `flag_read` NDJSON line through event_log.sh. The role is read from
# LOOP_EVENT_ROLE so the calling runner (`dev` / `reviewer` / etc.) can stamp
# itself; default is the literal "flags" since this is a library helper.
_ff_emit_flag_read() {
  local flag="$1" variant="$2" source="$3" issue_id="$4"
  local role="${LOOP_EVENT_ROLE:-flags}"
  # event_emit is itself best-effort (always returns 0); guard the call too
  # so a missing function (event_log.sh failed to source for some reason)
  # never breaks the caller's variant lookup.
  if command -v event_emit >/dev/null 2>&1; then
    event_emit "$role" flag_read flag="$flag" variant="$variant" \
      assignment_source="$source" issue_id="$issue_id"
  fi
}

ff_variant() {
  local flag="${1:-}"
  local issue_id="${2:-}"
  [ -n "$flag" ] || return 2

  local upper var_variants var_force variants force_arm
  upper=$(_ff_upper "$flag")
  var_variants="LOOP_FF_${upper}_VARIANTS"
  var_force="LOOP_FF_${upper}_FORCE"
  variants=$(_ff_lookup "$var_variants")
  force_arm=$(_ff_lookup "$var_force")

  # No variants configured → degenerate "off" path. No event: gating on
  # an unconfigured flag is a caller bug, not a rollout signal worth
  # logging.
  if [ -z "$variants" ]; then
    printf '%s\n' "control"
    return 0
  fi

  # Operator FORCE override beats the hash. Emit `force` so per-arm
  # outcome counts can isolate forced rows (they're debug noise vs. the
  # natural hash split).
  if [ -n "$force_arm" ]; then
    _ff_emit_flag_read "$upper" "$force_arm" force "$issue_id"
    printf '%s\n' "$force_arm"
    return 0
  fi

  # Parse the CSV. Strip per-arm whitespace and drop empties so a
  # copy-pasted "a, b ,c" or stray double-comma does not surface as a
  # literal arm name.
  local -a arms=()
  local raw item trimmed
  local IFS_save="$IFS"
  IFS=','
  # shellcheck disable=SC2206 # intentional word-splitting on ','
  local parts=( $variants )
  IFS="$IFS_save"
  for raw in "${parts[@]+"${parts[@]}"}"; do
    # Trim leading + trailing ASCII whitespace.
    item="${raw#"${raw%%[![:space:]]*}"}"
    trimmed="${item%"${item##*[![:space:]]}"}"
    [ -n "$trimmed" ] && arms+=( "$trimmed" )
  done

  local n="${#arms[@]}"
  if [ "$n" -eq 0 ]; then
    # VARIANTS was non-empty but parsed to zero arms (e.g. ",,,"). Treat
    # like the unset path — control, no event.
    printf '%s\n' "control"
    return 0
  fi

  local idx arm
  idx=$(_ff_hash_index "$upper" "$issue_id" "$n")
  arm="${arms[$idx]}"
  _ff_emit_flag_read "$upper" "$arm" hash "$issue_id"
  printf '%s\n' "$arm"
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
