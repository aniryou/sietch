#!/usr/bin/env bash
# lib/jq_filter.sh — Shared stream-json → human-readable jq filter.
#
# Sourced by runners/run-developer.sh and runners/run-reviewer.sh so both
# panes use identical event tags and ANSI colors. Output: defines $JQ_FILTER
# in the sourcing shell.
#
# Color mapping (the entire line is colorized — tag color spans tag + payload):
#   [init]    dim grey   — boilerplate context (model, tool count, cwd)
#   [text]    yellow     — agent narration
#   [tool]    cyan       — action being taken
#   [result]  dim grey   — voluminous tool output, deprioritized
#   [done]    green/red  — green on subtype=="success", red on any error_*
# A single ANSI reset is emitted at end-of-line so payloads aren't lost in a
# busy pane; this defeats the point of a 6-char tag in front of 200 chars of
# payload. NO_COLOR strips all escapes (see below).
#
# NO_COLOR opt-out: per https://no-color.org/, if NO_COLOR is set (regardless
# of value, including empty string), the filter emits no ANSI escapes — the
# output is byte-identical to the pre-colorization format.
#
# ANSI escapes are encoded inside jq string literals using the JSON \uHHHH
# form ( for the ESC byte). Bash's heredoc passes them through
# verbatim; jq parses them at filter-compile time and emits the literal
# 0x1B byte to stdout.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"

if [ "${NO_COLOR+set}" = "set" ]; then
  _C_INIT="" _C_TEXT="" _C_TOOL="" _C_RESULT="" _C_OK="" _C_ERR="" _C_RST=""
else
  _ESC=''
  _C_INIT="${_ESC}[2;37m" _C_TEXT="${_ESC}[33m" _C_TOOL="${_ESC}[36m"
  _C_RESULT="${_ESC}[2;37m" _C_OK="${_ESC}[32m" _C_ERR="${_ESC}[31m"
  _C_RST="${_ESC}[0m"
fi

# shellcheck disable=SC2034   # consumed by sourcing wrapper
JQ_FILTER="$(
  cat <<JQEOF
  if .type == "system" and .subtype == "init" then
    "${_C_INIT}[init] model=\(.model) tools=\(.tools | length) cwd=\(.cwd)${_C_RST}"
  elif .type == "assistant" then
    (.message.content // [])[] | (
      if .type == "text" then
        "${_C_TEXT}[text] " + ((.text // "") | gsub("\n"; " ⏎ ") | .[0:400]) + "${_C_RST}"
      elif .type == "tool_use" then
        "${_C_TOOL}[tool] " + .name + " " + ((.input // {}) | tostring | .[0:300]) + "${_C_RST}"
      else empty end
    )
  elif .type == "user" then
    (.message.content // [])[] | (
      if .type == "tool_result" then
        "${_C_RESULT}[result] " + (
          if (.content | type) == "array" then
            (.content[0].text // "" | gsub("\n"; " ⏎ ") | .[0:400])
          else (.content // "" | tostring | .[0:400]) end
        ) + "${_C_RST}"
      else empty end
    )
  elif .type == "result" then
    (if .subtype == "success" then "${_C_OK}" else "${_C_ERR}" end)
      + "[done] " + .subtype
      + " duration=\(.duration_ms)ms turns=\(.num_turns) cost=\$\(.total_cost_usd // 0)"
      + "${_C_RST}"
  else empty end
JQEOF
)"

unset _C_INIT _C_TEXT _C_TOOL _C_RESULT _C_OK _C_ERR _C_RST _ESC
