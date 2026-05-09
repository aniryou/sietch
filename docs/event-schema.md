# Loop event schema

This document is the contract between the loop's runners and any external
"control tower" tool that wants to monitor the loop without scraping pane
output. It corresponds to the events emitted by `runners/lib/event_log.sh`.

## File layout

Every event is a single line of NDJSON appended to:

```
${LOOP_EVENT_LOG:-/tmp/loop-events-${SESSION:-default}.jsonl}
```

`SESSION` is the per-repo tmux session name (`agent-loop-<owner>-<name>`),
exported by `runners/run-loop.sh` so child wrappers and dispatchers write to
the same file. Set `LOOP_EVENT_LOG=/dev/null` to silence event emission with
no other behaviour change.

A single `printf` write per event keeps the append atomic for writes ≤ 4 KiB
(POSIX `PIPE_BUF`). The file is append-only; no truncation, rotation, or
size cap lives in the loop — that's the tower's responsibility.

## Required fields (every event)

| field            | type   | description                                                    |
|------------------|--------|----------------------------------------------------------------|
| `ts`             | string | ISO-8601 timestamp (`date -Iseconds`).                         |
| `session`        | string | Per-repo session identifier; `default` when unset.             |
| `repo`           | string | `${REPO_OWNER}/${REPO_NAME}` from `.loop/loop.config`.         |
| `role`           | string | Pane / wrapper identity (`dev-1`, `reviewer`, `dispatch:review`, `dispatch:followup`, …). The `dispatch:review` pane uses the `reviewer` role on its wrapper invocations and `dispatch:review` on dispatcher-shell events. |
| `event`          | string | One of the names listed below.                                 |
| `schema_version` | number | Currently `1`. Bump only when an event's required fields change. |

Extra fields are documented per-event below. Numeric-looking values become
JSON numbers; everything else is a JSON string. Field names are
caller-defined; consumers should treat unknown extras as forward-compatible.

## Events

### Loop lifecycle (emitted by `runners/run-loop.sh`)

| event         | role(s)        | extra fields                                                  | when |
|---------------|----------------|---------------------------------------------------------------|------|
| `cycle_start` | all loops      | `cycle_id`                                                    | top of every per-role iteration |
| `cycle_end`   | all loops      | `cycle_id`, `exit_code`, `duration_s`, `dispatched` (dispatcher loops only) | after the wrapper / inner work returns 0 or non-zero (non-2); for dispatcher loops `exit_code` is always `0` and `dispatched` is the count of `dispatch_fired` events emitted this cycle |
| `cycle_skip`  | all loops      | `cycle_id`, `reason`, `streak`, `sleep_s`                     | after the wrapper returns 2 (no-work / predicate failed) or, for dispatcher loops, after a cycle that fired zero dispatches; `streak` is the consecutive-empty count (always `0` for `dispatch:followup` which has no backoff), `sleep_s` is the next backoff |

`cycle_id` is `${PID}-${counter}` so the tower can pair start/end/skip events
even when several panes interleave their output. Every per-role iteration
emits exactly one `cycle_start` and exactly one of `cycle_end` / `cycle_skip`,
so tower consumers can assume the file grows on every cycle of every pane.

### Wrapper eligibility (emitted by `run-developer.sh` and `run-reviewer.sh`)

| event         | role(s)             | extra fields                                | when |
|---------------|---------------------|---------------------------------------------|------|
| `eligibility` | `dev`, `reviewer`   | `result`, `count` (when `proceeding`)       | after the eligibility predicate runs |

`result` is one of:

- `proceeding` — the predicate found work; `count` is the candidate count.
- `no-work` — the predicate found no eligible work this cycle.
- `predicate-failed` — `gh` / `jq` failed transiently; the wrapper backs off.

### Lock acquisition (Mode 1, `run-developer.sh`)

| event             | role  | extra fields           | when |
|-------------------|-------|------------------------|------|
| `lock_acquired`   | `dev` | `issue`, `run_id`      | after the wrapper wins the per-issue mkdir lock |
| `lock_race_lost`  | `dev` | `run_id`               | after every candidate was already locked by a sibling wrapper |

### Mode 3 conflict triage (`run-developer.sh`)

| event           | role  | extra fields              | when |
|-----------------|-------|---------------------------|------|
| `triage_result` | `dev` | `pr`, `result`, `reason`  | after `runners/run-conflict-triage.sh` returns; `result` is `tractable` / `untractable` / `failed` |

### LLM invocation (emitted by both wrappers)

| event         | role(s)            | extra fields                                                    | when |
|---------------|--------------------|-----------------------------------------------------------------|------|
| `llm_started` | `dev`, `reviewer`  | `mode`, `pr` or `issue`, `run_id`                               | just before the `claude` pipeline starts |
| `llm_exited`  | `dev`, `reviewer`  | `mode`, `pr` or `issue`, `exit_code`, `duration_s`              | after `wait $PIPELINE_PID` returns |

`mode` is `default` / `follow-up` / `resolve-conflicts` for the dev wrapper
and `default` for the reviewer wrapper. Either `pr` (Mode 2/3 / reviewer) or
`issue` (Mode 1) is set per role.

### Hard failures (post-LLM fallback paths)

| event          | role               | extra fields                                                 | when |
|----------------|--------------------|--------------------------------------------------------------|------|
| `hard_failure` | `dev`, `reviewer`  | `mode`, `pr` or `issue`, `exit_code`, `retry_count` (Mode 1) | when a wrapper-level fallback fires after a non-zero LLM exit (Mode 1 retry counter, Mode 2 stub follow-up comment, Mode 3 hard-fail draft, reviewer sub-agent stub review) |

### Dispatcher lifecycle (emitted by `run-loop.sh`)

| event              | role(s)                                                  | extra fields                                | when |
|--------------------|----------------------------------------------------------|---------------------------------------------|------|
| `dispatch_fired`   | `dispatch:review`, `dispatch:followup`, `dispatch:conflicts`, `merger` | `pr`, `kind`, `verdict` (when present)      | when the dispatcher actually fires the underlying action (background dev-agent run for follow-up/conflicts, background reviewer run for review, server-side merge for merger) |
| `dispatch_skip`    | `dispatch:review`, `dispatch:followup`, `dispatch:conflicts`, `merger` | `pr`, `kind`, `reason` or `verdict`         | when an eligible PR is skipped (already-locked, gh-merge-failed, predicate skip) |
| `dispatch_at_cap`  | `dispatch:review`, `dispatch:followup`, `dispatch:conflicts`           | `kind`, `active`, `cap`                     | when the concurrency cap is reached and remaining eligible PRs are deferred to the next cycle. `dispatch:review` uses an independent `REVIEWER_DISPATCH_MAX_CONCURRENT` cap (GH#117); the other two share `DISPATCH_MAX_CONCURRENT` |

`kind` is `review` / `followup` / `conflicts` / `merge` and disambiguates
events when they all share a role-style name.

## Versioning

`schema_version` is currently `1`. The contract: any change that adds an
optional field is non-breaking; any rename, removal, or required-field
change bumps the version. Consumers should refuse events with a
`schema_version` they don't understand and surface the mismatch.
