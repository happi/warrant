# Warrant

No code reaches main without an explanation.

A warrant is a verifiable decision object. It binds the reason a change was made to the code that landed. Intent, code, authorization, and audit trail in one place.

```
Intent (task, issue, decision)
   |
Code (branch, commits, PR)
   |
Warrant (created at merge, binds intent + code + authorization)
   |
Main (every commit traceable to a warrant)
```

---

## Three problems, one model

### 1. Developers: why does this code look like this?

Six months from now, someone reads a function and asks why. The commit message says what changed. The PR is closed. The Jira ticket is archived or deleted.

With warrants, the answer is in the repo:

```bash
git blame src/auth.erl
# > abc1234  AUR-42: add retry with exponential backoff

warrant trace AUR-42
```

```
AUR-42: Fix token refresh
  Intent:   Users get 401 errors after sessions longer than 1 hour
  Decision: Retry with exponential backoff. Simpler than refresh,
            covers network failures too.

  Commits:
    abc1234 AUR-42: add retry with exponential backoff
    def5678 AUR-42: add backoff tests

  Merged: PR #17 by erik, reviewed by alice
  Warrant: a7f3b2c8...  (content-addressed, tamper-evident)
```

Every line traces to intent. Intent lives in the repo, not in a separate system that can go away.

### 2. AI development: what happened and why?

AI coding agents need structured context. They read code. They cannot read the team's memory. When an agent picks up a task, it needs to know what was decided and why. When it finishes, the system needs to verify what it did.

Warrants give agents the same traceability humans get:

