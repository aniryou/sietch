#!/usr/bin/env bash
# Wrapper for the interactive issue-author agent.
# Unlike run-developer.sh and run-reviewer.sh, this launches claude in
# interactive mode (no -p, no stream-json) so the agent can ask you questions
# and show you draft issue bodies before creating them.
#
# Usage:
#   st issue                # opens an interactive session
#   st issue "your request" # starts with this as the first message

set -u
set -o pipefail
\unalias -a 2>/dev/null || true

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.loop/loop.config"
cd "$REPO"

INITIAL_MSG="${1:-}"
PROMPT="$("$LOOP_HOME/runners/lib/render-prompt.sh" "$LOOP_HOME/templates/issue-author.md")"

if [ -n "$INITIAL_MSG" ]; then
  PAGER=cat GIT_PAGER=cat \
  claude --append-system-prompt "$PROMPT" "$INITIAL_MSG"
else
  PAGER=cat GIT_PAGER=cat \
  claude --append-system-prompt "$PROMPT"
fi
