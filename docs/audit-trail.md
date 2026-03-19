# Audit Trail Walkthrough

How to produce, query, and verify an audit trail using warrant.

## What the audit trail contains

Every change on the protected branch is traceable through four layers:

1. **Intent.** The task or issue that explains why the change was requested.
2. **Code.** The commits and PR that implement the change.
3. **Authorization.** Who reviewed and approved. Who merged.
4. **Verification.** The hash chain proving nothing was altered after the fact.

These layers are independent. Intent lives in task files. Code lives in git. Authorization lives in the PR metadata and the warrant object. Verification lives in the hash chain on the server.

## Scenario: auditing a production change

A regulator or internal auditor asks: "Show me the change history for the authentication module between January and March 2026."

### Step 1: identify the changes

```bash
git log --oneline --after="2026-01-01" --before="2026-04-01" -- src/auth/
```

```
c387202 W-28: Auto-create warrant on GitHub PR merge via webhook
a1fa135 W-38: Warrant object model with content-addressed IDs
b7b4233 W-37: Fix cookie auth
```

Every commit references a task ID. If any commit lacks one, `warrant check` flags it.

### Step 2: trace each change to its intent

```bash
warrant trace W-28
```

```
W-28: Publish VS Code extension to marketplace
  Intent:   Users should be able to install the extension with one
            click from the VS Code marketplace.
  Status:   done

  Commits:
    c387202 W-28: Auto-create warrant on GitHub PR merge via webhook
    0c8549c W-28: Make warrant merge the single command to land code
    49051e8 W-28: Document both GitHub PR and local merge workflows
    da787e7 W-28: Rewrite README in project style

  Branches:
    (merged and deleted)

  Audit (task file history):
    2026-03-19 17:00  erik  W-28: mark done
    2026-03-19 14:49  erik  W-28: create task
```

The trace shows: who created the task, what the intent was, which commits implemented it, and when it was completed.

### Step 3: verify a specific commit

```bash
warrant why c387202
```

```
c387202 W-28: Auto-create warrant on GitHub PR merge via webhook
  Author: erik
  Date:   2026-03-19
  Task:   W-28

  W-28: Publish VS Code extension to marketplace

  Intent:
    Users should be able to install the extension with one click
    from the VS Code marketplace.
```

This answers "why does this commit exist?" with the task's intent.

### Step 4: check warrant coverage

```bash
warrant blame src/auth/
```

```
  src/auth/handler.erl: 3/45 lines unwarranted
  src/auth/token.erl: 0/120 lines unwarranted

Warrant coverage: 162/165 lines (98%)

Unwarranted commits:
  b7b4233 Fix cookie auth: use authenticate_token/1 instead of faking request header
```

This shows that 98% of lines in the auth module trace to a warrant. Three lines come from a commit that was later covered retroactively by W-37.

### Step 5: verify chain integrity

```bash
warrant verify
```

```
Server chain: VALID (49 entries)
All commits verified against local git history
No rewritten or missing commits detected
```

This proves:
- Every commit on main was recorded to the hash chain.
- No recorded commit has been rewritten or removed from git history.
- The chain itself has not been tampered with (each entry hashes the previous one).

If someone force-pushed to rewrite history:

```
Server chain: VALID (49 entries)
  MISSING  abc1234: W-42: fix auth handler
           This commit was recorded but is not in git history.
           Possible force-push or rebase after recording.
```

### Step 6: generate a report

```bash
warrant release-notes --since v0.2.0 -o audit-report.md
```

This produces a markdown report listing every completed warrant and its commits between two release tags. Useful for periodic compliance reviews.

## Scenario: investigating an incident

Production broke after a deploy. The team needs to know what changed, why, and who approved it.

### What changed?

```bash
# Compare the two deploy tags
git log --oneline v0.2.0..v0.3.0
```

### Why was each change made?

```bash
# For each task ID in the output
warrant trace W-28
warrant trace W-35
warrant trace W-38
```

### Who approved it?

With the webhook and warrant objects, each warrant records the PR reviewers and who clicked Merge:

```
Warrant: a7f3b2c8...
  Summary:   W-28: Publish VS Code extension to marketplace
  PR:        #17
  Merged by: erik
  Reviewed:  alice
  Commits:   c387202, 0c8549c, 49051e8, da787e7
  Merged at: 2026-03-19T17:00:00Z
```

Without the server, the PR metadata is still on GitHub. The commit messages and task files provide the same answers, with more manual lookup.

## What to show an auditor

For a compliance audit, produce:

1. **`warrant release-notes --since <last-audit-tag>`** for the full list of changes with intent.
2. **`warrant verify`** to prove chain integrity.
3. **`warrant blame <critical-module>`** to show warrant coverage of sensitive code.
4. **`warrant trace <task-id>`** for any specific change the auditor wants to drill into.
5. The GitHub PR history for reviewer approvals (or the warrant objects if using the server).

The task files, commit messages, and hash chain are all in git or on the warrant server. Nothing depends on an external ticket system being available.

## Data retention

- **Task files**: committed to git. Retained as long as git history exists.
- **Commit messages**: part of git history. Retained as long as git history exists.
- **Hash chain**: stored on the warrant server's SQLite database. Back up `/data/ledger.db`.
- **Warrant objects**: stored on the warrant server's SQLite database. Same backup.
- **PR metadata**: on GitHub. Subject to GitHub's retention policies. The warrant object captures the relevant fields at merge time so the audit trail survives if the PR is deleted.
