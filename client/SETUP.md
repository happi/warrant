# Warrant — Project Setup Guide

## Quick Start (local-first, no server)

```bash
# Add warrant to your PATH
export PATH="/path/to/warrant/client/bin:$PATH"

# Initialize in your project
cd your-project
warrant init PRJ

# Install git hooks (enforces task IDs in commit messages)
install-hooks

# Create your first task
warrant task create "First task" --intent "Why it matters" --priority high
```

That's it. Tasks live in `.warrant/tasks/` as markdown files. Git history is the audit trail.

## Prerequisites

- `bash` 4+ (for associative arrays in `release-notes`)
- `git`
- `jq` (optional, only needed for server features)

## Configuration

Warrant reads from `.warrant/config.yaml` (or `backlog/config.yml` in backlog mode):

```yaml
# .warrant/config.yaml
prefix: PRJ
tasks_dir: .warrant/tasks
protected_branch: main

# Server (optional — enables ID allocation, CAS, leases, hash chain)
# server:
#   url: http://localhost:8090
#   org: myorg
#   project: myproject
#   token_env: WARRANT_TOKEN
```

### Backlog mode

For projects using [Backlog.md](https://github.com/MrLesk/Backlog.md):

```bash
warrant init --backlog PRJ
```

This creates `backlog/config.yml` with title-based filenames and a completed directory. When the `backlog` CLI is installed, warrant delegates task operations to it automatically.

## Git Hooks

```bash
install-hooks
```

Installs:
- **commit-msg** — ensures every commit starts with a task ID (`PRJ-42: ...`)
- **pre-push** — warns if commits don't reference a task
- **post-push** — records commits to the compliance hash chain (requires server)

To skip for a specific commit (rare — merge commits, initial commit):

```bash
git commit --no-verify -m "Merge branch 'main'"
```

## Daily Workflow

### Create a task

```bash
warrant task create "Fix token refresh" \
  --intent "Users get 401 on long sessions" \
  --priority high \
  --labels bug,auth
# > Created .warrant/tasks/PRJ-1.md
```

### Start work (creates branch automatically)

```bash
warrant task start PRJ-1
# > Created branch: task/PRJ-1-fix-token-refresh
# > PRJ-1: open > in_progress
```

### Commit with task ID

```bash
git commit -m "PRJ-1: fix token refresh logic"
# The commit-msg hook verifies the task ID
```

### Complete the task

```bash
warrant task review PRJ-1   # in_progress > in_review
warrant task done PRJ-1     # in_review > done
```

### Check trace

```bash
warrant trace PRJ-1
```

### Generate release notes

```bash
warrant release-notes                          # since latest tag
warrant release-notes --since v0.1.0           # since specific tag
warrant release-notes -o RELEASE.md            # write to file
```

## Server Setup (optional)

Only needed for ID allocation, status CAS, leases, or the compliance hash chain.

### Get credentials

Create a `.warrant/.env` file (gitignored):

```bash
WARRANT_URL=https://ledger.example.com
WARRANT_ORG=acme
WARRANT_PROJECT=backend
WARRANT_TOKEN=cl_xxxx
```

Or set `token_env` in config.yaml to read the token from an environment variable.

### First-time setup

```bash
./bin/warrant-setup
```

Creates org, project, and user on the server.

### Hash chain commands (require server)

```bash
warrant record              # record recent commits to compliance hash chain
warrant verify              # verify repo integrity against server chain
```

## CI Integration

### GitHub Actions

```bash
warrant setup-github
```

Copies `ci/warrant-check.yml` to `.github/workflows/warrant.yml`. This validates commit messages contain task IDs on every PR.

Add `WARRANT_TOKEN` as a repository secret if using server features.

## Troubleshooting

### "No tasks directory found"

Run `warrant init PREFIX` in your project root.

### Hook rejects commit

The commit message must start with a task ID: `PRJ-NNN: description`

Bypass with `git commit --no-verify` for exceptional cases (merge commits, initial commit).

### "Task not found"

Check that the task file exists in `.warrant/tasks/` (or `backlog/tasks/` in backlog mode). If using server mode, verify `WARRANT_ORG` and `WARRANT_PROJECT` are correct.
