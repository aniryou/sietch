#!/usr/bin/env bash
# lib/hard_failure.sh — Shared idempotent-escalate helper for loop wrappers.
#
# Two wrappers (run-developer.sh Mode 1, run-reviewer.sh per-PR cap) each
# implement the same shape of hard-failure escalation:
#
#   1. Check whether the escalation label is already present on the target.
#   2. If yes → log "idempotent skip" and return — re-applying the label is a
#      no-op but re-posting the operator comment piles up noise per cycle.
#   3. If no  → `gh label create --force` (idempotent), `gh <kind> edit
#      --add-label`, `gh <kind> comment --body`. Each best-effort.
#
# Without a shared helper, every new mode that wants escalation copies one of
# these ~15-line blocks. This helper extracts only the idempotent-escalate
# part (sub-issue 1 of GH#108); each wrapper keeps its mode-specific counter
# logic (numbered dev-failed:N labels for Mode 1, stub-review marker count
# for Reviewer). Sub-issues 2 and 3 will swap the existing inline blocks for
# one-line calls to this helper.
#
# Signature:
#   hard_failure_idempotent_escalate \
#     <target_kind> <target> <escalation_label> <comment_body> \
#     [label_color] [label_description]
#
# Returns:
#   0 — escalation applied, OR label already present (idempotent skip), OR
#       `gh view` failed and we fell through to apply (best-effort).
#   2 — invalid target_kind (typo guard; no gh side effects).
#
# Defensive note on `gh <kind> view` failure (rc != 0): we treat it as
# "label not present" and proceed to apply. This matches the existing
# wrappers' default-on-failure semantics in run-developer.sh:494-509 and
# run-reviewer.sh:188-220 where HAS_LABEL defaults to 0 on jq/gh failure.
# Better to apply (and risk a duplicate label-add no-op via gh's idempotency)
# than to silently swallow an escalation when the wrapper called us
# specifically because the agent hard-failed.

# `set -u` would make a missing positional arg crash the helper instead of
# returning rc=2. Wrappers source this file under `set -u` themselves; not
# re-applying `set -u` here keeps the helper robust to caller mistakes.

hard_failure_idempotent_escalate() {
  local kind="${1:-}"
  local target="${2:-}"
  local label="${3:-}"
  local body="${4:-}"
  local color="${5:-d73a4a}"
  local description="${6:-Hard failure escalation; agent will skip until label is removed}"

  case "$kind" in
    issue | pr) ;;
    *)
      echo "[hard_failure] unknown target_kind: '$kind' (expected issue|pr)" >&2
      return 2
      ;;
  esac

  local labels_json has_label
  labels_json=$(
    PAGER=cat GIT_PAGER=cat gh "$kind" view "$target" \
      --json labels 2>/dev/null \
      || echo '{"labels":[]}'
  )
  has_label=$(
    printf '%s' "$labels_json" \
      | jq -r --arg label "$label" \
        'if ((.labels // []) | map(.name) | index($label)) != null then 1 else 0 end' \
        2>/dev/null \
      || echo 0
  )

  if [ "$has_label" = "1" ]; then
    echo "[hard_failure] $kind #$target already carries '$label'; idempotent skip" >&2
    return 0
  fi

  echo "[hard_failure] escalating $kind #$target via label '$label'" >&2

  PAGER=cat GIT_PAGER=cat gh label create "$label" \
    --color "$color" --description "$description" --force \
    >/dev/null 2>&1 || true
  PAGER=cat GIT_PAGER=cat gh "$kind" edit "$target" \
    --add-label "$label" \
    >/dev/null 2>&1 || true
  PAGER=cat GIT_PAGER=cat gh "$kind" comment "$target" \
    --body "$body" \
    >/dev/null 2>&1 || true

  return 0
}
