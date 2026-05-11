# Agent Instructions

This project uses **bd** (beads) for issue tracking. Run `bd prime` for full workflow context.

## What is loop?

This repo is the loop framework itself — a multi-agent dev-loop where dev / reviewer / conflict-triage / issue-author agents drive PRs in consumer repos. When you edit `runners/`, `templates/`, or `bin/st` here, you are changing the behavior of every consumer repo's next agent run. Loop also dogfoods itself via `.loop/loop.config`.

CLI entry point: `bin/st` — run `st help` for the current subcommand list (`st dev`, `st review`, `st triage`, `st issue`, `st loop`, `st onboard`, `st init`, `st version`). Don't enumerate subcommands in docs; `st help` is the source of truth.

## Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work atomically
bd close <id>         # Complete work
bd dolt push          # Push beads data to remote
```

## Non-Interactive Shell Commands

This guidance is for **LLM-issued shell calls** — i.e. commands a Claude agent runs via the Bash tool inside a sietch wrapper. The wrappers themselves run `\unalias -a 2>/dev/null || true` near the top of every script, so the framework's own shell calls are protected. Any shell call you (the agent) issue at runtime needs the same care.

`cp`, `mv`, and `rm` are aliased to `-i` on many systems. Headless agents block forever on the y/n prompt. Always pass `-f`:

```bash
cp -f src dst        # not: cp src dst
mv -f src dst        # not: mv src dst
rm -f file           # not: rm file
rm -rf dir           # not: rm -r dir
cp -rf src dst       # not: cp -r src dst
```

Other interactive commands to harden:
- `scp` / `ssh` — `-o BatchMode=yes`
- `apt-get` — `-y`
- `brew` — `HOMEBREW_NO_AUTO_UPDATE=1`

## Test tiers

The bats suite is split into two tiers via the `regression` file-tag:

- **Untagged (PR-blocking, live behavior)** — eligibility, dispatchers, wrappers, locks, event log, merger, etc. Runs on every push and pull request.
- **`regression` (nightly pins)** — one-shot guards over template, registry, and parity-doc text. They exist to catch a specific past regression and rarely fire usefully on day-to-day feature work; during a major refactor they all break together. Runs nightly on `main` and on manual `workflow_dispatch`, not on PRs.

Tag a whole file by adding `# bats file_tags=regression` immediately under the shebang. Do **not** tag individual `@test` blocks; whole-file tagging is the supported granularity here.

Local runs:

```bash
bats --filter-tags '!regression' tests/   # what PR CI runs
bats --filter-tags regression tests/      # what the nightly job runs
bats tests/                               # everything (no filter)
```

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:ca08a54f -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   bd dolt push
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
