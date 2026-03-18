# Warrant — Project Setup Guide

## Prerequisites

1. A running Warrant server
2. `curl` and `jq` installed
3. An organization and user account on the server

## Step 1: Get Your Credentials

If your organization already exists, ask an admin for:
- Organization slug
- Your API token

If you're setting up a new organization, use `warrant-setup` (see Step 3).

## Step 2: Configure Environment

```bash
cp .env.example .env
```

Edit `.env`:

```bash
WARRANT_URL=https://ledger.example.com  # Your server URL
WARRANT_ORG=acme                         # Organization slug
WARRANT_PROJECT=backend                  # Project slug
WARRANT_TOKEN=cl_xxxx                    # Your API token
WARRANT_PREFIX=BE                        # Task ID prefix
```

Source it in your shell (or add to your `.bashrc`/`.zshrc`):

```bash
source /path/to/warrant-client/.env
```

## Step 3: Register Your Project

For first-time setup (creates org + project + user):

```bash
./bin/warrant-setup
```

This will:
1. Create the organization (if it doesn't exist)
2. Create the project with your prefix
3. Create a user and print the API token
4. Update your `.env` with the token

For adding a project to an existing org:

```bash
./bin/warrant-setup --project-only
```

## Step 4: Install Git Hooks

```bash
./bin/install-hooks
```

This installs:
- **commit-msg** hook: Ensures every commit message starts with a task ID (e.g., `BE-42: ...`)
- **pre-push** hook: Warns if any commits in the push don't reference a task

To skip the hook for a specific commit (rare — e.g., merge commits):

```bash
git commit --no-verify -m "Merge branch 'main'"
```

## Step 5: Daily Workflow

### Create a task

```bash
./bin/warrant task create "Fix token refresh" \
  --intent "Users get 401 on long sessions" \
  --priority high \
  --labels bug,auth
```

Output: `Created task BE-47`

### Start work

```bash
# Create branch with task ID
git checkout -b task/BE-47-fix-token-refresh

# Claim the task
./bin/warrant task start BE-47
```

### Commit with task ID

```bash
git commit -m "BE-47: Fix token refresh logic"
# The commit-msg hook verifies the task ID is present
```

### Link artifacts

```bash
# Link the branch (automatic if using task/* branch naming)
./bin/warrant link branch BE-47 task/BE-47-fix-token-refresh

# Link commits (or use ledger-scan-commits)
./bin/warrant link commit BE-47 abc123

# Link a PR
./bin/ledger-link-pr BE-47 17 https://github.com/acme/backend/pull/17
```

### Complete the task

```bash
./bin/warrant task review BE-47   # Move to in_review
./bin/warrant task done BE-47     # Move to done (after merge)
```

### Check trace

```bash
./bin/warrant trace BE-47
```

## Step 6: CI Integration (Optional)

### GitHub Actions

Copy `ci/github-action.yml` to `.github/workflows/warrant.yml` in your project.

This automatically:
- Validates commit messages contain task IDs
- Links commits and PRs to tasks
- Updates task status on PR merge

### Manual CI

Add to your CI pipeline:

```bash
# After PR merge
./bin/ledger-scan-commits --since "last-deploy" --auto-link
```

## Troubleshooting

### "Task not found"

Check that:
- Your `WARRANT_ORG` and `WARRANT_PROJECT` are correct
- The task ID prefix matches your project prefix
- The task was created on the correct server

### "Conflict: expected status X but found Y"

Another developer or agent changed the task status. Fetch the current state:

```bash
./bin/warrant task get BE-47
```

Then transition from the actual current status.

### Hook rejects commit

The commit message must start with a task ID: `XX-NNN: description`

If you need to bypass (e.g., initial commit, merge):
```bash
git commit --no-verify -m "Initial commit"
```
