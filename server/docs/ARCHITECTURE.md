# Change Ledger — Architecture

## Service Structure

The Change Ledger is a single Erlang/OTP application (`backlog_server`) running on Cowboy. It evolves from an existing ID counter service into a multi-tenant task registry with artifact linking.

```
┌─────────────────────────────────────────────────┐
│                   Cowboy HTTP                     │
│  /api/v1/orgs/:org/projects/:proj/tasks/...      │
│  /api/v1/orgs/:org/projects/:proj/tasks/:id/...  │
│  /api/id/next  (legacy, preserved)               │
│  /health                                         │
└─────────────┬───────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────┐
│              Handler Layer                       │
│  ledger_task_handler    — task CRUD + status     │
│  ledger_lease_handler   — lease acquire/release  │
│  ledger_link_handler    — artifact links         │
│  backlog_id_handler     — legacy ID counter      │
└─────────────┬───────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────┐
│              Service Layer                       │
│  ledger_task_srv   — task state machine          │
│  ledger_audit_srv  — append-only event log       │
│  backlog_id_srv    — ID counter (existing)       │
└─────────────┬───────────────────────────────────┘
              │
┌─────────────▼───────────────────────────────────┐
│              Storage Layer                       │
│  ledger_db         — SQLite via esqlite          │
│  counters.json     — legacy ID persistence       │
└─────────────────────────────────────────────────┘
```

## Key Design Decisions

### SQLite for Storage

The existing system persists counters to a JSON file. For the expanded data model (tasks, leases, links, audit events), we use SQLite:

- Single-file database, no external service dependency
- ACID transactions for state consistency
- Sufficient for the expected scale (thousands of tasks, not millions)
- Erlang binding via `esqlite` (NIF-based)

The legacy `counters.json` mechanism is preserved for backward compatibility. New task ID allocation flows through the same `backlog_id_srv` gen_server, which also writes to the task table.

### Multi-Tenancy Model

All data is scoped by `org_id` and `project_id`. These are path parameters in the API, not headers or tokens. Every query includes tenant scope in its WHERE clause.

There is no shared data between organizations. Project IDs are unique within an org. Task IDs are unique within a project (enforced by the ID counter).

### API Versioning

New endpoints live under `/api/v1/`. Legacy endpoints (`/api/id/*`, `/api/backlog/*`) are preserved at their current paths for backward compatibility.

### State Machine for Tasks

Task status transitions are controlled. A status change request must include the `expected_status` field — the status the caller believes the task is currently in. If the actual status doesn't match, the request fails with 409 Conflict. This prevents lost updates and race conditions.

## How Git + Tasks Interact

The Change Ledger does not interact with Git directly. Instead, it relies on conventions enforced by developers and CI:

1. **Branch naming**: `task/TASK-42-description` — the task ID is embedded in the branch name
2. **Commit messages**: Must include `TASK-42` — CI or pre-commit hooks enforce this
3. **PR body**: Must reference `TASK-42` and include intent

The system stores these links as artifact records:

```
Task TASK-42
  ├── branch: task/TASK-42-add-auth
  ├── commit: abc123 "TASK-42: Add OAuth flow"
  ├── commit: def456 "TASK-42: Add token refresh"
  └── pr: #17 "TASK-42: Add authentication"
```

A trace scanner (CLI tool or CI step) can POST these links to the API as they're created. The Change Ledger stores them and provides a unified view.

## How Traceability Is Achieved

Given a commit hash, the trace is:

```
commit abc123
  → contains "TASK-42" in message
    → task TASK-42: "Add OAuth authentication"
      → intent: "Users need to log in via Google OAuth"
      → status: done
      → linked PR: #17
      → linked commits: [abc123, def456]
      → linked branch: task/TASK-42-add-auth
      → audit: created by erik, status changes, lease history
```

Given a task ID, the trace is the reverse — from intent to all implementing artifacts.

## Supervision Tree

```
backlog_sup (one_for_one)
├── backlog_srv          — legacy CLI-based task ops (existing)
├── backlog_id_srv       — ID counter gen_server (existing)
├── ledger_db            — SQLite connection manager
├── ledger_task_srv      — task operations
├── ledger_audit_srv     — audit event writer
└── ledger_lease_reaper  — periodic expired lease cleanup
```
