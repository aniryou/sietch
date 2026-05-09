## Loop integration (multi-agent dev-loop framework)

This repo is a [Loop](https://github.com/aniryou/loop) consumer. The framework
code itself lives outside this repo (typically `~/code/loop/`); only the
per-repo configuration in `.loop/loop.config` lives here. Loop drives a
multi-agent dev-loop — a developer agent claims open issues and opens PRs,
a reviewer agent reviews them, and a tmux orchestrator runs both in parallel.

### Commands

Run from anywhere inside this repo:

- `st dev` — scan issues, claim one, drive a PR end-to-end.
- `st dev follow-up <PR>` — address reviewer-agent feedback on an existing PR.
- `st dev resolve <PR>` — auto-resolve a triage-gated merge conflict.
- `st review <PR>` — review a specific open dev-agent PR.
- `st loop start` — run the full multi-agent fleet under tmux.
- `st help` — full command list.

### Coordinating with the dev agent

The dev agent owns branches under `${BRANCH_PREFIX}/*`. Do **not** push,
rebase, or amend commits on those branches by hand while a run is in flight —
the dev agent will force-push during conflict resolution and will overwrite
unsynchronised local work.

Per-issue claim locks live under `${LOCK_DIR}`. Treat that directory as
agent-owned: do not delete or edit lock dirs there. Stale locks
(older than `${STALE_LOCK_HOURS}` hours) are recovered automatically.

### Tunables

`.loop/loop.config` carries every per-repo override: severity labels, branch
prefix, dispatch caps, retry counts, the project test command, etc. Defaults
are documented inline. Edit values there, not in the framework checkout.
