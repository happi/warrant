# Warrant

Warrant creates an immutable record of why each code change exists. It links intent, code, and authorization at the moment of merge.

Git tells you what changed. It does not tell you why it was allowed. In regulated systems, that gap becomes a liability. With AI-generated code, it becomes a black hole.

A warrant closes the gap.

---

## The moment of pain

Production incident. Someone asks: why was this retry logic added last month?

Without warrant:

```
grep through commits
read closed PRs
search for a Jira ticket that may or may not still exist
ask on Slack if anyone remembers
```

With warrant:

```bash
warrant why abc1234
```

```
abc1234 AUR-42: add retry with exponential backoff
  Author: erik
  Date:   2026-03-18
  Task:   AUR-42

  Intent:
    Users get 401 errors after sessions longer than 1 hour.

  Decision:
    Retry with exponential backoff. Simpler than token refresh,
    covers network failures too.
```

Five seconds. The answer lives in the repo, not in someone's memory.

---

## A warrant is created when code becomes reality

Not before. Not during. At merge.

Before merge, you have intent: a task, an issue, a decision. During development, you have code: branches, commits, a PR. At merge, warrant binds them together into a single verifiable object.

This is deliberate. Before merge, we do not know what will land. The code might change during review. Commits might be squashed. The warrant captures what actually happened.

```
Intent (task, issue, decision)
   |
Code (branch, commits, PR)
   |
Warrant (created at merge, binds intent + code + authorization)
   |
Main (every commit traceable to a warrant)
```

A task is not a warrant. A PR is not a warrant. A warrant is the decision record created when reviewed code enters the protected branch.

---

## Try it (5 minutes)

One repo, one task, one PR, one warrant, one query.

```bash
# Install
git clone https://github.com/happi/warrant.git
export PATH="$PWD/warrant/client/bin:$PATH"

# Set up a project
mkdir my-project && cd my-project
git init
warrant init PRJ
install-hooks

# Create a task (this is the intent)
warrant task create "Fix login timeout" \
  --intent "Users get logged out after 30 minutes of inactivity"
# > Created .warrant/tasks/PRJ-1.md

# Work on it
warrant task start PRJ-1
# > Created branch: task/PRJ-1-fix-login-timeout

echo "session_timeout = 3600" > config.py
git add config.py .warrant/
git commit -m "PRJ-1: increase session timeout to 1 hour"

# Land it
git checkout main
warrant merge task/PRJ-1-fix-login-timeout
# > Merged with warrant PRJ-1
# > Marked PRJ-1 as done
# > Deleted branch

# Query it
warrant why HEAD
# > PRJ-1: increase session timeout to 1 hour
# > Intent: Users get logged out after 30 minutes of inactivity

warrant trace PRJ-1
# > PRJ-1: Fix login timeout
# >   Intent: Users get logged out after 30 minutes of inactivity
# >   Commits: abc1234 PRJ-1: increase session timeout to 1 hour
# >   Status: done

warrant blame config.py
# > Warrant coverage: 1/1 lines (100%)
```

Every line in the repo traces to a warrant. Every warrant traces to an intent.

---

## Three use cases

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
  Warrant: a7f3b2c8...
