#!/usr/bin/env bats
# tests/test_flags_variant.bats — exercise deterministic A/B variant
# assignment in runners/lib/flags.sh (GH#189).
#
# Determinism matters because the dev-agent dispatchers re-fire the same
# wrapper on the same issue or PR many times — Mode 2 follow-up cycles,
# Mode 3 conflict triage, hard-failure retries, reviewer re-runs. If
# ff_variant returned a fresh random arm per call, one issue could be
# control on one cycle and treatment on the next, polluting any experiment.
#
# Acceptance criteria covered here:
#   - ff_variant FOO 42 returns the same arm every time, given the same
#     LOOP_FF_FOO_VARIANTS.
#   - Across 1000 distinct ids with VARIANTS="a,b", each arm gets 500 ± 50.
#   - LOOP_FF_FOO_FORCE=treatment ff_variant FOO 42 returns treatment
#     regardless of hash.
#   - The chosen arm appears in the flag_read event (variant +
#     assignment_source=hash|force).

load 'helpers'

# Run a helper in a clean subshell with the supplied env vars. Echoes stdout;
# returns the helper's exit code. Mirrors _run_ff in test_flags.bats.
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
# Determinism
# ---------------------------------------------------------------------------

@test "ff_variant returns the same arm on 10 successive calls for the same (flag, id)" {
  local arm out
  arm=$(_run_ff "LOOP_FF_FOO_VARIANTS=a,b" ff_variant FOO 42)
  [ -n "$arm" ] || { echo "first call returned empty"; return 1; }
  for i in 1 2 3 4 5 6 7 8 9; do
    out=$(_run_ff "LOOP_FF_FOO_VARIANTS=a,b" ff_variant FOO 42)
    [ "$out" = "$arm" ] || { echo "iteration $i: got '$out', expected '$arm'"; return 1; }
  done
}

@test "ff_variant determinism survives across separate processes" {
  # Two independent invocations (separate bash processes via env -i) must
  # produce the same arm — the function holds no per-process state and the
  # hash inputs are stable.
  local a b
  a=$(_run_ff "LOOP_FF_FOO_VARIANTS=control,treatment" ff_variant ROLLOUT 7)
  b=$(_run_ff "LOOP_FF_FOO_VARIANTS=control,treatment" ff_variant ROLLOUT 7)
  [ "$a" = "$b" ]
}

@test "ff_variant assignment changes when the flag name changes" {
  # Same id, different flag names — at least one collision pair should
  # differ within a handful of probes. We assert this against a fixed set
  # of names that are known to diverge on SHA-256(id||name).
  local seen_a=0 seen_b=0 out
  for name in FOO BAR BAZ QUX; do
    out=$(_run_ff "LOOP_FF_${name}_VARIANTS=a,b" ff_variant "$name" 42)
    [ "$out" = "a" ] && seen_a=1
    [ "$out" = "b" ] && seen_b=1
  done
  [ "$seen_a" = "1" ] && [ "$seen_b" = "1" ] || {
    echo "expected both arms across {FOO,BAR,BAZ,QUX} with id=42, got seen_a=$seen_a seen_b=$seen_b"
    return 1
  }
}

# ---------------------------------------------------------------------------
# Distribution
# ---------------------------------------------------------------------------

