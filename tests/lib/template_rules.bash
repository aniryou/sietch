#!/usr/bin/env bash
# Registry of template-rule guards.
#
# Each rule pins a regex that must (or must not) appear in an agent template
# file. New rules are added by appending one `rule ...` line below; the
# corresponding @test wrapper lives in tests/test_template_rule_registry.bats
# (bats 1.x doesn't support runtime-dynamic @test generation, so the wrapper
# is a one-line dispatcher kept in sync by name).
#
# Rule kinds:
#   require   — pattern must appear at least once in the named template.
#   forbid    — pattern must not appear in the named template.
#   count_max — pattern may appear at most $count_max times in the template.

TEMPLATE_RULE_NAMES=()
TEMPLATE_RULE_FILES=()
TEMPLATE_RULE_KINDS=()
TEMPLATE_RULE_PATTERNS=()
TEMPLATE_RULE_COUNT_MAX=()

rule() {
  local name="$1" file="$2" kind="$3" pattern="$4" count_max="${5:-}"
  TEMPLATE_RULE_NAMES+=("$name")
  TEMPLATE_RULE_FILES+=("$file")
  TEMPLATE_RULE_KINDS+=("$kind")
  TEMPLATE_RULE_PATTERNS+=("$pattern")
  TEMPLATE_RULE_COUNT_MAX+=("$count_max")
}

# --- Registry ---------------------------------------------------------------

# GH#67: pin the bd-dep direction. `bd dep add <blocked-id> <blocker-id>`
# means parent depends on each child being closed; the reversed form makes
# every step `bd close` need --force and re-introduces the original bug.
rule "GH#67: bd dep direction (parent first) — developer.md" \
     "developer.md" require 'bd dep add \$PARENT <child>'
rule "GH#67: no reversed bd dep form — developer.md" \
     "developer.md" forbid  'bd dep add[[:space:]]+<child>[[:space:]]+\$PARENT'
rule "GH#67: bd dep direction (parent first) — reviewer.md" \
     "reviewer.md" require 'bd dep add \$PARENT <child>'
rule "GH#67: no reversed bd dep form — reviewer.md" \
     "reviewer.md" forbid  'bd dep add[[:space:]]+<child>[[:space:]]+\$PARENT'

# GH#71: `gh pr checks` does not expose `conclusion`; the valid CI-state
# field is `bucket` (pass/fail/pending/skipping/cancel). The bad form errors
# and, alongside parallel gh calls, used to cancel the whole tool batch.
# GH#117: reviewer-orchestrator.md was removed; the per-PR `gh pr checks`
# invocation now lives in templates/reviewer.md (no `--json` flag), so the
# require rule is relaxed to "uses gh pr checks" while the forbid rule still
# pins against the bad `--json state,conclusion` form.
rule "GH#71: gh pr checks (per-PR sanity check) — reviewer.md" \
     "reviewer.md" require 'gh pr checks'
rule "GH#71: no conclusion field on gh pr checks — reviewer.md" \
     "reviewer.md" forbid  'gh pr checks[^`]*--json state,conclusion'
rule "GH#71: gh pr checks --json state,bucket — developer.md" \
     "developer.md" require 'gh pr checks[^`]*--json state,bucket'
rule "GH#71: no conclusion field on gh pr checks — developer.md" \
     "developer.md" forbid  'gh pr checks[^`]*--json state,conclusion'

# --- Helpers ----------------------------------------------------------------

template_rule_index() {
  local name="$1" i
  for i in "${!TEMPLATE_RULE_NAMES[@]}"; do
    if [ "${TEMPLATE_RULE_NAMES[$i]}" = "$name" ]; then
      echo "$i"
      return 0
    fi
  done
  return 1
}

run_rule_registry_check() {
  local name="$1" idx
  if ! idx="$(template_rule_index "$name")"; then
    echo "registry: rule '$name' not defined" >&2
    return 1
  fi
  local file="${TEMPLATE_RULE_FILES[$idx]}"
  local kind="${TEMPLATE_RULE_KINDS[$idx]}"
  local pattern="${TEMPLATE_RULE_PATTERNS[$idx]}"
  local count_max="${TEMPLATE_RULE_COUNT_MAX[$idx]}"
  local tpl="$LOOP_ROOT/templates/$file"

  if [ ! -f "$tpl" ]; then
    echo "[$name]: template file missing: templates/$file" >&2
    return 1
  fi

  case "$kind" in
    require)
      if ! grep -qE "$pattern" "$tpl"; then
        echo "[$name]: required pattern not found in templates/$file" >&2
        echo "  pattern: $pattern" >&2
        return 1
      fi
      ;;
    forbid)
      if grep -qE "$pattern" "$tpl"; then
        echo "[$name]: forbidden pattern found in templates/$file" >&2
        echo "  pattern: $pattern" >&2
        return 1
      fi
      ;;
    count_max)
      if [ -z "$count_max" ]; then
        echo "[$name]: count_max kind requires the count_max field" >&2
        return 1
      fi
      local count
      count=$(grep -cE "$pattern" "$tpl" 2>/dev/null || true)
      if [ "$count" -gt "$count_max" ]; then
        echo "[$name]: pattern count $count exceeds max $count_max in templates/$file" >&2
        echo "  pattern: $pattern" >&2
        return 1
      fi
      ;;
    *)
      echo "[$name]: unknown rule kind '$kind' (expected: require|forbid|count_max)" >&2
      return 1
      ;;
  esac
}
