#!/usr/bin/env bash
# lib/dispatcher.sh — Pure jq-filter helpers used by the dispatcher loops in
# run-loop.sh. Extracted into a sourceable library so the bats suite can
# exercise them without launching the dispatcher.
#
# Each function PRINTS a jq filter expression on stdout. The dispatcher pipes
# this into `gh pr list --jq ...`; tests pipe it through plain `jq` against
# fixture JSON.
#
# Note: `gh`'s `--jq` is a single-string flag. The earlier form
#   `--jq --arg prefix "${BRANCH_PREFIX}/" '<filter>'`
# was malformed — `--arg` was consumed as the filter value and the rest of
# the args were ignored, so every dispatcher cycle silently returned zero
# PRs. Shell-interpolating the prefix into the filter avoids that whole
# class of bug.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"

# jq filter: emit .number for each open dev-agent PR whose isDraft == false.
# Argument: branch prefix (without trailing slash), e.g. "dev-agent".
_dispatch_followup_jq() {
  printf '.[] | select(.headRefName | startswith("%s/")) | select(.isDraft == false) | .number' "$1"
}

# jq filter: emit .number for each open, non-draft dev-agent PR whose
# mergeable state is CONFLICTING.
# Arguments:
#   $1 = branch prefix (without trailing slash), e.g. "dev-agent"
#   $2 = (optional) blocked-human label name. When non-empty, PRs carrying
#        the label are excluded — closes the per-PR loop after the Mode 3
#        wrapper escalates DEV_CONFLICTS_FAILURE_RETRY_LIMIT consecutive
#        hard-failures (GH#111). Empty/omitted = no label filtering, for
#        backward-compat with older callers and tests.
_dispatch_conflicts_jq() {
  local prefix="$1"
  local label="${2:-}"
  if [ -n "$label" ]; then
    printf '.[] | select(.headRefName | startswith("%s/")) | select(.mergeable == "CONFLICTING") | select(.isDraft == false) | select((.labels // [] | map(.name)) | index("%s") | not) | .number' "$prefix" "$label"
  else
    printf '.[] | select(.headRefName | startswith("%s/")) | select(.mergeable == "CONFLICTING") | select(.isDraft == false) | .number' "$prefix"
  fi
}

# jq filter: emit .number for each open, non-draft dev-agent PR.
# Same candidate scan as the follow-up filter — verdict / staleness / CI /
# human-veto gating happens later in eligibility_merge_pr, not here.
# Argument: branch prefix (without trailing slash).
_dispatch_merge_jq() {
  printf '.[] | select(.headRefName | startswith("%s/")) | select(.isDraft == false) | .number' "$1"
}
