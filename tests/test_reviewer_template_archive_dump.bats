#!/usr/bin/env bats
# GH#136: Reviewer sub-agent re-fetches the same files via repeated `git show`.
#
# Across 66 reviewer sub-agent transcripts, six runs invoke
# `git show <head_sha>:<path>` 10–16 times for the same blob in a single
# review. Each repeat re-feeds the file body to the model — the median run
# burns ~2.1M cache_read tokens to produce ~7K output tokens.
#
# Fix: replace per-file `git show` guidance in templates/reviewer.md with a
# one-shot archive dump (`git -C $REPO archive $HEAD_SHA -- <files> | tar -x
# -C /tmp/pr-${PR}-files`), then point the agent at `Read /tmp/pr-${PR}-files/<path>`.
# Keep `git show` only as a fallback for renames/deletes (files not in the archive).
#
# These checks pin the guidance so a regression that drops any rule fails CI.

load 'helpers'

setup() {
  REVIEWER_TPL="$LOOP_ROOT/templates/reviewer.md"
}

@test "reviewer template materialises post-PR files via git archive + tar" {
  # The fix adds (around line 73, after the diff capture) a one-shot dump
  # like: `git -C "$REPO" archive "$HEAD_SHA" -- ... | tar -x -C /tmp/pr-${PR}-files`.
  # We accept any phrasing that combines `git ... archive` and `tar -x` and
  # writes to /tmp/pr-${PR}-files.
  grep -qE 'git .*archive.*\$\{?HEAD_SHA\}?' "$REVIEWER_TPL" \
    || { echo "reviewer.md missing 'git archive \$HEAD_SHA' command" >&2; false; }
  grep -qE 'tar -x' "$REVIEWER_TPL" \
    || { echo "reviewer.md missing 'tar -x' to extract the archive" >&2; false; }
  grep -qE '/tmp/pr-\$\{?PR\}?-files' "$REVIEWER_TPL" \
    || { echo "reviewer.md missing '/tmp/pr-\${PR}-files' destination dir" >&2; false; }
}

@test "reviewer template instructs Read from /tmp/pr-\${PR}-files (not git show) for changed-file context" {
  # Line-89 guidance must point at the dumped tree, not at per-file git show.
  grep -qE 'Read .*\/tmp\/pr-\$\{?PR\}?-files' "$REVIEWER_TPL" \
    || { echo "reviewer.md missing 'Read /tmp/pr-\${PR}-files/<path>' guidance" >&2; false; }
}

@test "reviewer template does NOT recommend per-file 'git show <sha>:<path>' as primary guidance" {
  # `git show <head_sha>:<path>` (or $HEAD_SHA variant) may appear ONLY inside
  # a fallback context — within 2 lines of the keywords "fallback", "renames",
  # or "deletes". Anywhere else means the old per-file guidance has crept back in.
  fail=0
  while IFS=: read -r lineno _; do
    [ -z "$lineno" ] && continue
    # Look 2 lines before and 2 lines after the match for fallback context.
    start=$((lineno > 2 ? lineno - 2 : 1))
    end=$((lineno + 2))
    if ! sed -n "${start},${end}p" "$REVIEWER_TPL" \
        | grep -qiE 'fallback|renames|deletes'; then
      echo "reviewer.md:$lineno mentions 'git show <sha>:<path>' outside fallback context" >&2
      fail=1
    fi
  done < <(grep -niE 'git show [^[:space:]"]*head_sha[^[:space:]"]*:' "$REVIEWER_TPL")
  [ "$fail" -eq 0 ]
}

@test "reviewer template Hard Rules forbid repeated 'git show' for the same <sha>:<path>" {
  # Section starts at "## Hard Rules"; capture body up to next H2.
  hard_rules=$(awk '
    /^## Hard Rules/ { capturing = 1; next }
    capturing && /^## / { exit }
    capturing { print }
  ' "$REVIEWER_TPL")
  [ -n "$hard_rules" ] || { echo "Hard Rules section missing from reviewer.md" >&2; false; }
  echo "$hard_rules" | grep -qiE 'git show.*more than once|do not.*git show.*twice|never.*git show.*same' \
    || { echo "Hard Rules missing 'no repeated git show for the same <sha>:<path>' guidance" >&2; false; }
}
