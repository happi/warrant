# Change Ledger — Roadmap

## v1 — Shipped

The minimum viable system for change traceability.

### Slice 1: Task Registry
- [x] SQLite storage layer (`ledger_db`)
- [x] Create task (POST, allocates ID via existing `backlog_id_srv`)
- [x] Get task (GET, with links and lease)
- [x] List tasks (GET, with filters: status, assigned_to, label)
- [x] Update task status (POST, with `expected_status` guard)
- [x] Update task fields (PATCH)
- [x] Task status state machine validation

### Slice 2: Multi-Tenancy + Auth
- [x] Organization CRUD
- [x] Project CRUD (with prefix, linked to ID counter)
- [x] User creation with API token
- [x] Bearer token authentication middleware
- [x] Tenant scoping on all queries
- [x] Role-based access (admin creates orgs/projects/users; developer does task work)
- [x] Google OAuth login for web UI

### Slice 3: Artifact Links
- [x] Add link to task (branch, commit, PR)
- [x] List links for task
- [x] Trace endpoint (task + links + audit assembled)
- [x] Unique constraint on (task_id, kind, ref)

### Slice 4: Leasing
- [x] Acquire lease (with TTL)
- [x] Release lease (owner-only)
- [x] Renew lease (same owner)
- [x] Lease expiration reaper (periodic gen_server)
- [x] Conflict on double-lease

### Slice 5: Audit Log
- [x] Append audit event on every mutation
- [x] List audit events (with filters: task_id, time range)
- [x] Include audit in trace endpoint

### Slice 6: Legacy Compatibility
- [x] Preserve `/api/id/*` endpoints unchanged
- [x] No auth required on legacy endpoints
- [x] Legacy counters kept in sync with new project prefixes

### Slice 7: Compliance Hash Chain
- [x] Append-only hash chain for commit notarization
- [x] Verify chain integrity endpoint
- [x] CLI `record` and `verify` commands
- [x] Post-push hook records protected branch commits

### Slice 8: Web UI
- [x] Server-rendered dashboard (home, login, admin)
- [x] Kanban board view per project
- [x] Task detail and trace pages
- [x] Cookie-based auth with token login

### Slice 9: GitHub Integration
- [x] Webhook receiver for PR and push events
- [x] GitHub Actions workflow for PR task-ID checks
- [x] Warrant-based release notes in CI

---

## v2 — Nice to Have

Features that improve the system but aren't required for v1.

- **Task file projection** — Generate `tasks/TASK-42.md` files from service state, push to repo
- **Git scanner CLI** — Parse branch names and commit messages, auto-link to tasks
- **Task search** — Full-text search across title, intent, labels
- **Bulk operations** — Create/update multiple tasks in one request
- **Token scoping** — Per-project tokens (currently tokens are org-wide)
- **Metrics endpoint** — Prometheus-compatible `/metrics` for task counts, lease utilization
- **Task dependencies** — `blocked_by` field linking tasks

---

## Explicitly Out of Scope

These will not be built:

- **Sprint planning** — No sprints, no velocity, no story points
- **Time tracking** — No estimates, no actuals
- **Full code indexing** — We link to commits, not parse ASTs
- **Notification routing** — No email, Slack, or PagerDuty integration
- **Multi-region / HA** — Single instance, SQLite, NFS backup
- **GraphQL** — REST only
