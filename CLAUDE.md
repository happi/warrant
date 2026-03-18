# CLAUDE.md — Warrant

## What This Is

Warrant is a system of record for why code changed. Monorepo with three components:

- `server/` — Erlang/OTP service (ID allocation, status CAS, leases, hash ledger)
- `client/` — CLI tools, git hooks, CI integration (bash)
- `vscode/` — VS Code extension (TypeScript)

## Branch

`main`

## Rules

- **No Co-Authored-By lines in commits.** Do not add `Co-Authored-By: Claude` or any AI attribution to commit messages.
- All commit messages must start with a task ID: `W-1: description`
- Task files live in `backlog/tasks/` — use the CLI or edit directly
- Task prefix: `W`

## Build

```bash
# Server
cd server && rebar3 compile

# VS Code extension
cd vscode && npm install && npm run compile

# Client — no build step (bash scripts)
```

## Backlog

Tasks tracked in `backlog/tasks/` as markdown files with YAML frontmatter.
ID server: `http://backlog.lan.stenmans.org` (prefix: `w`)
