# Loop

A multi-agent dev loop for Claude Code, built on top of
[beads](https://github.com/steveyegge/beads).

![loop](docs/loop.jpeg)

## Why "loop"?

Agentic engineering, as framed in Steve Yegge and Gene Kim's
*Vibe Coding*, runs on three loops. The **inner loop** — write, run,
debug a well-defined feature — is now fully automated by the dev
agent. The **outer loop** — product direction and prioritization —
stays a human responsibility. In between sits the **middle loop**:
define ↔ implement ↔ test ↔ review, the back-and-forth between a
junior and a senior engineer. That's what this framework automates,
targeting ~95% of cases and leaving the genuinely complex ~5% to
humans. Hence the name.

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

## Install

```bash
git clone git@github.com:aniryou/loop.git ~/code/loop
~/code/loop/install.sh          # symlinks ~/.local/bin/st
```

Make sure `~/.local/bin` is on your `$PATH`.

`install.sh` also wires up a local pre-commit hook (shellcheck + shfmt,
matching the CI lint steps) when [`pre-commit`](https://pre-commit.com)
is on `$PATH` and no custom hook is already installed. If pre-commit is
missing it skips with a one-line note — install it manually with
`pip install pre-commit && pre-commit install` to enable lint checks at
commit time.

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

## Multi-repo

Two onboarded repos can run their own `st loop start` fleets on the
same machine without collisions:

- The tmux session name is per-repo (`agent-loop-<owner>-<name>`), so
  `tmux ls` lists each fleet under its own target. `st loop status` /
  `attach` / `stop` resolve the session for the current `$PWD`.
- The default `WORKTREE_BASE` interpolates `${REPO_OWNER}-${REPO_NAME}`,
  so `st init`'d repos get distinct lock and worktree paths out of the
  box (`/tmp/dev-agent/<owner>-<name>/...`).
- Lock filenames carry a `LOCK_NAME_PREFIX` (defaults to `${REPO_NAME}-`)
  as defence-in-depth: even if two repos are deliberately pointed at a
  shared `WORKTREE_BASE`, claim/dispatch locks remain disambiguated by
  filename.
- `st onboard` runs `check_worktree_base_unique`, which drops a
  `.loop-owner` marker the first time a repo claims a `WORKTREE_BASE`
  and fails loudly if another repo later tries to share it.

Concretely, run `st loop start` in repo A, then in repo B (separate
shells); `tmux ls` shows two distinct sessions and `st loop stop` in
either repo only tears down that repo's fleet.

## Status

Early. No `st sync` yet to auto-pull framework changes — you `git pull`
this repo manually.
