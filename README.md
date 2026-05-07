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
