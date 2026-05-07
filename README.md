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
~/code/loop/                    ← framework (this repo)
├── bin/st                      ← global CLI dispatcher
├── templates/                  ← parameterized prompt templates
│   ├── developer.md
│   ├── reviewer.md
│   ├── reviewer-orchestrator.md
│   ├── issue-author.md
│   └── loop.config.example     ← template for `st init`
├── lib/render-prompt.sh        ← envsubst-based template renderer
├── lib/eligibility.sh          ← shell-side eligibility predicates
├── wrappers/                   ← headless agent wrappers (run-*.sh)
└── install.sh                  ← symlinks CLI into ~/.local/bin

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
st init                         # creates .loop/loop.config + README
$EDITOR .loop/loop.config       # set REPO_OWNER, REPO_NAME, branch prefix, etc.
git add .loop && git commit -m "loop: onboard this repo"
```

## Daily use

```bash
st issue "tests should cover negative inputs"   # draft → confirm → file
st dev                                          # claim & ship one issue
st review                                       # review one dev-agent PR
st loop start                                   # all of the above in tmux
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
