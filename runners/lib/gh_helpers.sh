#!/usr/bin/env bash
# lib/gh_helpers.sh — Shared `gh`-related shell helpers for the loop wrappers.
#
# The pattern this replaces is `gh ... >/dev/null 2>&1 || true` at best-effort
# recovery sites in run-developer.sh (triage-untractable draft + comment, Mode 3
# hard-fail draft + comment, Mode 2 follow-up hard-fail comment). Those calls
# must not break the wrapper if `gh` fails — but discarding stderr AND swallowing
# the non-zero exit also hid the failure entirely. When the recovery action
# silently didn't happen, downstream code (e.g. the conflicts dispatcher's
# `isDraft == false` filter) ended up in a state inconsistent with what the
# operator expected, with no breadcrumb for triage.
#
# Functions provided:
#
#   gh_best_effort <gh args...>
#       Run a `gh` command silently. On non-zero exit, emit one line on stderr:
#         [wrapper] gh-best-effort FAILED rc=<rc> cmd="<args>"
#       Always return 0, so callers under `set -e` are unaffected. The helper
#       does NOT propagate `gh`'s own stderr — only its own breadcrumb — so
#       transient gh chatter doesn't add noise to the wrapper pane on success.

# `set -e` interaction: assigning the exit code via `cmd || rc=$?` is the
# canonical way to capture rc without tripping errexit. Using a bare
# `cmd; rc=$?` would fault under `set -e` even with the trailing `return 0`,
# because the bare-command exit happens before `rc=` runs.
gh_best_effort() {
  local rc=0
  PAGER=cat GIT_PAGER=cat "$@" >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[wrapper] gh-best-effort FAILED rc=%d cmd="%s"\n' "$rc" "$*" >&2
  fi
  return 0
}
