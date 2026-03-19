# AI Agent Integration

How AI coding agents work with warrants.

## The problem

AI agents generate code. They can produce correct code without understanding why the code exists. Six months later, no one can explain the change because the agent's chat session is gone.

Warrants solve this by requiring every change to reference an intent source. The agent reads the intent before coding. The warrant records what happened after merging. The explanation survives.

## How agents use warrants

### 1. Read intent before coding

The agent reads task files from the repo:

```
.warrant/tasks/PRJ-42.md
---
id: PRJ-42
title: Fix token refresh
status: open
priority: high
---

## Intent

Users get 401 errors after sessions longer than 1 hour.

## Decision

Retry with exponential backoff.
```

This gives the agent structured context: what to do and why. The intent section explains the problem. The decision section (if present) constrains the approach.

### 2. Reference the task in every commit

The commit-msg hook enforces this automatically:

```bash
git commit -m "PRJ-42: add retry with exponential backoff"
```

If the agent commits without a task ID, the hook rejects the commit. The agent does not need to remember the convention. The hook enforces it.

### 3. Coordinate with leases

When multiple agents work on the same backlog, leases prevent conflicts:

```bash
# Agent claims the task (1 hour TTL)
warrant lease acquire PRJ-42 agent-1 3600

# Agent does its work...

# Agent releases when done
warrant lease release PRJ-42 agent-1
```

If the agent crashes or hangs, the lease expires after the TTL. Another agent can pick up the task. No manual intervention needed.

Lease conflicts return HTTP 409:
```json
{"error": "conflict", "current_owner": "agent-2", "expires_at": "2026-03-19T15:00:00Z"}
```

### 4. Verify at merge

When the agent's PR is merged (by a human reviewer or CI):

- The GitHub webhook fires
- The warrant server creates a warrant object automatically
- The warrant binds the agent's commits to the original intent
- The hash chain records the merge

The human reviewer approves the code. The warrant records that approval.

## Agent framework integration

### CLAUDE.md / configuration

Add warrant rules to the agent's configuration file:

```markdown
## Warrant Workflow

1. Read task files from .warrant/tasks/ or backlog/tasks/ before starting work
2. Start every commit message with the task ID: PRJ-42: description
3. Do not commit without a task file for the referenced ID
4. Use warrant lease acquire/release when working from a shared backlog
```

Claude Code, Cursor, and similar tools read these instructions and follow them.

### MCP integration

The warrant server exposes an MCP-compatible API. Agents with MCP support can:

- List open tasks
- Read task details (intent, decision, status)
- Acquire and release leases
- Check warrant coverage

### Programmatic access

For custom agent frameworks:

```bash
# List tasks
curl -s http://warrant-server:8090/api/v1/orgs/ORG/projects/PRJ/tasks \
  -H "Authorization: Bearer TOKEN"

# Get a specific task
curl -s http://warrant-server:8090/api/v1/orgs/ORG/projects/PRJ/tasks/PRJ-42/trace \
  -H "Authorization: Bearer TOKEN"

# Acquire a lease
curl -s -X POST http://warrant-server:8090/api/leases/acquire \
  -H "Authorization: Bearer TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"org":"ORG","project":"PRJ","task_id":"PRJ-42","owner":"agent-1","ttl_seconds":3600}'
```

## What this gives you

Without warrants, an AI agent's work looks like:

```
commit abc1234: add retry logic
commit def5678: fix test
```

No one knows why. The chat session is gone. The agent cannot be asked.

With warrants:

```
commit abc1234: PRJ-42: add retry with exponential backoff
commit def5678: PRJ-42: fix retry test edge case
```

```bash
warrant trace PRJ-42
# > Intent: Users get 401 errors after sessions longer than 1 hour
# > Decision: Retry with exponential backoff
# > Merged: PR #17, reviewed by alice
# > Warrant: a7f3b2c8... (content-addressed)
```

The code is explainable. The intent is preserved. The approval is recorded.

## Coverage reporting

To measure how well agents follow the warrant convention:

```bash
warrant blame src/
```

This shows what percentage of lines in the codebase trace to a warranted commit. Lines from commits without task IDs are flagged.

A team can set a coverage target (e.g., 95%) and track it over time. Agent-generated code that bypasses warrants shows up as coverage gaps.
