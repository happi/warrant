# Change Ledger — Workflow

## Task Lifecycle

Every code change begins with a task. A task moves through these states:

```
open → in_progress → in_review → done
```

With two special states:
- `blocked` — reachable from `open`, `in_progress`, or `in_review`; returns to the previous forward state
- `cancelled` — terminal, reachable from any non-terminal state

### State Semantics

| Status        | Meaning                                         |
|---------------|--------------------------------------------------|
| `open`        | Task exists, no one is working on it             |
| `in_progress` | Someone (human or agent) is actively working     |
| `in_review`   | Code is written, PR is open, awaiting review     |
| `done`        | PR merged, change is in the main branch          |
| `blocked`     | Cannot proceed (dependency, question, external)  |
| `cancelled`   | Abandoned — intent no longer applies             |

---

## Developer Flow

### 1. Create Task

Before writing code, create a task via the API:

```bash
curl -X POST https://ledger.example.com/api/v1/orgs/acme/projects/backend/tasks \
  -H "Authorization: Bearer $TOKEN" \
  -d '{"title": "Fix auth token refresh", "intent": "Tokens expire silently, causing 401s for long sessions"}'
```

Response includes the allocated ID: `BE-47`.

### 2. Create Branch

Use the task ID in the branch name:

```bash
git checkout -b task/BE-47-fix-token-refresh
```

Link the branch:

```bash
curl -X POST .../tasks/BE-47/links \
  -d '{"kind": "branch", "ref": "task/BE-47-fix-token-refresh"}'
```

### 3. Transition to In Progress

```bash
curl -X POST .../tasks/BE-47/status \
  -d '{"status": "in_progress", "expected_status": "open"}'
```

### 4. Commit with Task ID

Every commit message must reference the task:

```
BE-47: Fix token refresh logic

Tokens now refresh 5 minutes before expiry instead of
waiting for a 401 response.
```

Link commits as they're created (or batch via CI):

```bash
curl -X POST .../tasks/BE-47/links \
  -d '{"kind": "commit", "ref": "abc123"}'
```

### 5. Open PR

PR title or body must include the task ID:

```
BE-47: Fix auth token refresh

## Intent
Tokens expire silently, causing 401s for long sessions.

## Changes
- Added proactive refresh 5min before expiry
- Added refresh failure retry with backoff
```

Link the PR:

```bash
curl -X POST .../tasks/BE-47/links \
  -d '{"kind": "pr", "ref": "47", "url": "https://github.com/acme/backend/pull/47"}'
```

### 6. Transition to In Review

```bash
curl -X POST .../tasks/BE-47/status \
  -d '{"status": "in_review", "expected_status": "in_progress"}'
```

### 7. Merge and Complete

After PR is merged:

```bash
curl -X POST .../tasks/BE-47/status \
  -d '{"status": "done", "expected_status": "in_review"}'
```

---

## Agent Flow

Automated agents (CI bots, AI coding agents) follow the same flow with one addition: **leasing**.

### 1. Find Available Work

```bash
curl .../tasks?status=open&label=bug
```

### 2. Acquire Lease

Before starting work, the agent claims the task:

```bash
curl -X POST .../tasks/BE-47/lease \
  -d '{"owner": "agent-4", "ttl_seconds": 3600}'
```

The lease prevents other agents from working on the same task. It has a TTL — if the agent crashes, the lease expires and the task becomes available again.

### 3. Do Work

The agent creates a branch, makes commits, opens a PR — same as a developer. All with task ID references.

### 4. Release Lease

When done (or blocked):

```bash
curl -X DELETE .../tasks/BE-47/lease \
  -d '{"owner": "agent-4"}'
```

### 5. Renew Lease

For long-running work, renew before expiry:

```bash
curl -X POST .../tasks/BE-47/lease \
  -d '{"owner": "agent-4", "ttl_seconds": 3600}'
```

Same owner → lease is renewed, not rejected.

---

## Conventions

### Branch Naming

```
task/<TASK-ID>-<short-description>
```

Examples:
- `task/SF-42-add-oauth`
- `task/BE-47-fix-token-refresh`

### Commit Messages

```
<TASK-ID>: <summary>

<optional body>
```

The task ID must appear in the first line. This enables automated linking.

### PR Template

```markdown
<TASK-ID>: <title>

## Intent
<Why does this change exist? Copy from task intent.>

## Changes
<What was done.>
```

### Code Annotations (optional)

For non-obvious code, reference the task:

```python
# TASK: BE-47 — Proactive refresh needed because the OAuth
# provider doesn't send refresh-before-expiry hints.
```

This is a breadcrumb, not a replacement for the task system.
