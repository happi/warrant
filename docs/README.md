# Documentation

## Guides

- [Setup Guide](setup.md). How to configure warrant enforcement for solo, team, CI-only, and regulated environments.
- [Audit Trail Walkthrough](audit-trail.md). How to produce, query, and verify an audit trail. Includes scenarios for compliance audits and incident investigation.
- [AI Agent Integration](ai-agents.md). How AI coding agents read intent, reference warrants, coordinate through leases, and produce traceable code.

## Server documentation

The server-specific docs are in [server/docs/](../server/docs/):

- [Design: Warrant Object Model](../server/docs/design-warrant-model.md). Intent sources, content-addressed IDs, merge-time creation, canonical serialization.
- [API Reference](../server/docs/API.md). HTTP endpoints for tasks, leases, hash chain, webhooks.
- [Architecture](../server/docs/ARCHITECTURE.md). Server components and data flow.
- [Data Model](../server/docs/DATA_MODEL.md). Database schema and migrations.
