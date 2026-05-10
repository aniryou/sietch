#!/usr/bin/env bats
# bats file_tags=regression
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

@test "reviewer template uses portable array iteration for CHANGED_AM (zsh-safe)" {
  # The original implementation used unquoted `$CHANGED_AM` which silently
  # fails in zsh (no default word-splitting) — every Read of /tmp/pr-N-files/
  # missed and the agent fell back to per-file `git show`, defeating GH#136.
  # Pin the array form so a regression to the unquoted-string form fails CI.
  grep -qE 'CHANGED_AM=\(\)' "$REVIEWER_TPL" \
    || { echo "reviewer.md missing 'CHANGED_AM=()' array initialisation" >&2; false; }
  grep -qE '\$\{CHANGED_AM\[@\]\}' "$REVIEWER_TPL" \
    || { echo "reviewer.md missing quoted '\${CHANGED_AM[@]}' array expansion" >&2; false; }
  # Reject the bash-only unquoted expansion in the archive command.
  if grep -qE 'archive .*HEAD_SHA.* -- \$CHANGED_AM([[:space:]]|$|\|)' "$REVIEWER_TPL"; then
    echo "reviewer.md still uses unquoted \$CHANGED_AM (bash-only word-splitting; fails in zsh)" >&2
    false
  fi
}

@test "archive dump materialises post-PR files end-to-end under zsh and bash" {
  # Runtime test (companion to the static lint above): build a fixture git
  # repo that mirrors a PR (base + head commits, two AM files), then run
  # the same archive+tar logic the template uses, in both bash and the zsh
  # shell that Claude Code's Bash tool spawns on macOS. Catches regressions
  # the static greps can't: word-splitting failures, tied-parameter
  # clobbering (`path`/`PATH`), tar incompatibilities, etc.
  command -v git >/dev/null 2>&1 || skip "git not installed"

  local sandbox="$BATS_TEST_TMPDIR/archive-fixture"
  mkdir -p "$sandbox"
  (
    cd "$sandbox"
    git init -q
    git config user.email test@test.test
    git config user.name test
    printf 'v1\n' > a.txt
    git add a.txt
    git commit -qm base
    git rev-parse HEAD > "$BATS_TEST_TMPDIR/base_sha"
    printf 'v2\n' > a.txt
    printf 'added\n' > b.txt
    git add a.txt b.txt
    git commit -qm head
    git rev-parse HEAD > "$BATS_TEST_TMPDIR/head_sha"
  )
  local base_sha head_sha
  base_sha=$(cat "$BATS_TEST_TMPDIR/base_sha")
  head_sha=$(cat "$BATS_TEST_TMPDIR/head_sha")

  # Snippet body (matches templates/reviewer.md, parameterised on REPO/HEAD/BASE/DEST).
  local snippet='
    set -e
    mkdir -p "$DEST"
    CHANGED_AM=()
    while IFS= read -r f; do
      [ -n "$f" ] && CHANGED_AM+=("$f")
    done < <(git -C "$REPO" diff --name-only --diff-filter=AM "$BASE".."$HEAD")
    if [ "${#CHANGED_AM[@]}" -gt 0 ]; then
      git -C "$REPO" archive "$HEAD" -- "${CHANGED_AM[@]}" | tar -x -C "$DEST"
    fi
  '

  for shell_bin in bash zsh; do
    command -v "$shell_bin" >/dev/null 2>&1 || { echo "skipping $shell_bin (not installed)"; continue; }
    local dest="$BATS_TEST_TMPDIR/dump-$shell_bin"
    rm -rf "$dest"
    REPO="$sandbox" HEAD="$head_sha" BASE="$base_sha" DEST="$dest" PATH="$PATH" \
      "$shell_bin" -c "$snippet" \
      || { echo "$shell_bin: snippet failed"; false; }
    [ -f "$dest/a.txt" ] \
      || { echo "$shell_bin: expected $dest/a.txt to exist"; ls -laR "$dest" >&2; false; }
    [ -f "$dest/b.txt" ] \
      || { echo "$shell_bin: expected $dest/b.txt to exist"; ls -laR "$dest" >&2; false; }
    [ "$(cat "$dest/a.txt")" = "v2" ] \
      || { echo "$shell_bin: a.txt content wrong (expected v2, got $(cat "$dest/a.txt"))"; false; }
    [ "$(cat "$dest/b.txt")" = "added" ] \
      || { echo "$shell_bin: b.txt content wrong (expected added, got $(cat "$dest/b.txt"))"; false; }
  done
}
