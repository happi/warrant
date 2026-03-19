# Warrants

**Every change needs a warrant.** See why code exists, linked to tasks, PRs, and intent.

Warrants is a VS Code extension that surfaces task traceability directly in your editor. It reads task files from your repo (`.warrant/tasks/` or `backlog/tasks/`), shows which task your current branch relates to, and lets you trace any commit back to its warrant.

## Features

- **Current Task** — detects the task ID from your branch name and shows its status, intent, and priority in the sidebar
- **Task List** — browse all open tasks from the sidebar
- **Hover** — hover over a task ID (like `W-28`) anywhere in code or commit messages to see task details
- **Inline Blame** — see which task a line was committed under, right in the editor gutter
- **Trace** — view the full traceability chain: task, commits, branches, audit trail
- **Task Actions** — start, review, and complete tasks directly from VS Code

## Quick Start

1. Install the extension
2. Open a repo that has `.warrant/config.yaml` or `backlog/config.yml`
3. Tasks appear in the Warrants sidebar automatically

No server required. The extension reads task files directly from your repo.

## How It Works

Warrants reads YAML frontmatter from markdown task files:

```yaml
---
id: W-28
title: "Publish VS Code extension"
status: in_progress
priority: high
labels: [vscode, release]
---

## Intent

Users should install with one click from the marketplace.
```

When you're on a branch like `task/W-28-publish-extension`, the extension matches the task ID and shows its details.

## Configuration

The extension auto-detects configuration from:

1. `.warrant/config.yaml` — standard warrant config
2. `backlog/config.yml` or `backlog/config.yaml` — Backlog.md config
3. VS Code settings (fallback)

### Settings

| Setting | Description |
|---------|-------------|
| `warrant.prefix` | Task ID prefix (e.g., `W`, `AUR`) |
| `warrant.blameEnabled` | Show inline task annotations from git blame (default: true) |
| `warrant.url` | Optional server URL for leases, CAS, and hash chain |
| `warrant.org` | Organization slug (server mode) |
| `warrant.project` | Project slug (server mode) |

## Server Mode (Optional)

For team features like leases (exclusive task locks), compare-and-swap status updates, and compliance hash chain recording, point the extension at a Warrant server:

```yaml
# .warrant/config.yaml
server:
  url: https://warrant.example.com
  org: myorg
  project: myproject
  token_env: WARRANT_TOKEN
```

## Links

- [Warrant on GitHub](https://github.com/happi/warrant)
- [CLI documentation](https://github.com/happi/warrant#cli)
- [Report issues](https://github.com/happi/warrant/issues)
