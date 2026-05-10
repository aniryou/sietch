#!/usr/bin/env bats
# bats file_tags=regression
# GH#133: parity-doc bookkeeping for G2 (predicate ↔ prompt body-tag fallback).
#
# G2's resolution: drop the body-tag OR fallback from `templates/reviewer.md`
# so the prompt and `eligibility_review_pending` (which filters strictly on
# `head:${BRANCH_PREFIX}/`) agree. After the fix, the parity doc must:
#   - mark the G2 row(s) as Mirrored, not Gap; and
#   - record G2 as resolved by GH#133 in the Gaps section, mirroring how
#     G3 records "Resolved by GH#134".

load 'helpers'

PARITY="$LOOP_ROOT/runners/lib/eligibility-parity.md"

@test "GH#133: parity doc no longer marks the body-tag fallback row as Gap" {
  [ -f "$PARITY" ]
  # The two G2 rows are the only places `body-tag fallback` is paired with
  # **Gap**. After the fix, neither row should still carry the **Gap** tag.
  ! grep -E -- '(body[- ]tag|DEV_AGENT_PR_BODY_TAG).*\*\*Gap' "$PARITY"
  ! grep -E -- '\*\*Gap.*(body[- ]tag|DEV_AGENT_PR_BODY_TAG)' "$PARITY"
}

@test "GH#133: parity doc records G2 as resolved by GH#133" {
  [ -f "$PARITY" ]
  # The G2 bullet wraps across several lines (mirrors the G3 → GH#134
  # entry's shape). Slice from `- **G2**` to the next top-level bullet
  # `- **G…**`, then assert "Resolved by GH#133" appears inside the slice.
  local slice
  slice=$(awk '
    /^- \*\*G2\*\*/ { flag=1; print; next }
    flag && /^- \*\*G[0-9]/ { exit }
    flag { print }
  ' "$PARITY")
  [ -n "$slice" ]
  printf '%s\n' "$slice" | grep -q 'Resolved by GH#133'
}
