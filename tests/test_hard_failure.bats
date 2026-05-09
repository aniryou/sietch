#!/usr/bin/env bats
# GH#108 — runners/lib/hard_failure.sh: shared idempotent-escalate helper.
#
# Two wrappers (run-developer.sh, run-reviewer.sh) currently each implement
# the same shape of hard-failure escalation: idempotent label apply + single
# operator comment, gated on whether the label is already present. This file
# pins the contract for the extracted helper so any future mode that wants
# escalation gets the same idempotent semantics in one line.
#
# Sub-issue 1 of the GH#108 epic: ship the helper + tests; do NOT yet replace
# existing call sites in run-developer.sh / run-reviewer.sh (sub-issues 2/3).
#
# Helper signature:
#   hard_failure_idempotent_escalate \
#     <target_kind> <target> <escalation_label> <comment_body> \
#     [label_color] [label_description]
#
# Behavior:
#   - target_kind ∈ {issue, pr}; anything else → rc=2, no gh side effects.
#   - If escalation_label already on target → log idempotent skip, return 0,
#     no `gh edit` / `gh comment` calls fire.
#   - Else → `gh label create --force` (idempotent), `gh <kind> edit
#     --add-label`, `gh <kind> comment --body`. Each best-effort (|| true).
#   - `gh <kind> view` rc=1 → treated as "label not present" (matches the
#     existing wrappers' default-on-failure semantics): helper still applies
#     the label rather than crashing the wrapper. Returns 0.

load 'helpers'

# Build a tmp PATH dir with a `gh` shim that:
#   (a) Serves `gh <issue|pr> view --json labels` from a state file so each
#       test can drive the "already escalated?" branch.
#   (b) Captures every call's argv to $state/gh-args so the test can assert
#       which calls fired (and which did NOT) after the helper returns.
#
# The state files the shim reads:
#   $state/labels-json — the JSON the view call should emit on stdout.
#                        (Default: '{"labels":[]}'.)
#   $state/view-rc     — exit code for `gh <kind> view` (default 0).
_make_gh_stub() {
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  local state="$BATS_TEST_TMPDIR/state"
  mkdir -p "$tmpbin" "$state"

  cat >"$tmpbin/gh" <<STUB
#!/usr/bin/env bash
ARGS=("\$@")
SUB1="\${ARGS[0]:-}"
SUB2="\${ARGS[1]:-}"

case "\$SUB1 \$SUB2" in
  "issue view"|"pr view")
    LABELS_JSON='{"labels":[]}'
    if [ -f '$state/labels-json' ]; then
      LABELS_JSON=\$(cat '$state/labels-json')
    fi
    VIEW_RC=0
    if [ -f '$state/view-rc' ]; then
      VIEW_RC=\$(cat '$state/view-rc')
    fi
    if [ "\$VIEW_RC" != "0" ]; then
      exit "\$VIEW_RC"
    fi
    printf '%s\n' "\$LABELS_JSON"
    exit 0
    ;;
esac

# All other calls (label create, issue/pr edit, issue/pr comment) get logged.
{
  printf 'CALL: '
  printf '%s ' "\$@"
  printf '\n'
} >>'$state/gh-args'
exit 0
STUB
  chmod +x "$tmpbin/gh"
}

# Convenience: invoke the helper inside the stubbed PATH. Args forwarded.
_run_helper() {
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" \
    bash -c "set -e; . '$LOOP_ROOT/runners/lib/hard_failure.sh'; \
             hard_failure_idempotent_escalate \"\$@\"" _ "$@"
}

# ---------------------------------------------------------------------------
# Fresh-apply path: label is absent → 3 calls fire (label create, <kind> edit,
# <kind> comment). Both target_kind=issue and target_kind=pr exercised.
# ---------------------------------------------------------------------------

