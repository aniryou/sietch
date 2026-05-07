# Sietch

A multi-agent dev loop for Claude Code. Inspired by Steve Yegge's
[GasTown](https://github.com/steveyegge/gastown), built on top of
[beads](https://github.com/steveyegge/beads), and named after the Fremen
community concept from Dune — a self-contained group where every agent
has a role and pulls weight in hostile terrain.

## What it does

Given a GitHub repo with open issues labeled by severity, Sietch runs four
headless Claude Code agents in coordinated loops:

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
~/code/sietch/                  ← framework (this repo)
├── bin/sietch                  ← global CLI dispatcher
├── templates/                   ← parameterized prompt templates
│   ├── developer.md
│   ├── reviewer.md
│   ├── reviewer-orchestrator.md
│   ├── issue-author.md
│   └── rig.config.example      ← template for `st init`
├── lib/render-prompt.sh        ← envsubst-based template renderer
├── wrappers/                   ← headless agent wrappers (run-*.sh)
└── install.sh                  ← symlinks CLI into ~/.local/bin

<consumer-repo>/.sietch/        ← per-rig config, the only thing in-repo
└── rig.config                  ← REPO_OWNER, branch prefix, labels, etc.
```

The framework lives once. Every consumer repo carries a single config
file. Edit a prompt in `templates/` and every rig picks it up immediately.

## Install

```bash
git clone git@github.com:aniryou/sietch.git ~/code/sietch
~/code/sietch/install.sh        # symlinks ~/.local/bin/sietch
```

Make sure `~/.local/bin` is on your `$PATH`.

## Onboard a repo

```bash
cd path/to/your-repo
st init                      # creates .sietch/rig.config + README
$EDITOR .sietch/rig.config       # set REPO_OWNER, REPO_NAME, branch prefix, etc.
git add .sietch && git commit -m "sietch: onboard this repo"
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
- `jq`, `tmux`, `git` ≥ 2.30 (worktree support), `bash` ≥ 4 (or 3.2 — wrappers
  are macOS-compatible)
- `envsubst` (gettext) — required for prompt rendering. macOS: `brew install
  gettext && brew link --force gettext`. Debian: `apt-get install gettext-base`.

## Tests

Bats suite covering render-prompt, triage-conflict, and the eligibility
predicates. CI runs them on push to main and on PR.

```bash
bats tests/                     # macOS: brew install bats-core
                                # Debian: apt-get install bats
```

## Status

Early. Single-rig tested. Multi-rig untested. No `sietch update` to
auto-pull framework changes — you `git pull` this repo manually.
