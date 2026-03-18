# Warrant

**Every change needs a warrant.**

If you cannot answer *why* a line of code exists, the system has lost memory.
Warrant restores that link.

---

## Try it (60 seconds)

```bash
# 1. Create a task
mkdir -p .warrant/tasks
cat > .warrant/tasks/ZIN-42.md << 'EOF'
---
id: ZIN-42
title: Fix token refresh
status: open
priority: high
labels: [bug, auth]
---

## Intent

Users get 401 errors after sessions longer than 1 hour.

## Decision

Retry with exponential backoff — simpler than token refresh, covers more failure modes.
EOF

# 2. Branch
git checkout -b task/ZIN-42-fix-token-refresh

# 3. Commit
git commit -m "ZIN-42: fix token refresh logic"

# 4. Trace
warrant trace ZIN-42
```

Output:

```
ZIN-42: Fix token refresh
  Intent:   Users get 401 errors after sessions longer than 1 hour
  Decision: Retry with exponential backoff — simpler than refresh, covers more failure modes
  Status:   done

  Branch:  task/ZIN-42-fix-token-refresh
  Commits:
    abc1234  ZIN-42: fix token refresh logic
    def5678  ZIN-42: add retry backoff tests
  PR:      #17

  Audit:
    2026-03-18 10:00  erik     created
    2026-03-18 10:05  erik     open → in_progress
    2026-03-18 14:30  erik     in_progress → in_review
    2026-03-18 16:00  reviewer in_review → done
```

Every commit traces to a task. Every task declares intent. Every change is explainable.

---

## The Rule

**Every change must have a warrant.**

A warrant is:
- A **task ID** — unique, traceable
- An **intent** — why this change exists
- A **trace** to code changes — branches, commits, PRs

Code without a warrant is a guess that happened to compile.

---

## What is Warrant?

Warrant is a **model**:

1. Link code to intent
2. Store intent in the repo
3. Make the trace reconstructable

### This repository

This repo contains:
- A **CLI** for creating tasks, tracing changes, and coordinating agents
- **Conventions** for branches, commits, and task files
- A **reference server** for ID allocation, concurrency control, and compliance

You don't need all of it. The model works with just task files and commit conventions.

---

## Task files live in your repo

```
.warrant/
  tasks/
    ZIN-42.md          # Every task: frontmatter + intent + decision
    ZIN-43.md
  decisions/           # Architecture decisions (optional)
  policies/            # Team policies (optional)
```

A real task file:

```markdown
---
id: ZIN-42
title: Fix token refresh
status: done
priority: high
labels: [bug, auth]
created_by: erik
created_at: 2026-03-18T10:00:00Z
---

## Intent

Users get 401 errors after sessions longer than 1 hour.

## Decision

Retry with exponential backoff — simpler than token refresh,
covers more failure modes.

## Notes

Considered refresh-before-expiry but that requires tracking token
lifetime per provider. Backoff is stateless and handles network
failures too.
```

Git history on this file *is* the audit trail. No external database needed.

---

## Three layers of why

| Layer | Question | Where it lives |
|-------|----------|---------------|
| **Intent** | Why does this task exist? | Task file |
| **Decision** | Why this approach, not another? | Task file |
| **Audit** | Who did what, when? | Git history |

---

## The server is optional

It does not store project data.

It can:
- **Allocate IDs** — monotonic, no collisions across agents
- **Guard status transitions** — compare-and-swap prevents race conditions
- **Coordinate agents** — leases with TTL (crashed agents don't block work)
- **Notarize commits** — append-only hash chain for compliance verification

The repository remains the source of truth. Always.

---

## Example: fixing a production bug

**1. Create the warrant**

```markdown
# .warrant/tasks/ZIN-42.md
---
id: ZIN-42
title: Fix token refresh
status: open
priority: high
---

## Intent

Users get 401 errors after sessions longer than 1 hour.

## Decision

Retry with exponential backoff — simpler than refresh, covers more failure modes.
```

**2. Branch and work**

```bash
git checkout -b task/ZIN-42-fix-token-refresh
# ... fix the bug ...
git commit -m "ZIN-42: add retry with exponential backoff"
git commit -m "ZIN-42: add backoff tests"
```

**3. Open PR**

```
ZIN-42: Fix token refresh

Intent: Users get 401 errors after sessions longer than 1 hour
Decision: Retry with backoff instead of token refresh — simpler, covers more failure modes
```

**4. Six months later, someone reads the code**

```bash
git blame src/auth.erl
# → commit abc1234, message "ZIN-42: add retry with exponential backoff"

warrant trace ZIN-42
# → intent, decision, all commits, PR, full history
```

The system remembers why.

---

## Agent coordination

Multiple agents (AI coding agents, CI bots, humans) coordinate through warrants:

1. **Find work** — read open tasks from repo
2. **Claim it** — acquire a lease (atomic, TTL-based, 409 on conflict)
3. **Do the work** — branch, commit, update task status
4. **Hand off** — push, release lease

If an agent crashes, its lease expires. No stuck tasks. No direct communication needed.

---

## The problem this solves

Without warrants:
- Commits drift from intent
- PRs lack context
- Tickets go stale in Jira
- Audits become archaeology

With warrants:
- Every line maps to intent
- Every change is explainable
- Audits are queries, not investigations

Designed for systems where you must explain every change — fintech, healthcare, regulated environments, and teams running AI coding agents.

---

## Project structure

```
warrant/
├── client/          CLI tools, git hooks, CI integration
├── server/          Erlang/OTP (optional — ID, CAS, leases, hash chain)
├── vscode/          VS Code extension
└── backlog/         Warrant's own task tracking (dogfooding)
```

See [server/docs/](server/docs/) for architecture, API reference, and data model.

## License

MIT
