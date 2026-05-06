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

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the sietch CLI}"
: "${SIETCH_HOME:?SIETCH_HOME must be set; invoke via the sietch CLI}"
REPO="$REPO_ROOT"
# shellcheck disable=SC1091
. "$REPO/.sietch/rig.config"
cd "$REPO"

INITIAL_MSG="${1:-}"
PROMPT="$("$SIETCH_HOME/lib/render-prompt.sh" "$SIETCH_HOME/templates/issue-author.md")"

if [ -n "$INITIAL_MSG" ]; then
  PAGER=cat GIT_PAGER=cat \
  claude --append-system-prompt "$PROMPT" "$INITIAL_MSG"
else
  PAGER=cat GIT_PAGER=cat \
  claude --append-system-prompt "$PROMPT"
fi
