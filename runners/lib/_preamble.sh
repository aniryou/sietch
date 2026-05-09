#!/usr/bin/env bash
# lib/_preamble.sh — canonical bash strict-mode lines for runners/lib/*.sh.
#
# Sourced (not executed) by every other file in this directory so the
# strict-mode setup stays consistent. Adding new flags here propagates to
# every lib without per-file edits. Keep this file MINIMAL — anything more
# than the three canonical lines belongs in the lib that needs it.
#
# Why each line:
#   set -u             — unset-variable references abort. Catches typo'd
#                        env-var lookups (`$REPO_RPOT`) at source time
#                        instead of producing silent empty strings.
#   set -o pipefail    — a pipeline's exit status is the rightmost non-zero
#                        rc, not the last command's. Without this, a failure
#                        in `gh ... | jq ...` is masked by jq's success.
#   \unalias -a        — clear any aliases inherited from the user's shell
#                        (interactive `gh=...` aliases, etc.) so library
#                        code resolves command names against PATH, not the
#                        user's interactive config.
#
# `set -e` is intentionally NOT here. Adding it is a deliberate, separate
# decision per lib — several libs rely on non-zero rcs from probes
# (`kill -0`, `command -v`, `[ -d ... ]`) without wanting an immediate exit.
#
# This file is sourced — never executed directly. No shebang behavior is
# relied upon; the shebang is informational so editors highlight it as bash.

set -u
set -o pipefail
\unalias -a 2>/dev/null || true
