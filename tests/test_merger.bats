#!/usr/bin/env bats
# eligibility_merge_pr — verdict-aware gate for the merger dispatcher (GH#37).
#
# A PR is eligible to auto-merge iff:
#   1. The latest reviewer-agent review's verdict is in $MERGER_VERDICTS_ALLOWED
#      (default: "clean nits").
#   2. The review covers the current head SHA (commit.oid match, or
#      submittedAt > head.committedDate when commit.oid is null —
#      mirrors eligibility_review_pending).
#   3. No human comment (body NOT starting with "🤖") with createdAt > review.submittedAt.
#   4. No human review (body NOT matching the verdict regex) with submittedAt > review.submittedAt.
#   5. mergeable == "MERGEABLE" AND mergeStateStatus == "CLEAN".
#
# The predicate prints the verdict (or "none" / "?") on stdout for log
# visibility, and exits 0 = merge, 1 = skip, 2 = gh/jq failure — same shape
# as eligibility_followup_pr.

load 'helpers'

# ---------------------------------------------------------------------------
# Pure jq filter — kept in lockstep with runners/lib/eligibility.sh.
# Tests mutate the canonical pr-merger.json fixture (clean verdict at head,
# CI green, dev-comment older than review) to inject scenario-specific state.
# ---------------------------------------------------------------------------
MERGER_FILTER='
  . as $pr
  | (((.commits // [])[-1] | .committedDate) // null) as $head_date
  | (.reviews // []
      | map(select(.body | test($re)))
      | sort_by(.submittedAt)
      | last) as $latest_review
  | if $latest_review == null then "none\tno"
    else
      ($latest_review.body | match($re).captures[0].string) as $verdict
      | ($allowed | split(" ") | map(select(. != ""))) as $allowed_list
      | (if (($latest_review.commit // {}).oid // null) != null then
           $latest_review.commit.oid == $pr.headRefOid
         else
           ($head_date != null and $latest_review.submittedAt > $head_date)
         end) as $covers_head
      | ([($pr.comments // [])[]
          | select((.body // "") | startswith("🤖") | not)
          | select(.createdAt > $latest_review.submittedAt)] | length == 0) as $no_human_comment
      | ([($pr.reviews // [])[]
          | select((.body // "") | test($re) | not)
          | select(.submittedAt > $latest_review.submittedAt)] | length == 0) as $no_human_review
      | (($pr.mergeable == "MERGEABLE") and ($pr.mergeStateStatus == "CLEAN")) as $ci_clean
      | if (($allowed_list | index($verdict)) != null
            and $covers_head
            and $no_human_comment
            and $no_human_review
            and $ci_clean) then "\($verdict)\tyes"
        else "\($verdict)\tno"
        end
    end
'

RE='\[reviewer-agent: (clean|nits|comment|changes|blocked)\]'
PREFIX='🤖 Developer agent'
DEFAULT_ALLOWED='clean nits'

# Mutate the latest reviewer-agent review body to a different verdict;
# emit modified JSON to stdout. Keeps each test focused on one variable.
_with_verdict() {
  jq --arg body "🤖 Reviewer agent — automated review

[reviewer-agent: $1]

generated" '.reviews[-1].body = $body' \
     "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json"
}

@test "merger filter: clean verdict + CLEAN merge state → merge" {
  local out
  out=$(jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER" \
           < "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json")
  [ "$out" = $'clean\tyes' ]
}

@test "merger filter: nits verdict + CLEAN merge state → merge" {
  local out
  out=$(_with_verdict nits | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'nits\tyes' ]
}

@test "merger filter: comment verdict → skip (not in default allow-list)" {
  local out
  out=$(_with_verdict comment | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'comment\tno' ]
}

@test "merger filter: changes verdict → skip" {
  local out
  out=$(_with_verdict changes | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'changes\tno' ]
}

@test "merger filter: blocked verdict → skip" {
  local out
  out=$(_with_verdict blocked | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'blocked\tno' ]
}

@test "merger filter: no reviewer-agent review → none / skip" {
  local out
  out=$(jq '.reviews = []' "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'none\tno' ]
}

@test "merger filter: stale agent review (commit.oid != headRefOid) → skip but echo verdict" {
  local out
  out=$(jq '.reviews[-1].commit.oid = "deadbeef0000000000000000000000000000dead"' \
          "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'clean\tno' ]
}

@test "merger filter: review.commit.oid null + submittedAt > head → merge" {
  # Mirrors the eligibility_review_pending fallback: when commit.oid is
  # missing, fall back to time comparison vs head commit's committedDate.
  local out
  out=$(jq '.reviews[-1].commit = null' \
          "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'clean\tyes' ]
}

@test "merger filter: review.commit.oid null + submittedAt <= head → skip" {
  local out
  out=$(jq '.reviews[-1].commit = null
            | .reviews[-1].submittedAt = "2026-05-07T09:00:00Z"' \
          "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'clean\tno' ]
}

@test "merger filter: human comment newer than review → skip with verdict echoed" {
  local out
  out=$(jq '.comments += [{
              "author":{"login":"alice"},
              "body":"hold on, I want to look at this first",
              "createdAt":"2026-05-07T12:00:00Z"
            }]' \
          "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'clean\tno' ]
}

@test "merger filter: dev-agent comment newer than review does NOT veto" {
  # Comments starting with the 🤖 prefix are automation, not human input.
  local out
  out=$(jq '.comments += [{
              "author":{"login":"claude"},
              "body":"🤖 Developer agent — follow-up cycle 1\n\nFixed",
              "createdAt":"2026-05-07T12:00:00Z"
            }]' \
          "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'clean\tyes' ]
}

@test "merger filter: human review newer than agent review → skip" {
  local out
  out=$(jq '.reviews += [{
              "author":{"login":"bob"},
              "body":"Please hold off — I want to read this end-to-end.",
              "submittedAt":"2026-05-07T12:00:00Z",
              "state":"COMMENTED"
            }]' \
          "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'clean\tno' ]
}

@test "merger filter: mergeStateStatus DIRTY → skip" {
  local out
  out=$(jq '.mergeStateStatus = "DIRTY"' \
          "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'clean\tno' ]
}

@test "merger filter: mergeable CONFLICTING → skip" {
  local out
  out=$(jq '.mergeable = "CONFLICTING"' \
          "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" \
        | jq -r --arg re "$RE" --arg allowed "$DEFAULT_ALLOWED" "$MERGER_FILTER")
  [ "$out" = $'clean\tno' ]
}

@test "merger filter: MERGER_VERDICTS_ALLOWED override drops nits" {
  local out
  out=$(_with_verdict nits | jq -r --arg re "$RE" --arg allowed "clean" "$MERGER_FILTER")
  [ "$out" = $'nits\tno' ]
}

@test "merger filter: MERGER_VERDICTS_ALLOWED override accepts comment" {
  local out
  out=$(_with_verdict comment | jq -r --arg re "$RE" --arg allowed "clean nits comment" "$MERGER_FILTER")
  [ "$out" = $'comment\tyes' ]
}

# ---------------------------------------------------------------------------
# eligibility_merge_pr (function-level via PATH-mocked gh).
# Confirms the new CLI mode `merge <PR#>` matches the dev/review/followup
# shape (0=merge, 1=skip, 2=fail) and prints the verdict (or "none" / "?").
# ---------------------------------------------------------------------------
_make_gh_pr_view_stub() {
  # Args: <fixture-json-path>. Writes a gh shim that returns the fixture for
  # any `pr view ... --json ...` invocation. Same minimal shape as the
  # followup tests.
  local fixture="$1"
  local tmpbin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<STUB
#!/usr/bin/env bash
case "\$1 \$2" in
  "pr view")
    cat '$fixture'
    exit 0
    ;;
esac
exit 1
STUB
  chmod +x "$tmpbin/gh"
  echo "$tmpbin"
}

@test "eligibility_merge_pr: clean verdict + CLEAN → exits 0, prints 'clean'" {
  local repo
  repo=$(make_repo)
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 0 ]
  [ "$output" = "clean" ]
}

@test "eligibility_merge_pr: nits verdict + CLEAN → exits 0, prints 'nits'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/nits.json"
  _with_verdict nits > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 0 ]
  [ "$output" = "nits" ]
}

@test "eligibility_merge_pr: comment verdict → exits 1, prints 'comment'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/comment.json"
  _with_verdict comment > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 1 ]
  [ "$output" = "comment" ]
}

@test "eligibility_merge_pr: changes verdict → exits 1, prints 'changes'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/changes.json"
  _with_verdict changes > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 1 ]
  [ "$output" = "changes" ]
}

@test "eligibility_merge_pr: blocked verdict → exits 1, prints 'blocked'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/blocked.json"
  _with_verdict blocked > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 1 ]
  [ "$output" = "blocked" ]
}

@test "eligibility_merge_pr: no reviewer-agent review → exits 1, prints 'none'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/none.json"
  jq '.reviews = []' "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 1 ]
  [ "$output" = "none" ]
}

@test "eligibility_merge_pr: clean review + human comment newer → exits 1, prints 'clean'" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/vetoed.json"
  jq '.comments += [{
        "author":{"login":"alice"},
        "body":"hold up",
        "createdAt":"2026-05-07T12:00:00Z"
      }]' "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 1 ]
  [ "$output" = "clean" ]
}

