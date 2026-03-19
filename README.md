# Warrant

**No code reaches main without an explanation.**

A warrant is a verifiable decision object that binds *why* a change was made to *what* actually landed. It connects intent to code, through merge, with an audit trail.

```
Intent (task, issue, decision)
   ↓
Code (branch, commits, PR)
   ↓
Warrant (created at merge — binds intent + code + authorization)
   ↓
Main (every commit traceable to a warrant)
```

---

## Three problems, one model

### 1. Developers: "Why does this code look like this?"

Six months from now, someone reads a function and asks *why*. The commit message says what changed. The PR is closed. The Jira ticket is archived or deleted.

With warrants, the answer is in the repo:

```bash
git blame src/auth.erl
# > abc1234  AUR-42: add retry with exponential backoff

warrant trace AUR-42
```

```
AUR-42: Fix token refresh
  Intent:   Users get 401 errors after sessions longer than 1 hour
  Decision: Retry with exponential backoff — simpler than refresh, covers network failures too

  Commits:
    abc1234 AUR-42: add retry with exponential backoff
    def5678 AUR-42: add backoff tests

  Merged: PR #17 by erik, reviewed by alice
  Warrant: a7f3b2c8...  (content-addressed, tamper-evident)
```

Every line traces to intent. Intent lives in the repo, not in a separate system that can go away.

### 2. AI development: "What happened and why?"

AI coding agents need structured context. They read code, but they cannot read the team's memory. When an agent picks up a task, it needs to know what was decided and why. When it finishes, the system needs to verify what it did.

Warrants give agents the same traceability humans get:

- **Read intent** from task files or issues before writing code
- **Reference the warrant** in every commit so the change is explainable
- **Coordinate** through leases — if an agent crashes, its lock expires, another picks up the work
- **Verify at merge** — a warrant is created automatically, binding the agent's commits to the original intent

No hidden state. No chat logs to parse. The warrant is the machine-readable explanation of what happened and why.

### 3. Compliance: "Prove this change was authorized"

Regulated environments need change management with audit trails. Who requested the change? Who approved it? What exactly was merged? Can you prove it hasn't been tampered with?

Warrants are designed for this:

- **Content-addressed IDs** — the warrant ID is `sha256(canonical_content)`. Any modification produces a different ID. The ID *is* the integrity proof.
- **Append-only hash chain** — commits are notarized in sequence. Rewriting history breaks the chain, and the break is detectable.
- **Merge-time creation** — the warrant captures reviewers, approvals, and exact commit SHAs at the moment code enters the protected branch.
- **No external dependency** — intent, decisions, and audit history live in git. The repo is the audit trail.

```
warrant verify
# > Server chain: VALID (142 entries)
# > All commits verified against local git history
# > No rewritten or missing commits detected
```

---

## What is a warrant?

A warrant is a first-class object, not a ticket number.

| Field | What it captures |
|-------|-----------------|
| **Intent sources** | The tasks, issues, or decisions that motivated the change |
| **Merged code** | Commit SHAs, PR, target branch |
| **Authorization** | Who merged, who reviewed, who approved |
| **Warrant ID** | `sha256(canonical_content)` — deterministic, tamper-evident |
| **Timestamp** | When the change reached the protected branch |

A warrant is created at merge time because that is when we know what actually landed. Intent can exist before code (as a task or issue). The warrant binds intent to the accepted change after review.

### Intent sources are not warrants

A backlog task, a GitHub issue, a design decision — these are **intent sources**. They describe what should happen and why. They exist before code.

The warrant is created later, when code is merged, and it references those intent sources. This separation matters:

- Intent can change during development
- Multiple intent sources can converge into one change
- The warrant captures the final state, not the plan

---

## How it works

### Day-to-day flow

