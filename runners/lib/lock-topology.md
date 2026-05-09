# Lock Topology

Audit (GH#115) of every `mkdir`-style atomic lock the loop fleet uses to
serialize work. Each row pins where the lock is acquired, where it is released,
and why parallel acquirers cannot race for the same resource. When you add a
new dispatcher, parallel agent, or change a lock-name format, update this file
in the same commit so future readers can verify completeness.

The patterns are well-established and worth re-stating once at the top:

- **`mkdir <dir>` is the atomic primitive.** Exactly one caller succeeds;
  everyone else gets `EEXIST`. No flock, no lockfile, no fcntl — just
  filesystem semantics. Every lock here is a directory whose existence is
  the lock and whose contents (`run_id`, `pid`, `started`) carry metadata
  for GC and observability.
- **Lock-name prefix `${LOCK_NAME_PREFIX}` is repo-disambiguation
  defense-in-depth (GH#74).** Defaults to `${REPO_NAME}-` (e.g. `loop-`).
  Two repos pointed at a misconfigured shared `LOCK_DIR` /
  `DISPATCH_LOCK_DIR` cannot false-positive on the same issue or PR
  number. Every glob inside a lock dir is `${LOCK_NAME_PREFIX}*` so a
  shared dir is iterated repo-locally.
- **Lock dirs are disjoint by mode.** `$LOCK_DIR`
  (`${WORKTREE_BASE}/locks`) holds Mode-1 issue locks; `$DISPATCH_LOCK_DIR`
  (`${WORKTREE_BASE}/dispatched`) holds Mode-2/Mode-3 dispatcher locks.
  They never share filenames, so a Mode-1 GC policy cannot accidentally
  collect a Mode-2 lock or vice versa.

## Lock map

| # | Mode / role                  | Lock layer    | Lock dir                | Lock name format                                      | Acquired (`file:line`)                          | Released (`file:line`)                                                                   | Parallel-race analysis                                                                                                                              |
|---|------------------------------|---------------|-------------------------|-------------------------------------------------------|-------------------------------------------------|-------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | Mode 1 dev-agent (claim)     | wrapper       | `$LOCK_DIR`             | `${LOCK_NAME_PREFIX}gh-N.lock`                        | `runners/run-developer.sh:257` (`mkdir`)        | `runners/run-developer.sh:198-206` (cleanup trap, matches `run_id`)                       | N parallel `dev-K` panes can race. Wrapper iterates `eligibility_dev_candidates` ids in ascending order and the first successful `mkdir` wins; siblings exit `result=lock-race-loss-pre-LLM` (rc=2) before spawning `claude`. Pre-fix the LLM did discovery+lock, costing $0.20–$0.50 per losing race (GH#31). |
| 1a | Mode 1 dev-agent (defense)  | LLM (template)| `$LOCK_DIR`             | `${LOCK_NAME_PREFIX}gh-N.lock`                        | `templates/developer.md:97-130` (`mkdir`)       | wrapper trap (same as row 1) — LLM owns the lock for the rest of the cycle when this path runs | Defense-in-depth for direct `claude -p` invocations bypassing the wrapper. With `DEV_AGENT_TARGET_ISSUE` set the LLM follows the "wrapper pre-lock shortcut" (`templates/developer.md:55-95`) and skips this snippet entirely. |
| 2 | Mode 2 dev-agent (followup)  | dispatcher    | `$DISPATCH_LOCK_DIR`    | `${LOCK_NAME_PREFIX}pr-N-followup.lock`               | `runners/run-loop.sh:261` (`mkdir`)             | `runners/run-loop.sh:71-93` (`cleanup_stale_dispatch_locks`, `kill -0` GC) + `runners/run-loop.sh:694-704` (session stop) | Single `dispatch:followup` tmux pane per repo (`runners/run-loop.sh:639,651`); no parallel dispatcher exists. The `mkdir` is defense-in-depth against re-entry within the same pane (a wrapper still running from the previous cycle). Lock is released by PID-based GC on the next cycle once the wrapper exits. |
| 3 | Mode 3 dev-agent (conflicts) | dispatcher    | `$DISPATCH_LOCK_DIR`    | `${LOCK_NAME_PREFIX}pr-N-conflicts.lock`              | `runners/run-loop.sh:404` (`mkdir`)             | `runners/run-loop.sh:71-93` (`cleanup_stale_dispatch_locks`) + `runners/run-loop.sh:694-704` (session stop) | Single `dispatch:conflicts` tmux pane per repo (`runners/run-loop.sh:641,653`). Same shape as row 2. PR-N-followup and PR-N-conflicts are disjoint lock names so the same PR may carry both lock dirs simultaneously without collision. |
| 4 | Conflict triage              | _none (sub-step of row 3)_ | _N/A_      | _N/A_                                                 | _no own lock_                                   | trap-cleanup of triage worktree (`runners/run-conflict-triage.sh:52-58`)                  | `run-conflict-triage.sh` runs only as a pre-flight inside the Mode-3 wrapper (`runners/run-developer.sh:317`); serialization is inherited from the dispatcher-side `pr-N-conflicts.lock` (row 3). The triage worktree path `${WORKTREE_BASE}/triage-pr${PR}` cannot collide because two parallel triage runs for the same PR are excluded upstream. |
| 5 | Reviewer orchestrator        | _none (single tmux pane)_ | _N/A_       | _N/A_                                                 | _no lock_                                       | _N/A_                                                                                     | One `reviewer` pane per repo (`runners/run-loop.sh:639,651`). The orchestrator is single-pass per cycle and dispatches one sub-agent per cycle, so concurrent invocations are impossible from the loop. Manual `st review` runs alongside the loop could double-fire — duplicate reviews would land on the PR but cause no state corruption (each `gh pr review` is independent). |

## GC mechanisms

Three release paths exist; coverage differs by lock dir.

| Lock dir              | Trap-on-EXIT | Timer-based GC          | PID-liveness GC                   | Fires on `SIGKILL`? |
|-----------------------|--------------|-------------------------|-----------------------------------|---------------------|
| `$LOCK_DIR` (row 1)   | yes (wrapper trap, `runners/run-developer.sh:198-206` and `:230`) — released when `lock/run_id` matches `$DEV_AGENT_RUN_ID` | **none** — `$STALE_LOCK_HOURS` is declared in `loop.config` but is read only by the developer template (LLM-side advisory text); no shell GC honours it | none | **no** — `SIGKILL` bypasses traps |
| `$DISPATCH_LOCK_DIR` (rows 2, 3) | session stop only (`runners/run-loop.sh:694-704`) | **none** — same situation as `$LOCK_DIR` | yes — `cleanup_stale_dispatch_locks` runs `kill -0 $(cat lock/pid)` each dispatcher cycle (`runners/run-loop.sh:71-93`) | yes — PID GC catches it on the next cycle |

## Cross-mode interactions

- **Lock dirs are disjoint by mode.** `$LOCK_DIR` (default
  `${WORKTREE_BASE}/locks`) and `$DISPATCH_LOCK_DIR` (default
  `${WORKTREE_BASE}/dispatched`) never overlap, so Mode 1's `gh-N.lock`
  cannot be confused with Mode 2/3's `pr-N-{followup,conflicts}.lock` even
  if both globs were applied to the same dir by accident. The
  `${LOCK_NAME_PREFIX}` prefix (GH#74) provides a second layer of
  isolation when two repos share a `WORKTREE_BASE`.
- **Mode 2 and Mode 3 share `$DISPATCH_LOCK_DIR`** but use distinct lock
  names (`pr-N-followup.lock` vs `pr-N-conflicts.lock`), so the same PR
  may legitimately carry both lock dirs simultaneously. Both dispatchers
  share `count_active_dispatch_locks` and the `DISPATCH_MAX_CONCURRENT`
  budget (`runners/run-loop.sh:101-111`), which is intentional —
  dispatch fan-out is the limiting resource, not per-mode parallelism.
- **TOCTOU window between dispatcher `mkdir` and child PID write** is
  closed by writing the dispatcher's PID into `lock/pid` _before_
  spawning the child (`runners/run-loop.sh:262, 405`), then overwriting
  it with the child PID after `&` (`runners/run-loop.sh:267, 410`). The
  intermediate dispatcher PID is always alive, so the `kill -0` GC never
  collects an in-flight lock.

## Known gap (filed as follow-up)

`$LOCK_DIR` has **no timer-based GC and no PID-liveness GC** — only the
EXIT/INT/TERM trap in `runners/run-developer.sh:198-206`. A `SIGKILL`
(or hard crash that bypasses the trap) leaks a `gh-N.lock` indefinitely,
and the eligibility predicate (`runners/lib/eligibility.sh:148, 256`)
treats the leaked lock as a live claim, blocking that issue from any
future Mode-1 cycle until a human runs `rm -rf` manually. The wrapper
pre-lock shortcut (`templates/developer.md:55-95`) means the LLM no
longer scans `$LOCK_DIR` for the GC sweep that the template's
"Stale locks" paragraph (`templates/developer.md:141`) describes.
`cleanup_stale_dispatch_locks` (`runners/run-loop.sh:71-93`) provides
the equivalent sweep for `$DISPATCH_LOCK_DIR`; the symmetric
`cleanup_stale_dev_locks` for `$LOCK_DIR` is the suggested fix.

Filed as GH#139.
