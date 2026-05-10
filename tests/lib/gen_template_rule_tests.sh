#!/usr/bin/env bash
# GH#120: emit tests/test_template_rule_registry.bats from
# tests/lib/template_rules.bash. One `rule …` entry in the registry produces
# one `@test … { run_rule_registry_check … }` block in the generated file,
# so adding a new rule is genuinely one line. tests/test_template_rule_registry_sync.bats
# fails CI if the generated file drifts from the registry.
#
# Usage:
#   tests/lib/gen_template_rule_tests.sh [OUT_PATH]
#
# Default OUT_PATH is the canonical generated file under tests/. The sync
# test passes a $BATS_TEST_TMPDIR path so it can diff without touching the
# checked-in file.

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP_ROOT="$(cd "$HERE/../.." && pwd)"
OUT="${1:-$LOOP_ROOT/tests/test_template_rule_registry.bats}"

# shellcheck source=tests/lib/template_rules.bash
source "$HERE/template_rules.bash"

# Escape a string for safe embedding inside a "..." double-quoted bash literal.
# Order matters: backslashes first so we don't double-escape the inserts that
# follow.
escape_for_double_quotes() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//\$/\\\$}"
  s="${s//\`/\\\`}"
  printf '%s' "$s"
}

tmp="$OUT.tmp.$$"
{
  cat <<'EOF'
#!/usr/bin/env bats
# GENERATED — do not edit by hand.
# Regenerate with: tests/lib/gen_template_rule_tests.sh
# Source of truth: tests/lib/template_rules.bash
#
# Rule definitions (kind, pattern, file) live in the registry. This file is
# the bats-discoverable surface — one @test block per registry entry, each
# delegating to run_rule_registry_check by name. Adding a rule is one line:
# append `rule …` to the registry and run the generator (or trust CI's
# tests/test_template_rule_registry_sync.bats to flag the drift).

load 'helpers'
load 'lib/template_rules'

EOF
  for i in "${!TEMPLATE_RULE_NAMES[@]}"; do
    name="${TEMPLATE_RULE_NAMES[$i]}"
    esc="$(escape_for_double_quotes "$name")"
    printf '@test "[%s]" {\n  run_rule_registry_check "%s"\n}\n' "$esc" "$esc"
  done
} >"$tmp"
mv -f "$tmp" "$OUT"