@test "eligibility_merge_pr: stale agent review (commit.oid mismatch) → exits 1" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/stale.json"
  jq '.reviews[-1].commit.oid = "deadbeef0000000000000000000000000000dead"' \
     "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 1 ]
  [ "$output" = "clean" ]
}

@test "eligibility_merge_pr: mergeStateStatus DIRTY → exits 1" {
  local repo
  repo=$(make_repo)
  local synth="$BATS_TEST_TMPDIR/dirty.json"
  jq '.mergeStateStatus = "DIRTY"' \
     "$LOOP_ROOT/tests/fixtures/gh/pr-merger.json" > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 1 ]
  [ "$output" = "clean" ]
}

@test "eligibility_merge_pr: gh failure → exits 2, prints '?'" {
  local repo
  repo=$(make_repo)
  local tmpbin="$BATS_TEST_TMPDIR/bin-fail"
  mkdir -p "$tmpbin"
  cat > "$tmpbin/gh" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
  chmod +x "$tmpbin/gh"
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 2 ]
  [ "$output" = "?" ]
}

@test "eligibility_merge_pr: missing PR# arg → exits 2, prints '?'" {
  local repo
  repo=$(make_repo)
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge
  [ "$status" -eq 2 ]
  [ "$output" = "?" ]
}

