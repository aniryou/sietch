#!/usr/bin/env bats
# Shared bash strict-mode preamble for runners/lib/*.sh (GH#96).
#
# A single _preamble.sh source-of-truth defines the canonical strict-mode
# lines (set -u, set -o pipefail, unalias -a). Every other lib file sources
# it. These tests pin the contract:
#
#   1. _preamble.sh has the exact pinned contents (snapshot).
#   2. Every runners/lib/*.sh (except _preamble.sh itself) sources it.
#   3. Sourcing any lib file in a fresh subshell turns nounset + pipefail on.
#   4. File modes match the convention: 755 for CLI-entry libs, 644 for the
#      sourced-only libs (_preamble.sh included).

load 'helpers'

# Lib files that are expected to source _preamble.sh.
LIBS_THAT_SOURCE_PREAMBLE=(
  dispatcher.sh
  eligibility.sh
  event_log.sh
  jitter.sh
  jq_filter.sh
  onboard.sh
  pipeline_signal.sh
  render-prompt.sh
  repo_id.sh
)

EXECUTABLE_LIBS=(eligibility.sh jitter.sh render-prompt.sh)
NON_EXECUTABLE_LIBS=(
  _preamble.sh
  dispatcher.sh
  event_log.sh
  jq_filter.sh
  onboard.sh
  pipeline_signal.sh
  repo_id.sh
)

@test "_preamble.sh contents pinned to canonical strict-mode lines" {
  local expected
  expected=$(
    cat <<'EOF'
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
EOF
  )
  local actual
  actual=$(<"$LOOP_ROOT/runners/lib/_preamble.sh")
  if [ "$actual" != "$expected" ]; then
    diff <(printf '%s\n' "$expected") <(printf '%s\n' "$actual") >&2 || true
    return 1
  fi
}

@test "every runners/lib/*.sh sources _preamble.sh" {
  local lib path
  for lib in "${LIBS_THAT_SOURCE_PREAMBLE[@]}"; do
    path="$LOOP_ROOT/runners/lib/$lib"
    [ -f "$path" ] || {
      echo "missing lib file: $path" >&2
      return 1
    }
    grep -qE '_preamble\.sh' "$path" || {
      echo "$lib does not source _preamble.sh" >&2
      return 1
    }
  done
}

@test "sourcing each lib turns nounset + pipefail on" {
  # eligibility.sh / onboard.sh / render-prompt.sh need REPO_ROOT (with a
  # valid loop.config inside) and LOOP_HOME. make_repo gives us the former;
  # LOOP_HOME points to the live framework root.
  #
  # `trap 'set -o' EXIT` captures the option state regardless of how the
  # source-target exits. render-prompt.sh in particular runs CLI logic
  # unconditionally and exits 2 when no template arg is given, so a plain
  # "source then `set -o`" sequence never reaches the second statement —
  # the EXIT trap fires either way and reports state at exit time.
  local repo
  repo=$(make_repo)

  local lib path out
  for lib in "${LIBS_THAT_SOURCE_PREAMBLE[@]}"; do
    path="$LOOP_ROOT/runners/lib/$lib"
    # Some libs (render-prompt.sh) run main logic on source and exit
    # non-zero when args are missing. We don't care about the exit code
    # here — the EXIT trap captured the strict-mode flags. Allow the
    # subshell to fail without tripping bats's implicit `set -e`.
    out=$(REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
      bash --noprofile --norc -c "trap 'set -o' EXIT; . '$path' >/dev/null 2>&1" 2>/dev/null) || true
    echo "$out" | grep -qE '^nounset[[:space:]]+on$' || {
      echo "$lib: nounset is not on after source" >&2
      echo "$out" >&2
      return 1
    }
    echo "$out" | grep -qE '^pipefail[[:space:]]+on$' || {
      echo "$lib: pipefail is not on after source" >&2
      echo "$out" >&2
      return 1
    }
  done
}

@test "file modes follow CLI-vs-sourced convention" {
  local lib path
  for lib in "${EXECUTABLE_LIBS[@]}"; do
    path="$LOOP_ROOT/runners/lib/$lib"
    [ -x "$path" ] || {
      echo "$lib should be executable (755) but is not" >&2
      return 1
    }
  done
  for lib in "${NON_EXECUTABLE_LIBS[@]}"; do
    path="$LOOP_ROOT/runners/lib/$lib"
    [ -f "$path" ] || {
      echo "missing lib file: $path" >&2
      return 1
    }
    if [ -x "$path" ]; then
      echo "$lib should NOT be executable (644) but is" >&2
      return 1
    fi
  done
}
