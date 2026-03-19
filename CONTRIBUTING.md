# Contributing to Warrant

## The Rule

Every change must have a warrant.

A warrant is a task file in `.warrant/tasks/` with an ID, intent, and decision.
Every commit message starts with the task ID. No exceptions.

## Conventions

### Commits

```
W-42: short description of what changed
```

The task ID must be the first thing in the commit message.
The git hooks in `client/hooks/` enforce this.

### Branches

```
task/W-42-short-description
```

### Task files

```
.warrant/tasks/W-42.md
```

Markdown with YAML frontmatter. See any existing task file for the format.

### PRs

Reference the task ID in the title. Include the intent in the body.

## Task prefix

This project uses prefix `W`. IDs are allocated from the warrant server to ensure uniqueness.

## Branch

`main`. Not `master`.

## Building

```bash
# Server (Erlang/OTP)
cd server && rebar3 compile

# VS Code extension
cd vscode && npm ci && npm run compile

# Client has no build step (bash scripts)
```

## CLI Commands

```bash
warrant init [--backlog] [PREFIX]   # Initialize warrant in a repo
warrant task create|get|list|start|review|done|block|archive
warrant trace TASK-ID               # Full traceability for a task
warrant board                       # Kanban board (browser or terminal)
warrant release-notes [--since TAG] [-o FILE]  # Generate release notes
warrant record [N]                  # Record commits to hash chain (server)
warrant verify                      # Verify against server chain (server)
warrant setup-github                # Install GitHub Actions workflow
warrant setup-webhook               # Configure GitHub webhook
```

## Commit hygiene

- Do not add AI attribution lines (Co-Authored-By or similar) to commits
- One warrant per logical change
- Keep commits focused. If a commit does two unrelated things, it needs two warrants.
