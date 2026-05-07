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
# Refresh.sh self-tests — exercised offline using a synthetic schema/fixture.
# These guard the union-merge and --print behaviors that defend against
# sparse-repo regressions and accidental working-tree mutation during
# inspection. See refresh.sh comments for the contract.
# ---------------------------------------------------------------------------

@test "fixtures/gh: refresh.sh advertises --print in its --help output" {
  run bash "$FIXTURE_DIR/refresh.sh" --help
  [ "$status" -eq 0 ]
  echo "$output" | grep -q -- '--print'
}

@test "fixtures/gh: refresh.sh --print emits stdout but does not modify schemas" {
  # Stub gh to return a valid empty array for every list query. The script
  # then derives a minimal schema, but --print must route it to stdout, not
  # to the *.schema.json files. We verify by hashing the directory before
  # and after.
  local sandbox="$BATS_TEST_TMPDIR/sandbox"
  cp -r "$FIXTURE_DIR" "$sandbox"
  local before_hash
  before_hash=$(find "$sandbox" -name '*.schema.json' -exec sha256sum {} + | sort)

  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  issue|pr)
    [ "$2" = "list" ] && { echo '[]'; exit 0; }
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"

  run env PATH="$tmpbin:$PATH" bash "$sandbox/refresh.sh" --print
  [ "$status" -eq 0 ]
  # Stdout should contain the schema-header markers so callers can grep.
  echo "$output" | grep -q '===== issues-high.schema.json ====='
  echo "$output" | grep -q '===== prs-dispatch.schema.json ====='

  # Schema files must be byte-identical to before.
  local after_hash
  after_hash=$(find "$sandbox" -name '*.schema.json' -exec sha256sum {} + | sort)
  [ "$before_hash" = "$after_hash" ]
}

@test "fixtures/gh: union-merge preserves nested keys when new schema is sparse" {
  # Simulates the sparse-repo regression the reviewer flagged: an existing
  # rich schema, plus a freshly-derived sparse schema (because the queried
  # repo had e.g. no assigned issues). The merged result must keep the
  # rich keys.
  #
  # We exercise refresh.sh end-to-end by stubbing gh on PATH to return our
  # synthetic sparse JSON, then inspect the on-disk schema afterward.
  local sandbox="$BATS_TEST_TMPDIR/sandbox"
  cp -r "$FIXTURE_DIR" "$sandbox"

  # Pre-seed a richer-than-sparse schema so we can prove union-merge
  # preserves the extra paths.
  cat > "$sandbox/issues-high.schema.json" <<'EOF'
{
  ".": "array",
  ".[]": "object",
  ".[].assignees": "array",
  ".[].assignees[]": "object",
  ".[].assignees[].fictional_field": "string",
  ".[].assignees[].login": "string",
  ".[].number": "number"
}
EOF

  # Stub gh: return one issue with no assignees (sparse) for any list query.
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  issue|pr)
    if [[ "$2" = "list" ]]; then
      echo '[{"number": 1, "assignees": []}]'
      exit 0
    fi
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"

  PATH="$tmpbin:$PATH" bash "$sandbox/refresh.sh" >/dev/null 2>&1

  # The fictional_field came only from the prior on-disk schema — if union-merge
  # works it should still be there. The .login key was implicitly recorded
  # before; same.
  run jq -r '.[".[].assignees[].fictional_field"]' "$sandbox/issues-high.schema.json"
  [ "$status" -eq 0 ]
  [ "$output" = "string" ]

  run jq -r '.[".[].assignees[].login"]' "$sandbox/issues-high.schema.json"
  [ "$status" -eq 0 ]
  [ "$output" = "string" ]
}

# ---------------------------------------------------------------------------
# Live mode — opt-in via LOOP_FIXTURE_LIVE=1. Skipped in CI.
# Reruns refresh.sh against $LOOP_FIXTURE_REPO and asserts no git diff
# in tests/fixtures/gh/. Catches gh-API shape drift over time. With
# union-merge in place, sparse queries against a different LOOP_FIXTURE_REPO
# no longer cause spurious diffs — only genuinely new gh keys do.
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

@test "fixtures/gh: live mode — refresh.sh --print does not modify schemas" {
  [ "${LOOP_FIXTURE_LIVE:-0}" = "1" ] || skip "set LOOP_FIXTURE_LIVE=1 to enable"
  command -v gh >/dev/null || skip "gh not installed"
  gh auth status >/dev/null 2>&1 || skip "gh not authenticated"
  bash "$FIXTURE_DIR/refresh.sh" --print >/dev/null
  # Scope the diff to *.schema.json — script-/manifest-level edits during
  # development shouldn't break this test, only schema mutations.
  run git -C "$LOOP_ROOT" diff --exit-code -- 'tests/fixtures/gh/*.schema.json'
  if [ "$status" -ne 0 ]; then
    echo "$output"
    return 1
  fi
}
