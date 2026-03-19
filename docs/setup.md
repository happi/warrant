# Setup Guide

How to set up warrant enforcement in different environments.

## Solo developer (local only)

Minimum setup. No server needed. Tasks and audit trail live in git.

```bash
cd your-project
warrant init PRJ
install-hooks
```

This creates:
- `.warrant/config.yaml` with your prefix
- `.warrant/tasks/` directory
- Git hooks: `commit-msg` (blocks commits without task ID), `pre-push` (blocks pushes to main without task IDs)
- `merge.ff = false` (forces merge commits)

Workflow:
```bash
warrant task create "Fix the bug" --intent "Users see 500 on login"
warrant task start PRJ-1
git commit -m "PRJ-1: fix null check in auth handler"
git checkout main
warrant merge task/PRJ-1-fix-the-bug
```

`warrant merge` does the merge, marks the task done, and deletes the branch.

Traceability comes from `git log` and `git blame`. The task files are the audit trail. No server, no database.

## Team with GitHub PRs

Standard GitHub workflow. Developers use git and GitHub as normal. Warrants are created automatically on PR merge.

### Step 1: Initialize the repo

```bash
warrant init PRJ
install-hooks
git add .warrant/ && git commit -m "PRJ-1: add warrant configuration"
git push
```

Every developer who clones the repo needs to run `install-hooks` once. Add it to the contributing guide or a setup script.

### Step 2: Add the CI check

```bash
warrant setup-github
git add .github/workflows/warrant.yml
git commit -m "PRJ-2: add warrant CI check"
git push
```

This adds a GitHub Actions workflow that checks every PR for task IDs in commit messages. PRs with missing task IDs fail the check.

### Step 3: Enable branch protection

Go to the repo on GitHub: Settings > Branches > Add rule.

- Branch name pattern: `main`
- Require status checks to pass before merging: enable
- Status checks that are required: add "Warrant convention check"
- Require a pull request before merging: enable
- Require approvals: set to 1 or more
- Do not allow bypassing the above settings: enable

This prevents anyone from pushing directly to main or merging a PR without passing the warrant check.

### Step 4: Set up the webhook (optional, recommended)

The webhook makes the server create a warrant object automatically when a PR is merged.

```bash
warrant setup-webhook
```

Then in GitHub: Settings > Webhooks > Add webhook.

- Payload URL: `https://your-warrant-server/webhooks/github`
- Content type: `application/json`
- Secret: shown by `setup-webhook`
- Events: Pull requests, Pushes

With the webhook, every merged PR produces a content-addressed warrant object with the PR metadata, commit SHAs, reviewers, and linked intent sources.

Without the webhook, traceability still works through task files, commit messages, and the hash chain. The warrant objects add structured query support.

### What developers do

Nothing new. The only change to their workflow:

1. Create a task (or reference an existing GitHub issue)
2. Start commit messages with the task ID: `PRJ-42: fix the thing`
3. Open a PR, get it reviewed, merge

The commit-msg hook catches missing task IDs at commit time. The CI check catches them at PR time. The webhook creates the warrant at merge time.

## CI-only enforcement (no server)

For teams that do not want to run a warrant server. All enforcement happens through GitHub Actions and branch protection.

Follow steps 1-3 from the team setup above. Skip step 4 (no webhook).

Traceability:
- Task files in the repo are the intent sources
- Commit messages reference task IDs
- `git blame` and `warrant trace` reconstruct the audit trail
- `warrant release-notes` generates release notes from warrants

Missing compared to full setup:
- No content-addressed warrant objects (traceability is still there, through git)
- No hash chain verification
- No lease coordination for agents

## Regulated environment (full compliance)

For fintech, healthcare, or any context where you need to prove change authorization.

Follow all steps from the team setup. Then add:

### Hash chain recording

The hash chain notarizes every commit on the protected branch. It is an append-only ledger. Rewriting history (force push, rebase) breaks the chain and the break is detectable.

The post-push hook records commits automatically when pushing to the protected branch. For GitHub-only workflows (no local push to main), the webhook handles recording.

Verify the chain:
```bash
warrant verify
```

Output:
```
Server chain: VALID (142 entries)
All commits verified against local git history
No rewritten or missing commits detected
```

If someone force-pushed or amended a recorded commit:
```
Server chain: VALID (142 entries)
  MISSING  abc1234: PRJ-42: fix auth handler
           This commit was recorded but is not in git history.
           Possible force-push or rebase after recording.
```

### Content-addressed warrant IDs

Every warrant ID is `sha256(canonical_content)`. The ID is the integrity proof. Changing any field (commits, reviewers, timestamps) produces a different ID.

To verify a warrant has not been tampered with:
1. Retrieve the warrant and its canonical content from the server
2. Recompute `sha256(canonical_content)`
3. Compare with the stored warrant ID

If they match, the warrant is authentic. No signatures or certificates needed.

### Deployment audit

To answer "what warrants are included in this deployment":

```bash
# List commits between two releases
git log --oneline v0.2.0..v0.3.0

# Generate release notes with warrant references
warrant release-notes --since v0.2.0
```

Every commit in the range maps to a task ID. Every task ID maps to an intent source. Every merged PR has a warrant object.

### Lease coordination for agents

If AI agents or CI bots modify code, use leases to prevent conflicts:

```bash
warrant lease acquire PRJ-42 agent-1 3600   # lock for 1 hour
# ... agent does work ...
warrant lease release PRJ-42 agent-1
```

If agent-1 crashes, the lease expires after the TTL. Another agent can pick up the task.

## Environment comparison

| Feature | Solo | Team (GitHub) | CI-only | Regulated |
|---------|------|---------------|---------|-----------|
| Task files in repo | yes | yes | yes | yes |
| commit-msg hook | yes | yes | yes | yes |
| pre-push hook | yes | yes | yes | yes |
| CI status check | no | yes | yes | yes |
| Branch protection | no | yes | yes | yes |
| Webhook (auto-warrant) | no | yes | no | yes |
| Hash chain | no | optional | no | yes |
| Warrant objects | local | auto | no | auto |
| Lease coordination | no | optional | no | yes |
| `warrant verify` | no | optional | no | yes |
