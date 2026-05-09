#!/usr/bin/env bash
# lib/eligibility.sh — Shell-side eligibility predicates for loop agents.
#
# Each function answers "does this agent mode have any work to do?" without
# loading an LLM. Wrappers source this file and short-circuit before invoking
# 'claude' on empty cycles. Agents may also invoke the same predicates (via
# Bash) on entry, so the wrapper preflight and the in-prompt re-check stay
# in sync — they call the same shell function.
#
# Each predicate prints the candidate count to stdout (one line) and exits:
#   0  → there is work; the wrapper should proceed to invoke the agent
#   1  → there is NO work; the wrapper should exit early without invoking
#   2  → gh / jq invocation failed (network, auth, GraphQL schema drift, ...).
#         Wrappers must skip the LLM and back off (treat rc=2 as rc=1) —
#         run-loop.sh already applies exponential backoff on wrapper exit 2.
#         The previous "fall back to assume work" policy turned any persistent
#         predicate failure into a per-cycle token leak, since the LLM was
#         spawned every poll cycle while doing nothing useful. Loud logging
#         on stderr is the operator-visibility signal that the predicate is
#         wedged. (GH#27)
#
# Required env (set by the loop CLI):
#   REPO_ROOT     consumer repo (contains .loop/loop.config)
#   LOOP_HOME   ~/code/loop
#
# loop.config keys consumed:
#   REPO_SLUG, BRANCH_PREFIX, SEVERITY_LABEL_HIGH, SEVERITY_LABEL_MEDIUM,
#   REVIEWER_AGENT_VERDICT_REGEX
#
# Parity with prompt skip-rules: see eligibility-parity.md (sibling file).
# Each predicate below is the gate of record for one or more "skip if X"
# rules in templates/{developer,reviewer,reviewer-orchestrator}.md. When
# adding or changing a predicate, update the parity matrix at the same
# time so the prompt rules and predicate filters stay in lockstep.

# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/_preamble.sh"

: "${REPO_ROOT:?REPO_ROOT must be set; invoke via the loop CLI or wrappers}"
: "${LOOP_HOME:?LOOP_HOME must be set; invoke via the loop CLI or wrappers}"

# shellcheck disable=SC1091
. "$REPO_ROOT/.loop/loop.config"
# Canonical loop_sanitize_id helper — single source of truth for the
# LOCK_NAME_PREFIX defaulting below (GH#98).
# shellcheck disable=SC1091
. "$LOOP_HOME/runners/lib/repo_id.sh"

# Default for older loop.config files predating GH#28. Set unconditionally
# (default-if-unset) so consumer repos don't have to re-run `st init` to pick
# up the new safety-net skip marker.
: "${BLOCKED_HUMAN_LABEL:=blocked:human}"

# Default for older loop.config files predating GH#94. Same default-if-unset
# pattern. Applied to PRs by run-reviewer.sh after
# REVIEWER_SUB_AGENT_FAILURE_CAP consecutive sub-agent failures, and consumed
# below by eligibility_review_pending to drop the PR from review dispatch.
: "${REVIEWER_ESCALATION_LABEL:=reviewer:needs-human}"

# Defaults for older loop.config files predating GH#37 (merger dispatcher).
# Same default-if-unset pattern as BLOCKED_HUMAN_LABEL — consumer repos don't
# have to re-run `st init` to pick up the merger.
: "${MERGER_VERDICTS_ALLOWED:=clean nits}"
: "${MERGER_MERGE_METHOD:=squash}"
: "${MERGER_DELETE_BRANCH:=1}"

# Default for older loop.config files predating GH#74 (multi-repo support).
# Sanitize REPO_NAME so a `.`-bearing name (e.g. lodash.debounce) still
# yields a filesystem-safe prefix. Helper sourced above (GH#98).
: "${LOCK_NAME_PREFIX:=$(loop_sanitize_id "${REPO_NAME:-}")-}"

