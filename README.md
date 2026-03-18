# Warrant

**A system of record for why code changed.**

*Every change needs one.*

---

Every commit traces to a task. Every task declares intent. Every change is explainable.

```
code line
  ← commit "ZIN-42: Fix token refresh"
    ← branch task/ZIN-42-fix-token-refresh
      ← PR #17
        ← Task ZIN-42: "Fix auth token refresh"
          ← Intent: "Users get 401 errors on sessions longer than 1 hour"
          ← Decision: "Retry with backoff — simpler than token refresh, covers more failure modes"
```

## The Problem

Without Warrant:
- Commits drift from intent
- PRs lack context
- Tickets go stale in Jira
- Audits become archaeology

With Warrant:
- Every line maps to intent
- Every change is explainable
- Audits are queries, not investigations

Designed for systems where you must explain every change — fintech, healthcare, regulated environments, and teams running AI coding agents.

## How It Works

Task files live in your git repo as markdown with frontmatter. Git history is the audit trail. The Warrant server only handles what requires centralized coordination: ID allocation, status transitions (compare-and-swap), agent leases, and a hash ledger for compliance verification.

```
Your repo (source of truth)         Warrant server (serialization only)
┌─────────────────────────┐         ┌──────────────────────────┐
│ backlog/tasks/ZIN-42.md │         │ ID counter (monotonic)   │
│ backlog/tasks/ZIN-43.md │         │ Status CAS (race guard)  │
│ backlog/config.yml      │         │ Lease registry (TTL)     │
│ .git/ (audit trail)     │────────▶│ Hash ledger (notary)     │
└─────────────────────────┘  commit └──────────────────────────┘
                              hash
```

**Conventions are simple:**
- Branch: `task/ZIN-42-fix-token-refresh`
- Commit: `ZIN-42: Fix token refresh logic`
- PR body: references `ZIN-42` with intent

**The server enforces:**
- Unique, monotonic task IDs per project (no collisions)
- Status transitions with compare-and-swap (no race conditions)
- Leases with TTL for agent coordination (crashed agents don't block work)
- Append-only hash chain for compliance verification

## Three Layers of Why

Each task captures three things:

| Layer | Question | Example |
|-------|----------|---------|
| **Intent** | Why does this task exist? | "Users get 401 errors on sessions longer than 1 hour" |
| **Decision** | Why this approach? | "Retry with backoff — simpler, covers more failure modes" |
| **Audit** | Who did what, when? | Git history on the task file — every change traceable |

Intent and decision live in the task file. Audit lives in git.

## Trace Is the Product

Everything resolves to a trace. One query answers "why does this code exist, who did it, and what was the reasoning."

```bash
warrant trace ZIN-42
# → task + intent + decision + branches + commits + PRs + git log
```

## Agent Coordination

Multiple agents (AI coding agents, CI bots, humans) coordinate through Warrant without direct communication:

1. **Find work** — read open tasks from repo files
2. **Claim it** — acquire a lease (atomic, TTL-based, 409 on conflict)
3. **Do the work** — branch, commit, CAS the status transition
4. **Hand off** — update task file, push, release lease

If an agent crashes, its lease expires automatically. No stuck tasks.

## Project Structure

```
warrant/
├── server/          Erlang/OTP service (ID, CAS, leases, hash ledger)
├── client/          CLI tools, git hooks, CI integration
├── vscode/          VS Code extension
├── backlog/         Warrant's own task tracking (dogfooding)
└── README.md
```

### Server (`server/`)

Erlang/OTP + Cowboy + SQLite. Four endpoints:

| Endpoint | Purpose |
|----------|---------|
| `POST /api/id/next` | Allocate monotonic task ID |
| `POST /api/cas/status` | Compare-and-swap status transition |
| `POST /api/leases/acquire` | Atomic lease with TTL |
| `POST /api/ledger/record` | Append to compliance hash chain |

### Client (`client/`)

Bash CLI + git hooks:

```bash
warrant task create "Fix login bug" --intent "Users can't log in"
warrant task start ZIN-42
warrant link commit ZIN-42 $(git rev-parse HEAD)
warrant trace ZIN-42
warrant lease acquire ZIN-42 agent-4 3600
```

### VS Code Extension (`vscode/`)

- Inline blame annotations with task IDs per line
- Hover tooltips with task title, intent, and linked PRs
- Sidebar with current task and browsable task list
- Commands for status transitions and task creation
- Trace webview with full history

## Quick Start

```bash
# 1. Clone and set up
git clone https://github.com/happi/warrant.git
cp client/.env.example client/.env
# Edit client/.env with your server URL and token

# 2. Install git hooks
client/bin/install-hooks

# 3. Create your first task
client/bin/warrant task create "My first task" --intent "Testing Warrant"

# 4. Start working
client/bin/warrant task start W-1
git checkout -b task/W-1-my-first-task
# ... code ...
git commit -m "W-1: Implement the thing"
client/bin/warrant link commit W-1 $(git rev-parse HEAD)
client/bin/warrant task done W-1
```

## Auth

- Bearer tokens for API access (agents, CI, scripts)
- Google OAuth for human login (configurable per org)
- Multi-tenant: organizations, projects, users
- Superadmin orgs can create and manage other organizations

## Not a Project Management Tool

No sprints. No story points. No velocity. No Kanban boards. No estimation. No planning.

Warrant tracks one thing: **why code changed**. Every feature exists to improve traceability or control. Nothing else ships.

You can start using it in 10 minutes without changing your process.

## Documentation

- [SYSTEM.md](server/docs/SYSTEM.md) — what the system is and its principles
- [ARCHITECTURE.md](server/docs/ARCHITECTURE.md) — service structure and design decisions
- [DATA_MODEL.md](server/docs/DATA_MODEL.md) — entities, fields, relationships
- [API.md](server/docs/API.md) — complete API reference
- [WORKFLOW.md](server/docs/WORKFLOW.md) — task lifecycle, developer and agent flows
- [TRACEABILITY.md](server/docs/TRACEABILITY.md) — how task-to-code mapping works
- [SETUP.md](client/SETUP.md) — project setup guide

## License

MIT
