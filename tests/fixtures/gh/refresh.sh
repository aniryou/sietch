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
#   tests/fixtures/gh/refresh.sh           # update <name>.schema.json files in place
#   tests/fixtures/gh/refresh.sh --print   # emit schemas to stdout, leave tree untouched
#
# Env:
#   LOOP_FIXTURE_REPO  Source repo to query (default: aniryou/loop). Should be a
#                      "rich" repo — at least one assigned issue + one PR with
#                      at least one review — so the queries surface every
#                      nested key (`.[].assignees[].login`, `.[].reviews[].submittedAt`,
#                      etc.). If a query happens to be sparse (no assignees, no
#                      reviews), the union-merge below preserves whatever was
#                      already on disk so the schema only ever grows.
#
# Idempotency / monotonicity: schemas are union-merged with their existing
# on-disk version per key path (types are deduped, sorted, and re-joined with
# "|"). Running the script twice in a row produces no git diff. Running it
# against a sparser repo than was used previously also produces no diff. The
# only diffs you'll see are when the gh API surfaces a new key the schema
# doesn't already know about — which is the drift we want CI to flag.
#
# Read-only: this script only invokes `gh ... list` and `gh ... view`
# (no mutating commands).

set -euo pipefail
\unalias -a 2>/dev/null || true

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${LOOP_FIXTURE_REPO:-aniryou/loop}"

PRINT_ONLY=0

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

# union_schema <old-file>
#   Reads a freshly-derived schema from stdin and merges it with the existing
#   on-disk schema at <old-file> (if any). Per-path: take the union of types,
#   dedupe, sort lexicographically, rejoin with "|". Output is sorted/pretty.
#   If <old-file> doesn't exist or is empty, the input is passed through.
union_schema() {
  local old_file="$1"
  if [ -n "$old_file" ] && [ -s "$old_file" ]; then
    jq -S --slurpfile old "$old_file" '
      def parse_types: if . == "" then [] else split("|") end;
      ($old[0] // {}) as $oldmap |
      ((. | to_entries) + ($oldmap | to_entries))
      | group_by(.key)
      | map({
          key: .[0].key,
          value: ([.[].value] | map(parse_types) | add | unique | join("|"))
        })
      | from_entries
    '
  else
    jq -S '.'
  fi
}

# gen_schema <fixture-name> <gh-args...>
#   Runs `gh <args>` against $REPO, derives the path/type schema, union-merges
#   with any prior on-disk schema, and (unless --print is set) writes the
#   result to <fixture-name>.schema.json (i.e. issues-high.json -> issues-high.schema.json).
gen_schema() {
  local fixture="$1"; shift
  local out="$HERE/${fixture%.json}.schema.json"
  local raw
  if ! raw=$(PAGER=cat GIT_PAGER=cat gh "$@" --repo "$REPO" 2>/dev/null); then
    echo "[refresh] gh invocation failed for $fixture; leaving schema untouched" >&2
    return 1
  fi
  local merged
  merged=$(printf '%s\n' "$raw" | emit_schema | union_schema "$out")
  if [ "$PRINT_ONLY" = "1" ]; then
    printf '===== %s =====\n%s\n' "$(basename "$out")" "$merged"
  else
    printf '%s\n' "$merged" > "$out"
    echo "[refresh] wrote $(basename "$out")"
  fi
}

main() {
  command -v gh >/dev/null || { echo "[refresh] gh not on PATH" >&2; exit 1; }
  command -v jq >/dev/null || { echo "[refresh] jq not on PATH" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "[refresh] gh not authenticated" >&2; exit 1; }

  while [ $# -gt 0 ]; do
    case "$1" in
      --print)
        PRINT_ONLY=1
        shift
        ;;
      -h|--help)
        # Echo the leading comment block as the help text.
        sed -n '2,/^set -euo/{ /^set -euo/d; s/^# \?//; p; }' "${BASH_SOURCE[0]}"
        exit 0
        ;;
      *)
        echo "[refresh] unknown arg: $1" >&2
        exit 2
        ;;
    esac
  done

  # --- issue list shapes ---
  # Production runners query: --json number,assignees (eligibility_dev_count)
  # and --json number (issues-with-locks scenario).
  # Schema source uses --state all without label filter so the result is
  # representative even on repos where severity:high happens to be empty.
  # --limit 50 widens the sample so optional nested keys
  # (assignees[].login, reviews[].submittedAt, ...) are more likely to be
  # surfaced; the union-merge above is the fallback if the sample is sparse.
  gen_schema issues-high.json \
    issue list --state all --json number,assignees --limit 50
  gen_schema issues-medium.json \
    issue list --state all --json number,assignees --limit 50
  gen_schema issues-with-locks.json \
    issue list --state all --json number --limit 50

  # --- pr list shapes ---
  # eligibility_review_pending: --json number,commits,reviews
  # dispatcher.sh: --json number,headRefName,isDraft,mergeable
  #
  # Heavy queries (commits+reviews) are bounded at --limit 25 because
  # GraphQL caps per-query node cost at 500k and ~50 PRs exceeds it on
  # active repos. 25 is still 5x the original and well under the cap.
  gen_schema prs-current.json \
    pr list --state all --json number,commits,reviews --limit 25
  gen_schema prs-stale.json \
    pr list --state all --json number,commits,reviews --limit 25
  gen_schema prs-mixed.json \
    pr list --state all --json number,commits,reviews --limit 25
  gen_schema prs-dispatch.json \
    pr list --state all --json number,headRefName,isDraft,mergeable --limit 50
}

main "$@"
