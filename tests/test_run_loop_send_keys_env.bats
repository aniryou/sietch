#!/usr/bin/env bats
# GH#162: tmux send-keys payloads must explicitly re-export REPO_ROOT
# (and LOOP_HOME) so the per-pane re-exec of run-loop.sh sees the calling
# repo's identity, not whatever stale value the existing tmux server
# inherited at first launch.
#
# The bug: `tmux send-keys "cd '$REPO' && '$SCRIPT' --internal-role=..."`
# updates the pane shell's PWD but leaves REPO_ROOT pointing at whatever
# the tmux server was started with. The per-pane run-loop.sh then sources
# the wrong .loop/loop.config and queries the wrong GitHub repo.
#
# The fix: prefix every send-keys payload with `export REPO_ROOT='$REPO'`
# (and LOOP_HOME for defence-in-depth) before the run-loop.sh exec.

load 'helpers'

setup() {
  REPO="$BATS_TEST_TMPDIR/repo-right"
  mkdir -p "$REPO/.loop"
  awk -v wb="$BATS_TEST_TMPDIR/wb-$$" '
    /^REPO_OWNER=/    { print "REPO_OWNER=\"right-owner\""; next }
    /^REPO_NAME=/     { print "REPO_NAME=\"right-repo\""; next }
    /^WORKTREE_BASE=/ { print "WORKTREE_BASE=\"" wb "\""; next }
    { print }
  ' "$LOOP_ROOT/templates/loop.config.example" >"$REPO/.loop/loop.config"

  STUB_BIN="$BATS_TEST_TMPDIR/bin"
  CAPTURE="$BATS_TEST_TMPDIR/sendkeys.log"
  mkdir -p "$STUB_BIN"
  : >"$CAPTURE"

  # tmux stub: capture every send-keys payload (one per line) so the test
  # can assert their contents. Other tmux subcommands return canned
  # success / pane-id values sufficient to drive start_session() through
  # to the send-keys block.
  cat >"$STUB_BIN/tmux" <<'STUB'
#!/usr/bin/env bash
sub="${1:-}"; shift || true
case "$sub" in
  has-session) exit 1 ;;       # pretend no session, force the create path
  list-panes)  echo "%0" ;;    # initial pane id
  split-window)
    # Allocate a unique-ish pane id; start_session uses these as -t targets.
    counter_file="${TMPDIR:-/tmp}/tmux-stub-counter-$$"
    n=$(cat "$counter_file" 2>/dev/null || echo 0)
    n=$((n + 1))
    echo "$n" >"$counter_file"
    printf '%%%d\n' "$n"
    ;;
  send-keys)
    # Argv after `send-keys`: -t <pane> <payload> Enter. Capture verbatim.
    printf '%s\n' "$*" >>"$TMUX_STUB_CAPTURE"
    ;;
  *) ;;                         # new-session, set-option, select-pane, etc.
esac
exit 0
STUB
  chmod +x "$STUB_BIN/tmux"
  export TMUX_STUB_CAPTURE="$CAPTURE"
}

@test "GH#162: send-keys payloads re-export REPO_ROOT to the calling REPO" {
  # Pre-export REPO_ROOT and LOOP_HOME to *wrong* values, simulating a
  # stale tmux server env. The fix must override these in every pane.
  export REPO_ROOT_PREEXISTING=/tmp/some-wrong-repo-from-other-fleet
  export LOOP_HOME_PREEXISTING=/tmp/some-wrong-loop-home

  run env \
    REPO_ROOT="$REPO" \
    LOOP_HOME="$LOOP_ROOT" \
    PATH="$STUB_BIN:$PATH" \
    bash "$LOOP_ROOT/runners/run-loop.sh" start --detach --dev-instances=2

  [ "$status" -eq 0 ] || {
    echo "run-loop.sh exited $status; output:" >&2
    echo "$output" >&2
    return 1
  }

  # 3 dispatch panes (review/followup/conflicts) + 2 dev panes = 5.
  payload_count=$(wc -l <"$CAPTURE" | tr -d ' ')
  [ "$payload_count" -eq 5 ] || {
    echo "Expected 5 send-keys captures, got $payload_count:" >&2
    cat "$CAPTURE" >&2
    return 1
  }

  # Every payload must re-export REPO_ROOT to the intended REPO.
  while IFS= read -r line; do
    [[ "$line" == *"export REPO_ROOT='$REPO'"* ]] || {
      echo "Payload missing 'export REPO_ROOT=$REPO':" >&2
      echo "  $line" >&2
      return 1
    }
  done <"$CAPTURE"

  # And LOOP_HOME for defence-in-depth (so SCRIPT path resolution and
  # subsequent library sourcing also point at the intended loop install).
  while IFS= read -r line; do
    [[ "$line" == *"LOOP_HOME='$LOOP_ROOT'"* ]] || {
      echo "Payload missing 'LOOP_HOME=$LOOP_ROOT':" >&2
      echo "  $line" >&2
      return 1
    }
  done <"$CAPTURE"

  # The export must come BEFORE the run-loop.sh exec (i.e. before
  # `--internal-role=`), otherwise the per-pane run-loop.sh runs with
  # the still-stale env and fails the line-39 :? guard or sources the
  # wrong loop.config.
  while IFS= read -r line; do
    export_pos=${line%%export REPO_ROOT*}
    role_pos=${line%%--internal-role=*}
    [ "${#export_pos}" -lt "${#role_pos}" ] || {
      echo "'export REPO_ROOT=' must precede '--internal-role=':" >&2
      echo "  $line" >&2
      return 1
    }
  done <"$CAPTURE"
}
