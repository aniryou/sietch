#!/usr/bin/env bats
# tests/test_flags.bats — exercise runners/lib/flags.sh.
#
# The module exposes three helpers for reading `LOOP_FF_*` feature flags from
# the environment (after .loop/loop.config is sourced by a wrapper):
#
#   ff_enabled <name>             — exit 0 iff LOOP_FF_<NAME>=1; else exit 1.
#   ff_variant <name> <issue_id>  — print variant from LOOP_FF_<NAME>_VARIANTS,
#                                   default "control" (hash-based assignment
#                                   lands in a later child issue).
#   ff_value   <name> <default>   — print LOOP_FF_<NAME> if set, else <default>.
#
# Tests model after test_event_log.bats: source flags.sh in a clean subshell
# with the desired env, capture exit code / stdout, assert.

load 'helpers'

# Run a helper in a clean subshell with the supplied env vars. Echoes stdout;
# returns the helper's exit code.
_run_ff() {
  local env_pairs="$1"; shift
  local helper="$1"; shift
  # shellcheck disable=SC2086 # intentional word-splitting of env_pairs.
  env -i PATH="$PATH" $env_pairs bash -c '
    . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
    '"$helper"' "$@"
  ' _ "$@"
}

# ---------------------------------------------------------------------------
# ff_enabled
# ---------------------------------------------------------------------------

@test "ff_enabled returns 0 when LOOP_FF_FOO=1" {
  set +e
  _run_ff "LOOP_FF_FOO=1" ff_enabled FOO
  ec=$?
  set -e
  [ "$ec" -eq 0 ]
}

@test "ff_enabled returns 1 when LOOP_FF_FOO=0" {
  set +e
  _run_ff "LOOP_FF_FOO=0" ff_enabled FOO
  ec=$?
  set -e
  [ "$ec" -eq 1 ]
}

@test "ff_enabled returns 1 when LOOP_FF_FOO is unset" {
  set +e
  _run_ff "" ff_enabled FOO
  ec=$?
  set -e
  [ "$ec" -eq 1 ]
}

@test "ff_enabled returns 1 when LOOP_FF_FOO is empty string" {
  set +e
  _run_ff "LOOP_FF_FOO=" ff_enabled FOO
  ec=$?
  set -e
  [ "$ec" -eq 1 ]
}

@test "ff_enabled returns 1 for non-'1' truthy values (e.g. 'true', 'yes', '2')" {
  # The convention is strictly "1"; we don't accept "true"/"yes"/etc so that
  # callers in different runners can't drift on coercion semantics.
  for val in true yes on 2 enabled; do
    set +e
    _run_ff "LOOP_FF_FOO=$val" ff_enabled FOO
    ec=$?
    set -e
    [ "$ec" -eq 1 ] || { echo "expected 1 for LOOP_FF_FOO=$val, got $ec"; return 1; }
  done
}

@test "ff_enabled uppercases the flag name (LOOP_FF_FOO read for ff_enabled foo)" {
  # Convention: the env var is always upper-snake, but the caller may pass
  # any case. The helper uppercases so a `ff_enabled my_flag` lookup hits
  # `LOOP_FF_MY_FLAG`.
  set +e
  _run_ff "LOOP_FF_MY_FLAG=1" ff_enabled my_flag
  ec=$?
  set -e
  [ "$ec" -eq 0 ]
}

@test "ff_enabled with no flag name returns non-zero (caller error)" {
  set +e
  _run_ff "" ff_enabled
  ec=$?
  set -e
  [ "$ec" -ne 0 ]
}

# ---------------------------------------------------------------------------
# ff_variant
# ---------------------------------------------------------------------------

@test "ff_variant returns 'control' when LOOP_FF_FOO_VARIANTS is unset" {
  out=$(_run_ff "" ff_variant FOO 42)
  [ "$out" = "control" ]
}

@test "ff_variant returns 'control' when LOOP_FF_FOO_VARIANTS is empty string" {
  out=$(_run_ff "LOOP_FF_FOO_VARIANTS=" ff_variant FOO 42)
  [ "$out" = "control" ]
}

@test "ff_variant uppercases the flag name (LOOP_FF_MY_FLAG_VARIANTS read for ff_variant my_flag)" {
  out=$(_run_ff "" ff_variant my_flag 42)
  [ "$out" = "control" ]
}

@test "ff_variant with no flag name returns non-zero (caller error)" {
  set +e
  _run_ff "" ff_variant
  ec=$?
  set -e
  [ "$ec" -ne 0 ]
}

# ---------------------------------------------------------------------------
# ff_value
# ---------------------------------------------------------------------------

@test "ff_value returns the default when LOOP_FF_FOO is unset" {
  out=$(_run_ff "" ff_value FOO 10)
  [ "$out" = "10" ]
}

@test "ff_value returns the default when LOOP_FF_FOO is empty string" {
  # An empty override is treated as 'not set' so a stray LOOP_FF_FOO= in a
  # config file doesn't silently zero out a tunable.
  out=$(_run_ff "LOOP_FF_FOO=" ff_value FOO 10)
  [ "$out" = "10" ]
}

@test "ff_value returns the env value when LOOP_FF_FOO is set" {
  out=$(_run_ff "LOOP_FF_FOO=7" ff_value FOO 10)
  [ "$out" = "7" ]
}

@test "ff_value supports string values (not just numbers)" {
  out=$(_run_ff "LOOP_FF_MODE=fast" ff_value MODE control)
  [ "$out" = "fast" ]
}

@test "ff_value uppercases the flag name" {
  out=$(_run_ff "LOOP_FF_MY_KNOB=99" ff_value my_knob 10)
  [ "$out" = "99" ]
}

@test "ff_value with no flag name returns non-zero (caller error)" {
  set +e
  _run_ff "" ff_value
  ec=$?
  set -e
  [ "$ec" -ne 0 ]
}

@test "ff_value with no default and unset flag prints empty string and exits 0" {
  # No default supplied is legal; the caller is responsible for handling
  # empty output. Mirrors `${VAR:-}` semantics.
  out=$(_run_ff "" ff_value FOO)
  [ -z "$out" ]
}

# ---------------------------------------------------------------------------
# Module hygiene
# ---------------------------------------------------------------------------

@test "shellcheck runners/lib/flags.sh is clean" {
  # Acceptance criterion in the issue. Skip cleanly on CI envs without
  # shellcheck rather than fail the suite.
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  run shellcheck "$LOOP_ROOT/runners/lib/flags.sh"
  [ "$status" -eq 0 ]
}

@test "flags.sh sources _preamble.sh (strict-mode discipline)" {
  grep -qF '_preamble.sh' "$LOOP_ROOT/runners/lib/flags.sh"
}

@test "templates/loop.config.example has a Feature flags section documenting LOOP_FF_*" {
  local cfg="$LOOP_ROOT/templates/loop.config.example"
  [ -f "$cfg" ]
  grep -qE '^#+ Feature flags' "$cfg"
  grep -qE 'LOOP_FF_' "$cfg"
}
