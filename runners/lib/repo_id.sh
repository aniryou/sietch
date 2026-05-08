#!/usr/bin/env bash
# lib/repo_id.sh — derive per-repo identifiers from loop.config.
#
# Sourced by run-loop.sh (and by tests directly) so two `st loop start`
# fleets running against different repos don't collide on the tmux
# session name. REPO_OWNER and REPO_NAME must already be in scope (i.e.
# the caller has sourced .loop/loop.config first).

# Sanitize a repo identifier so it's safe inside tmux target syntax and
# filesystem paths. tmux treats `.` and `:` as separators inside target
# names ("session.window:pane"), and we also strip whitespace + slashes
# defensively. Anything outside [A-Za-z0-9_-] becomes `-`.
loop_sanitize_id() {
  printf '%s' "$1" | tr -c 'A-Za-z0-9_-' '-'
}

# Per-repo tmux session name. Two repos onboarded against this framework
# get distinct sessions, so `st loop start` in repo A doesn't clash with
# `st loop start` in repo B (GH#74). Format: `agent-loop-<owner>-<name>`.
loop_session_name() {
  printf 'agent-loop-%s-%s' \
    "$(loop_sanitize_id "${REPO_OWNER:-}")" \
    "$(loop_sanitize_id "${REPO_NAME:-}")"
}
