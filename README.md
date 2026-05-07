# Loop

A multi-agent dev loop for Claude Code, built on top of
[beads](https://github.com/steveyegge/beads).

## What it does

Given a GitHub repo with open issues labeled by severity, Loop runs four
headless Claude Code agents in coordinated cycles:

- **Issue author** (interactive) — turns rough requests into precise,
  file:line-cited GitHub issues.
- **Developer agent** — scans issues, claims one with a filesystem lock,
  drives it through TDD → PR → green CI in an isolated git worktree.
- **Reviewer orchestrator** + **per-PR reviewer sub-agent** — picks an
  eligible dev-agent PR, dispatches an isolated sub-agent to review.
  Posts a structured P0/P1/P2 review with a machine-parseable verdict.
- **Dispatchers** — watch for new reviewer feedback and merge conflicts,
  re-invoke the developer agent in follow-up or conflict-resolution mode.

A single `st loop start` brings them all up in tmux panes.

## Architecture

```
~/code/loop/                       ← framework (this repo)
├── bin/st                         ← global CLI dispatcher
├── templates/                     ← parameterized prompt templates
│   ├── developer.md
│   ├── reviewer.md
│   ├── reviewer-orchestrator.md
│   ├── issue-author.md
│   └── loop.config.example        ← template for `st init`
├── runners/                       ← headless agent runners (run-*.sh)
│   └── lib/                       ← shared shell helpers
│       ├── render-prompt.sh       ← envsubst-based template renderer
│       └── eligibility.sh         ← shell-side eligibility predicates
└── install.sh                     ← symlinks CLI into ~/.local/bin

<consumer-repo>/.loop/          ← per-repo config, the only thing in-repo
└── loop.config                 ← REPO_OWNER, branch prefix, labels, etc.
```

The framework lives once. Every consumer repo carries a single config
file. Edit a prompt in `templates/` and every consumer repo picks it up
immediately.

### Agent fleet (tmux layout)

`st loop start` brings up six headless agents in a single tmux session
(see `runners/run-loop.sh`):

```
┌────────────┬─────────────────────┬──────────────────────┐
│ reviewer   │ dispatch:followup   │ dispatch:conflicts   │
├────────────┼──────────┬──────────┴──────────────────────┤
│ dev-1      │ dev-2    │ dev-3 (number = --dev-instances)│
└────────────┴──────────┴─────────────────────────────────┘
```

Issue-author is **not** in the loop — it's interactive (`st issue`) and
runs in a separate terminal.

### Dev-agent modes

The developer agent runs in one of three single-pass modes, dispatched
differently (see `runners/run-developer.sh`):

| Mode | Triggered by | What it does |
|---|---|---|
| **Mode 1 — claim** | `dev-N` panes (default invocation) | Scans `severity:high\|medium` GitHub issues, claims one with a filesystem lock, drives it through TDD → PR → green CI. |
| **Mode 2 — follow-up** | `dispatch:followup` pane | On a PR with new reviewer-agent feedback, addresses every P0/P1 finding (fix or explicit decline), pushes a follow-up commit. Caps at 3 cycles. |
| **Mode 3 — resolve-conflicts** | `dispatch:conflicts` pane | On a PR flagged by the conflict-triage gate as tractable, rebases onto `main`, resolves mechanical conflicts, force-pushes with a lease. Auto-reverts the remote on test or CI failure. |

### Coordination & isolation

Multiple `dev-N` workers and the dispatchers run as the same `gh`
identity, so concurrency control is filesystem-based, not GitHub-based.

- **Claim locks** (`$LOCK_DIR`, default `$WORKTREE_BASE/locks`) — one
  dir per claimed issue, e.g. `gh-42.lock/`. The wrapper `mkdir`s it
  atomically before spawning the LLM (`runners/run-developer.sh`),
  closing the TOCTOU window where two agents would both spawn `claude`
  on the same issue and one would burn ~$0.20-$0.50 losing the race.
- **Dispatch locks** (`$DISPATCH_LOCK_DIR`, default
  `$WORKTREE_BASE/dispatched`) — one dir per `(PR, mode)` pair, e.g.
  `pr-42-followup.lock/`. The dispatchers in `runners/run-loop.sh`
  acquire these so a follow-up or conflict resolution for a given PR
  can't fan out twice. A shared `DISPATCH_MAX_CONCURRENT` cap bounds
  total in-flight dispatched work.
- **Eligibility preflight** — every wrapper sources
  `runners/lib/eligibility.sh` and runs a shell-only predicate before
  invoking `claude`. Empty cycles exit `2`, which `run-loop.sh`
  translates into exponential backoff with jitter — this is the
  load-bearing token-cost decision that keeps an idle fleet
  effectively free. The agents call the same predicate on entry so the
  wrapper preflight and the in-prompt re-check stay in sync.
- **Worktrees** (`$WORKTREE_BASE`, default `/tmp/dev-agent/`) — every
  dev cycle works in `$WORKTREE_BASE/gh-<num>/` on a deterministic
  branch, never inside the user's primary working tree. The wrapper
  cleans up successful runs (`KEEP_ON_FAIL=0` to clean up failures
  too); deterministic paths mean retries reuse the same branch so the
  existing PR picks up new commits automatically.

Stale claim locks (older than `STALE_LOCK_HOURS`, default 6h) are
reaped on the next eligibility scan — only `SIGKILL` of a wrapper can
leave a lock behind, since the trap on `EXIT/INT/TERM` releases the
locks tagged with this run's `DEV_AGENT_RUN_ID`.

### Conflict triage gate

Before `dispatch:conflicts` fans out a Mode 3 dev-agent on a
conflicting PR, it runs `runners/run-conflict-triage.sh` in a
throwaway worktree. Triage probes the rebase against `main` and
returns **tractable** (exit 0) or **untractable** (exit 1). A conflict
is untractable — and the PR sits waiting for a human — if **any** of:

- the conflict touches a test file (`tests/`, `test_*.py`, `*_test.py`),
- it touches CI / secrets / `.github/` / `.env`,
- it touches one of the core code files (`eval.py`, `Dockerfile`,
  `.pre-commit-config.yaml`),
- combined `ours + theirs` conflict-line count exceeds
  `TRIAGE_LINE_LIMIT` (default 10).

This gate is what stops Mode 3 from "winning" a merge by silently
combining changes whose intent it can't reason about.

## Install

```bash
git clone git@github.com:aniryou/loop.git ~/code/loop
~/code/loop/install.sh          # symlinks ~/.local/bin/st
```

Make sure `~/.local/bin` is on your `$PATH`.

## Onboard a repo

```bash
cd path/to/your-repo
st init                         # creates .loop/loop.config + README; appends a LOOP block to CLAUDE.md
$EDITOR .loop/loop.config       # set REPO_OWNER, REPO_NAME, branch prefix, etc.
st onboard                      # audit prerequisites; auto-create canonical labels on the GitHub repo
git add .loop CLAUDE.md && git commit -m "loop: onboard this repo"
```

`st onboard` runs nine checks. All are read-only **except** `check_labels`,
which creates any missing canonical labels on `$REPO_SLUG` (it never
modifies labels that already exist).

| Check | Verifies |
|---|---|
| `check_loop_config` | `.loop/loop.config` exists and isn't holding placeholder values |
| `check_beads` | `.beads/` directory exists in the repo |
| `check_gh_auth` | `gh` CLI is authenticated |
| `check_labels` | severity + type labels exist on the GitHub repo (auto-creates missing) |
| `check_pre_commit_config` | `.pre-commit-config.yaml` exists at the repo root |
| `check_pre_commit_hook` | `.git/hooks/pre-commit` is installed (not the stock sample) |
| `check_workflows` | first file under `.github/workflows/` triggers on `pull_request` |
| `check_test_dir` | `tests/` or `test/` exists with at least one file |
| `check_worktree_base` | `WORKTREE_BASE` (default `/tmp/dev-agent`) is writable |

Each check prints `✓` or `✗ <why>` plus a copy-pasteable `fix:` line on
failure. Exit code is non-zero iff any check fails.

```bash
st onboard                      # run all checks
st onboard -v                   # also print the path each check inspected
st onboard check_gh_auth        # run a single check
```

## Daily use

```bash
st issue "tests should cover negative inputs"   # draft → confirm → file
st loop start                                   # bring up the multi-agent fleet in tmux
st loop start --enable-merger                   # also auto-merge clean/nits PRs
st loop status                                  # check what's running
st loop stop                                    # tear it down
```

## Dependencies

- `claude` (Claude Code CLI) on `$PATH`
- `gh` authenticated to the consumer repo
- `bd` (beads) for task tracking inside agents
- `jq`, `tmux`, `git` ≥ 2.30 (worktree support), `bash` ≥ 4 (or 3.2 —
  wrappers are macOS-compatible)
- `envsubst` (gettext) — required for prompt rendering. macOS: `brew
  install gettext && brew link --force gettext`. Debian: `apt-get install
  gettext-base`.

## Tests

Bats suite covering `render-prompt`, `triage-conflict`, and the
eligibility predicates. CI runs them on push to main and on PR.

```bash
bats tests/                     # macOS: brew install bats-core
                                # Debian: apt-get install bats
```

## Status

Early. Single-repo tested. Multi-repo untested. No `st sync` yet to
auto-pull framework changes — you `git pull` this repo manually.
