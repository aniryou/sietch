#!/usr/bin/env bats
# tests/fixtures/gh/* — fixture-vs-reality contract test.
#
# Background — see GH#14. Hand-written fixtures are how #8 happened:
# every prs-*.json hand-included a "commit_id" key that real
# `gh pr view --json reviews` returns as null. Tests passed against
# fixtures that didn't reflect reality; the production predicate that
# consumed real gh output silently misbehaved.
#
# This file enforces a thin contract:
#   1. Every fixture has a sibling *.schema.json describing the shape
#      that real gh returns for the equivalent --json field set.
#   2. Every key path the fixture sets must be present in the schema,
#      with a compatible type (null in the fixture is always allowed).
#   3. MANIFEST.md lists every fixture with its source gh command.
#
# Schema regeneration is the job of tests/fixtures/gh/refresh.sh.
# In `LOOP_FIXTURE_LIVE=1` mode, this test invokes that script against
# $LOOP_FIXTURE_REPO (default: aniryou/loop) and asserts no git diff —
# i.e. real gh output still matches the checked-in shape.

load 'helpers'

FIXTURE_DIR="$BATS_TEST_DIRNAME/fixtures/gh"

# ---------------------------------------------------------------------------
# Helper jq filter: walk a JSON value and emit a flat dict
#   { "<path>": "<type-union>" }
# where <path> is jq-style ("." root, "[]" array element, ".foo" object key)
# and <type-union> is a "|"-joined sorted unique list of jq types observed
# at that path. Used both to derive schema snapshots and to fingerprint a
# fixture's key shape for subset comparison.
# ---------------------------------------------------------------------------
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

# Validate a fixture against a schema. Prints any violations and returns
# nonzero if the fixture is not a subset of the schema.
#
# Subset rule:
#   - For every path P present in the fixture, the schema must contain P.
#   - Every non-null type observed at P in the fixture must also appear in
#     the schema's type union for P. (`null` in the fixture is tolerated
#     unconditionally, since gh nullability is widespread and fixtures often
#     stub fields with null to scope a scenario.)
validate_fixture() {
  local fixture="$1" schema="$2"
  local fix_paths
  fix_paths=$(jq "$WALK_PATHS_JQ" < "$fixture")
  local schema_paths
  schema_paths=$(cat "$schema")
  jq -n \
    --argjson fix "$fix_paths" \
    --argjson schema "$schema_paths" '
    ($fix | to_entries)
    | map(
        .key as $p | .value as $ftype
        | ($ftype | split("|") | map(select(. != "null"))) as $fts
        | if ($schema | has($p) | not) then
            "PATH NOT IN SCHEMA: \($p) (fixture type: \($ftype))"
          else
            ($schema[$p] | split("|")) as $sts
            | ($fts - $sts) as $extra
            | if ($extra | length) > 0 then
                "TYPE MISMATCH at \($p): fixture=\($ftype), schema=\($schema[$p]), unexpected=\($extra | join(","))"
              else
                empty
              end
          end
      )
    | if length == 0 then "" else (. | join("\n")) end
  ' -r
}

# Bash predicate: returns 0 if fixture validates, nonzero otherwise.
# Prints violations to stdout on failure.
fixture_conforms() {
  local out
  out=$(validate_fixture "$1" "$2")
  if [ -z "$out" ]; then
    return 0
  fi
  echo "$out"
  return 1
}

# ---------------------------------------------------------------------------
# Existence / wiring tests
# ---------------------------------------------------------------------------

@test "fixtures/gh: MANIFEST.md exists" {
  [ -f "$FIXTURE_DIR/MANIFEST.md" ]
}

@test "fixtures/gh: refresh.sh exists and is executable" {
  [ -x "$FIXTURE_DIR/refresh.sh" ]
}