```bash
# 1. Create a task (intent source)
warrant task create "Fix token refresh" \
  --intent "Users get 401 errors after sessions longer than 1 hour"

# 2. Start work (creates branch)
warrant task start AUR-42

# 3. Work and commit (reference the task)
git commit -m "AUR-42: add retry with exponential backoff"

# 4. Merge (warrant is created at merge time)
warrant merge task/AUR-42-fix-token-refresh
```

The merge creates a `--no-ff` merge commit and a warrant object that binds the task intent to the merged commits.

### Task files live in the repo

```markdown
---
id: AUR-42
title: Fix token refresh
status: done
priority: high
labels: [bug, auth]
---

## Intent

Users get 401 errors after sessions longer than 1 hour.

## Decision

Retry with exponential backoff. Simpler than token refresh,
covers more failure modes.
```

Git history on this file is the audit trail. No external database needed.

### Three layers of why

| Layer | Question | Where it lives |
|-------|----------|---------------|
| **Intent** | Why does this task exist? | Task file or issue |
| **Decision** | Why this approach? | Task file |
| **Audit** | Who did what, when? | Git history + warrant object |

---

## Content-addressed warrant IDs

Warrant IDs are not sequential numbers. They are hashes of the warrant content:

```
warrant_id = sha256(canonical_json)
```

This means:

- **No central allocator** — any developer or agent can work offline
- **Deterministic** — same content always produces the same ID
- **Tamper-evident** — changing any field produces a different ID
- **Self-verifying** — recompute the hash to verify integrity

The canonical JSON has sorted keys, sorted arrays, no nulls, and a schema version field. Same inputs, same bytes, same hash. Always.

---

## Intent source plugins

Warrant does not care where intent lives. It reads intent from pluggable sources:

| Source | What it reads |
|--------|--------------|
| **Task files** | `.warrant/tasks/*.md` or `backlog/tasks/*.md` in your repo |
| **GitHub Issues** | Issue number, title, body, labels, author via API or webhook |
| *Future* | Jira, Linear, plain text, anything with a stable reference |

At merge time, warrant extracts references from branch names, commit messages, and PR body, then resolves them through the appropriate plugin. The warrant records what was found.

---

## The server is optional

The repo is always the source of truth. The server adds coordination features for teams and agents:

- **ID allocation** — monotonic counters, no collisions across agents
- **Status CAS** — compare-and-swap prevents race conditions on task transitions
- **Leases** — exclusive locks with TTL, crashed agents auto-release
- **Hash chain** — append-only notarization of commits for compliance verification
- **Web UI** — Kanban board and trace view

You can use warrant with just task files and commit conventions. No server needed.

---

## Getting started

### CLI

```bash
# Download a release
curl -L https://github.com/happi/warrant/releases/latest -o warrant-cli.tar.gz
tar xzf warrant-cli.tar.gz -C ~/.warrant-cli
export PATH="$HOME/.warrant-cli/bin:$PATH"

# Or clone and use directly
git clone https://github.com/happi/warrant.git
export PATH="$PWD/warrant/client/bin:$PATH"

# Initialize in your project
cd your-project
warrant init PRJ
```

### VS Code extension

Download `warrants-*.vsix` from [releases](https://github.com/happi/warrant/releases):

```bash
code --install-extension warrants-v0.3.0.vsix
```

Shows current task in the sidebar, inline blame annotations with task IDs, and trace view. Activates when it finds `.warrant/config.yaml` or `backlog/config.yml`.

### Server (optional)

```bash
cd warrant/server
rebar3 compile
rebar3 shell    # starts on port 8090
```

Or with Docker:

```bash
docker build -t warrant-server server/
docker run -p 8090:8090 -v /data:/data warrant-server
```

---

## Project structure

```
warrant/
  client/          CLI (bash), git hooks, CI integration
  server/          Erlang/OTP server (optional)
  vscode/          VS Code extension (TypeScript)
  backlog/         Warrant's own task tracking
```

See [server/docs/](server/docs/) for architecture, API reference, and design notes.

## License

MIT
