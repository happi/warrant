# Change Ledger — Roadmap

## v1 — Must Ship

The minimum viable system for change traceability.

### Slice 1: Task Registry
- [ ] SQLite storage layer (`ledger_db`)
- [ ] Create task (POST, allocates ID via existing `backlog_id_srv`)
- [ ] Get task (GET, with links and lease)
- [ ] List tasks (GET, with filters: status, assigned_to, label)
- [ ] Update task status (POST, with `expected_status` guard)
- [ ] Update task fields (PATCH)
- [ ] Task status state machine validation

### Slice 2: Multi-Tenancy + Auth
- [ ] Organization CRUD
- [ ] Project CRUD (with prefix, linked to ID counter)
- [ ] User creation with API token
- [ ] Bearer token authentication middleware
- [ ] Tenant scoping on all queries
- [ ] Role-based access (admin creates orgs/projects/users; developer does task work)

### Slice 3: Artifact Links
- [ ] Add link to task (branch, commit, PR)
- [ ] List links for task
- [ ] Trace endpoint (task + links + audit assembled)
- [ ] Unique constraint on (task_id, kind, ref)

### Slice 4: Leasing
- [ ] Acquire lease (with TTL)
- [ ] Release lease (owner-only)
- [ ] Renew lease (same owner)
- [ ] Lease expiration reaper (periodic gen_server)
- [ ] Conflict on double-lease

### Slice 5: Audit Log
- [ ] Append audit event on every mutation
- [ ] List audit events (with filters: task_id, time range)
- [ ] Include audit in trace endpoint

### Slice 6: Legacy Compatibility
- [ ] Preserve `/api/id/*` endpoints unchanged
- [ ] No auth required on legacy endpoints
- [ ] Legacy counters kept in sync with new project prefixes

---

## v2 — Nice to Have

Features that improve the system but aren't required for v1.

- **Task file projection** — Generate `tasks/TASK-42.md` files from service state, push to repo
- **Webhook notifications** — POST to configured URL on task state changes
- **Git scanner CLI** — Parse branch names and commit messages, auto-link to tasks
- **CI integration** — GitHub Actions / GitLab CI steps that enforce conventions and post links
- **Task search** — Full-text search across title, intent, labels
- **Bulk operations** — Create/update multiple tasks in one request
- **Token scoping** — Per-project tokens (currently tokens are org-wide)
- **Metrics endpoint** — Prometheus-compatible `/metrics` for task counts, lease utilization
- **Task dependencies** — `blocked_by` field linking tasks

---

## Explicitly Out of Scope

These will not be built:

- **UI / Dashboard** — API-only; clients build their own views
- **Sprint planning** — No sprints, no velocity, no story points
- **Time tracking** — No estimates, no actuals
- **Kanban boards** — No drag-and-drop, no swimlanes
- **Full code indexing** — We link to commits, not parse ASTs
- **Notification routing** — No email, Slack, or PagerDuty integration
- **Multi-region / HA** — Single instance, SQLite, NFS backup
- **GraphQL** — REST only
- **OAuth / SAML provider** — Simple token auth, not an identity provider
