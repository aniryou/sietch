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

set -u

# jq filter: emit .number for each open dev-agent PR whose isDraft == false.
# Argument: branch prefix (without trailing slash), e.g. "dev-agent".
_dispatch_followup_jq() {
  printf '.[] | select(.headRefName | startswith("%s/")) | select(.isDraft == false) | .number' "$1"
}

# jq filter: emit .number for each open, non-draft dev-agent PR whose
# mergeable state is CONFLICTING.
# Argument: branch prefix (without trailing slash).
_dispatch_conflicts_jq() {
  printf '.[] | select(.headRefName | startswith("%s/")) | select(.mergeable == "CONFLICTING") | select(.isDraft == false) | .number' "$1"
}
