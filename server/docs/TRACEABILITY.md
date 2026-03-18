# Change Ledger — Traceability

## The Traceability Chain

Every line of code in the system should be traceable back to an intent:

```
code change ← commit ← branch ← PR ← task ← intent
```

The Change Ledger stores the right side of this chain (task + intent) and the links between Git artifacts and tasks.

## How It Works

### Forward Trace (task → code)

Starting from a task ID:

```
Task SF-42: "Add OAuth authentication"
  Intent: "Users need Google OAuth to access the dashboard"
  │
  ├── Branch: task/SF-42-add-oauth
  ├── Commits:
  │     abc123 — "SF-42: Add OAuth flow"
  │     def456 — "SF-42: Add token refresh"
  │     ghi789 — "SF-42: Fix redirect URI"
  ├── PR: #17 — "SF-42: Add OAuth authentication"
  └── Status: done (via open → in_progress → in_review → done)
```

**API**: `GET /api/v1/orgs/:org/projects/:proj/tasks/SF-42/trace`

### Reverse Trace (code → task)

Starting from a commit:

1. Read the commit message: `"SF-42: Add OAuth flow"`
2. Extract task ID: `SF-42`
3. Query: `GET .../tasks/SF-42/trace`
4. Get the full picture: intent, all related commits, PR, status history

This answers: **"Why does this code exist?"**

### Audit Trace (who, when, why)

Starting from a task ID, the audit log shows:

```
2026-03-18T10:00:00Z  erik        task.created    {title: "Add OAuth..."}
2026-03-18T10:05:00Z  erik        task.status     {from: "open", to: "in_progress"}
2026-03-18T10:06:00Z  erik        link.added      {kind: "branch", ref: "task/SF-42-add-oauth"}
2026-03-18T14:30:00Z  erik        link.added      {kind: "commit", ref: "abc123"}
2026-03-18T15:00:00Z  erik        task.status     {from: "in_progress", to: "in_review"}
2026-03-18T15:01:00Z  erik        link.added      {kind: "pr", ref: "17"}
2026-03-18T16:00:00Z  reviewer    task.status     {from: "in_review", to: "done"}
```

**API**: `GET .../audit?task_id=SF-42`

## Conventions That Enable Traceability

### Mandatory

1. **Every commit message includes a task ID** — `SF-42: description`
2. **Every branch includes a task ID** — `task/SF-42-description`
3. **Every PR references a task ID** — in title or body

### Enforced By

| Convention       | Enforcement Mechanism            |
|-----------------|----------------------------------|
| Commit message  | Pre-commit hook or CI check      |
| Branch naming   | CI check on PR                   |
| PR reference    | PR template + CI check           |
| Link recording  | CI step posts to Change Ledger   |

### Optional

4. **Code annotations** — `# TASK: SF-42 — rationale` for non-obvious code
5. **Intent in PR body** — copy from task intent field

## What Traceability Answers

| Question                              | How to answer                        |
|---------------------------------------|--------------------------------------|
| Why does this code exist?             | Commit → task ID → task intent       |
| What changed for task X?              | Task → linked commits, PR            |
| Who authorized this change?           | Task → created_by + audit trail      |
| When was this task completed?         | Audit log → `task.status` to `done`  |
| What's blocking this task?            | Task → status `blocked` + audit note |
| Did an agent or human do this?        | Task → assigned_to, lease history    |
| What's the full history of task X?    | Audit events for task X              |

## Traceability Without the Service

Even if the Change Ledger is down, the conventions (branch naming, commit messages) still provide traceability. The task ID is embedded in Git history — `git log --grep="SF-42"` always works.

The service adds:
- Intent (the "why")
- Status tracking
- Audit history
- Unified view across branches, commits, and PRs

## Example: Full Trace Query

```bash
# "Why was this line changed?"
git blame src/auth.erl
# → commit abc123, message "SF-42: Add OAuth flow"

# "What was SF-42 about?"
curl .../tasks/SF-42/trace
# → intent, all commits, PR, full audit history
```