```

Every line traces to intent. Intent lives in the repo, not in a separate system that can go away.

### 2. AI agents: structured context in, verifiable output out

AI coding agents generate code without understanding why it exists. The chat session disappears. Six months later, no one can explain the change.

Warrants give agents the same traceability humans get:

- Read intent from task files before writing code
- Reference the task in every commit (the hook enforces this)
- Coordinate through leases (crashed agent, lock expires, another picks up)
- At merge, the warrant is created automatically

The warrant is the machine-readable explanation of what an agent did and why.

### 3. Compliance: prove every change was authorized

Who requested this change? Who approved it? What exactly was merged? Can you prove nothing was tampered with?

- **Content-addressed IDs.** The warrant ID is `sha256(canonical_content)`. The ID is the integrity proof.
- **Append-only hash chain.** Commits are notarized in sequence. Rewriting history breaks the chain. The break is detectable.
- **Merge-time creation.** The warrant captures reviewers, approvals, and exact commit SHAs at the moment code enters the protected branch.

```bash
warrant verify
# > Server chain: VALID (142 entries)
# > All commits verified against local git history
# > No rewritten or missing commits detected
```

---

## How it works

### GitHub PR workflow (most teams)

Normal GitHub flow. No new steps for the developer.

```
1. Create a task or issue (the intent)
2. Branch and commit (hook enforces task ID in each commit message)
3. Push and open a PR
4. CI check blocks merge if any commit lacks a task ID
5. Reviewer approves, developer clicks Merge
6. Webhook fires, server creates the warrant automatically
```

The developer never runs a warrant command. The commit-msg hook is the only thing they notice.

### Local workflow (solo, offline)

```bash
warrant task start PRJ-42
git commit -m "PRJ-42: fix the thing"
git checkout main
warrant merge task/PRJ-42-fix-the-thing
```

`warrant merge` does everything: verifies commits, merges `--no-ff`, marks the task done, records to the hash chain, deletes the branch.

### Enforcement

| Layer | What it does | Bypassable? |
|-------|-------------|-------------|
| **commit-msg hook** | Blocks commits without a task ID | `--no-verify` |
| **pre-push hook** | Blocks pushes to main without task IDs | `--no-verify` |
| **CI status check** | Blocks PR merge if commits lack task IDs | Repo admin |
| **Branch protection** | Requires CI + review to merge to main | Repo admin |
| **Webhook** | Creates warrant when PR is merged | Disable webhook |
| **Hash chain** | Detects history rewriting and gaps | Cannot hide from `warrant verify` |

You can bypass any single layer. The hash chain sees everything.

The intended policy: **no warrant, no merge.** This is enforceable through branch protection + CI checks. The warrant system provides the tools. The team decides how strict to be.

---

## Design decisions

### Why merge-time creation?

A warrant represents what actually happened. Before merge, we do not know what will land. The PR might change during review. Commits might be squashed or amended. By creating the warrant at merge time, we capture the final state: the exact commits that entered main, the reviewers who approved them, and the intent that motivated the work.

### Why content-addressed IDs?

Sequential IDs (W-1, W-2, ...) require a central counter. That means online coordination, race conditions, and a single point of failure. Content-addressed IDs are computed locally from the warrant content. No network needed. Same content always produces the same ID. Any tampering produces a different ID. The ID is the integrity proof, not just a label.

### Why not replace Jira / GitHub Issues / Linear?

Warrant is not a ticket system. It does not manage task assignments, sprint planning, or kanban boards. Those tools handle pre-work coordination. Warrant handles post-merge traceability. They are complementary. Warrant reads intent from whatever system you already use (task files, GitHub Issues, or future plugins) and creates a verifiable record at merge time.

### Why task IDs in commit messages?

This is the simplest convention that works everywhere. No special tooling needed. Any git client, any CI system, any code review tool can read a commit message. The task ID is the link between a commit and its intent. The commit-msg hook enforces it automatically.

---

## What is a warrant?

A first-class decision object with these fields:

| Field | What it captures |
|-------|-----------------|
| **Intent sources** | Tasks, issues, or decisions that motivated the change |
| **Merged code** | Commit SHAs, PR, target branch |
| **Authorization** | Who merged, who reviewed, who approved |
| **Warrant ID** | `sha256(canonical_content)`, deterministic, tamper-evident |
| **Timestamp** | When the change reached the protected branch |

Intent sources are not warrants. A task describes what should happen. A warrant records what did happen. The separation matters because intent changes during development, multiple sources can converge into one change, and the warrant captures the final state.

---

## Getting started

### CLI

```bash
# Clone and use directly
git clone https://github.com/happi/warrant.git
export PATH="$PWD/warrant/client/bin:$PATH"

# Initialize in your project
cd your-project
warrant init PRJ
install-hooks
```

### VS Code extension

Download `warrants-*.vsix` from [releases](https://github.com/happi/warrant/releases):

```bash
code --install-extension warrants-v0.3.0.vsix
```

Current task in the sidebar, inline blame annotations, trace view. Toggle annotations with `Ctrl+Shift+P` > "Warrant: Toggle Annotations".

### Server (optional)

```bash
docker build -t warrant-server server/
docker run -p 8090:8090 -v /data:/data warrant-server
```

Needed for: hash chain, lease coordination, content-addressed warrant objects, web UI. Not needed for: task files, commit hooks, CI checks, trace, blame.

---

## Documentation

- [Setup Guide](docs/setup.md). Solo, team, CI-only, and regulated environment configurations.
- [Audit Trail Walkthrough](docs/audit-trail.md). Producing, querying, and verifying an audit trail.
- [AI Agent Integration](docs/ai-agents.md). How agents read intent, coordinate, and produce traceable code.
- [Server docs](server/docs/). Architecture, API reference, data model, design notes.

## License

MIT
