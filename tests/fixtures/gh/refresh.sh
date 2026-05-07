#!/usr/bin/env bash
# refresh.sh — regenerate *.schema.json snapshots for tests/fixtures/gh/
#
# Background — see GH#14. Hand-written fixtures drifted from real `gh`
# output (commit_id strings where gh always returns null), masking a real
# bug behind a green test. The contract test in tests/test_fixture_contract.bats
# enforces "fixture key paths ⊆ schema key paths"; this script generates the
# schema half of that contract by walking real gh output for each command shape
# the runners actually use in production.
#
# Usage:
#   tests/fixtures/gh/refresh.sh [--print]
#
# Env:
#   LOOP_FIXTURE_REPO  Source repo to query (default: aniryou/loop).
#                      Use a repo that has both open issues and dev-agent PRs
#                      so the queries return data; if a query is empty the
#                      derived schema records only the root array path.
#
# Idempotency: schemas record sorted (path, type-union) pairs derived from
# observed gh output. Running this twice in a row should produce no git diff
# unless the gh API shape itself has drifted.
#
# Read-only: this script only invokes `gh ... list` and `gh ... view`
# (no mutating commands).

set -euo pipefail
\unalias -a 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${LOOP_FIXTURE_REPO:-aniryou/loop}"

# Walk a JSON value and emit a flat dict { "<path>": "<type-union>" }.
# Mirrors the WALK_PATHS_JQ filter in test_fixture_contract.bats — kept
# in lockstep so a fixture validates iff the schema regenerated against
# real gh would accept it.
WALK_PATHS_JQ='
  def walk(p):
    if type == "array" then
      [{path: p, t: "array"}] +
      ([range(length) as $i | .[$i] | walk(p + "[]")] | add // [])
    elif type == "object" then
      [{path: p, t: "object"}] +
      ([keys[] as $k | .[$k] | walk(p + "." + $k)] | add // [])
    else
      [{path: p, t: type}]
    end;
  walk(".")
  | group_by(.path)
  | map({(.[0].path): ([.[].t] | unique | join("|"))})
  | add // {}
'

# Sort keys deterministically and pretty-print so git diffs are clean.
emit_schema() {
  jq -S "$WALK_PATHS_JQ"
}

# gen_schema <fixture-name> <gh-args...>
# Runs `gh <args>` against $REPO, derives the path/type schema, and writes it
# to <fixture-name>.schema.json (i.e. issues-high.json -> issues-high.schema.json).
gen_schema() {
  local fixture="$1"; shift
  local out="$HERE/${fixture%.json}.schema.json"
  local raw
  if ! raw=$(PAGER=cat GIT_PAGER=cat gh "$@" --repo "$REPO" 2>/dev/null); then
    echo "[refresh] gh invocation failed for $fixture; leaving schema untouched" >&2
    return 1
  fi
  printf '%s\n' "$raw" | emit_schema > "$out"
  echo "[refresh] wrote $(basename "$out")"
}

main() {
  command -v gh >/dev/null || { echo "[refresh] gh not on PATH" >&2; exit 1; }
  command -v jq >/dev/null || { echo "[refresh] jq not on PATH" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "[refresh] gh not authenticated" >&2; exit 1; }

  # --- issue list shapes ---
  # Production runners query: --json number,assignees (eligibility_dev_count)
  # and --json number (issues-with-locks scenario).
  # Schema source uses --state all without label filter so the result is
  # representative even on repos where severity:high happens to be empty.
  gen_schema issues-high.json \
    issue list --state all --json number,assignees --limit 5
  gen_schema issues-medium.json \
    issue list --state all --json number,assignees --limit 5
  gen_schema issues-with-locks.json \
    issue list --state all --json number --limit 5

  # --- pr list shapes ---
  # eligibility_review_pending: --json number,commits,reviews
  # dispatcher.sh: --json number,headRefName,isDraft,mergeable
  gen_schema prs-current.json \
    pr list --state all --json number,commits,reviews --limit 5
  gen_schema prs-stale.json \
    pr list --state all --json number,commits,reviews --limit 5
  gen_schema prs-mixed.json \
    pr list --state all --json number,commits,reviews --limit 5
  gen_schema prs-dispatch.json \
    pr list --state all --json number,headRefName,isDraft,mergeable --limit 5
}

main "$@"