- Read intent from task files or issues before writing code
- Reference the warrant in every commit so the change is explainable
- Coordinate through leases (if an agent crashes, its lock expires, another picks up the work)
- Verify at merge (a warrant is created automatically, binding the agent's commits to the original intent)

The warrant is the machine-readable explanation of what happened and why.

### 3. Compliance: prove this change was authorized

Regulated environments need change management with audit trails. Who requested the change? Who approved it? What exactly was merged? Can you prove nothing was tampered with?

Warrants handle this:

- **Content-addressed IDs.** The warrant ID is `sha256(canonical_content)`. Any modification produces a different ID. The ID is the integrity proof.
- **Append-only hash chain.** Commits are notarized in sequence. Rewriting history breaks the chain. The break is detectable.
- **Merge-time creation.** The warrant captures reviewers, approvals, and exact commit SHAs at the moment code enters the protected branch.
- **No external dependency.** Intent, decisions, and audit history live in git. The repo is the audit trail.

```
warrant verify
# > Server chain: VALID (142 entries)
# > All commits verified against local git history
# > No rewritten or missing commits detected
```

---

## What is a warrant?

A warrant is a first-class decision object.

| Field | What it captures |
|-------|-----------------|
| **Intent sources** | The tasks, issues, or decisions that motivated the change |
| **Merged code** | Commit SHAs, PR, target branch |
| **Authorization** | Who merged, who reviewed, who approved |
| **Warrant ID** | `sha256(canonical_content)`, deterministic, tamper-evident |
| **Timestamp** | When the change reached the protected branch |

A warrant is created at merge time. That is when we know what actually landed. Intent exists before code, as a task or issue. The warrant binds intent to the accepted change after review.

### Intent sources are not warrants

A backlog task, a GitHub issue, a design decision: these are intent sources. They describe what should happen and why. They exist before code.

The warrant is created when code is merged. It references those intent sources. This separation matters because intent can change during development, multiple intent sources can converge into one change, and the warrant captures the final state.

---

## How it works

### Two workflows, same result

#### GitHub PR workflow (teams)

Normal GitHub flow. No new steps for the developer.

```
1. Create a task or issue (the intent source)
2. Branch and commit (hooks enforce task ID in every commit message)
3. Push and open a PR
4. CI check verifies all commits have task IDs (blocks merge if not)
5. Reviewer approves, developer clicks Merge
6. GitHub webhook fires, warrant server creates the warrant automatically
```

The developer never runs a warrant command during this flow. The commit-msg hook is the only thing they notice. It requires a task ID prefix like `AUR-42:` in each commit message. Everything else happens automatically.

#### Local workflow (solo, offline)

One command to land code on the protected branch:

```bash
warrant task create "Fix token refresh" \
  --intent "Users get 401 errors after sessions longer than 1 hour"

warrant task start AUR-42
# > Created branch: task/AUR-42-fix-token-refresh

git commit -m "AUR-42: add retry with exponential backoff"
git commit -m "AUR-42: add backoff tests"

git checkout main
warrant merge task/AUR-42-fix-token-refresh
```

`warrant merge` verifies all commits have task IDs, merges `--no-ff`, marks the task done, records to the hash chain, and deletes the branch. One command.

### Enforcement

The right thing is the easy thing. Bypasses are visible.

| Layer | What it does | Bypassable? |
|-------|-------------|-------------|
| **commit-msg hook** | Blocks commits without a task ID | `--no-verify` |
| **pre-push hook** | Blocks pushes to main without task IDs | `--no-verify` |
| **CI status check** | Blocks PR merge if commits lack task IDs | Repo admin |
| **Branch protection** | Requires CI + review to merge to main | Repo admin |
| **Webhook** | Auto-creates warrant when PR is merged | Disable webhook |
| **Hash chain** | Detects rewritten history, gaps, tampering | Cannot hide from `warrant verify` |

You can bypass any single layer. The hash chain sees everything. `warrant verify` compares the server's chain against local git history and reports gaps, missing commits, and rewrites.

### Setup

```bash
warrant init AUR                  # creates .warrant/ and config
install-hooks                     # installs commit-msg, pre-push hooks
warrant setup-github              # adds CI workflow for PR checks
warrant setup-webhook             # configures GitHub webhook (needs server)
```

For GitHub branch protection, go to repo Settings > Branches > Add rule:
- Branch name pattern: `main`
- Require status checks: enable, add "Warrant convention check"
- Require pull request reviews: enable
- Do not allow bypassing: enable

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

Warrant IDs are hashes of the warrant content:

```
warrant_id = sha256(canonical_json)
```

No central allocator. Any developer or agent can work offline. Same content always produces the same ID. Changing any field produces a different ID. Recompute the hash to verify integrity.

The canonical JSON has sorted keys, sorted arrays, no nulls, and a schema version field. Same inputs, same bytes, same hash.

---

## Intent source plugins

Warrant reads intent from pluggable sources:

| Source | What it reads |
|--------|--------------|
| **Task files** | `.warrant/tasks/*.md` or `backlog/tasks/*.md` in the repo |
| **GitHub Issues** | Issue number, title, body, labels, author via API or webhook |
| *Future* | Jira, Linear, plain text, anything with a stable reference |

At merge time, warrant extracts references from branch names, commit messages, and PR body. It resolves them through the appropriate plugin and records what was found.

---

## The server is optional

The repo is the source of truth. The server adds coordination features:

- **ID allocation.** Monotonic counters, no collisions across agents.
- **Status CAS.** Compare-and-swap prevents race conditions on task transitions.
- **Leases.** Exclusive locks with TTL. Crashed agents auto-release.
- **Hash chain.** Append-only notarization of commits for compliance verification.
- **Web UI.** Kanban board and trace view.

Warrant works with task files and commit conventions alone. No server needed.

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

## Documentation

- [Setup Guide](docs/setup.md). Solo, team, CI-only, and regulated environment configurations.
- [Audit Trail Walkthrough](docs/audit-trail.md). How to produce, query, and verify an audit trail.
- [AI Agent Integration](docs/ai-agents.md). How agents read intent, coordinate, and produce traceable code.
- [Server docs](server/docs/). Architecture, API reference, data model, and design notes.

## Project structure

```
warrant/
  client/          CLI (bash), git hooks, CI integration
  server/          Erlang/OTP server (optional)
  vscode/          VS Code extension (TypeScript)
  docs/            Guides: setup, audit trail, AI agents
  backlog/         Warrant's own task tracking
```

## License

MIT