@test "eligibility_merge_pr: MERGER_VERDICTS_ALLOWED override drops nits → exits 1" {
  # Confirms the function honors a config override (e.g. a repo that wants
  # auto-merge on `clean` only).
  local repo
  repo=$(make_repo)
  echo 'MERGER_VERDICTS_ALLOWED="clean"' >> "$repo/.loop/loop.config"
  local synth="$BATS_TEST_TMPDIR/nits-override.json"
  _with_verdict nits > "$synth"
  local tmpbin
  tmpbin=$(_make_gh_pr_view_stub "$synth")
  REPO_ROOT="$repo" LOOP_HOME="$LOOP_ROOT" \
    run env PATH="$tmpbin:$PATH" \
    bash "$LOOP_ROOT/runners/lib/eligibility.sh" merge 42
  [ "$status" -eq 1 ]
  [ "$output" = "nits" ]
}

# ---------------------------------------------------------------------------
# Source-of-truth checks: run-loop.sh wiring and config defaults.
# These guard against accidental refactors that detach the merger from the
# CLI flag, internal-role dispatch, or the loop.config defaults that
# consumer repos rely on (so they don't have to re-run `st init`).
# ---------------------------------------------------------------------------
@test "eligibility.sh: defines eligibility_merge_pr" {
  grep -qE '^eligibility_merge_pr\(\)' "$LOOP_ROOT/runners/lib/eligibility.sh"
}

@test "eligibility.sh: CLI exposes 'merge <PR#>' mode" {
  grep -qE '^[[:space:]]+merge\)' "$LOOP_ROOT/runners/lib/eligibility.sh"
}

@test "eligibility.sh: ships defaults for MERGER_VERDICTS_ALLOWED / METHOD / DELETE_BRANCH" {
  # Defensive defaults so consumer repos predating GH#37 don't have to
  # re-run `st init` to pick up the new merger config keys.
  grep -qF 'MERGER_VERDICTS_ALLOWED:=' "$LOOP_ROOT/runners/lib/eligibility.sh"
  grep -qF 'MERGER_MERGE_METHOD:=' "$LOOP_ROOT/runners/lib/eligibility.sh"
  grep -qF 'MERGER_DELETE_BRANCH:=' "$LOOP_ROOT/runners/lib/eligibility.sh"
}

@test "loop.config.example: declares MERGER_* keys with documented defaults" {
  grep -qF 'MERGER_VERDICTS_ALLOWED=' "$LOOP_ROOT/templates/loop.config.example"
  grep -qF 'MERGER_MERGE_METHOD=' "$LOOP_ROOT/templates/loop.config.example"
  grep -qF 'MERGER_DELETE_BRANCH=' "$LOOP_ROOT/templates/loop.config.example"
}

@test "run-loop.sh: defines loop_dispatcher_merge" {
  grep -qF 'loop_dispatcher_merge' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: --internal-role=dispatch-merge case arm exists" {
  grep -qE 'dispatch-merge\)' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: --enable-merger flag is parsed in start_session" {
  grep -qF -- '--enable-merger' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: merger pane labeled 'merger' is created when --enable-merger is set" {
  # The 4th top-row pane uses the title 'merger' (matches the eligibility
  # CLI mode and the dispatch-merge internal role).
  grep -qF '"merger"' "$LOOP_ROOT/runners/run-loop.sh"
}

@test "run-loop.sh: merger dispatcher uses gh pr merge with the configured method" {
  awk '/loop_dispatcher_merge\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -qE 'gh pr merge'
  awk '/loop_dispatcher_merge\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -qE 'MERGER_MERGE_METHOD'
}

@test "run-loop.sh: merger dispatcher invokes eligibility_merge_pr per PR" {
  awk '/loop_dispatcher_merge\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -qF 'eligibility_merge_pr'
}

@test "run-loop.sh: merger dispatcher re-sources lib/eligibility.sh per cycle (hot-reload)" {
  awk '/loop_dispatcher_merge\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -qF 'lib/eligibility.sh'
}

@test "run-loop.sh: --enable-merger usage line documented" {
  # `usage()` text must mention the flag so `st loop start --help` discovers it.
  awk '/^usage\(\)/,/^}/' "$LOOP_ROOT/runners/run-loop.sh" \
    | grep -qF -- '--enable-merger'
}