@test "hard_failure_idempotent_escalate: issue + label absent → label create + issue edit --add-label + issue comment all fire (GH#108)" {
  _make_gh_stub
  : >"$BATS_TEST_TMPDIR/state/labels-json"  # default: empty labels
  echo '{"labels":[]}' >"$BATS_TEST_TMPDIR/state/labels-json"

  run _run_helper issue 42 blocked:human "stuck on issue #42"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  # Three side-effecting calls fired in order.
  grep -qF 'label create blocked:human' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'issue edit 42' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--add-label blocked:human' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'issue comment 42' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'stuck on issue #42' "$BATS_TEST_TMPDIR/state/gh-args"
  # Each call exactly once (no duplicate, no pile-up).
  [ "$(grep -c 'label create blocked:human' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
  [ "$(grep -c 'issue edit 42' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
  [ "$(grep -c 'issue comment 42' "$BATS_TEST_TMPDIR/state/gh-args")" -eq 1 ]
}

@test "hard_failure_idempotent_escalate: pr + label absent → label create + pr edit + pr comment fire (target_kind=pr) (GH#108)" {
  _make_gh_stub
  echo '{"labels":[]}' >"$BATS_TEST_TMPDIR/state/labels-json"

  run _run_helper pr 99 reviewer:needs-human "reviewer hard-failed on PR #99"

  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  # PR-flavoured calls — not issue.
  grep -qF 'label create reviewer:needs-human' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr edit 99' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF -- '--add-label reviewer:needs-human' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'pr comment 99' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'reviewer hard-failed on PR #99' "$BATS_TEST_TMPDIR/state/gh-args"
  # No issue-flavoured calls leaked.
  ! grep -qF 'issue edit' "$BATS_TEST_TMPDIR/state/gh-args"
  ! grep -qF 'issue comment' "$BATS_TEST_TMPDIR/state/gh-args"
}

# ---------------------------------------------------------------------------
# Idempotent-skip path: label is already present → helper returns 0 without
# making any edit/comment calls. The label-create call is also skipped (no
# point re-creating a label we already know exists on the target).
# ---------------------------------------------------------------------------

@test "hard_failure_idempotent_escalate: issue + label already present → no edit/comment/label-create calls; stderr says 'idempotent skip' (GH#108)" {
  _make_gh_stub
  echo '{"labels":[{"name":"blocked:human"}]}' \
    >"$BATS_TEST_TMPDIR/state/labels-json"

  run _run_helper issue 42 blocked:human "stuck on issue #42"

  [ "$status" -eq 0 ]
  # No mutating side effects fired at all.
  [ ! -f "$BATS_TEST_TMPDIR/state/gh-args" ] \
    || [ ! -s "$BATS_TEST_TMPDIR/state/gh-args" ]
  # Stderr carries the operator-visibility log line.
  echo "$output" | grep -qF 'idempotent skip'
}

@test "hard_failure_idempotent_escalate: pr + escalation label already present → fully idempotent (no calls) (GH#108)" {
  _make_gh_stub
  echo '{"labels":[{"name":"reviewer:needs-human"},{"name":"enhancement"}]}' \
    >"$BATS_TEST_TMPDIR/state/labels-json"

  run _run_helper pr 99 reviewer:needs-human "stuck"

  [ "$status" -eq 0 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/gh-args" ] \
    || [ ! -s "$BATS_TEST_TMPDIR/state/gh-args" ]
  echo "$output" | grep -qF 'idempotent skip'
}

# ---------------------------------------------------------------------------
# Defensive: gh view fails (network blip, transient API outage). Helper must
# treat as "label not present" (matching the existing wrappers' default-on-
# failure semantics in run-developer.sh:474-489 and run-reviewer.sh:188-220
# where HAS_LABEL defaults to 0 on jq/gh failure) and still apply, rather
# than crash the wrapper.
# ---------------------------------------------------------------------------

@test "hard_failure_idempotent_escalate: gh view rc=1 → falls through safely, applies label (treats as absent) (GH#108)" {
  _make_gh_stub
  echo 1 >"$BATS_TEST_TMPDIR/state/view-rc"

  run _run_helper issue 42 blocked:human "stuck"

  [ "$status" -eq 0 ]
  # The fall-through path still applies the label — view failure is treated
  # as "label not present" (safer than silently giving up: better to apply
  # than to leak tokens by failing to escalate).
  [ -f "$BATS_TEST_TMPDIR/state/gh-args" ]
  grep -qF 'label create blocked:human' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'issue edit 42' "$BATS_TEST_TMPDIR/state/gh-args"
  grep -qF 'issue comment 42' "$BATS_TEST_TMPDIR/state/gh-args"
}

# ---------------------------------------------------------------------------
# Defensive: invalid target_kind → helper returns rc=2 with no gh calls.
# Catches typos like `hard_failure_idempotent_escalate Issue 42 ...`
# (capitalised) before they corrupt the gh CLI invocation.
# ---------------------------------------------------------------------------

@test "hard_failure_idempotent_escalate: invalid target_kind → rc=2, no gh side effects (GH#108)" {
  _make_gh_stub
  echo '{"labels":[]}' >"$BATS_TEST_TMPDIR/state/labels-json"

  run _run_helper bogus 42 blocked:human "stuck"

  [ "$status" -eq 2 ]
  [ ! -f "$BATS_TEST_TMPDIR/state/gh-args" ] \
    || [ ! -s "$BATS_TEST_TMPDIR/state/gh-args" ]
}

# ---------------------------------------------------------------------------
# Source-of-truth: helper file exists, exports the documented function name,
# and is sourced by both wrappers (per the GH#108 sub-issue 1 scope: source
# but DON'T yet replace existing call sites — that's sub-issues 2 and 3).
# ---------------------------------------------------------------------------

@test "hard_failure.sh: file exists and defines hard_failure_idempotent_escalate (GH#108)" {
  [ -f "$LOOP_ROOT/runners/lib/hard_failure.sh" ]
  grep -qE '^hard_failure_idempotent_escalate\(\)' \
    "$LOOP_ROOT/runners/lib/hard_failure.sh"
}

@test "run-developer.sh: sources runners/lib/hard_failure.sh (GH#108 sub-issue 1)" {
  grep -qF 'lib/hard_failure.sh' "$LOOP_ROOT/runners/run-developer.sh"
}

@test "run-reviewer.sh: sources runners/lib/hard_failure.sh (GH#108 sub-issue 1)" {
  grep -qF 'lib/hard_failure.sh' "$LOOP_ROOT/runners/run-reviewer.sh"
}
