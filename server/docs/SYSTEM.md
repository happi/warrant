# Change Ledger — System Overview

## What It Is

The Change Ledger is a **traceability service for software systems**. It provides a centralized registry of tasks (units of intended change) and links them to the Git artifacts that implement those changes: branches, commits, and pull requests.

The core question it answers:

> **Why does this code exist?**

For any commit, PR, or code change, the system traces back to the task that authorized it, the intent behind that task, and the person or agent that performed the work.

## What Problems It Solves

1. **Traceability** — In regulated or high-accountability environments, you need a chain from requirement → task → code change → review → merge. The Change Ledger provides this chain without requiring heavyweight project management tooling.

2. **Controlled ID allocation** — Task IDs must be globally unique per project, monotonically increasing, and centrally managed. Distributed ID generation leads to collisions and gaps. The service owns ID allocation.

3. **Safe state transitions** — Task status changes require the caller to declare the expected current state, preventing race conditions when multiple developers or agents work concurrently.

4. **Agent coordination** — Automated agents (CI bots, AI coding agents) need a way to claim work, signal progress, and release tasks. The leasing mechanism provides this without custom coordination protocols.

5. **Audit trail** — Every mutation (task creation, status change, lease, link) is recorded as an immutable audit event. This supports compliance requirements and post-incident investigation.

## Non-Goals

The Change Ledger is **not**:

- A project management tool (no sprints, story points, velocity)
- A Jira/Linear replacement (no boards, no drag-and-drop)
- A planning system (no estimation, no scheduling)
- A full code indexer (no AST parsing, no semantic analysis)
- A CI/CD system (no builds, no deployments)

It deliberately stays small: task registry, state machine, artifact linking, audit log.

## Core Principles

1. **Control in the core** — Task state and IDs are centrally managed by this service. No client generates IDs or manages state transitions independently.

2. **Git is the change log** — We do not replace Git. Git remains the authoritative record of what changed. We attach *intent* to Git artifacts.

3. **Markdown is a projection** — Human-readable task files (e.g., `tasks/TASK-42.md`) are generated from the service. The service owns mutable metadata (status, ID, lease). Narrative content is editable in the file.

4. **Everything is traceable** — Every code change links to a task. Every task declares intent. The chain is: task → branch → commits → PR → merged code.

5. **Keep the system small** — Every feature must improve traceability or control. If it doesn't, it doesn't ship.
