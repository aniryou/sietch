#!/usr/bin/env bash
# Registry of template-rule guards.
#
# Each rule pins a regex that must (or must not) appear in an agent template
# file. Adding a new rule is one line: append a `rule …` entry below, then
# run tests/lib/gen_template_rule_tests.sh to regenerate
# tests/test_template_rule_registry.bats (the bats-discoverable surface).
# CI fails via tests/test_template_rule_registry_sync.bats if the generated
# file drifts from this registry, so forgetting to regenerate is loud.
#
# Rule kinds:
#   require     — pattern must appear at least once in the named template.
#   forbid      — pattern must not appear in the named template.
#   count_max   — pattern may appear at most $count_max times in the template.
#   require_all — every tab-separated pattern must appear (independently)
#                 at least once. Used for compound checks where two distinct
#                 substrings must both be present somewhere in the file.

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

# GH#80: cut redundant `--repo …` and `cd "$WORKTREE"` prefixes from
# dev-agent commands. The wrapper exports GH_REPO so `gh` reads it natively,
# and the Claude Code Bash tool persists CWD across calls. Section-scoped
# narrative checks (Mode 1 Step 1 mentions inheritance) live in
# tests/test_dev_developer_wrapper_env.bats; the file-wide regex rules are
# pinned here.
rule "GH#80: --repo rule call-out present — developer.md" \
     "developer.md" require '--repo'
rule "GH#80: no in-template gh examples pass --repo — developer.md" \
     "developer.md" forbid  'gh[[:space:]]+[a-z]+[^|]*--repo'
rule "GH#80: cd \"\$WORKTREE\" lines capped at 3 (one per worktree creation) — developer.md" \
     "developer.md" count_max '^[[:space:]]*cd[[:space:]]+"\$WORKTREE"[[:space:]]*$' 3

# GH#47: plain-English/TL;DR contract for user-facing templates. Section
# ordering (TL;DR before Problem/Changes) lives in
# tests/test_templates_section_ordering.bats since that's not a regex match.
rule "GH#47: ## TL;DR section present — issue-author.md" \
     "issue-author.md" require '^## TL;DR$'
rule "GH#47: title-style rule (70-char + plain-English) — issue-author.md" \
     "issue-author.md" require_all $'70 ?char\t[Pp]lain[ -][Ee]nglish'
rule "GH#47: title warns against opaque acronyms — issue-author.md" \
     "issue-author.md" require '[Aa]cronym|[Jj]argon|[Ii]nsider'
rule "GH#47: draft preview surfaces the title for plain-English review — issue-author.md" \
     "issue-author.md" require '[Tt]itle.*([Pp]lain|[Rr]eads|[Rr]eview)'
rule "GH#47: Title and TL;DR examples section present — issue-author.md" \
     "issue-author.md" require 'Title and TL;DR examples|Title.*TL;DR'
rule "GH#47: ## TL;DR section present in PR body — developer.md" \
     "developer.md" require '^## TL;DR$'
rule "GH#47: ## Changes section present in PR body — developer.md" \
     "developer.md" require '^## Changes$'
rule "GH#47: PR body no longer leads with ## Summary — developer.md" \
     "developer.md" forbid '^## Summary$'
rule "GH#47: PR title still uses the Fix GH# prefix — developer.md" \
     "developer.md" require 'Fix GH#'
rule "GH#47: PR title plain-English rules (70-char + plain-English) — developer.md" \
     "developer.md" require_all $'70 ?char\t[Pp]lain[ -][Ee]nglish'
rule "GH#47: ## Test plan heading anchors Step 7a CI flip — developer.md" \
     "developer.md" require '^## Test plan$'

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
      # `grep -- "$pattern"` so patterns starting with `--` (e.g. literal
      # `--repo`) aren't mis-parsed as flags.
      if ! grep -qE -- "$pattern" "$tpl"; then
        echo "[$name]: required pattern not found in templates/$file" >&2
        echo "  pattern: $pattern" >&2
        return 1
      fi
      ;;
    forbid)
      if grep -qE -- "$pattern" "$tpl"; then
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
      count=$(grep -cE -- "$pattern" "$tpl" 2>/dev/null || true)
      if [ "$count" -gt "$count_max" ]; then
        echo "[$name]: pattern count $count exceeds max $count_max in templates/$file" >&2
        echo "  pattern: $pattern" >&2
        return 1
      fi
      ;;
    require_all)
      # Tab-separated patterns; every one must match independently.
      local p IFS=$'\t'
      for p in $pattern; do
        [ -n "$p" ] || continue
        if ! grep -qE -- "$p" "$tpl"; then
          echo "[$name]: required pattern not found in templates/$file" >&2
          echo "  pattern: $p" >&2
          return 1
        fi
      done
      ;;
    *)
      echo "[$name]: unknown rule kind '$kind' (expected: require|forbid|count_max|require_all)" >&2
      return 1
      ;;
  esac
}
