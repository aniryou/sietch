#!/usr/bin/env bash
# Wrapper for the headless reviewer agent.
# Streams readable output to a log while keeping raw stream-json for debugging.
#
# Usage:
#   st review
#
# Exit code is the agent's exit code.

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.loop/loop.config"

# Preflight: skip the LLM if no dev-agent PR needs review at its current
# headRefOid. Exit code 2 lets run-loop.sh distinguish "skipped, no work"
# from "ran successfully" so it can apply exponential backoff.
EL_COUNT=$("$LOOP_HOME/runners/lib/eligibility.sh" review)
EL_RC=$?
case "$EL_RC" in
  0) echo "[wrapper] eligibility: $EL_COUNT PR(s) pending review; proceeding" ;;
  1)
    echo "[wrapper] eligibility: no PRs need review; skipping LLM invocation"
    echo "[wrapper] result=no-work"
    exit 2
    ;;
  *) echo "[wrapper] eligibility: predicate failed (rc=$EL_RC); proceeding to be safe" >&2 ;;
esac
unset EL_COUNT EL_RC

# $$ suffix keeps log paths unique when two wrappers start in the same second.
TS="$(date +%Y%m%d-%H%M%S)-$$"
LOG="/tmp/reviewer-agent-${TS}.log"
RAW="/tmp/reviewer-agent-${TS}.jsonl"

cleanup() {
  local exit_code=$?
  echo "[wrapper] reviewer exited with code $exit_code" >&2
  echo "[wrapper] live log: $LOG" >&2
  echo "[wrapper] raw json: $RAW" >&2
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# jq filter: same stream-json → human-readable filter as run-developer.sh,
# sourced from the shared lib so both panes emit identical event tags and
# ANSI colors. Honors NO_COLOR.
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/jq_filter.sh"

cd "$REPO" || exit 1

echo "[wrapper] live log: $LOG"
echo "[wrapper] raw json: $RAW"
echo "[wrapper] tail with: tail -f $LOG"
echo

PAGER=cat GIT_PAGER=cat \
  claude -p "Run the reviewer orchestrator workflow defined in your system prompt. Begin the scan, then dispatch a sub-agent for the chosen PR via the Agent tool. Single-pass — exit after one dispatch." \
  --append-system-prompt "$("$LOOP_HOME/runners/lib/render-prompt.sh" "$LOOP_HOME/templates/reviewer-orchestrator.md")" \
  --permission-mode bypassPermissions \
  --max-turns "$REVIEWER_MAX_TURNS" \
  --verbose \
  --output-format stream-json \
  2> >(tee "$RAW.stderr" >&2) \
  | tee "$RAW" \
  | jq -r --unbuffered "$JQ_FILTER" 2>/dev/null \
  | tee "$LOG"
