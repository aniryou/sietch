#!/usr/bin/env bats
# Pins the bd-dep direction in agent templates.
#
# GH#67: Both developer.md and reviewer.md previously instructed agents to call
# `bd dep add <child> $PARENT`, which per `bd dep add <blocked-id> <blocker-id>`
# semantics makes the parent block each child — the reverse of the prose
# intent ("parent depends on each child being closed"). Symptom: every step
# `bd close` was rejected with "blocked by open issues" and agents had to
# retry with `--force`, ritualizing the workaround and masking real bugs.
#
# Correct form is `bd dep add $PARENT <child>` (parent is blocked-by child).
# This test pins the invariant so a future template edit can't silently
# regress the direction.

load 'helpers'

setup() {
  DEV_TPL="$LOOP_ROOT/templates/developer.md"
  REV_TPL="$LOOP_ROOT/templates/reviewer.md"
}

# --- developer.md -------------------------------------------------------

@test "developer template uses 'bd dep add \$PARENT <child>' (parent blocked-by child)" {
  grep -qE 'bd dep add \$PARENT <child>' "$DEV_TPL"
}

@test "developer template does not use the reversed 'bd dep add <child> \$PARENT' form" {
  # The reversed form would re-introduce GH#67. Match permissively (allow any
  # whitespace between tokens) so a future reformatting can't sneak it back.
  ! grep -qE 'bd dep add[[:space:]]+<child>[[:space:]]+\$PARENT' "$DEV_TPL"
}

# --- reviewer.md --------------------------------------------------------

@test "reviewer template includes an explicit 'bd dep add \$PARENT <child>' example" {
  grep -qE 'bd dep add \$PARENT <child>' "$REV_TPL"
}

@test "reviewer template does not use the reversed 'bd dep add <child> \$PARENT' form" {
  ! grep -qE 'bd dep add[[:space:]]+<child>[[:space:]]+\$PARENT' "$REV_TPL"
}