@test "fixtures/gh: every fixture has a sibling *.schema.json" {
  local missing=()
  shopt -s nullglob
  for fix in "$FIXTURE_DIR"/*.json; do
    case "$fix" in
      *.schema.json) continue ;;
    esac
    local schema="${fix%.json}.schema.json"
    [ -f "$schema" ] || missing+=("$schema")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'missing schema: %s\n' "${missing[@]}"
    return 1
  fi
}

@test "fixtures/gh: every fixture is listed in MANIFEST.md" {
  local missing=()
  shopt -s nullglob
  for fix in "$FIXTURE_DIR"/*.json; do
    case "$fix" in
      *.schema.json) continue ;;
    esac
    local base
    base=$(basename "$fix")
    grep -qF "$base" "$FIXTURE_DIR/MANIFEST.md" || missing+=("$base")
  done
  if [ "${#missing[@]}" -ne 0 ]; then
    printf 'fixture not listed in MANIFEST.md: %s\n' "${missing[@]}"
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Subset-conformance: fixture key paths must be a subset of schema key paths
# ---------------------------------------------------------------------------

@test "fixtures/gh: every fixture conforms to its schema (offline)" {
  local fail=0
  shopt -s nullglob
  for fix in "$FIXTURE_DIR"/*.json; do
    case "$fix" in
      *.schema.json) continue ;;
    esac
    local schema="${fix%.json}.schema.json"
    [ -f "$schema" ] || { echo "SKIP (no schema): $fix"; continue; }
    local out
    out=$(validate_fixture "$fix" "$schema") || true
    if [ -n "$out" ]; then
      echo "=== $(basename "$fix") ==="
      echo "$out"
      fail=1
    fi
  done
  [ "$fail" -eq 0 ]
}

# ---------------------------------------------------------------------------
# Negative tests — the contract should reject obvious drift.
# ---------------------------------------------------------------------------

@test "fixtures/gh: synthetic drift fixture (extra key) is rejected" {
  # Pick any existing fixture that has a schema; inject a hallucinated key
  # at a known path and assert validate_fixture flags it.
  local source="$FIXTURE_DIR/issues-high.json"
  local schema="$FIXTURE_DIR/issues-high.schema.json"
  [ -f "$schema" ] || skip "schema not yet generated"
  local synth="$BATS_TEST_TMPDIR/_drift.json"
  jq '.[0].surprise = "drift"' < "$source" > "$synth"
  ! fixture_conforms "$synth" "$schema"
}

@test "fixtures/gh: synthetic drift fixture (wrong type) is rejected" {
  # Spirit of #8: a hand-written value whose type clashes with real gh
  # output. Use the always-present `.number` path (a number per gh's schema)
  # and stuff a string in.
  local source="$FIXTURE_DIR/prs-current.json"
  local schema="$FIXTURE_DIR/prs-current.schema.json"
  [ -f "$schema" ] || skip "schema not yet generated"
  local synth="$BATS_TEST_TMPDIR/_drift_type.json"
  jq '.[0].number = "not-a-number"' < "$source" > "$synth"
  ! fixture_conforms "$synth" "$schema"
}

# ---------------------------------------------------------------------------
# Live mode — opt-in via LOOP_FIXTURE_LIVE=1. Skipped in CI.
# Reruns refresh.sh against $LOOP_FIXTURE_REPO and asserts no git diff
# in tests/fixtures/gh/. Catches gh-API shape drift over time.
# ---------------------------------------------------------------------------

@test "fixtures/gh: live mode — refresh.sh produces no git diff" {
  [ "${LOOP_FIXTURE_LIVE:-0}" = "1" ] || skip "set LOOP_FIXTURE_LIVE=1 to enable"
  command -v gh >/dev/null || skip "gh not installed"
  gh auth status >/dev/null 2>&1 || skip "gh not authenticated"
  bash "$FIXTURE_DIR/refresh.sh"
  run git -C "$LOOP_ROOT" diff --exit-code -- tests/fixtures/gh/
  if [ "$status" -ne 0 ]; then
    echo "$output"
    return 1
  fi
}
