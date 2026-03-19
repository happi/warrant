---
id: W-30
title: Add integration test for full warrant lifecycle
status: Done
assignee: []
created_date: '2026-03-19 14:50'
updated_date: '2026-03-19 14:54'
labels:
  - testing
  - client
dependencies: []
priority: medium
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
No end-to-end test proves that the CLI, server, and git conventions work together. A shell script that starts the server, creates a task via CLI, transitions status, links a commit, reads the trace, and verifies each step. Run in CI.
<!-- SECTION:DESCRIPTION:END -->