# ---------------------------------------------------------------------------
# Mode 1 dev-agent: open severity:high|medium issues with no assignee, no
# ${BLOCKED_HUMAN_LABEL} label, no live filesystem lock under $LOCK_DIR, AND
# no open `${BRANCH_PREFIX}/gh-N-...` PR (GH#65).
#
# The label filter (GH#28) drops issues the safety-net flow has flagged as
# permanently ineligible until a human acts. Without it, every poll cycle
# rediscovers the same blocked issue, the wrapper spawns a fresh LLM, the
# LLM re-trips the same safety-net rule, and exits — burning tokens until
# the human closes/reassigns the GH issue.
#
# The lock-dir post-filter is advisory: the agent still does the atomic mkdir
# for the actual claim. Without it, every parallel wrapper sees the same gh
# count, every wrapper invokes the LLM, and N-1 lose the lock race and exit
# after a wasted scan — the dominant cost path under DEV_INSTANCES>1.
#
# Stale-lock cleanup remains the agent's responsibility (STALE_LOCK_HOURS).
# False negatives (gh hit but lock present) still skip real work for one
# cycle, but the next cycle picks them up once the lock is released.
#
# The open-PR filter (GH#65) skips issues whose deterministic dev-agent branch
# (`${BRANCH_PREFIX}/gh-<num>-<slug>`, see template Step 1) is already the head
# of an open PR. Without it the wrapper happily mkdir-locks a redundant claim
# under DEV_AGENT_TARGET_ISSUE, the LLM (which skips its own discovery in that
# mode) trips the safety net every cycle, and we burn tokens per cycle on work
# that is by definition already in flight. The agent prompt's Step 2 has
# always said "Skip issues that already have a linked open PR", but the
# wrapper-driven path bypasses that filter — fixing it here closes the gap.
# ---------------------------------------------------------------------------
eligibility_dev_count() {
  # Use the REST list endpoint (--label) instead of --search: the search index
  # silently drops freshly-created issues (minutes of lag) and issues hidden by
  # GitHub's automated content filter (e.g. duplicate titles, code-dense bodies
  # on new repos). REST list reflects current state immediately.
  local label raw nums_all nums n filtered pr_json open_pr_issues
  nums_all=""
  for label in "$SEVERITY_LABEL_HIGH" "$SEVERITY_LABEL_MEDIUM"; do
    if ! raw=$(
      PAGER=cat GIT_PAGER=cat gh issue list \
        --repo "$REPO_SLUG" --state open \
        --label "$label" \
        --json number,assignees,labels \
        --limit 50 2>/dev/null \
        | jq -r --arg blocked "$BLOCKED_HUMAN_LABEL" '
            .[]
            | select(.assignees == [])
            | select((.labels // [] | map(.name)) | index($blocked) | not)
            | .number
          ' 2>/dev/null
    ); then
      echo "?"
      return 2
    fi
    nums_all+="${raw}"$'\n'
  done
  nums=$(printf '%s' "$nums_all" | sort -u | grep . || true)

  # GH#65: build the set of issue numbers that already have an open dev-agent
  # PR. Skip the network call when there are no candidates to filter.
  open_pr_issues=""
  if [ -n "$nums" ]; then
    if ! pr_json=$(
      PAGER=cat GIT_PAGER=cat gh pr list \
        --repo "$REPO_SLUG" --state open \
        --json number,headRefName \
        --limit 100 2>/dev/null
    ); then
      echo "?"
      return 2
    fi
    open_pr_issues=$(
      printf '%s' "$pr_json" \
        | jq -r --arg prefix "$BRANCH_PREFIX" '
            .[] | (.headRefName // "")
                | select(test("^" + $prefix + "/gh-[0-9]+-"))
                | match("^" + $prefix + "/gh-([0-9]+)-").captures[0].string
          ' 2>/dev/null
    )
  fi

  filtered=0
  for n in $nums; do
    [ -d "${LOCK_DIR}/${LOCK_NAME_PREFIX}gh-${n}.lock" ] && continue
    if [ -n "$open_pr_issues" ] && printf '%s\n' "$open_pr_issues" | grep -qx "$n"; then
      continue
    fi
    filtered=$((filtered + 1))
  done
  echo "$filtered"
  [ "$filtered" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Mode 1 dev-agent (lock-acquisition variant): same filter semantics as
# eligibility_dev_count but emits one candidate-number per line on stdout
# in strictly id-ascending order across both severities (GH#113), de-duplicated.
# Severity is no longer a tiebreaker — lower-numbered issues are usually
# foundational (filed earlier; later issues build on them), so claiming them
# first keeps the queue in dependency order.
#
# This is what run-developer.sh consumes to acquire the lock BEFORE spawning
# the LLM (GH#31). The wrapper iterates the printed numbers and tries
# `mkdir "$LOCK_DIR/${LOCK_NAME_PREFIX}gh-N.lock"` on each; the first
# successful mkdir is the wrapper's claim (GH#74 added the prefix as a
# defence-in-depth multi-repo guard). Without this list, the wrapper had only a count and the
# LLM did its own discovery + lock — the TOCTOU window between count and
# lock cost ~$0.20-$0.50 per losing parallel agent under DEV_INSTANCES>1.
#
# Filter set must stay in lockstep with eligibility_dev_count: assignees == [],
# no BLOCKED_HUMAN_LABEL (GH#28), no live lock under $LOCK_DIR, AND no open
# `${BRANCH_PREFIX}/gh-N-...` PR (GH#65). Any divergence reopens a silent-zero
# token-leak window — both predicates feed the same wrapper preflight.
#
# Output and exit-code shape mirrors eligibility_dev_count:
#   stdout: candidate numbers, one per line (no trailing blank), or `?` on
#           predicate failure
#   exit:   0 = at least one candidate, 1 = none, 2 = gh/jq failure
# ---------------------------------------------------------------------------
eligibility_dev_candidates() {
  local raw_h raw_m all filtered_lines n filtered_count pr_json open_pr_issues
  # Filter set must mirror eligibility_dev_count exactly: assignees == [],
  # no BLOCKED_HUMAN_LABEL (GH#28), AND no open dev-agent PR (GH#65). Without
  # any one of these, the wrapper happily mkdir-locks an ineligible issue and
  # the LLM (which skips its own discovery when DEV_AGENT_TARGET_ISSUE is set)
  # either re-trips the safety net or thrashes on a redundant claim — both
  # silent-zero token leaks.
  if ! raw_h=$(
    PAGER=cat GIT_PAGER=cat gh issue list \
      --repo "$REPO_SLUG" --state open \
      --label "$SEVERITY_LABEL_HIGH" \
      --json number,assignees,labels \
      --limit 50 2>/dev/null \
      | jq -r --arg blocked "$BLOCKED_HUMAN_LABEL" '
          .[]
          | select(.assignees == [])
          | select((.labels // [] | map(.name)) | index($blocked) | not)
          | .number
        ' 2>/dev/null
  ); then
    echo "?"
    return 2
  fi
  if ! raw_m=$(
    PAGER=cat GIT_PAGER=cat gh issue list \
      --repo "$REPO_SLUG" --state open \
      --label "$SEVERITY_LABEL_MEDIUM" \
      --json number,assignees,labels \
      --limit 50 2>/dev/null \
      | jq -r --arg blocked "$BLOCKED_HUMAN_LABEL" '
          .[]
          | select(.assignees == [])
          | select((.labels // [] | map(.name)) | index($blocked) | not)
          | .number
        ' 2>/dev/null
  ); then
    echo "?"
    return 2
  fi
  # GH#113: strict id-ascending across both severities. `sort -un` dedupes
  # numerically (an issue tagged both severities surfaces once, in its id
  # slot) and orders by integer value. `grep .` strips blank lines so the
  # iteration loop below doesn't burn a cycle on an empty entry.
  all=$(printf '%s\n%s\n' "$raw_h" "$raw_m" | sort -un | grep . || true)

  # GH#65: build the set of issue numbers that already have an open dev-agent
  # PR. Skip the network call when there are no candidates to filter.
  open_pr_issues=""
  if [ -n "$all" ]; then
    if ! pr_json=$(
      PAGER=cat GIT_PAGER=cat gh pr list \
        --repo "$REPO_SLUG" --state open \
        --json number,headRefName \
        --limit 100 2>/dev/null
    ); then
      echo "?"
      return 2
    fi
    open_pr_issues=$(
      printf '%s' "$pr_json" \
        | jq -r --arg prefix "$BRANCH_PREFIX" '
            .[] | (.headRefName // "")
                | select(test("^" + $prefix + "/gh-[0-9]+-"))
                | match("^" + $prefix + "/gh-([0-9]+)-").captures[0].string
          ' 2>/dev/null
    )
  fi

  filtered_count=0
  filtered_lines=""
  for n in $all; do
    [ -d "${LOCK_DIR}/${LOCK_NAME_PREFIX}gh-${n}.lock" ] && continue
    if [ -n "$open_pr_issues" ] && printf '%s\n' "$open_pr_issues" | grep -qx "$n"; then
      continue
    fi
    filtered_lines+="$n"$'\n'
    filtered_count=$((filtered_count + 1))
  done
  if [ -n "$filtered_lines" ]; then
    printf '%s' "$filtered_lines"
  fi
  [ "$filtered_count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Reviewer orchestrator: open ${BRANCH_PREFIX}/* PRs whose head commit is not
# yet covered by a [reviewer-agent: ...] review AND whose CI has finished.
#
# A review is considered to "cover" the head when its `submittedAt` is later
# than the head commit's `committedDate`. (We can't use `review.commit_id` —
# `gh pr list --json reviews` populates it as null in current gh versions.)
#
# Mirrors the orchestrator's own filter, so false-positive rate is minimal.
# The orchestrator still re-checks before dispatching its sub-agent.
#
# GH#26: pre-fix this issued `gh pr list --json number,commits,reviews
# --limit 100`, which the GraphQL planner expanded by every neighbouring
# connection (`commits.authors[]`, `reviews.author`, ...) and the gateway
# rejected with "1,000,000 possible nodes which exceeds the maximum limit of
# 500,000". gh exited non-zero, the predicate fell through to its rc=2 branch,
# and the wrapper's "proceed to be safe" policy spawned the reviewer LLM on
# every cycle even with no work to do (~$1.90 per 10 idle cycles).
#
# The fix narrows the query to `--json number,headRefOid,reviews` (no
# `commits` connection) and resolves the head commit's `committedDate` per
# `headRefOid` via a separate `gh api graphql` call — bounded at 1 commit
# × 1 field per PR, well under the 500k node ceiling.
#
# GH#46: pre-fix this predicate filtered only on review coverage; the CI gate
# the orchestrator applies in-prompt (skip if any check is IN_PROGRESS /
# PENDING / QUEUED) was missing. While CI ran on a freshly-pushed dev-agent
# PR, every reviewer poll cycle spawned the orchestrator LLM only to discover
# CI hadn't finished and exit `result=none-found` — leaking ~$0.50–$1.50
# per CI window per PR. The fix adds `statusCheckRollup` to the `--json` field
# set (one extra field on the existing call, no extra round-trip) and excludes
# any PR with an unfinished check. Note: gh's `statusCheckRollup` carries a
# `.status` field on `CheckRun` entries (Actions/check-suite checks) and a
# `.state` field on legacy `StatusContext` entries (older status API), so the
# filter normalizes via `.status // .state` to handle both shapes. Failed CI
# (COMPLETED + FAILURE) is still reviewable — only RUNNING states gate.
# ---------------------------------------------------------------------------
# Shared back-end for eligibility_review_pending (count form) and
# eligibility_review_pending_list (PR-numbers form). Fetches the candidate PR
# list + per-head committedDate map, then prints a single JSON object on
# stdout: {"prs": <pr-array>, "dates": <oid→date map>}. Callers run their own
# jq projection (count vs. ordered list) on top.
#
# Returns 0 on success, 2 on gh/jq failure.
_eligibility_review_fetch() {
  local prs owner repo oid_dates oid date_iso
  # GH#94: `labels` is added to the field set so the predicate can drop PRs
  # carrying ${REVIEWER_ESCALATION_LABEL}. Mirrors the BLOCKED_HUMAN_LABEL
  # precedent in eligibility_dev_count above. Single extra field on the
  # existing call — no extra round-trip.
  # GH#117: `updatedAt` is added so the dispatcher can sort
  # backlog by "oldest updatedAt first" within the green-CI bucket.
  if ! prs=$(
    PAGER=cat GIT_PAGER=cat gh pr list \
      --repo "$REPO_SLUG" --state open \
      --search "head:${BRANCH_PREFIX}/ -is:draft" \
      --json number,headRefOid,reviews,statusCheckRollup,labels,updatedAt \
      --limit 100 2>/dev/null
  ); then
    return 2
  fi

  # Split REPO_SLUG ("owner/repo") for the GraphQL variables.
  owner="${REPO_SLUG%%/*}"
  repo="${REPO_SLUG##*/}"

  # Build an oid → committedDate map by issuing one tiny GraphQL query per
  # head sha. The per-PR query is intentionally minimal (object resolved by
  # oid → Commit → committedDate) so total node count stays bounded.
  oid_dates="{}"
  while IFS= read -r oid; do
    [ -z "$oid" ] && continue
    # $owner/$name/$oid below are GraphQL variables, not bash. Single quotes
    # on the query body are intentional (and required) — silence SC2016.
    # shellcheck disable=SC2016
    if ! date_iso=$(
      PAGER=cat GIT_PAGER=cat gh api graphql \
        -F owner="$owner" -F name="$repo" -F oid="$oid" \
        -f query='
          query($owner:String!,$name:String!,$oid:GitObjectID!) {
            repository(owner:$owner,name:$name) {
              object(oid:$oid) { ... on Commit { committedDate } }
            }
          }' \
        --jq '.data.repository.object.committedDate // ""' 2>/dev/null
    ); then
      return 2
    fi
    oid_dates=$(jq --arg oid "$oid" --arg d "$date_iso" '. + {($oid): $d}' <<<"$oid_dates")
  done < <(echo "$prs" | jq -r '.[].headRefOid // empty')

  jq -n --argjson prs "$prs" --argjson dates "$oid_dates" \
    '{prs: $prs, dates: $dates}'
}

# Shared jq filter that maps the {prs, dates} object emitted by
# _eligibility_review_fetch to the array of eligible PRs. Each surviving entry
# carries .number plus a .ci_bucket ("green" | "red") so callers can sort by
# CI status without re-querying. Apply the "no review covers head" filter
# (looking up the head date in $dates by headRefOid) AND a CI gate (GH#46):
# exclude any PR with a check in IN_PROGRESS/PENDING/QUEUED. The gate uses
# `.status // .state` because gh's statusCheckRollup carries `status` for
# CheckRun (Actions) and `state` for legacy StatusContext entries. Missing/null
# statusCheckRollup falls through to an empty list (PR is treated as "no CI
# gating") so the predicate is permissive when GitHub has nothing to report.
#
# The single-quoted body intentionally embeds jq variable references
# ($pr, $head_date, $dates, $re, $escalation_label, $check_states, ...) —
# they are jq, not bash, and must not expand at source-load time.
# shellcheck disable=SC2016
_REVIEW_ELIGIBLE_JQ='
  [.prs[]
   | . as $pr
   | (($dates[$pr.headRefOid] // "") | (if . == "" then null else . end)) as $head_date
   | ($pr.reviews // [] | [.[] | select(.body | test($re)) | .submittedAt]) as $review_dates
   | ($pr.statusCheckRollup // [] | map(.status // .state)) as $check_states
   | ($pr.labels // [] | map(.name)) as $label_names
   | select(($label_names | index($escalation_label)) | not)
   | select(
       $head_date == null
       or ($review_dates | map(select(. != null and . > $head_date)) | length == 0)
     )
   | select(
       ($check_states | index("IN_PROGRESS") | not)
       and ($check_states | index("PENDING") | not)
       and ($check_states | index("QUEUED") | not)
     )
   | (
       $pr.statusCheckRollup // []
       | map(.conclusion // .state // "SUCCESS")
       | if any(. == "FAILURE" or . == "ERROR" or . == "CANCELLED" or . == "TIMED_OUT" or . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE")
         then "red"
         else "green"
         end
     ) as $ci_bucket
   | {
       number: .number,
       updatedAt: (.updatedAt // ""),
       ci_bucket: $ci_bucket
     }
  ]'

eligibility_review_pending() {
  local fetched count
  if ! fetched=$(_eligibility_review_fetch); then
    echo "?"
    return 2
  fi
  if ! count=$(
    jq -r --arg re "$REVIEWER_AGENT_VERDICT_REGEX" \
      --arg escalation_label "$REVIEWER_ESCALATION_LABEL" \
      --argjson dates "$(jq -c '.dates' <<<"$fetched")" \
      "$_REVIEW_ELIGIBLE_JQ | length" \
      <<<"$fetched" 2>/dev/null
  ); then
    echo "?"
    return 2
  fi
  count="${count:-0}"
  echo "$count"
  [ "$count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Reviewer dispatcher (GH#117): list form of eligibility_review_pending.
# Emits one PR number per line on stdout, ordered: green CI first, then by
# oldest updatedAt within each CI bucket (clear the backlog). Same filter
# semantics as eligibility_review_pending; both share _eligibility_review_fetch
# and _REVIEW_ELIGIBLE_JQ so the count-form and list-form can never disagree.
#
# Output and exit-code shape mirrors eligibility_dev_candidates:
#   stdout: PR numbers, one per line (no trailing blank), or `?` on failure
#   exit:   0 = at least one candidate, 1 = none, 2 = gh/jq failure
# ---------------------------------------------------------------------------
eligibility_review_pending_list() {
  local fetched lines count
  if ! fetched=$(_eligibility_review_fetch); then
    echo "?"
    return 2
  fi
  if ! lines=$(
    jq -r --arg re "$REVIEWER_AGENT_VERDICT_REGEX" \
      --arg escalation_label "$REVIEWER_ESCALATION_LABEL" \
      --argjson dates "$(jq -c '.dates' <<<"$fetched")" \
      "$_REVIEW_ELIGIBLE_JQ
       | sort_by([(if .ci_bucket == \"green\" then 0 else 1 end), .updatedAt])
       | .[].number" \
      <<<"$fetched" 2>/dev/null
  ); then
    echo "?"
    return 2
  fi
  count=0
  if [ -n "$lines" ]; then
    # `lines` came from jq -r, which produces one value per line with no
    # trailing blank. `$(...)` strips trailing newlines, so a single trailing
    # printf '\n' restores newline-termination without doubling it.
    printf '%s\n' "$lines"
    count=$(printf '%s\n' "$lines" | grep -c .)
  fi
  [ "$count" -gt 0 ]
}

# ---------------------------------------------------------------------------
# Mode 2 follow-up dispatcher: should we spin up a dev-agent on PR <N>?
#
# Until GH#24 the dispatcher fired on a pure timestamp comparison — every
# `[reviewer-agent: clean]` review beat the latest dev-comment by definition,
# so the LLM was woken up only to discover there was nothing actionable. Cost
# recurred every poll cycle until the PR merged (severity:medium token leak).
#
# The verdict-aware gate:
#   - {clean, nits}             → skip regardless of timestamp ordering
#                                   (`nits` is explicitly optional in Mode 2;
#                                    `clean` is by definition no-op).
#   - {changes, comment, blocked} → dispatch IFF the review's submittedAt
#                                   is newer than the latest dev-agent
#                                   comment's createdAt (otherwise the dev
#                                   already responded; another dispatch
#                                   would re-do work).
#   - no reviewer-agent review yet → skip (nothing to follow-up on).
#
# Prints the verdict (or "none" / "?") on stdout for log visibility.
# ---------------------------------------------------------------------------
eligibility_followup_pr() {
  local pr="${1:-}"
  if [ -z "$pr" ]; then
    echo "?"
    return 2
  fi

  local data
  # GH#111: `labels` is added to the field set so the predicate can drop PRs
  # carrying ${BLOCKED_HUMAN_LABEL} after the wrapper escalates a Mode 2 cap.
  # Mirrors the GH#94 REVIEWER_ESCALATION_LABEL precedent in
  # eligibility_review_pending. Single extra field on the existing call —
  # no extra round-trip.
  if ! data=$(
    PAGER=cat GIT_PAGER=cat gh pr view "$pr" \
      --repo "$REPO_SLUG" \
      --json reviews,comments,labels 2>/dev/null
  ); then
    echo "?"
    return 2
  fi

  # One pass of jq: short-circuit when BLOCKED_HUMAN_LABEL is present, else
  # classify the latest reviewer-agent review and the ordering vs the latest
  # dev-agent comment, emit a TAB-separated "<verdict>\t<dispatch?>" string.
  local result
  if ! result=$(
    echo "$data" | jq -r \
      --arg re "$REVIEWER_AGENT_VERDICT_REGEX" \
      --arg prefix "$DEV_AGENT_COMMENT_PREFIX" \
      --arg blocked_label "$BLOCKED_HUMAN_LABEL" '
      if ((.labels // [] | map(.name)) | index($blocked_label)) != null then
        "blocked-by-label\tno"
      else
        (.reviews // []
          | map(select(.body | test($re)))
          | sort_by(.submittedAt)
          | last) as $latest_review
        | (.comments // []
          | map(select(.body | startswith($prefix)))
          | sort_by(.createdAt)
          | last) as $latest_devcomment
        | if $latest_review == null then "none\tno"
          else
            ($latest_review.body | match($re).captures[0].string) as $verdict
            | if ($verdict == "clean" or $verdict == "nits") then "\($verdict)\tno"
              elif ($latest_devcomment == null
                    or $latest_review.submittedAt > $latest_devcomment.createdAt) then
                "\($verdict)\tyes"
              else "\($verdict)\tno"
              end
          end
      end
      ' 2>/dev/null
  ); then
    echo "?"
    return 2
  fi

  local verdict should
  # `result` is "<verdict>\t<dispatch>"; use cut(1) instead of literal-tab
  # parameter expansion so the source is robust to whitespace re-indenting.
  verdict=$(printf '%s\n' "$result" | cut -f1)
  should=$(printf '%s\n' "$result" | cut -f2)
  echo "$verdict"
  if [ "$should" = "yes" ]; then
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Merger dispatcher (GH#37): should we squash-merge PR <N> right now?
#
# Closes the loop end-to-end: scans dev-agent PRs that earned a `clean` (or
# `nits`) verdict from the reviewer-agent and have green CI / no conflicts,
# and squash-merges them — eliminating the manual `gh pr merge` step the
# loop used to require (#34, #30, #25, #23 all merged by hand).
#
# A PR is mergeable iff ALL of:
#   - The latest reviewer-agent review's verdict is in $MERGER_VERDICTS_ALLOWED
#     (default: "clean nits"; configurable per-repo).
#   - The agent review covers the current head commit. Prefer a `commit.oid`
#     match (the post-#14 fixture shape); fall back to `submittedAt > head
#     committedDate` when the API returns commit.oid as null. Stale reviews
#     get skipped — a `clean` verdict on yesterday's HEAD doesn't bless
#     today's HEAD.
#   - No human comment (body NOT prefixed with the dev-agent automation
#     marker `🤖`) and no human review (body NOT matching the reviewer-agent
#     verdict regex) postdates the agent review. Either is a veto signal —
#     the human is engaging mid-flight, so the merger waits.
#   - mergeable == "MERGEABLE" AND mergeStateStatus == "CLEAN". Combined,
#     these cover green CI + no conflicts + branch up-to-date with base —
#     so the merger never auto-merges a PR that needs a rebase or has a red
#     check.
#
# Always prints the verdict (or "none" / "?") on stdout for the dispatcher's
# log line. Exit 0 = merge, 1 = skip, 2 = gh/jq failure (treat as skip;
# next cycle re-checks).
#
# No locks — gh refuses to merge an already-merged PR (idempotent), and the
# verdict-aware gate prevents racing two parallel merger panes from
# accepting the same PR more than once at the API layer.
# ---------------------------------------------------------------------------
eligibility_merge_pr() {
  local pr="${1:-}"
  if [ -z "$pr" ]; then
    echo "?"
    return 2
  fi

  local data
  if ! data=$(
    PAGER=cat GIT_PAGER=cat gh pr view "$pr" \
      --repo "$REPO_SLUG" \
      --json reviews,comments,commits,mergeable,mergeStateStatus,headRefOid 2>/dev/null
  ); then
    echo "?"
    return 2
  fi

  local result
  if ! result=$(
    echo "$data" | jq -r \
      --arg re "$REVIEWER_AGENT_VERDICT_REGEX" \
      --arg allowed "$MERGER_VERDICTS_ALLOWED" '
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
      ' 2>/dev/null
  ); then
    echo "?"
    return 2
  fi

  local verdict should
  verdict=$(printf '%s\n' "$result" | cut -f1)
  should=$(printf '%s\n' "$result" | cut -f2)
  echo "$verdict"
  if [ "$should" = "yes" ]; then
    return 0
  else
    return 1
  fi
}

# ---------------------------------------------------------------------------
# CLI entry point. Lets agents invoke this via:
#   bash $LOOP_HOME/runners/lib/eligibility.sh dev
#   bash $LOOP_HOME/runners/lib/eligibility.sh dev-candidates
#   bash $LOOP_HOME/runners/lib/eligibility.sh review
#   bash $LOOP_HOME/runners/lib/eligibility.sh followup <PR#>
#   bash $LOOP_HOME/runners/lib/eligibility.sh merge <PR#>
# Wrappers source the file and call functions directly.
# ---------------------------------------------------------------------------
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  case "${1:-}" in
    dev)
      eligibility_dev_count
      exit $?
      ;;
    dev-candidates)
      eligibility_dev_candidates
      exit $?
      ;;
    review)
      eligibility_review_pending
      exit $?
      ;;
    review-list)
      eligibility_review_pending_list
      exit $?
      ;;
    followup)
      eligibility_followup_pr "${2:-}"
      exit $?
      ;;
    merge)
      eligibility_merge_pr "${2:-}"
      exit $?
      ;;
    -h | --help | help | "")
      cat <<'EOF'
Usage: eligibility.sh <mode> [args]

Modes:
  dev              Count open severity:high|medium issues with no assignee.
  dev-candidates   Print one candidate-number per line (id-ascending across
                   severities, GH#113), so the wrapper can mkdir-acquire a lock
                   BEFORE spawning the LLM (closes the TOCTOU window of 'dev').
  review           Count open dev-agent PRs not yet reviewed at current head SHA.
  review-list      Print one candidate-PR number per line (green CI first, then
                   oldest updatedAt). Same filter as 'review'; consumed by the
                   reviewer dispatcher in run-loop.sh (GH#117).
  followup <PR#>   Should the follow-up dispatcher dispatch a Mode 2 dev-agent
                   for PR <PR#>? Skips clean/nits verdicts unconditionally;
                   dispatches changes/comment/blocked iff the review is newer
                   than the latest dev-agent comment.
  merge <PR#>      Should the merger dispatcher squash-merge PR <PR#>? Returns
                   merge iff the latest reviewer-agent verdict is in
                   $MERGER_VERDICTS_ALLOWED (default: clean nits), the review
                   covers the current head, no human has engaged after the
                   review, and mergeable=MERGEABLE + mergeStateStatus=CLEAN.

Output: one line — count (dev/review) or verdict (followup/merge), or '?' on failure.
        Multi-line for dev-candidates (one number per line, empty if none).
Exit:   0 = work to do, 1 = nothing eligible, 2 = predicate failed.

Required env:
  REPO_ROOT, LOOP_HOME (set automatically when invoked via the loop CLI).
EOF
      exit 0
      ;;
    *)
      echo "[eligibility] unknown mode: $1" >&2
      exit 2
      ;;
  esac
fi