@test "ff_variant distributes 1000 distinct ids across two arms within ±50 of 500" {
  # Critical correctness test: across a uniform-random-looking input
  # space (1..1000), SHA-256 mod 2 must give a near-uniform split. We
  # batch the 1000 calls into ONE subshell to avoid 1000 fork+source
  # cycles (which would dwarf the cost of the hash itself).
  local out count_a count_b
  set +e
  out=$(env -i PATH="$PATH" LOOP_FF_FOO_VARIANTS=a,b bash -c '
    . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
    for i in $(seq 1 1000); do
      ff_variant FOO "$i"
    done
  ' | sort | uniq -c)
  set -e
  count_a=$(printf '%s\n' "$out" | awk '$2=="a"{print $1}')
  count_b=$(printf '%s\n' "$out" | awk '$2=="b"{print $1}')
  [ -n "$count_a" ] || { echo "no 'a' bucket emitted; raw:\n$out"; return 1; }
  [ -n "$count_b" ] || { echo "no 'b' bucket emitted; raw:\n$out"; return 1; }
  [ "$count_a" -ge 450 ] && [ "$count_a" -le 550 ] || { echo "a count $count_a out of [450,550]; raw:\n$out"; return 1; }
  [ "$count_b" -ge 450 ] && [ "$count_b" -le 550 ] || { echo "b count $count_b out of [450,550]; raw:\n$out"; return 1; }
}

# ---------------------------------------------------------------------------
# FORCE override
# ---------------------------------------------------------------------------

@test "LOOP_FF_FOO_FORCE pins ff_variant to the named arm regardless of hash" {
  local out
  out=$(_run_ff "LOOP_FF_FOO_VARIANTS=a,b LOOP_FF_FOO_FORCE=b" ff_variant FOO 42)
  [ "$out" = "b" ] || { echo "expected 'b', got '$out'"; return 1; }
}

@test "LOOP_FF_FOO_FORCE wins over the hash assignment that would otherwise apply" {
  # Compute the hash arm with no FORCE, then re-run with FORCE pinned to
  # the OTHER arm and confirm it flips.
  local natural other out
  natural=$(_run_ff "LOOP_FF_FOO_VARIANTS=a,b" ff_variant FOO 99)
  if [ "$natural" = "a" ]; then other="b"; else other="a"; fi
  out=$(_run_ff "LOOP_FF_FOO_VARIANTS=a,b LOOP_FF_FOO_FORCE=$other" ff_variant FOO 99)
  [ "$out" = "$other" ] || { echo "expected '$other', got '$out' (natural was '$natural')"; return 1; }
}

@test "LOOP_FF_FOO_FORCE uppercases the flag name (LOOP_FF_MY_FLAG_FORCE for my_flag)" {
  local out
  out=$(_run_ff "LOOP_FF_MY_FLAG_VARIANTS=a,b LOOP_FF_MY_FLAG_FORCE=b" ff_variant my_flag 42)
  [ "$out" = "b" ]
}

# ---------------------------------------------------------------------------
# flag_read event emission
# ---------------------------------------------------------------------------

@test "ff_variant emits a flag_read event carrying variant and assignment_source=hash" {
  local log="$BATS_TEST_TMPDIR/events.jsonl"
  : >"$log"
  _run_ff "LOOP_FF_FOO_VARIANTS=a,b LOOP_EVENT_LOG=$log" ff_variant FOO 42
  [ -s "$log" ] || { echo "no events written"; return 1; }
  local line
  line=$(tail -1 "$log")
  printf '%s\n' "$line" | jq -e '.event == "flag_read"' >/dev/null || { echo "event != flag_read: $line"; return 1; }
  printf '%s\n' "$line" | jq -e '.variant == "a" or .variant == "b"' >/dev/null || { echo "variant not in {a,b}: $line"; return 1; }
  printf '%s\n' "$line" | jq -e '.assignment_source == "hash"' >/dev/null || { echo "assignment_source != hash: $line"; return 1; }
  printf '%s\n' "$line" | jq -e '.flag == "FOO"' >/dev/null || { echo "flag != FOO: $line"; return 1; }
}

@test "ff_variant emits assignment_source=force when LOOP_FF_FOO_FORCE is set" {
  local log="$BATS_TEST_TMPDIR/events.jsonl"
  : >"$log"
  _run_ff "LOOP_FF_FOO_VARIANTS=a,b LOOP_FF_FOO_FORCE=b LOOP_EVENT_LOG=$log" ff_variant FOO 42
  local line
  line=$(tail -1 "$log")
  printf '%s\n' "$line" | jq -e '.event == "flag_read"' >/dev/null || { echo "event != flag_read: $line"; return 1; }
  printf '%s\n' "$line" | jq -e '.variant == "b"' >/dev/null || { echo "variant != b: $line"; return 1; }
  printf '%s\n' "$line" | jq -e '.assignment_source == "force"' >/dev/null || { echo "assignment_source != force: $line"; return 1; }
}

@test "ff_variant does NOT emit flag_read when LOOP_FF_FOO_VARIANTS is unset" {
  # When VARIANTS isn't configured the helper is a no-op returning "control"
  # — emitting flag_read for an unconfigured flag would pollute the event
  # log with reads no one is gating on.
  local log="$BATS_TEST_TMPDIR/events.jsonl"
  : >"$log"
  _run_ff "LOOP_EVENT_LOG=$log" ff_variant FOO 42
  ! grep -q '"event":"flag_read"' "$log" || { echo "unexpected flag_read event: $(cat "$log")"; return 1; }
}

# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

@test "ff_variant returns the sole arm when VARIANTS has a single element" {
  local out
  out=$(_run_ff "LOOP_FF_FOO_VARIANTS=only" ff_variant FOO 42)
  [ "$out" = "only" ]
}

@test "ff_variant tolerates whitespace around CSV entries (VARIANTS='a, b ,c')" {
  # Operators copy-paste CSV lists with spaces. The helper strips per-arm
  # whitespace so an accidental " b" doesn't surface as a literal arm
  # name in events. Bypass _run_ff because its unquoted-env_pairs split
  # cannot pass a value containing a literal space.
  local out
  out=$(env -i PATH="$PATH" LOOP_FF_FOO_VARIANTS='a, b ,c' bash -c '
    . "'"$LOOP_ROOT"'/runners/lib/flags.sh"
    ff_variant FOO 42
  ')
  case "$out" in
    a|b|c) ;;
    *) echo "expected one of {a,b,c}, got '$out'"; return 1 ;;
  esac
}

@test "ff_variant skips empty CSV entries (VARIANTS=',a,,b,')" {
  # Same trailing/leading/double-comma robustness — empty arm strings
  # must not show up as assignments.
  local out
  out=$(_run_ff "LOOP_FF_FOO_VARIANTS=,a,,b," ff_variant FOO 42)
  case "$out" in
    a|b) ;;
    *) echo "expected one of {a,b}, got '$out'"; return 1 ;;
  esac
}

@test "ff_variant with empty issue_id is still deterministic" {
  # Empty id is a valid (though unusual) input — the hash of ('' || flag)
  # is well-defined, so two calls with empty id must agree.
  local a b
  a=$(_run_ff "LOOP_FF_FOO_VARIANTS=a,b" ff_variant FOO "")
  b=$(_run_ff "LOOP_FF_FOO_VARIANTS=a,b" ff_variant FOO "")
  [ "$a" = "$b" ]
}
