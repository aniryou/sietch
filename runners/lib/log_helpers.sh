#!/usr/bin/env bash
# lib/log_helpers.sh — Shared helpers for parsing append-only logs.
#
# Wrappers tail orchestrator/agent logs to extract structured markers
# (`result=...`, `reason=...`) emitted as the agent runs. These logs are
# append-only: when an agent retries within one session, both the stale and
# current marker land in the file. The canonical value is therefore the LAST
# matching line — a `head -1` read returns whichever marker fired first,
# which is exactly the wrong answer for state-driven follow-up actions
# (post a stub on PR #N, escalate via reason=R, etc.).
#
# loop_marker_last <pattern> [<file>|-]
#   <file>   path to a regular file (read with grep -E)
#   -        explicitly read from stdin
#   omitted  same as `-` (read from stdin)
#
#   Returns the last line matching the extended-regex <pattern>, or empty
#   output. Exit code is always 0: a missing file or zero matches is a
#   regular outcome at the call sites (no marker emitted yet, log absent
#   on first run), not an error to propagate.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"

loop_marker_last() {
  local pattern="${1:?loop_marker_last: pattern required}"
  local source="${2:--}"

  if [ "$source" = "-" ]; then
    grep -E "$pattern" 2>/dev/null | tail -1 || true
  elif [ -f "$source" ]; then
    grep -E "$pattern" "$source" 2>/dev/null | tail -1 || true
  fi
  return 0
}
