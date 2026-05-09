# Eligibility Predicate ↔ Prompt Skip-Rule Parity

This doc maps every "skip if X" / "abort if X" / "exit early" rule in
`templates/developer.md`, `templates/reviewer.md`, and
`templates/reviewer-orchestrator.md` to its counterpart in
`runners/lib/eligibility.sh`.

The predicates are the **gate of record**: wrappers source `eligibility.sh`
and short-circuit before invoking `claude` on idle cycles. Prompt rules
duplicate a subset of these gates as a defense-in-depth safety net for
direct `claude -p` invocations that bypass the wrapper.

The audit (filed as GH#114) had three goals:

1. Confirm that every prompt skip-rule is mirrored or explicitly
   marked defense-in-depth.
2. Surface any LLM-only rule with no predicate counterpart as a gap.
3. Provide a single document future PRs can update when adding a new
   skip-rule on either side.

## Categories

- **Mirrored** — the predicate enforces the rule before the LLM is spawned.
  The prompt rule is informational; the wrapper-driven path never reaches it.
- **Defense-in-depth** — same as mirrored, but the prompt rule explicitly
  exists for direct `claude -p` invocations that bypass the wrapper. The
  prompt should call this out (e.g. `templates/reviewer-orchestrator.md:51`
  is the model example).
- **Gap** — the rule is enforced only in the prompt; the wrapper still
  spawns `claude` on these cycles and the LLM has to re-verify. Worth
  filing a follow-up issue to close.

## Parity matrix

### Mode 1 (developer.md): claim a GitHub issue

| Prompt rule (file:line) | Rule summary | Predicate (function + snippet) | Category | Notes |
|---|---|---|---|---|
| `templates/developer.md:66-71` | Fast eligibility gate — `bash $LOOP_HOME/runners/lib/eligibility.sh dev`; exit on rc=1 | `eligibility_dev_count` (whole function) | Defense-in-depth | Prompt explicitly says "the call here protects against direct `claude -p` invocations" |
| `templates/developer.md:42-49`, `templates/developer.md:806` | Severity filter — only `severity:high\|medium`; ignore `severity:low` and unlabeled | `eligibility_dev_count` (`for label in "$SEVERITY_LABEL_HIGH" "$SEVERITY_LABEL_MEDIUM"`), `eligibility_dev_candidates` (`raw_h` + `raw_m` blocks, one per severity label) | Mirrored | `gh issue list --label "$SEVERITY_LABEL_HIGH"` and `--label "$SEVERITY_LABEL_MEDIUM"` are the only queries; no-label issues never surface |
| `templates/developer.md:83` | Skip issues with an existing assignee | `eligibility_dev_count` and `eligibility_dev_candidates` (`select(.assignees == [])` in each `gh issue list \| jq` pipeline) | Mirrored | `select(.assignees == [])` |
| `templates/developer.md:84` | Skip issues that already have a linked open dev-agent PR | `eligibility_dev_count` and `eligibility_dev_candidates` (open-PR set built from `gh pr list … --json number,headRefName`, applied via `printf '%s\n' "$open_pr_issues" \| grep -qx "$n"`) | Mirrored | GH#65 — built the open-PR set keyed by `${BRANCH_PREFIX}/gh-N-…` head ref |
| `templates/developer.md:85` | "Skip issues that have a beads memory tag `developer-agent:claimed:<issue#>`" | `eligibility_dev_count` and `eligibility_dev_candidates` (`[ -d "${LOCK_DIR}/${LOCK_NAME_PREFIX}gh-${n}.lock" ] && continue`) | **Gap (stale prompt rule)** | Prompt refers to a beads-memory mechanism that does not exist. Actual concurrency primitive is the filesystem lock at `${LOCK_DIR}/${LOCK_NAME_PREFIX}gh-${n}.lock` — see "Concurrency safety" section starting at developer.md:91. Predicate skips on the lock, prompt should be reworded. **Filed as follow-up.** |
| `templates/developer.md:830-851` (Safety Net) | Apply `${BLOCKED_HUMAN_LABEL}` to the GH issue when tripping a safety-net rule | `eligibility_dev_count` and `eligibility_dev_candidates` (`select((.labels // [] \| map(.name)) \| index($blocked) \| not)` in each severity pipeline) | Mirrored | GH#28 — predicate's blocked-label filter drops labelled issues |
| `templates/developer.md:91-143` (Concurrency safety) | Filesystem lock — if `mkdir` succeeds, this agent owns the issue | `eligibility_dev_count` and `eligibility_dev_candidates` (`[ -d "${LOCK_DIR}/${LOCK_NAME_PREFIX}gh-${n}.lock" ] && continue`) | Mirrored | Predicate is advisory; agent's atomic mkdir is the actual claim |

### Mode 2 (developer.md): follow up on an existing PR

| Prompt rule (file:line) | Rule summary | Predicate (function + snippet) | Category | Notes |
|---|---|---|---|---|
| `templates/developer.md:425` | `[reviewer-agent: clean]` or `[reviewer-agent: nits]` → exit `result=follow-up-no-action` | `eligibility_followup_pr` (`if ($verdict == "clean" or $verdict == "nits") then "\($verdict)\tno"`) | Mirrored | The clean/nits branch short-circuits regardless of comment timestamps |
| `templates/developer.md:426` | `comment` (P1) or `changes` (P0) → dispatch | `eligibility_followup_pr` (`elif ($latest_devcomment == null or $latest_review.submittedAt > $latest_devcomment.createdAt) then "\($verdict)\tyes"`) | Mirrored | Dispatches iff review's submittedAt is newer than latest dev-agent comment's createdAt |
| `templates/developer.md:427` | No marker found → exit cleanly | `eligibility_followup_pr` (`if $latest_review == null then "none\tno"`) | Mirrored | `$latest_review` is null when no review body matches `$REVIEWER_AGENT_VERDICT_REGEX` |
| `templates/developer.md:429-461` (F2) | After 3 follow-up cycles → give up, mark PR draft? **No** — only marks beads parent blocked + `bd human` | (none) | **Gap** | Predicate has no per-PR follow-up-cycle counter. After give-up, the wrapper still fires Mode 2 every cycle; the LLM re-counts beads memories, re-trips the cap, and exits — token leak (~$0.20-$0.50 per cycle). Mode 3's give-up paths *do* draft the PR (developer.md:660-663, 701-703, 748-752), so they get the `-is:draft` filter for free. Mode 2's give-up does not. **Filed as follow-up.** |
| `templates/developer.md:585`, `templates/developer.md:815` | Mode 3 — abort on a conflict in test/CI/secrets/core files | `runners/run-conflict-triage.sh` (separate gate) | Defense-in-depth | Triage script is the gate of record (it's a separate strict-mode gate, not an `eligibility.sh` predicate). Mode 3 abort paths additionally draft the PR so the next-cycle conflicts dispatcher's `isDraft == false` filter excludes it |
| `templates/developer.md:631`, `templates/developer.md:585` | Mode 3 — abort if conflict ≤ `${TRIAGE_LINE_LIMIT}` budget exceeded | `runners/run-conflict-triage.sh` | Defense-in-depth | Triage script enforces the line-count cap before the LLM is spawned |

### Reviewer orchestrator (reviewer-orchestrator.md)

| Prompt rule (file:line) | Rule summary | Predicate (function + snippet) | Category | Notes |
|---|---|---|---|---|
| `templates/reviewer-orchestrator.md:24-33` | Fast eligibility gate — `bash $LOOP_HOME/runners/lib/eligibility.sh review`; exit on rc=1 | `eligibility_review_pending` (whole function) | Defense-in-depth | Prompt explicitly says "the call here protects against direct `claude -p` invocations" |
| `templates/reviewer-orchestrator.md:49` | Eligible PR has `headRefName` starting with `${BRANCH_PREFIX}/` **OR** body contains `${DEV_AGENT_PR_BODY_TAG}` | `eligibility_review_pending` (`--search "head:${BRANCH_PREFIX}/ -is:draft"`) | **Gap** | Predicate uses `--search "head:${BRANCH_PREFIX}/ -is:draft"` only; the body-tag fallback is missing. False-negative window: PRs with the body tag but a non-prefix branch are silently un-reviewed. **Filed as follow-up.** |
| `templates/reviewer-orchestrator.md:50` | `isDraft == false` | `eligibility_review_pending` (`-is:draft` clause in `--search`) | Mirrored | The orchestrator-side filter is enforced via the `gh pr list --search` qualifier |
| `templates/reviewer-orchestrator.md:51` | CI must be finished (no `IN_PROGRESS` / `PENDING` / `QUEUED` checks) | `eligibility_review_pending` (`statusCheckRollup` in `--json` field set + `($check_states \| index("IN_PROGRESS") \| not)` etc. in jq filter) | Defense-in-depth | GH#46 — predicate's `statusCheckRollup` filter and the prompt's defense-in-depth call-out are the model example for this pattern |
| `templates/reviewer-orchestrator.md:52-58` | A review covers the current head iff its `submittedAt` is newer than the head commit's `committedDate` AND its body contains the `[reviewer-agent: …]` marker | `eligibility_review_pending` (per-oid GraphQL `committedDate` lookup → `$head_date == null or ($review_dates \| map(select(. != null and . > $head_date)) \| length == 0)`, where `$review_dates` is restricted to bodies matching `$REVIEWER_AGENT_VERDICT_REGEX`) | Mirrored | GH#26 — predicate resolves head's `committedDate` via per-oid GraphQL and applies the `submittedAt > head_date` filter, restricted to bodies matching `$REVIEWER_AGENT_VERDICT_REGEX` |
| `templates/reviewer-orchestrator.md:59-61` | "No human PR comments or reviews postdate that agent review" — re-dispatch on human input | (none) | **Gap** | Predicate has no human-postdates check. A human comment landing after a clean reviewer-agent review at the current head is silently swallowed: the wrapper short-circuits, the orchestrator never runs, the human's input is never folded in. **Filed as follow-up.** |
| (no prompt rule) | Skip PRs carrying `${REVIEWER_ESCALATION_LABEL}` (set by the wrapper after `REVIEWER_SUB_AGENT_FAILURE_CAP` consecutive sub-agent failures) | `eligibility.sh` (default-if-unset of `REVIEWER_ESCALATION_LABEL` constant), `eligibility_review_pending` (`labels` in `--json` field set + `select(($label_names \| index($escalation_label)) \| not)` in jq filter) | Mirrored | GH#94. The label itself is wrapper-applied; the prompts don't refer to it (no skip rule needed in the LLM since the predicate eliminates the PR before dispatch) |

### Reviewer sub-agent (reviewer.md)

| Prompt rule (file:line) | Rule summary | Predicate (function + snippet) | Category | Notes |
|---|---|---|---|---|
| `templates/reviewer.md:32-41` (Sanity check) | Verify PR is open + non-draft, branch matches prefix or body tag, CI done, headRefOid not already reviewed | `eligibility_review_pending` (whole function) | Defense-in-depth | Prompt's sanity check duplicates the orchestrator's filter — defense-in-depth for malformed kickoff or mid-flight PR state changes |
| `templates/reviewer.md:274` | Never review the same `headRefOid` twice | `eligibility_review_pending` (per-oid GraphQL `committedDate` lookup → `submittedAt > $head_date` filter; same pipeline as the orchestrator's "review covers head" row above) | Mirrored | Predicate's review-covers-head logic surfaces only un-reviewed heads |
| `templates/reviewer.md:275` | Never review draft PRs | `eligibility_review_pending` (`-is:draft` clause in `--search`) | Mirrored | Same `-is:draft` search clause as the orchestrator's `isDraft == false` row |
| `templates/reviewer.md:276` | Never review PRs from non-`${BRANCH_PREFIX}/*` branches (or PRs without the body tag) | `eligibility_review_pending` (`head:${BRANCH_PREFIX}/` clause in `--search`) | **Gap (same as orchestrator G2)** | Same body-tag fallback gap. Sub-agent only runs on PRs the orchestrator already filtered, so the gap surfaces upstream |

### Merger dispatcher (no template — wrapper-only)

The merger has no LLM template — it is implemented entirely in
`eligibility_merge_pr` (in `runners/lib/eligibility.sh`) and the
dispatcher's shell logic. There are no prompt skip-rules to mirror. The merger's
gate (`MERGER_VERDICTS_ALLOWED`, review-covers-head, no human comment
or review postdates the agent review, `mergeable=MERGEABLE` AND
`mergeStateStatus=CLEAN`) is the gate of record by construction.

## Gaps surfaced

Each gap is filed as a separate follow-up GitHub issue:

- **G1** (`templates/reviewer-orchestrator.md:59-61`) — predicate
  `eligibility_review_pending` does not honor the "human postdates
  agent review" override. Filed as GH#132.
- **G2** (`templates/reviewer-orchestrator.md:49`,
  `templates/reviewer.md:276`) — predicate filters strictly on
  `head:${BRANCH_PREFIX}/`; body-tag fallback (`DEV_AGENT_PR_BODY_TAG`)
  is missing. Filed as GH#133.
- **G3** (`templates/developer.md:429-461`) — Mode 2's 3-cycle give-up
  has no predicate-level guard, and unlike Mode 3's give-up paths it
  does not draft the PR. Filed as GH#134.
- **G4** (`templates/developer.md:85`) — stale prompt rule references
  a "beads memory tag `developer-agent:claimed:<issue#>`" mechanism
  that does not exist. Actual concurrency primitive is the filesystem
  lock at `${LOCK_DIR}/${LOCK_NAME_PREFIX}gh-${n}.lock`. Filed as
  GH#135 (documentation cleanup).

## How to keep this in sync

When adding a new skip-rule:

- If it's enforceable from `gh`/`jq` output, add a predicate to
  `eligibility.sh` and add a row here marked **mirrored** or
  **defense-in-depth**. If you keep a mirrored copy in the prompt,
  add an explicit "see `eligibility_X` (GH#…)" comment so future
  readers know it's defense-in-depth (template
  `templates/reviewer-orchestrator.md:51` is the model).
- If it's not enforceable from a wrapper-side query (e.g., it requires
  reading the PR diff or a beads-memory walk), document it here as a
  **gap** with a brief note on the symptom and the cost of leaving it
  LLM-only. Open a follow-up issue if the cost justifies the work.

### Anchor convention (predicate column)

The predicate column anchors by **function name + load-bearing
snippet**, never by line number. Line numbers in `eligibility.sh`
drift on every unrelated edit, so any line-anchored row would silently
rot the moment someone adds a comment block above the function. The
snippet (a literal `select(...)`, `--search "..."`, `gh api graphql`
fragment, or short jq pipeline) is grep-able and stable across
unrelated edits. The only line numbers in this doc are prompt-side
(`file:line` references into `templates/*.md`); those columns are
stable enough to be useful and can be re-verified with one grep.

When updating a row: if you change a predicate's filter, update the
row's snippet in lockstep. If you only renumber lines (e.g. add a
comment block, refactor unrelated code), no edit needed here.

## References

- `runners/lib/eligibility.sh` — the 5 predicate functions audited.
- Historical context: GH#1, GH#7, GH#8, GH#14, GH#28, GH#46, GH#56,
  GH#65, GH#94, GH#113 — each moved one or more gates into a predicate.
- GH#114 (this audit).
